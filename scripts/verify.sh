#!/usr/bin/env bash
# Confirm the PF admin imported the bulk config and the engines are Ready.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command kubectl

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
