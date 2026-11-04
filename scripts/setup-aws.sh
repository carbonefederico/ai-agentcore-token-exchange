#!/usr/bin/env bash
# Create the two AWS objects the token exchange needs outside the repo:
# the KMS signing key for the private_key_jwt client assertion, and the
# AgentCore credential provider that binds PingFederate, the KMS key, and
# the on-behalf-of token exchange together. Both steps are idempotent:
# existing objects are detected and reused, never overwritten.
#
# The script prints, at the end, every value that must be copied into the
# repo: the KMS key ID (cdk-stack.ts), the public key as a JWK
# (data.json.subst), and the STS issuer/JWKS URL (.env for deploy.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/common.sh"

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "eu-central-1")}"
KMS_KEY_ID="${KMS_KEY_ID:-}"
PROVIDER_NAME="${PROVIDER_NAME:-pingfederate-obo-poc}"
KID="agentcore-pf-poc-1"

require_command aws
require_command python3

aws_region() { [[ -n "${AWS_REGION:-}" ]] || export AWS_REGION="${REGION}"; }
aws_region

key_desc="AgentCore ${PROVIDER_NAME} client assertion signing key (private_key_jwt)"

echo "== KMS signing key =="
if [[ -z "${KMS_KEY_ID}" ]]; then
  # Reuse an existing key by description, so re-runs are safe. (A shell
  # while-read loop cannot do this under set -e: a trailing non-match
  # silently aborts the whole substitution.)
  KMS_KEY_ID="$(aws kms list-keys --region "${REGION}" --output json --query 'Keys[].KeyId' 2>/dev/null |
    python3 -I -c "
import json, subprocess, sys
for k in json.load(sys.stdin):
    d = subprocess.run(
        ['aws', 'kms', 'describe-key', '--key-id', k,
         '--query', 'KeyMetadata.Description', '--output', 'text'],
        capture_output=True, text=True).stdout.strip()
    if d == sys.argv[1]:
        print(k)
        break
" "${key_desc}")"
fi
if [[ -n "${KMS_KEY_ID}" ]]; then
  echo "using existing key ${KMS_KEY_ID}"
else
  KMS_KEY_ID="$(aws kms create-key --region "${REGION}" \
    --key-spec RSA_2048 --key-usage SIGN_VERIFY \
    --description "${key_desc}" \
    --query 'KeyMetadata.KeyId' --output text)"
  echo "created key ${KMS_KEY_ID}"
  # AgentCore Identity signs the client assertion as the bedrock-agentcore
  # service principal; without this policy the provider cannot use the key.
  cat > /tmp/kms-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableIAMUserPermissions",
      "Effect": "Allow",
      "Principal": {"AWS": "$(aws sts get-caller-identity --query 'Account' --output text)"},
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowAgentCoreIdentityToSign",
      "Effect": "Allow",
      "Principal": {"Service": "bedrock-agentcore.amazonaws.com"},
      "Action": ["kms:Sign", "kms:DescribeKey"],
      "Resource": "*"
    }
  ]
}
EOF
  aws kms put-key-policy --region "${REGION}" --key-id "${KMS_KEY_ID}" \
    --policy-name default --policy file:///tmp/kms-policy.json
  rm -f /tmp/kms-policy.json
  echo "key policy set (bedrock-agentcore may Sign)"
fi

echo
echo "== Credential provider ${PROVIDER_NAME} =="
# Enable STS JWT vending first: it mints the exchange's actor token. New
# accounts have it disabled; when already enabled this call is a no-op.
if ! aws iam get-outbound-web-identity-federation-info --output text 2>/dev/null | grep -q "tokens.sts.global.api.aws"; then
  aws iam enable-outbound-web-identity-federation
  echo "enabled outbound web identity federation"
fi
STS_ISSUER="$(aws iam get-outbound-web-identity-federation-info --query 'IssuerIdentifier' --output text)"

# The provider's discovery URL points at PingFederate (same convention
# deploy.sh uses for the profile's subst variables): the release is the
# repo folder name, so the engine host follows the ping-devops pattern.
PF_DISCOVERY_URL="https://${PF_RELEASE}-pingfederate-engine.ping-devops.com/.well-known/openid-configuration"

if aws bedrock-agentcore-control get-oauth2-credential-provider \
     --name "${PROVIDER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "provider ${PROVIDER_NAME} exists, leaving it unchanged"
else
  # The local AWS CLI's service model predates the KMS key binding and
  # rejects privateKeyJwtConfig, so provider calls go through a raw signed
  # request via botocore (the server accepts and stores the field; verified
  # 2026-11-04). CloudTrail shows the original provider was created the
  # same way.
  python3 - "$PROVIDER_NAME" "$KMS_KEY_ID" "$KID" "$PF_DISCOVERY_URL" create <<'PYEOF'
import json, sys
import boto3, botocore.awsrequest, botocore.auth
import urllib3

provider, key_id, kid, discovery_url, action = sys.argv[1:6]
account = boto3.client("sts").get_caller_identity()["Account"]
region = boto3.session.Session().region_name or "eu-central-1"
# Placeholder clientId: the runtime role does not exist yet; re-run this
# script after 'agentcore deploy' to bind the real role ARN (step 4 below).
placeholder_client = f"arn:aws:iam::{account}:role/PENDING-RUNTIME-ROLE"

config = {
    "oauthDiscovery": {"discoveryUrl": discovery_url},
    "clientId": placeholder_client,
    "clientAuthenticationMethod": "PRIVATE_KEY_JWT",
    "privateKeyJwtConfig": {
        "privateKeySource": {"kmsKeySource": {
            "kmsKeyArn": f"arn:aws:kms:{region}:{account}:key/{key_id}"}},
        "signingAlgorithm": "RS256",
        "additionalHeaderClaims": {"kid": kid},
    },
    "onBehalfOfTokenExchangeConfig": {
        "grantType": "TOKEN_EXCHANGE",
        "tokenExchangeGrantTypeConfig": {"actorTokenContent": "AWS_IAM_ID_TOKEN_JWT"},
    },
}
operation = {"create": "CreateOauth2CredentialProvider",
             "update": "UpdateOauth2CredentialProvider"}[action]
body = json.dumps({
    "name": provider,
    "credentialProviderVendor": "CustomOauth2",
    "oauth2ProviderConfigInput": {"customOauth2ProviderConfig": config},
})
url = f"https://bedrock-agentcore-control.{region}.amazonaws.com/identities/{operation}"
creds = boto3.Session().get_credentials().get_frozen_credentials()
req = botocore.awsrequest.AWSRequest(method="POST", url=url, data=body,
                                     headers={"Content-Type": "application/json"})
botocore.auth.SigV4Auth(creds, "bedrock-agentcore", region).add_auth(req)
resp = urllib3.PoolManager().request("POST", url, body=body.encode(),
                                     headers=dict(req.headers), timeout=30)
if resp.status not in (200, 201):
    sys.exit(f"{operation} failed ({resp.status}): {resp.data.decode()[:400]}")
print(f"created provider {provider}")
PYEOF
fi

# The provider's clientId must be the runtime execution role (AgentCore
# Identity presents itself as that role). The role is created by
# 'agentcore deploy', so bind it whenever this script runs after that —
# and skip when the runtime isn't deployed yet.
RUNTIME_ROLE="$(aws bedrock-agentcore-control list-agent-runtimes --region "${REGION}" --output json 2>/dev/null |
  python3 -I -c "
import json, sys
try:
    runtimes = json.load(sys.stdin).get('agentRuntimes', [])
except ValueError:
    runtimes = []
for r in runtimes:
    if r.get('agentRuntimeName', '').endswith('_exchange_agent'):
        print(r['agentRuntimeId'])
        break
")"
if [[ -n "${RUNTIME_ROLE}" ]]; then
  ROLE_ARN="$(aws bedrock-agentcore-control get-agent-runtime \
    --agent-runtime-id "${RUNTIME_ROLE}" --region "${REGION}" \
    --query 'roleArn' --output text 2>/dev/null || true)"
  CURRENT_CLIENT="$(aws bedrock-agentcore-control get-oauth2-credential-provider \
    --name "${PROVIDER_NAME}" --region "${REGION}" \
    --query 'oauth2ProviderConfigOutput.customOauth2ProviderConfig.clientId' --output text 2>/dev/null || true)"
  if [[ -n "${ROLE_ARN}" && "${ROLE_ARN}" != "${CURRENT_CLIENT}" ]]; then
    echo "binding provider clientId to the runtime role ${ROLE_ARN}"
    python3 - "$PROVIDER_NAME" "$KMS_KEY_ID" "$KID" "$PF_DISCOVERY_URL" "$ROLE_ARN" update <<'PYEOF'
import json, sys
import boto3, botocore.awsrequest, botocore.auth
import urllib3

provider, key_id, kid, discovery_url, role_arn = sys.argv[1:6]
account = boto3.client("sts").get_caller_identity()["Account"]
region = boto3.session.Session().region_name or "eu-central-1"
config = {
    "oauthDiscovery": {"discoveryUrl": discovery_url},
    "clientId": role_arn,
    "clientAuthenticationMethod": "PRIVATE_KEY_JWT",
    "privateKeyJwtConfig": {
        "privateKeySource": {"kmsKeySource": {
            "kmsKeyArn": f"arn:aws:kms:{region}:{account}:key/{key_id}"}},
        "signingAlgorithm": "RS256",
        "additionalHeaderClaims": {"kid": kid},
    },
    "onBehalfOfTokenExchangeConfig": {
        "grantType": "TOKEN_EXCHANGE",
        "tokenExchangeGrantTypeConfig": {"actorTokenContent": "AWS_IAM_ID_TOKEN_JWT"},
    },
}
body = json.dumps({
    "name": provider,
    "credentialProviderVendor": "CustomOauth2",
    "oauth2ProviderConfigInput": {"customOauth2ProviderConfig": config},
})
url = f"https://bedrock-agentcore-control.{region}.amazonaws.com/identities/UpdateOauth2CredentialProvider"
creds = boto3.Session().get_credentials().get_frozen_credentials()
req = botocore.awsrequest.AWSRequest(method="POST", url=url, data=body,
                                     headers={"Content-Type": "application/json"})
botocore.auth.SigV4Auth(creds, "bedrock-agentcore", region).add_auth(req)
resp = urllib3.PoolManager().request("POST", url, body=body.encode(),
                                     headers=dict(req.headers), timeout=30)
if resp.status not in (200, 201):
    sys.exit(f"UpdateOauth2CredentialProvider failed ({resp.status}): {resp.data.decode()[:400]}")
print(f"provider {provider} clientId set to the runtime role")
PYEOF
  fi
fi

echo
echo "== Values for the repo =="
KMS_ARN="$(aws kms describe-key --region "${REGION}" --key-id "${KMS_KEY_ID}" --query 'KeyMetadata.Arn' --output text)"

# Public key as a JWK for the PF client's inline JWKS (RFC 7517). The DER
# SubjectPublicKeyInfo is parsed by hand: modulus (INTEGER, leading sign
# byte stripped) and exponent, base64url-encoded.
aws kms get-public-key --region "${REGION}" --key-id "${KMS_KEY_ID}" \
  --output json --query 'PublicKey' > /tmp/kms-pub.json
JWK="$(python3 - /tmp/kms-pub.json "$KID" <<'PYEOF'
import base64, json, sys

def ber_read(b, i):
    tag = b[i]; i += 1
    ln = b[i]; i += 1
    if ln & 0x80:
        nb = ln & 0x7F
        ln = int.from_bytes(b[i:i+nb], "big"); i += nb
    return tag, ln, i

def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

der = base64.b64decode(json.load(open(sys.argv[1])))
_, _, i = ber_read(der, 0)          # SEQUENCE
_, alen, i = ber_read(der, i)       # AlgorithmIdentifier
i += alen
_, plen, i = ber_read(der, i)       # BIT STRING
pk = der[i+1:i+plen]                # skip unused-bits byte
_, _, k = ber_read(pk, 0)           # RSAPublicKey SEQUENCE
_, nlen, k = ber_read(pk, k)
n = pk[k:k+nlen]
if n[0] == 0x00:
    n = n[1:]                       # INTEGER sign byte
_, elen, k = ber_read(pk, k + nlen)
e = pk[k:k+elen]
print(json.dumps({"keys": [{"kty": "RSA", "kid": sys.argv[2], "use": "sig",
                            "alg": "RS256", "n": b64u(n), "e": b64u(e)}]}))
PYEOF
)"
rm -f /tmp/kms-pub.json

echo
echo "1. KMS key ID — pin it in agentcore/cdk/lib/cdk-stack.ts (KmsSignClientAssertion grant):"
echo "   ${KMS_KEY_ID}"
echo
echo "2. Public JWK — paste into server-profiles/.../data.json.subst (agent client jwksSettings.jwks):"
echo "   ${JWK}"
echo
echo "3. STS issuer + JWKS — put in .env for scripts/deploy.sh:"
echo "   AWS_STS_ISSUER=${STS_ISSUER}"
echo "   AWS_STS_JWKS_URL=${STS_ISSUER}/.well-known/jwks.json"
echo
echo "4. AgentCore runtime role ARN — after 'agentcore deploy', set the provider's clientId:"
echo "   PF_AGENT_CLIENT_ID=\$(aws bedrock-agentcore-control get-agent-runtime \\"
echo "     --agent-runtime-id <runtime-id> --region ${REGION} --query roleArn --output text)"
