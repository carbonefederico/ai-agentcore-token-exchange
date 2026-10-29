#!/usr/bin/env bash
# Deploy PingFederate (official ping-devops chart, values.yaml in this repo)
# configured for the AgentCore secretless token exchange via the server
# profile at helm/pingfederate/values.yaml's SERVER_PROFILE_URL.
#
# This script only supplies what cannot live in the static values file:
#   - the subst variables the profile's bulk config expands (release-derived
#     hostnames, the agent client id from the AWS setup, demo constants)
#   - the generated SSL server keypair (p12 filedata + password)
#   - the devops-secret license when the namespace doesn't have one yet
#
# Namespace works like any helm command: the context's default, or pass
# --namespace. Same for other helm flags.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm

# Hostnames, issuer and JWKS URLs are NOT set here: the chart exports
# PF_ENGINE_PUBLIC_HOSTNAME / PF_ADMIN_PUBLIC_HOSTNAME into the pods
# (derived from the release name) and the profile's bulk config expands
# them directly.

# Fixed lab constants (match the bulk config and cli/config defaults).
DEMO_USERNAME="${DEMO_USERNAME:-demouser}"
DEMO_PASSWORD="${DEMO_PASSWORD:-changeme}"
PF_CLI_CLIENT_ID="${PF_CLI_CLIENT_ID:-agentcore-demo-cli}"
PF_CLI_REDIRECT_URI="${PF_CLI_REDIRECT_URI:-http://127.0.0.1:8400/callback}"
RUNTIME_API_AUDIENCE="${RUNTIME_API_AUDIENCE:-https://agentcore.demo.internal/invoke}"
DEMO_RESOURCE_URI="${DEMO_RESOURCE_URI:-https://demo.example.internal/resource}"
PING_IDENTITY_PASSWORD="${PING_IDENTITY_PASSWORD:-2FederateM0re}"

# The agent client_id must equal the agent IAM role ARN (the AWS JWT's sub).
# ./aws/setup-identity.sh creates the role and records the ARN in .env.
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

# Operator credentials (Ping DevOps license) are carried by the namespace's
# devops-secret. Create it only when missing; never overwrite an existing one.
if ! kubectl -n "${NAMESPACE}" get secret devops-secret >/dev/null 2>&1; then
  require_value PING_IDENTITY_DEVOPS_USER
  require_value PING_IDENTITY_DEVOPS_KEY
  kubectl -n "${NAMESPACE}" create secret generic devops-secret \
    --from-literal=PING_IDENTITY_DEVOPS_USER="${PING_IDENTITY_DEVOPS_USER}" \
    --from-literal=PING_IDENTITY_DEVOPS_KEY="${PING_IDENTITY_DEVOPS_KEY}" \
    --from-literal=PING_IDENTITY_ACCEPT_EULA="YES" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "devops-secret already exists in ${NAMESPACE}; leaving it untouched."
fi

GENERATED_ENVS="$(mktemp -t pf-agentcore-envs).yaml"
trap 'rm -f "${GENERATED_ENVS}"' EXIT
cat > "${GENERATED_ENVS}" <<EOF
pingfederate-admin:
  envs:
    AWS_STS_ISSUER: "${AWS_STS_ISSUER}"
    AWS_STS_JWKS_URL: "${AWS_STS_JWKS_URL}"
    RUNTIME_API_AUDIENCE: "${RUNTIME_API_AUDIENCE}"
    DEMO_RESOURCE_URI: "${DEMO_RESOURCE_URI}"
    PF_CLI_CLIENT_ID: "${PF_CLI_CLIENT_ID}"
    PF_CLI_REDIRECT_URI: "${PF_CLI_REDIRECT_URI}"
    PF_AGENT_CLIENT_ID: "${PF_AGENT_CLIENT_ID}"
    PING_IDENTITY_PASSWORD: "${PING_IDENTITY_PASSWORD}"
    DEMO_USERNAME: "${DEMO_USERNAME}"
    DEMO_PASSWORD: "${DEMO_PASSWORD}"
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
