#!/usr/bin/env bash
# One-time key material generation for the PingFederate deployment.
#
# The bulk import REQUIRES the SSL server keypair the instance will activate
# (bulk_config_ssl_server_config_invalid otherwise) — this is a PingFederate
# bulk-config requirement, not a TLS trust requirement: nothing external
# validates the engines' own certificate (TLS terminates on the ingress with
# the wildcard *.ping-devops.com cert; nginx does not verify the upstream).
#
# Generates (once, stable across deployments; --force to regenerate):
#   keys/pf-runtime.key + keys/pf-runtime.crt  self-signed pair (unused
#       externally; exists to be packaged)
#   keys/agentcore-ssl-server.p12              PKCS#12 imported by the bulk
#                                              config as the active keypair
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="${ROOT_DIR}/keys"
KEY_FILE="${KEYS_DIR}/pf-runtime.key"
CRT_FILE="${KEYS_DIR}/pf-runtime.crt"
P12_FILE="${KEYS_DIR}/agentcore-ssl-server.p12"
ALIAS="sslservercert"
PASS="${AGENTCORE_SSL_SERVER_P12_PASSWORD:-}"

if [[ "${1:-}" == "--force" ]]; then
  rm -f "${KEY_FILE}" "${CRT_FILE}" "${P12_FILE}"
elif [[ -f "${CRT_FILE}" && -f "${P12_FILE}" ]]; then
  echo "Keys already exist (${CRT_FILE}, ${P12_FILE}); use --force to regenerate."
  exit 0
fi

if [[ -z "${PASS}" ]]; then
  # Generate and persist one, so the operator does not have to.
  PASS="$(openssl rand -hex 16)"
  mkdir -p "${ROOT_DIR}"
  if grep -q '^AGENTCORE_SSL_SERVER_P12_PASSWORD=' "${ROOT_DIR}/.env" 2>/dev/null; then
    sed -i.bak "s|^AGENTCORE_SSL_SERVER_P12_PASSWORD=.*|AGENTCORE_SSL_SERVER_P12_PASSWORD=${PASS}|" "${ROOT_DIR}/.env" && rm -f "${ROOT_DIR}/.env.bak"
  else
    printf 'AGENTCORE_SSL_SERVER_P12_PASSWORD=%s\n' "${PASS}" >> "${ROOT_DIR}/.env"
  fi
  echo "Generated AGENTCORE_SSL_SERVER_P12_PASSWORD into .env"
fi

mkdir -p "${KEYS_DIR}"

openssl req -x509 -newkey rsa:2048 -keyout "${KEY_FILE}" \
  -out "${CRT_FILE}" -days 3650 -nodes \
  -subj "/CN=pf-pingfederate" \
  -addext "subjectAltName=DNS:pf-pingfederate,DNS:localhost"

openssl pkcs12 -export -inkey "${KEY_FILE}" -in "${CRT_FILE}" \
  -out "${P12_FILE}" -name "${ALIAS}" -password "pass:${PASS}"

echo "Generated:"
echo "  ${KEY_FILE}            (git-ignored)"
echo "  ${CRT_FILE}            (git-ignored)"
echo "  ${P12_FILE}  (git-ignored)"
