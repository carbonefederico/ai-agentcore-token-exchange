"""Shared helpers for the Phase 0 PingFederate validation scripts.

Used by pf_phase0_preflight.py and pf_phase0_exchange.py.

Security: tokens are handled in memory only, never logged or persisted.
"""

import base64
import hashlib
import json
import secrets
import sys
import urllib.parse

try:
    import boto3
    import requests
except ImportError as exc:  # pragma: no cover
    sys.exit(f"Missing dependency ({exc}). Run: pip install -r requirements.txt")


class PreflightError(Exception):
    """Preconfigured PingFederate objects are missing or misconfigured."""


def load_config(path="config.env"):
    """Parse KEY=VALUE lines from config.env into a dict."""
    config = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                config[key.strip()] = value.strip()
    except FileNotFoundError:
        sys.exit(f"{path} not found. Copy config.example.env to config.env and fill it in.")
    return config


def require(config, key):
    """Return config[key], exiting if missing or still a placeholder."""
    value = config.get(key, "").strip()
    if not value:
        sys.exit(f"{key} is required in config.env.")
    if "example.com" in value or value.startswith("arn:aws:iam::123456789012"):
        sys.exit(f"{key} still has its placeholder value: {value}. Edit config.env.")
    return value


def optional(config, key, default=""):
    """Return config[key] or the default, without placeholder checks."""
    return config.get(key, default).strip() or default


def build_urls(config):
    """Resolve the runtime and admin base URLs from config.env."""
    runtime = require(config, "PF_BASE_URL").rstrip("/")
    admin = optional(config, "PF_ADMIN_BASE_URL").rstrip("/")
    return {"runtime": runtime, "admin": admin or runtime}


def decode_jwt_claims(token, label):
    """Decode a JWT payload without verifying the signature. Display only."""
    parts = token.split(".")
    if len(parts) != 3:
        sys.exit(f"{label}: not a JWT (expected 3 segments, got {len(parts)}).")
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError) as exc:
        sys.exit(f"{label}: undecodable JWT payload ({exc}).")


def show_claims(claims, label):
    """Print decoded claims (claims only — raw tokens are never printed)."""
    print(f"\n{label} claims:")
    print(json.dumps(claims, indent=2, sort_keys=True))


def browser_login(config):
    """Run the Authorization Code + PKCE browser login; return the user JWT.

    Opens the user's browser for interactive login and catches the redirect
    on a short-lived loopback listener. Requires the PF client to register
    redirect URI http://127.0.0.1:<PF_REDIRECT_PORT>/callback.
    """
    import http.server
    import threading
    import webbrowser

    urls = build_urls(config)
    client_id = require(config, "PF_CLI_CLIENT_ID")
    port = int(optional(config, "PF_REDIRECT_PORT", "8400"))
    scope = optional(config, "PF_DEMO_SCOPE", "openid profile")
    redirect_uri = f"http://127.0.0.1:{port}/callback"

    # RFC 7636 PKCE verifier/challenge (S256).
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()

    state = secrets.token_urlsafe(16)
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    auth_url = f"{urls['runtime']}/as/authorization.oauth2?{urllib.parse.urlencode(params)}"

    captured = {}

    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            captured["code"] = (query.get("code") or [None])[0]
            captured["state"] = (query.get("state") or [None])[0]
            captured["error"] = (query.get("error") or [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<html><body><p>Login captured, return to the terminal.</p></body></html>")

        def log_message(self, fmt, *args):  # keep the console clean
            pass

    server = http.server.HTTPServer(("127.0.0.1", port), CallbackHandler)
    server.timeout = 120
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()

    print("Authenticating user with PingFederate...")
    print(f"Opening browser: {auth_url}")
    webbrowser.open(auth_url)
    thread.join(timeout=120)
    server.server_close()

    if not captured.get("code"):
        if captured.get("error"):
            sys.exit(f"Login failed: authorization server returned error '{captured['error']}'.")
        sys.exit("No authorization code received within 120s.")

    if captured["state"] != state:
        sys.exit("Login failed: state mismatch (possible CSRF) — aborting.")

    token_resp = requests.post(
        f"{urls['runtime']}/as/token.oauth2",
        data={
            "grant_type": "authorization_code",
            "code": captured["code"],
            "redirect_uri": redirect_uri,
            "client_id": client_id,
            "code_verifier": verifier,
        },
        timeout=30,
    )
    if token_resp.status_code != 200:
        sys.exit(f"Token request failed: HTTP {token_resp.status_code}: {token_resp.text[:300]}")
    access_token = token_resp.json().get("access_token")
    if not access_token:
        sys.exit("Token response contained no access_token.")
    return access_token


def get_aws_identity_jwt(config):
    """Call sts:GetWebIdentityToken; return the AWS IAM identity JWT.

    Audience is the PingFederate token endpoint, matching what AgentCore
    Identity sends. Requires regional STS (the global endpoint does not
    expose this API) and outbound web identity federation enabled.
    """
    region = optional(config, "AWS_REGION", "us-east-1")
    audience = f"{build_urls(config)['runtime']}/as/token.oauth2"
    role_arn = require(config, "PF_AGENT_ROLE_ARN")
    algorithm = optional(config, "STS_SIGNING_ALG", "RS256")
    if algorithm not in ("RS256", "ES384"):
        sys.exit(f"STS_SIGNING_ALG must be RS256 or ES384, got {algorithm!r}.")

    sts = boto3.client("sts", region_name=region)
    try:
        resp = sts.get_web_identity_token(
            Audience=[audience],
            SigningAlgorithm=algorithm,
            DurationSeconds=300,
        )
    except Exception as exc:  # noqa: BLE001 — surface the AWS error verbatim
        sys.exit(
            f"sts:GetWebIdentityToken failed ({exc}).\n"
            "Check: outbound web identity federation enabled "
            "(aws iam enable-outbound-web-identity-federation), the caller "
            "role has sts:GetWebIdentityToken, and you use a regional endpoint."
        )

    jwt_token = resp.get("WebIdentityToken") or resp.get("IdentityToken")
    if not jwt_token:
        sys.exit("STS response contained no web identity token.")
    _ = role_arn  # validated in the exchange script; here we only need the JWT
    return jwt_token


def token_exchange(config, user_token, aws_jwt):
    """POST the RFC 8693 exchange to PingFederate; return (status, body).

    Secretless: no client secret, and the AWS JWT doubles as the RFC 7523
    client assertion and the RFC 8693 actor token.
    """
    urls = build_urls(config)
    role_arn = require(config, "PF_AGENT_ROLE_ARN")
    scope = optional(config, "PF_EXCHANGE_SCOPE", "demo:read")

    return requests.post(
        f"{urls['runtime']}/as/token.oauth2",
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "client_id": role_arn,
            "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": aws_jwt,
            "subject_token": user_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "actor_token": aws_jwt,
            "actor_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "scope": scope,
        },
        timeout=30,
    )
