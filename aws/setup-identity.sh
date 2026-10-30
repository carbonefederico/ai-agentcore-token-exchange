#!/usr/bin/env bash
# One-time AWS setup for the POC:
#   1. Enable outbound web identity federation (account-level).
#   2. Create the agent execution role with sts:GetWebIdentityToken +
#      AgentCore Identity permissions (the agentcore CLI can also create its
#      own runtime role; this one carries the exchange-specific permissions).
#   3. Create the custom OAuth2 credential provider (secretless).
#   4. Print the AWS STS issuer/JWKS to copy into .env before scripts/deploy.sh.
# Requires an AWS session with administrator-equivalent permissions.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

[[ -f .env ]] && { set -a; source .env; set +a; }

require() { [[ -n "${!1:-}" ]] || { echo "$1 is required (set in .env or environment)" >&2; exit 1; }; }
require AWS_REGION

REGION="${AWS_REGION}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# Same hostname convention as scripts/deploy.sh: <release>-pingfederate-engine
# .ping-devops.com (release name = the repo folder name).
PF_PUBLIC_HOSTNAME="${PF_PUBLIC_HOSTNAME:-ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com}"
PF_TOKEN_ENDPOINT_AUDIENCE="${PF_TOKEN_ENDPOINT_AUDIENCE:-https://${PF_PUBLIC_HOSTNAME}/as/token.oauth2}"
OAUTH_PROVIDER_NAME="${OAUTH_PROVIDER_NAME:-pingfederate-obo-poc}"
ROLE_NAME="agentcore-demo-agent"
TRUST_POLICY="$(mktemp)"
PERM_POLICY="$(mktemp)"
PROVIDER_JSON="$(mktemp)"
trap 'rm -f "${TRUST_POLICY}" "${PERM_POLICY}" "${PROVIDER_JSON}"' EXIT

echo "== 1. Outbound web identity federation =="
if aws iam get-outbound-web-identity-federation-info >/dev/null 2>&1; then
  echo "Already enabled."
else
  aws iam enable-outbound-web-identity-federation
fi
# The API names the field IssuerIdentifier (not IssuerUrl).
AWS_STS_ISSUER="$(aws iam get-outbound-web-identity-federation-info --query IssuerIdentifier --output text)"
AWS_STS_JWKS_URL="${AWS_STS_ISSUER}/.well-known/jwks.json"
echo "Issuer: ${AWS_STS_ISSUER}"

echo "== 2. Agent execution role =="
cat > "${TRUST_POLICY}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
      "ArnLike": { "aws:SourceArn": "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:*" }
    }
  }]
}
EOF

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role ${ROLE_NAME} already exists."
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY}" \
    --description "AgentCore demo agent execution role (secretless OBO POC)" \
    --query 'Role.Arn' --output text
fi
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

cat > "${PERM_POLICY}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "STSIdentityToken",
      "Effect": "Allow",
      "Action": "sts:GetWebIdentityToken",
      "Resource": "*",
      "Condition": {
        "ForAllValues:StringEquals": {
          "sts:IdentityTokenAudience": "${PF_TOKEN_ENDPOINT_AUDIENCE}"
        },
        "NumericLessThanEquals": { "sts:DurationSeconds": 300 }
      }
    },
    {
      "Sid": "AgentCoreIdentityData",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:GetResourceOauth2Token",
        "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
        "bedrock-agentcore:GetWorkloadAccessToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "agentcore-demo-agent-permissions" \
  --policy-document "file://${PERM_POLICY}" >/dev/null
echo "Role: ${ROLE_ARN}"

# Record everything PF's deploy needs from the AWS side — no manual
# copy-paste. Idempotent: replaces existing lines, appends when absent.
for kv in "AWS_STS_ISSUER=${AWS_STS_ISSUER}" \
          "AWS_STS_JWKS_URL=${AWS_STS_JWKS_URL}" \
          "PF_AGENT_CLIENT_ID=${ROLE_ARN}"; do
  key="${kv%%=*}"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${kv}|" .env && rm -f .env.bak
  else
    printf '%s\n' "${kv}" >> .env
  fi
done
echo "Recorded AWS_STS_ISSUER, AWS_STS_JWKS_URL, PF_AGENT_CLIENT_ID in .env"

echo
echo "== 3. Custom OAuth2 credential provider (secretless) =="
# clientAuthenticationMethod=AWS_IAM_ID_TOKEN_JWT with no clientId and no
# clientSecret; TOKEN_EXCHANGE grant with the AWS JWT as actor token.
cat > "${PROVIDER_JSON}" <<EOF
{
  "name": "${OAUTH_PROVIDER_NAME}",
  "credentialProviderVendor": "CustomOauth2",
  "oauth2ProviderConfigInput": {
    "customOauth2ProviderConfig": {
      "oauthDiscovery": {
        "discoveryUrl": "https://${PF_PUBLIC_HOSTNAME}/.well-known/openid-configuration"
      },
      "clientAuthenticationMethod": "AWS_IAM_ID_TOKEN_JWT",
      "onBehalfOfTokenExchangeConfig": {
        "grantType": "TOKEN_EXCHANGE",
        "tokenExchangeGrantTypeConfig": {
          "actorTokenContent": "AWS_IAM_ID_TOKEN_JWT"
        }
      }
    }
  }
}
EOF

if aws bedrock-agentcore-control get-oauth2-credential-provider \
     --name "${OAUTH_PROVIDER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "Provider ${OAUTH_PROVIDER_NAME} already exists; updating config."
  aws bedrock-agentcore-control update-oauth2-credential-provider \
    --cli-input-json "file://${PROVIDER_JSON}" \
    --region "${REGION}" >/dev/null
else
  aws bedrock-agentcore-control create-oauth2-credential-provider \
    --cli-input-json "file://${PROVIDER_JSON}" \
    --region "${REGION}" \
    --query 'name' --output text
fi
echo "Provider ready: ${OAUTH_PROVIDER_NAME}"
echo
echo "Setup complete. Next:"
echo "  1. Set the discoveryUrl + allowedAudience in agentcore.json (PF values)."
echo "  2. ./scripts/deploy.sh (PingFederate), if not yet deployed."
echo "  3. agentcore deploy   (deploys the agent via the AgentCore CLI/CDK)."
