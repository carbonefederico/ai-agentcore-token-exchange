#!/usr/bin/env bash
# Confirm the PF admin imported the bulk config and the engines are Ready.
# Namespace: -n <ns>, else the current kubectl context's namespace.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command kubectl

NAMESPACE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)"
  NAMESPACE="${NAMESPACE:-default}"
fi

echo "== Pods =="
kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${PF_RELEASE}" -o wide

echo
echo "== Bulk import result =="
kubectl -n "${NAMESPACE}" logs deploy/pf-pingfederate-admin -c pingfederate-admin 2>/dev/null \
  | grep -i bulk || echo "(no bulk log lines found — import may still be running)"

echo
echo "== Engine count (expect 2) =="
kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${PF_RELEASE},app.kubernetes.io/name=pingfederate-engine" \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l
