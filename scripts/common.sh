#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

# No NAMESPACE logic here: the namespace is an install-time decision passed
# to the scripts (-n) or resolved by kubectl from the current context —
# matching plain helm workflow. PF release name follows the ping-devops
# hostname convention (<release>-pingfederate-engine.ping-devops.com).
PF_RELEASE="${PF_RELEASE:-pf}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "Required value is empty: ${name}" >&2
    exit 1
  }
}
