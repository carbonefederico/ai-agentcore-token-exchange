#!/usr/bin/env python3
"""CLI demo client: PKCE login -> invoke AgentCore -> display claims.

Never performs workload identity federation or token exchange. Tokens stay
in memory; only the agent's returned claims are displayed.
"""

import json
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import boto3
import requests

from pf_phase0_common import browser_login, load_config, require, build_urls


def main():
    config = load_config()
    region = config.get("AWS_REGION", "us-east-1").strip() or "us-east-1"
    runtime_name = config.get("AGENT_RUNTIME_NAME", "").strip()
    if not runtime_name:
        sys.exit("AGENT_RUNTIME_NAME is required in config.env (or use .env values).")
    scope = config.get("PF_EXCHANGE_SCOPE", "demo:read").strip() or "demo:read"

    # 1. User identity.
    user_token = browser_login(config)
    print("Authentication successful.")

    # 2. Resolve the runtime endpoint. AGENT_RUNTIME_NAME holds the runtime
    #    ID as reported by `agentcore status` (e.g.
    #    tokenexchangeagent_default_exchange_agent-AbCdEfGhIp).
    account = boto3.client("sts", region_name=region).get_caller_identity()["Account"]
    runtime_id = runtime_name
    runtime_arn = f"arn:aws:bedrock-agentcore:{region}:{account}:runtime/{runtime_id}"
    runtime_url = (
        f"https://bedrock-agentcore.{region}.amazonaws.com/runtimes/"
        f"{urllib.parse.quote(runtime_arn, safe='')}/invocations?qualifier=DEFAULT"
    )

    # 3. Invoke with the user JWT. SigV4 is NOT required for custom-JWT
    #    authorized runtimes; the bearer token IS the authentication.
    print("Invoking AgentCore agent...")
    resp = requests.post(
        runtime_url,
        headers={
            "Authorization": f"Bearer {user_token}",
            "Content-Type": "application/json",
        },
        data=json.dumps({"prompt": "exchange"}),
        timeout=120,
    )
    if resp.status_code != 200:
        sys.exit(f"Agent invocation failed: HTTP {resp.status_code}: {resp.text[:300]}")

    body = resp.json()
    print("Agent invoked successfully.")

    # 4. Display.
    exchange = body.get("exchange")
    claims = body.get("claims", {})
    print("AgentCore Identity:")
    print(f"  Outbound token exchange: {exchange or 'FAILED'}")
    print(f"  Authentication method:   {body.get('clientAuthentication', '<missing>')}")
    print("Exchanged PingFederate token claims:")
    print(json.dumps(claims, indent=2, sort_keys=True))

    act = claims.get("act", {})
    if exchange == "SUCCESS" and act.get("sub"):
        print("RESULT: SUCCESS")
        return 0
    print("RESULT: FAILED — see the agent logs "
          f"(log group /aws/bedrock-agentcore/{runtime_name}).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
