#!/usr/bin/env bash
# Remove the PingFederate release. The namespace and its Secrets are retained.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command helm

helm uninstall "${PF_RELEASE}" --namespace "${NAMESPACE}"
echo "Namespace ${NAMESPACE} and its Secrets were retained."
