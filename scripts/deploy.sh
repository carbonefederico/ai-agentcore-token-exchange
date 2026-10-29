#!/usr/bin/env bash
# Deploy PingFederate (official ping-devops chart, values.yaml in this repo)
# configured for the AgentCore secretless token exchange via this repo's
# server profile.
#
# The script only supplies what cannot live in the static values file:
# the subst variables the profile's bulk config expands (AWS-side values
# from ./aws/setup-identity.sh, and the generated SSL server keypair).
#
# Namespace works like any helm command: the context's default, or pass
# --namespace. Same for other helm flags.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command helm

# The agent client_id must equal the agent IAM role ARN (the AWS JWT's sub).
# ./aws/setup-identity.sh creates the role and records these in .env.
require_value PF_AGENT_CLIENT_ID
require_value AWS_STS_ISSUER
require_value AWS_STS_JWKS_URL

# The bulk import requires the SSL server keypair the instance activates
# (bulk_config_ssl_server_config_invalid otherwise). Generate it once if
# missing; its password + base64 filedata travel into the admin container.
P12_FILE="${ROOT_DIR}/keys/agentcore-ssl-server.p12"
if [[ ! -f "${P12_FILE}" ]]; then
  "${ROOT_DIR}/scripts/generate-keys.sh"
  # generate-keys.sh writes the password into .env; re-source it (common.sh
  # sourced the file before the password existed).
  set -a; source "${ROOT_DIR}/.env"; set +a
fi
AGENTCORE_SSL_SERVER_P12_PASSWORD="${AGENTCORE_SSL_SERVER_P12_PASSWORD:?AGENTCORE_SSL_SERVER_P12_PASSWORD missing — generate-keys.sh writes it into .env}"
AGENTCORE_SSL_SERVER_P12_FILEDATA="$(base64 -i "${P12_FILE}" | tr -d '\n')"

GENERATED_ENVS="$(mktemp -t pf-agentcore-envs).yaml"
trap 'rm -f "${GENERATED_ENVS}"' EXIT
cat > "${GENERATED_ENVS}" <<EOF
pingfederate-admin:
  envs:
    AWS_STS_ISSUER: "${AWS_STS_ISSUER}"
    AWS_STS_JWKS_URL: "${AWS_STS_JWKS_URL}"
    RUNTIME_API_AUDIENCE: "${RUNTIME_API_AUDIENCE:-https://agentcore.demo.internal/invoke}"
    DEMO_RESOURCE_URI: "${DEMO_RESOURCE_URI:-https://demo.example.internal/resource}"
    PF_CLI_CLIENT_ID: "${PF_CLI_CLIENT_ID:-agentcore-demo-cli}"
    PF_CLI_REDIRECT_URI: "${PF_CLI_REDIRECT_URI:-http://127.0.0.1:8400/callback}"
    PF_AGENT_CLIENT_ID: "${PF_AGENT_CLIENT_ID}"
    AGENTCORE_SSL_SERVER_P12_PASSWORD: "${AGENTCORE_SSL_SERVER_P12_PASSWORD}"
    AGENTCORE_SSL_SERVER_P12_FILEDATA: "${AGENTCORE_SSL_SERVER_P12_FILEDATA}"
EOF

PING_CHART_VERSION="${PING_CHART_VERSION:-0.15.0}"
helm upgrade --install "${PF_RELEASE}" pingidentity/ping-devops \
  --version "${PING_CHART_VERSION}" \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --values "${GENERATED_ENVS}" \
  --wait --timeout 15m

echo
kubectl get pods,ingress -l "app.kubernetes.io/instance=${PF_RELEASE}"
