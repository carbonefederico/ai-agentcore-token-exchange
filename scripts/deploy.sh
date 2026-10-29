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
#   ./scripts/deploy.sh -n <namespace>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm
helm repo list 2>/dev/null | grep -q pingidentity || helm repo add pingidentity https://helm.pingidentity.com/ >/dev/null

NAMESPACE=""
CREATE_NS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --create-namespace) CREATE_NS="--create-namespace"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)"
  NAMESPACE="${NAMESPACE:-default}"
  echo "No -n given; using the current context's namespace: ${NAMESPACE}"
fi

# Public hostnames follow the chart's own convention (global.ingress with
# addReleaseNameToHost: prepend): <release>-pingfederate-{admin,engine}.<domain>.
# The profile's bulk config expands these into the issuer, JWKS URLs and
# client config.
PF_DOMAIN="${PF_DOMAIN:-ping-devops.com}"
PF_ENGINE_HOST="${PF_ENGINE_HOST:-${PF_RELEASE}-pingfederate-engine.${PF_DOMAIN}}"
PF_ADMIN_HOST="${PF_ADMIN_HOST:-${PF_RELEASE}-pingfederate-admin.${PF_DOMAIN}}"

# Fixed lab constants (match the bulk config and cli/config defaults).
PF_TOKEN_ENDPOINT_AUDIENCE="${PF_TOKEN_ENDPOINT_AUDIENCE:-https://${PF_ENGINE_HOST}/as/token.oauth2}"
OUTPUT_ISSUER="${OUTPUT_ISSUER:-https://${PF_ENGINE_HOST}}"
OUTPUT_JWKS_URL="${OUTPUT_JWKS_URL:-https://${PF_ENGINE_HOST}/pf/JWKS}"
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
    PF_TOKEN_ENDPOINT_AUDIENCE: "${PF_TOKEN_ENDPOINT_AUDIENCE}"
    OUTPUT_ISSUER: "${OUTPUT_ISSUER}"
    OUTPUT_JWKS_URL: "${OUTPUT_JWKS_URL}"
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
helm upgrade --install "${PF_RELEASE}" ping-devops/ping-devops \
  --version "${PING_CHART_VERSION}" \
  --namespace "${NAMESPACE}" ${CREATE_NS} \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --values "${GENERATED_ENVS}" \
  --wait --timeout 15m

echo
kubectl -n "${NAMESPACE}" get pods,ingress -l "app.kubernetes.io/instance=${PF_RELEASE}"
echo
echo "Admin UI:  https://${PF_ADMIN_HOST}"
echo "Engine:    https://${PF_ENGINE_HOST}"
