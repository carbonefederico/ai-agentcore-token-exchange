#!/usr/bin/env bash
# Deploy PingFederate (1 admin + 2 engines) configured for the AgentCore
# secretless token exchange. The server profile's bulk config is imported at
# admin startup. TLS terminates on the cluster ingress (nginx-public class,
# wildcard *.ping-devops.com controller cert).
#
# Namespace is an install-time decision, as with any helm chart:
#   ./scripts/deploy.sh -n <namespace> [--create-namespace]
# Defaults to the current kubectl context's namespace.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm

# --- Pass-through arguments: -n <ns>, --create-namespace, --set key=val ----
NAMESPACE=""
CREATE_NS=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --create-namespace) CREATE_NS="--create-namespace"; shift ;;
    --set) EXTRA_ARGS+=("--set-string" "$2"); shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)"
  NAMESPACE="${NAMESPACE:-default}"
  echo "No -n given; using the current context's namespace: ${NAMESPACE}"
fi

# Operator credentials (Ping DevOps license) are carried by the cluster's
# devops-secret. Create it only when missing, from env vars supplied by the
# operator; never overwrite an existing one.
HAVE_SECRET="$(kubectl -n "${NAMESPACE}" get secret devops-secret >/dev/null 2>&1 && echo yes || echo no)"
if [[ "${HAVE_SECRET}" != "yes" ]]; then
  require_value PING_IDENTITY_DEVOPS_USER
  require_value PING_IDENTITY_DEVOPS_KEY
fi

PING_CHART_VERSION="${PING_CHART_VERSION:-0.15.0}"
CHART_DIR="${ROOT_DIR}/helm/pingfederate"

# Server profile pointer lives in the chart values (a project pointer, not
# operator config). Read the three flat keys from our own controlled file.
PROFILE_URL="$(awk '/^profile:/{f=1;next} f&&/^  url:/{print $2;exit}' "${CHART_DIR}/values.yaml")"
PROFILE_PATH="$(awk '/^profile:/{f=1;next} f&&/^  path:/{print $2;exit}' "${CHART_DIR}/values.yaml")"
SERVER_PROFILE_BRANCH="${SERVER_PROFILE_BRANCH:-$(awk '/^profile:/{f=1;next} f&&/^  branch:/{print $2;exit}' "${CHART_DIR}/values.yaml")}"
[[ -n "${PROFILE_URL}" && -n "${PROFILE_PATH}" && -n "${SERVER_PROFILE_BRANCH}" ]] || {
  echo "Cannot read profile.url/profile.path/profile.branch from ${CHART_DIR}/values.yaml" >&2
  exit 1
}

# --- Derived values (override via env or --set to deviate) ------------------
# Public hostname follows the standard ping-devops chart convention, as in
# the operator's other deployments: <release>-<product>.ping-devops.com,
# served by the public nginx controller's wildcard *.ping-devops.com cert.
PF_PUBLIC_HOSTNAME="${PF_PUBLIC_HOSTNAME:-${PF_RELEASE}-pingfederate-engine.ping-devops.com}"
# Endpoints all hang off the public hostname.
PF_TOKEN_ENDPOINT_AUDIENCE="${PF_TOKEN_ENDPOINT_AUDIENCE:-https://${PF_PUBLIC_HOSTNAME}/as/token.oauth2}"
OUTPUT_ISSUER="${OUTPUT_ISSUER:-https://${PF_PUBLIC_HOSTNAME}}"
OUTPUT_JWKS_URL="${OUTPUT_JWKS_URL:-https://${PF_PUBLIC_HOSTNAME}/pf/JWKS}"

# Fixed lab constants (match cli/config defaults and the bulk config).
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

GENERATED_VALUES="$(mktemp -t pf-agentcore-values).yaml"
mv "${GENERATED_VALUES%.yaml}" "${GENERATED_VALUES}"
trap 'rm -f "${GENERATED_VALUES}"' EXIT

# Under the umbrella chart, subchart values must be nested under the
# dependency key (ping-devops:); the perf sibling uses the chart directly and
# writes pingfederate-admin.envs at the top level — here that path is
# invisible to the subchart and env vars silently never reach the pods.
cat > "${GENERATED_VALUES}" <<EOF
ping-devops:
  pingfederate-admin:
    envs:
      DEMO_USERNAME: "${DEMO_USERNAME}"
      DEMO_PASSWORD: "${DEMO_PASSWORD}"
    AWS_STS_ISSUER: "${AWS_STS_ISSUER:?AWS_STS_ISSUER required — run ./aws/setup-identity.sh (it writes it into .env)}"
    AWS_STS_JWKS_URL: "${AWS_STS_JWKS_URL:?AWS_STS_JWKS_URL required — run ./aws/setup-identity.sh (it writes it into .env)}"
    PF_TOKEN_ENDPOINT_AUDIENCE: "${PF_TOKEN_ENDPOINT_AUDIENCE}"
    OUTPUT_ISSUER: "${OUTPUT_ISSUER}"
    OUTPUT_JWKS_URL: "${OUTPUT_JWKS_URL}"
    RUNTIME_API_AUDIENCE: "${RUNTIME_API_AUDIENCE}"
    DEMO_RESOURCE_URI: "${DEMO_RESOURCE_URI}"
    PF_CLI_CLIENT_ID: "${PF_CLI_CLIENT_ID}"
    PF_CLI_REDIRECT_URI: "${PF_CLI_REDIRECT_URI}"
    PF_AGENT_CLIENT_ID: "${PF_AGENT_CLIENT_ID}"
    PING_IDENTITY_PASSWORD: "${PING_IDENTITY_PASSWORD}"
    SERVER_PROFILE_URL: "${PROFILE_URL_WITH_CREDS}"
    SERVER_PROFILE_PATH: "${PROFILE_PATH}"
    SERVER_PROFILE_BRANCH: "${SERVER_PROFILE_BRANCH}"
  pingfederate-engine:
    envs:
      SERVER_PROFILE_URL: "${PROFILE_URL_WITH_CREDS}"
      SERVER_PROFILE_PATH: "${PROFILE_PATH}"
      SERVER_PROFILE_BRANCH: "${SERVER_PROFILE_BRANCH}"
EOF

if [[ "${HAVE_SECRET}" == "yes" ]]; then
  echo "devops-secret already exists in ${NAMESPACE}; leaving it untouched."
else
  kubectl -n "${NAMESPACE}" create secret generic devops-secret \
    --from-literal=PING_IDENTITY_DEVOPS_USER="${PING_IDENTITY_DEVOPS_USER}" \
    --from-literal=PING_IDENTITY_DEVOPS_KEY="${PING_IDENTITY_DEVOPS_KEY}" \
    --from-literal=PING_IDENTITY_ACCEPT_EULA="${PING_IDENTITY_ACCEPT_EULA:-YES}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# The image's git clone reads credentials from the SERVER_PROFILE_URL itself
# (envsubst expands the placeholders inside the pod, supplied by the chart's
# optional *-git-secret).
PROFILE_URL_WITH_CREDS="${PROFILE_URL}"
case "${PROFILE_URL}" in
  https://*)
    PROFILE_URL_WITH_CREDS="https://\${SERVER_PROFILE_GIT_USER}:\${SERVER_PROFILE_GIT_PASSWORD}@${PROFILE_URL#https://}"
    ;;
esac

helm dependency update "${CHART_DIR}"

helm upgrade --install "${PF_RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" ${CREATE_NS} \
  --values "${CHART_DIR}/values.yaml" \
  --values "${GENERATED_VALUES}" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  --wait --timeout 15m

echo
kubectl -n "${NAMESPACE}" get pods,services,ingress -l "app.kubernetes.io/instance=${PF_RELEASE}" -o wide 2>/dev/null || \
  kubectl -n "${NAMESPACE}" get pods,services,ingress
echo
echo "Confirm the bulk import succeeded:"
echo "  kubectl -n ${NAMESPACE} logs deploy/pf-pingfederate-admin -c pingfederate-admin | grep -i bulk"
echo "  'INFO: Removing Imported Bulk File' = success."
