#!/usr/bin/env bash
# Remove the AgentCore stack (via the agentcore CLI when available, else the
# raw CloudFormation stack) and the credential provider.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

[[ -f .env ]] && { set -a; source .env; set +a; }

require() { [[ -n "${!1:-}" ]] || { echo "$1 is required (set in .env or environment)" >&2; exit 1; }; }
require AWS_REGION

REGION="${AWS_REGION}"
OAUTH_PROVIDER_NAME="${OAUTH_PROVIDER_NAME:-pingfederate-obo-poc2}"

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
echo "Teardown complete. Not removed (created out-of-band, delete manually if needed):"
echo "  - the KMS key used for the private_key_jwt client assertion"
