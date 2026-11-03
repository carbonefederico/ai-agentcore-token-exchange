"""Shared helpers for the PingFederate smoke test.

Used by tests/pf_preflight.py and tests/demo_cli.py.

Security: tokens stay in memory during the flow; the CLI's token cache
(tokens.cache) holds them on disk locally (git-ignored) so demo runs
don't re-login on every invocation.
"""

import base64
import hashlib
import json
import secrets
import sys
import urllib.parse
from pathlib import Path

# Constants of the deployment this repo provisions (see
# server-profiles/pingfederate-agentcore/): the demo CLI client and its
# secret are registered there, and the redirect loopback port with it.
CLI_CLIENT_ID = "agentcore-demo-cli"
CLI_CLIENT_SECRET = "cli-demo-secret"
REDIRECT_PORT = 8400
LOGIN_SCOPE = "openid demo:read"

try:
    import requests
except ImportError as exc:  # pragma: no cover
    sys.exit(f"Missing dependency ({exc}). Run: pip install -r requirements.txt")


class PreflightError(Exception):
    """Preconfigured PingFederate objects are missing or misconfigured."""


def load_config(path=None):
    """Parse KEY=VALUE lines from tests/config.env into a dict."""
    if path is None:
        path = Path(__file__).resolve().parent / "config.env"
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
        sys.exit(f"{path} not found. Copy tests/config.example.env to tests/config.env and fill it in.")
    return config


def require(config, key):
    """Return config[key], exiting if missing or still a placeholder."""
    value = config.get(key, "").strip()
    if not value:
        sys.exit(f"{key} is required in tests/config.env.")
    if "example.com" in value or value.startswith("arn:aws:iam::123456789012"):
        sys.exit(f"{key} still has its placeholder value: {value}. Edit tests/config.env.")
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

    Caches the token on disk (tokens.cache, git-ignored) so repeated demo
    runs don't need a fresh browser login. The cached token is reused until
    it expires; a refresh_token is used when present, else a new login runs.
    """
    cached = _load_cached_token(config)
    if cached:
        refreshed = _try_refresh(config, cached)
        if refreshed:
            return refreshed
        if _token_valid(cached.get("access_token")):
            return cached["access_token"]
    return _browser_login_uncached(config)


# The cache lives in the repo root next to config.env, regardless of where
# this module is imported from.
CACHE_FILE = Path(__file__).resolve().parent / "tokens.cache"


def _load_cached_token(config):
    try:
        return json.loads(CACHE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _save_cached_token(token_resp_json):
    try:
        CACHE_FILE.write_text(json.dumps(token_resp_json))
    except OSError:
        pass  # best effort; the demo still works without a cache


def _token_valid(token):
    """True if the JWT is decodable and not expired (30s skew)."""
    import time
    try:
        claims = decode_jwt_claims(token, "cached_token")
    except SystemExit:
        return False
    exp = claims.get("exp")
    return bool(exp) and exp > time.time() + 30


def _try_refresh(config, cached):
    """Refresh-token grant against PF; None on any failure."""
    refresh_token = cached.get("refresh_token")
    if not refresh_token:
        return None
    urls = build_urls(config)
    client_id = CLI_CLIENT_ID
    secret = CLI_CLIENT_SECRET
    try:
        resp = requests.post(
            f"{urls['runtime']}/as/token.oauth2",
            data={
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": client_id,
            },
            auth=(client_id, secret) if secret else None,
            timeout=30,
        )
    except requests.RequestException:
        return None
    if resp.status_code != 200:
        return None
    body = resp.json()
    if not body.get("access_token"):
        return None
    # PF rolls refresh tokens; keep the un-rotated one if a new one isn't returned.
    body.setdefault("refresh_token", refresh_token)
    _save_cached_token(body)
    return body["access_token"]


def _browser_login_uncached(config):
    """The interactive browser flow; caches the result on success."""
    import http.server
    import threading
    import webbrowser

    urls = build_urls(config)
    client_id = CLI_CLIENT_ID
    port = REDIRECT_PORT
    scope = LOGIN_SCOPE
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
    server.timeout = 300
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()

    print("Authenticating user with PingFederate...")
    print(f"Opening browser: {auth_url}")
    webbrowser.open(auth_url)
    thread.join(timeout=300)
    server.server_close()

    if not captured.get("code"):
        if captured.get("error"):
            sys.exit(f"Login failed: authorization server returned error '{captured['error']}'.")
        sys.exit("No authorization code received within 300s.")

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
        auth=(client_id, CLI_CLIENT_SECRET),
        timeout=30,
    )
    if token_resp.status_code != 200:
        sys.exit(f"Token request failed: HTTP {token_resp.status_code}: {token_resp.text[:300]}")
    body = token_resp.json()
    access_token = body.get("access_token")
    if not access_token:
        sys.exit("Token response contained no access_token.")
    _save_cached_token(body)
    return access_token

