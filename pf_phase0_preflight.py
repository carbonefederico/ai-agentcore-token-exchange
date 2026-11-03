#!/usr/bin/env python3
"""Phase 0 preflight: verify the preconfigured PingFederate objects exist.

Read-only Admin REST API checks (GET only). Run this before attempting any
token exchange. Uses PF_ADMIN_TOKEN (bearer) against /pf-admin-api/v1;
skips the admin checks with a warning if no token is configured.

Usage: python3 pf_phase0_preflight.py
"""

import sys

import requests

from pf_phase0_common import PreflightError, build_urls, load_config, optional


def check(client, url, description, expected=None):
    """GET url; PASS if 200 and (optionally) the id appears in the payload."""
    try:
        resp = client.get(url, timeout=30)
    except requests.RequestException as exc:
        print(f"  WARN  {description}: unreachable ({exc.__class__.__name__})")
        return False
    if resp.status_code != 200:
        print(f"  WARN  {description}: HTTP {resp.status_code}")
        return False
    if expected is not None:
        body = resp.text
        if expected not in body:
            print(f"  WARN  {description}: found but '{expected}' not present — check its config")
            return False
    print(f"  PASS  {description}")
    return True


def main():
    config = load_config()
    urls = build_urls(config)
    client_id = optional(config, "PF_CLI_CLIENT_ID")
    admin = requests.Session()
    token = optional(config, "PF_ADMIN_TOKEN")
    if token:
        admin.headers["Authorization"] = f"Bearer {token}"

    print("PingFederate preflight\n")

    print("Runtime endpoints (no auth):")
    ok = True
    ok &= check(admin, f"{urls['runtime']}/.well-known/openid-configuration",
                "OIDC discovery endpoint")
    ok &= check(admin, f"{urls['runtime']}/.well-known/jwks.json",
                "PingFederate JWKS endpoint")
    if not ok:
        print("\nFix the runtime URL/ingress before continuing.")
        return 1

    if not token:
        print("\nAdmin checks skipped: PF_ADMIN_TOKEN not set in config.env.")
        return 0

    print("\nAdmin API (read-only):")
    api = f"{urls['admin']}/pf-admin-api/v1"
    all_ok = True
    all_ok &= check(admin, f"{api}/oauth/clients/{client_id}",
                    f"CLI client '{client_id}'", expected=client_id)
    all_ok &= check(admin, f"{api}/oauth/tokenExchange/processor/policies",
                    "token exchange processor policy exists", expected="actorTokenRequired")
    all_ok &= check(admin, f"{api}/oauth/credentials/validator",
                    "client-assertion validator config (issuerMustBeEqualToClientId)")

    print()
    if all_ok:
        print("RESULT: PASS")
        return 0
    print("RESULT: INCOMPLETE — resolve the WARN items with the platform team.")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PreflightError as exc:
        sys.exit(f"Preflight error: {exc}")
