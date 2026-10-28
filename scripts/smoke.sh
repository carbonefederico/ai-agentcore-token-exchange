#!/usr/bin/env bash
# Post-deploy smoke: raw RFC 8693 exchange against the deployed PingFederate,
# using the demo user's CLI login + a locally obtained AWS STS JWT. Reuses
# the Phase 0 helper (pf_phase0_common.py) for login and exchange. Point
# config.env at the deployed instance, port-forward if testing in-cluster:
#   kubectl -n pf-agentcore port-forward service/pf-pingfederate-engine 9031:9031
# then set PF_BASE_URL=https://localhost:9031 in config.env.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 pf_phase0_exchange.py
