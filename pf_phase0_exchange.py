#!/usr/bin/env python3
"""Phase 0 exchange test: raw RFC 8693 token exchange against PingFederate.

No AgentCore involved. Proves, end to end with curl-equivalent HTTP:

  1. User login (Authorization Code + PKCE, public client).
  2. AWS IAM identity JWT via sts:GetWebIdentityToken
     (audience = PingFederate token endpoint).
  3. Secretless RFC 8693 exchange against the preconfigured TEPP:
     - the AWS JWT doubles as the RFC 7523 client assertion (no secret,
       client_id = the agent IAM role ARN) and as the actor token;
     - the PingFederate user JWT is the subject token.

Security: tokens stay in memory; only decoded claims are printed.

Usage: python3 pf_phase0_exchange.py
"""

import json
import sys

from pf_phase0_common import (
    browser_login,
    decode_jwt_claims,
    get_aws_identity_jwt,
    load_config,
    show_claims,
    token_exchange,
)


def main():
    config = load_config()

    # 1. User identity — Authorization Code + PKCE.
    user_token = browser_login(config)
    print("Authentication successful.")
    show_claims(decode_jwt_claims(user_token, "user access token"), "User token")

    # 2. Agent workload identity — AWS-issued JWT.
    print("\nRequesting AWS IAM identity JWT (sts:GetWebIdentityToken)...")
    aws_jwt = get_aws_identity_jwt(config)
    show_claims(decode_jwt_claims(aws_jwt, "AWS identity JWT"), "AWS identity JWT")

    # 3. The secretless exchange.
    print("\nExchanging tokens (RFC 8693) — client assertion + actor token "
          "= AWS JWT, no client secret...")
    resp = token_exchange(config, user_token, aws_jwt)

    if resp.status_code != 200:
        body = resp.text[:500]
        print(f"\nExchange rejected: HTTP {resp.status_code}: {body}")
        _print_hints(resp.status_code, body)
        return 1

    granted = resp.json().get("access_token", "")
    if not granted:
        print("\nExchange returned 200 but no access_token.")
        return 1

    print("Exchange accepted.")
    claims = decode_jwt_claims(granted, "exchanged token")
    show_claims(claims, "Exchanged PingFederate token")

    # The whole point of the demo: both identities in one token.
    act = claims.get("act", {})
    has_actor = bool(act.get("sub"))
    print(f"\n  sub (user):        {claims.get('sub', '<missing>')}")
    print(f"  act.sub (agent):   {act.get('sub', '<missing>')}")
    print(f"  aud:               {claims.get('aud', '<missing>')}")
    print(f"  scope:             {claims.get('scope', '<missing>')}")

    if has_actor:
        print("\nRESULT: SUCCESS — delegated token carries user + agent identity.")
        return 0
    print("\nRESULT: PARTIAL — token issued but no 'act' claim: check the TEPP's "
          "actor token processor mapping.")
    return 1


def _print_hints(status, body):
    """Map common PingFederate rejections to the spec's Phase 0 gates."""
    lowered = body.lower()
    if status == 400 and "invalid_client" in lowered:
        print("Hint: client assertion rejected. Check the spec's Phase 0 gates:")
        print("  - client_id registered as the agent IAM role ARN?")
        print("  - client JWKS URL points at the AWS STS JWKS?")
        print("  - issuerMustBeEqualToClientId=false needed? (platform sign-off)")
    elif status == 400 and "invalid_grant" in lowered:
        print("Hint: subject/actor token rejected — check the TEPP token "
              "processors (issuer, audience, algorithms) and actorTokenRequired.")


if __name__ == "__main__":
    sys.exit(main())
