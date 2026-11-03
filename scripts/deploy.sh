#!/usr/bin/env bash
# Deploy PingFederate (official ping-devops chart, values.yaml in this repo)
# configured for the AgentCore token exchange via this repo's server profile.
# The profile's bulk config needs no external values: the hostname variables
# are image-provided and the KMS client material is inline.
#
# Namespace works like any helm command: the context's default, or pass
# --namespace. Same for other helm flags.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command helm

helm upgrade --install "${PF_RELEASE}" pingidentity/ping-devops \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --wait --timeout 15m

echo
kubectl get pods,ingress -l "app.kubernetes.io/instance=${PF_RELEASE}"
