#!/usr/bin/env bash
# Deploy PingFederate (official ping-devops chart, values.yaml in this repo)
# configured for the AgentCore token exchange via this repo's server profile.
# Hostname variables are image-provided and the KMS client material is
# inline; the only external values are the AWS STS issuer/JWKS consumed by
# the AwsStsTokenProcessor (the exchange actor-token validator). They come
# from .env (written by the AWS one-time setup) or are derived from the
# account ID in agentcore/aws-targets.json.
#
# Namespace works like any helm command: the context's default, or pass
# --namespace. Same for other helm flags.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command helm

[[ -f "${ROOT_DIR}/.env" ]] && { set -a; source "${ROOT_DIR}/.env"; set +a; }

ACCOUNT="$(python3 -c "import json;print(json.load(open('${ROOT_DIR}/agentcore/aws-targets.json'))[0]['account'])")"
AWS_STS_ISSUER="${AWS_STS_ISSUER:-https://${ACCOUNT}.tokens.sts.global.api.aws}"
AWS_STS_JWKS_URL="${AWS_STS_JWKS_URL:-${AWS_STS_ISSUER}/.well-known/jwks.json}"

helm upgrade --install "${PF_RELEASE}" pingidentity/ping-devops \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --set-string "pingfederate-admin.envs.AWS_STS_ISSUER=${AWS_STS_ISSUER}" \
  --set-string "pingfederate-admin.envs.AWS_STS_JWKS_URL=${AWS_STS_JWKS_URL}" \
  --wait --timeout 15m

echo
kubectl get pods,ingress -l "app.kubernetes.io/instance=${PF_RELEASE}"
