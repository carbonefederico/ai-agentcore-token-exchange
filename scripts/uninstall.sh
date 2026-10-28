#!/usr/bin/env bash
# Remove the PingFederate release. Namespace: -n <ns>, else the current
# kubectl context's namespace. Secrets in the namespace are retained.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command helm

NAMESPACE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)"
  NAMESPACE="${NAMESPACE:-default}"
fi

helm uninstall "${PF_RELEASE}" --namespace "${NAMESPACE}"
echo "Namespace ${NAMESPACE} and its Secrets were retained."
