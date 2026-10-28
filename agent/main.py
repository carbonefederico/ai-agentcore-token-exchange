"""AgentCore hosted agent: secretless on-behalf-of token exchange via PingFederate.

Flow (see SPEC.md):
  1. AgentCore Runtime validates the inbound PingFederate user JWT
     (custom JWT authorizer) and forwards the Authorization header.
  2. Runtime supplies the workload access token via the SDK context
     (BedrockAgentCoreContext.get_workload_access_token()).
  3. The agent calls GetResourceOauth2Token with
     oauth2Flow=ON_BEHALF_OF_TOKEN_EXCHANGE; AgentCore Identity performs the
     full secretless exchange (AWS IAM identity JWT as client assertion and
     actor token; inbound user JWT as subject token).
  4. The agent decodes the exchanged token (signature NOT verified — display
     only) and returns its claims.

The agent never sees tokens' raw material outside its process, never calls
STS, never implements OAuth itself, and holds no secrets.

The LLM/tool reference code at the bottom ships DISABLED (commented out).
The goal of this demo is the secretless token exchange; that code shows how
the exchanged token would be used downstream.
"""

import json
import logging
import os

import boto3
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.runtime.context import BedrockAgentCoreContext

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("agentcore-exchange-agent")

app = BedrockAgentCoreApp()

REGION = boto3.session.Session().region_name or "us-east-1"
CREDENTIAL_PROVIDER_NAME = os.environ.get("CREDENTIAL_PROVIDER_NAME", "pingfederate-obo-poc")
EXCHANGE_SCOPES = os.environ.get("EXCHANGE_SCOPES", "demo:read").split()


def _decode_jwt_claims(token: str) -> dict:
    """Decode a JWT payload without verifying the signature. Display only."""
    import base64

    padding = "=" * (-len(token.split(".")[1]) % 4)
    payload = token.split(".")[1] + padding
    return json.loads(base64.urlsafe_b64decode(payload))


@app.entrypoint
def invoke(payload, context):
    # 1. The inbound user JWT arrives (validated by Runtime) in the
    #    Authorization header — allowlisted via requestHeaderConfiguration.
    #    It is only logged as a claim summary; the token itself is not.
    workload_access_token = BedrockAgentCoreContext.get_workload_access_token()
    if not workload_access_token:
        return {
            "error": "no_workload_access_token",
            "hint": (
                "Runtime did not supply a workload access token. Verify the "
                "runtime's inbound authorizer is customJWTAuthorizer and the "
                "invocation carried the user JWT."
            ),
        }

    # 2. The secretless OBO exchange — AgentCore Identity does everything.
    agentcore = boto3.client("bedrock-agentcore", region_name=REGION)
    resp = agentcore.get_resource_oauth2_token(
        workloadIdentityToken=workload_access_token,
        resourceCredentialProviderName=CREDENTIAL_PROVIDER_NAME,
        oauth2Flow="ON_BEHALF_OF_TOKEN_EXCHANGE",
        scopes=EXCHANGE_SCOPES,
    )
    exchanged_token = resp["accessToken"]

    # 3. Decode (not verify) the exchanged token's claims for display.
    claims = _decode_jwt_claims(exchanged_token)

    return {
        "exchange": "SUCCESS",
        "clientAuthentication": "AWS_IAM_ID_TOKEN_JWT (no client secret)",
        "actorToken": "AWS_IAM_ID_TOKEN_JWT (sts:GetWebIdentityToken)",
        "claims": claims,
    }


# ============================================================================
# DISCLAIMER — disabled on purpose.
# The goal of this demo is the secretless OAuth token exchange between
# AgentCore Identity and PingFederate. Everything above proves identity
# delegation. The code below shows how the exchanged token would be used
# downstream in a real agentic flow: the LLM invokes a tool that calls the
# protected resource with the delegated token (sub = user, act.sub = agent
# IAM role). It is NOT enabled in this demo. Enabling it requires
# bedrock:InvokeModel permissions on the agent role, a reachable downstream
# resource, and moving LLM integration out of this POC's out-of-scope list.
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
