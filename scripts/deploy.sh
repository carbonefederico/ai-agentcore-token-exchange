#!/usr/bin/env bash
# Deploy PingFederate (official ping-devops chart, values.yaml in this repo)
# configured for the AgentCore secretless token exchange via this repo's
# server profile.
#
# The script only passes the AWS-side values the profile's bulk config
# expands (written to .env by ./aws/setup-identity.sh).
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

helm upgrade --install "${PF_RELEASE}" pingidentity/ping-devops \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --set-string "pingfederate-admin.envs.AWS_STS_ISSUER=${AWS_STS_ISSUER}" \
  --set-string "pingfederate-admin.envs.AWS_STS_JWKS_URL=${AWS_STS_JWKS_URL}" \
  --set-string "pingfederate-admin.envs.PF_AGENT_CLIENT_ID=${PF_AGENT_CLIENT_ID}" \
  --wait --timeout 15m

echo
kubectl get pods,ingress -l "app.kubernetes.io/instance=${PF_RELEASE}"
