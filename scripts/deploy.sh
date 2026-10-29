#!/usr/bin/env bash
# Deploy PingFederate (official ping-devops chart, values.yaml in this repo)
# configured for the AgentCore secretless token exchange via this repo's
# server profile.
#
# The script only supplies the AWS-side values the profile's bulk config
# expands (from ./aws/setup-identity.sh). Everything else is in the profile.
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
EOF

PING_CHART_VERSION="${PING_CHART_VERSION:-0.15.0}"
helm upgrade --install "${PF_RELEASE}" pingidentity/ping-devops \
  --version "${PING_CHART_VERSION}" \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --values "${GENERATED_ENVS}" \
  --wait --timeout 15m

echo
kubectl get pods,ingress -l "app.kubernetes.io/instance=${PF_RELEASE}"
