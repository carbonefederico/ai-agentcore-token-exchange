#!/usr/bin/env bash
# Remove the AgentCore stack (via the agentcore CLI when available, else the
# raw CloudFormation stack), the credential provider, and the IAM role.
# Outbound web identity federation is account-level and is NOT disabled
# automatically; the script prompts.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

[[ -f .env ]] && { set -a; source .env; set +a; }

require() { [[ -n "${!1:-}" ]] || { echo "$1 is required (set in .env or environment)" >&2; exit 1; }; }
require AWS_REGION
require OAUTH_PROVIDER_NAME

REGION="${AWS_REGION}"
ROLE_NAME="agentcore-demo-agent"

echo "== Deleting AgentCore stack (agentcore CLI) =="
if command -v agentcore >/dev/null 2>&1; then
  agentcore destroy --force 2>/dev/null || agentcore destroy || true
else
  echo "agentcore CLI not found; delete the CloudFormation stack manually:"
  echo "  aws cloudformation delete-stack --stack-name AgentCore-tokenexchangeagent-default --region ${REGION}"
fi

echo
echo "== Deleting credential provider ${OAUTH_PROVIDER_NAME} =="
aws bedrock-agentcore-control delete-oauth2-credential-provider \
  --name "${OAUTH_PROVIDER_NAME}" \
  --region "${REGION}" || true

echo
echo "== Deleting IAM role ${ROLE_NAME} =="
for policy in $(aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${policy}"
done
aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true

echo
read -r -p "Disable outbound web identity federation on this account? [y/N] " answer
if [[ "${answer,,}" == "y" ]]; then
  aws iam disable-outbound-web-identity-federation
  echo "Disabled."
else
  echo "Left enabled."
fi
