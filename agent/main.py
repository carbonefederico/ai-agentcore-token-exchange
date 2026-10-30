"""AgentCore hosted agent: direct secretless on-behalf-of token exchange to PingFederate.

Flow (see SPEC.md):
  1. AgentCore Runtime validates the inbound PingFederate user JWT
     (custom JWT authorizer) and forwards the Authorization header.
  2. The agent calls sts:GetWebIdentityToken to obtain an AWS IAM identity
     JWT for its own workload role (no stored secret - AWS signs it).
  3. The agent POSTs the RFC 8693 exchange DIRECTLY to PingFederate:
       grant_type=token-exchange, client_id=<workload role ARN> (no client
       credentials - PF client auth is NONE), subject_token=<user JWT>,
       actor_token=<AWS identity JWT>.
  4. PF validates the actor token with AwsStsTokenProcessor (issuer + JWKS
     configured on the token processor) and issues a user-context token.

AgentCore Identity is not involved in the outbound leg (see docs/LIMITATIONS:
AgentCore's credential provider always attaches client credentials, which a
client-auth=NONE OAuth client must reject).

The LLM/tool reference code at the bottom ships DISABLED (commented out).
"""

import json
import logging
import os

import boto3
import requests
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.runtime.context import BedrockAgentCoreContext

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("agentcore-exchange-agent")

app = BedrockAgentCoreApp()

REGION = boto3.session.Session().region_name or "eu-central-1"
PF_TOKEN_URL = os.environ["PF_TOKEN_URL"]
PF_AGENT_CLIENT_ID = os.environ["PF_AGENT_CLIENT_ID"]
EXCHANGE_SCOPES = os.environ.get("EXCHANGE_SCOPES", "demo:read").split()

STS_AUDIENCE = PF_TOKEN_URL  # the exchange target doubles as the STS token audience


def _decode_jwt_claims(token: str) -> dict:
    """Decode a JWT payload without verifying the signature. Display only."""
    import base64

    padding = "=" * (-len(token.split(".")[1]) % 4)
    payload = token.split(".")[1] + padding
    return json.loads(base64.urlsafe_b64decode(payload))


def _get_aws_identity_jwt() -> str:
    """Mint a short-lived AWS IAM identity JWT via sts:GetWebIdentityToken."""
    sts = boto3.client("sts", region_name=REGION)
    resp = sts.get_web_identity_token(
        Audience=[STS_AUDIENCE],
        DurationSeconds=300,
    )
    return resp["WebIdentityToken"]


@app.entrypoint
def invoke(payload, context):
    # 1. The inbound user JWT arrives in the Authorization header
    #    (allowlisted via requestHeaderConfiguration on the runtime).
    headers = BedrockAgentCoreContext.get_request_headers() or {}
    user_token = headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if not user_token:
        return {"error": "no_user_token", "hint": "Authorization header missing from the invocation."}

    # 2. AWS-issued identity JWT for the actor role (secretless: AWS signs).
    aws_jwt = _get_aws_identity_jwt()

    # 3. Direct RFC 8693 exchange against PingFederate. Client auth is NONE:
    #    client_id identifies the client, no credentials are attached.
    resp = requests.post(
        PF_TOKEN_URL,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "client_id": PF_AGENT_CLIENT_ID,
            "subject_token": user_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "actor_token": aws_jwt,
            "actor_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "scope": " ".join(EXCHANGE_SCOPES),
        },
        timeout=30,
    )
    if resp.status_code != 200:
        logger.error("token exchange failed: HTTP %s %s", resp.status_code, resp.text[:300])
        return {
            "exchange": "FAILED",
            "status": resp.status_code,
            "error": resp.text[:300],
        }
    exchanged_token = resp.json()["access_token"]

    # 4. Decode (not verify) the exchanged token's claims for display.
    claims = _decode_jwt_claims(exchanged_token)

    return {
        "exchange": "SUCCESS",
        "clientAuthentication": "NONE (client_id only, no secret)",
        "actorToken": "AWS_IAM_ID_TOKEN_JWT (sts:GetWebIdentityToken)",
        "claims": claims,
    }


# ============================================================================
# DISCLAIMER — disabled on purpose.
# The goal of this demo is the secretless OAuth token exchange between
# the AgentCore-hosted agent and PingFederate. Everything above proves
# identity delegation. The code below shows how the exchanged token would
# be used downstream in a real agentic flow: the LLM invokes a tool that
# calls the protected resource with the delegated token (sub = user,
# act.sub = agent IAM role). It is NOT enabled in this demo. Enabling it
# requires bedrock:InvokeModel permissions on the agent role, a reachable
# downstream resource, and moving LLM integration out of this POC's
# out-of-scope list.
# ============================================================================
# import requests
# from strands import Agent, tool
#
# DEMO_API_URL = "https://demo.example.internal/resource"
#
#
# @tool
# def read_demo_resource() -> str:
#     """Reads the protected demo resource on behalf of the user."""
#     # The delegated token: sub = user, act.sub = agent IAM role ARN.
#     delegated_token = _last_exchanged_token  # captured in invoke() above
#     resp = requests.get(
#         f"{DEMO_API_URL}/things",
#         headers={"Authorization": f"Bearer {delegated_token}"},
#         timeout=10,
#     )
#     return f"HTTP {resp.status_code}: {resp.text[:200]}"
#
#
# def run_llm_stub(delegated_token: str) -> dict:
#     """One hardcoded single-turn LLM call whose tool uses the exchanged token."""
#     global _last_exchanged_token
#     _last_exchanged_token = delegated_token
#     llm = Agent(
#         model="us.anthropic.claude-sonnet-4-5-20250929-v1:0",
#         tools=[read_demo_resource],
#     )
#     result = llm("Call read_demo_resource and report the result.")
#     return {"llm_output": str(result)}
#
#
# # To enable: call run_llm_stub(exchanged_token) inside invoke() after the
# # exchange, add bedrock:InvokeModel to the agent role, and make
# # DEMO_API_URL reachable from the runtime.


if __name__ == "__main__":
    app.run()
