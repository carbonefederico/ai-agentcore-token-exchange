#!/usr/bin/env bash
# Static validation: shell syntax, JSON well-formedness of the bulk config,
# helm render of the ping-devops values (when helm is installed).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for script in "${ROOT_DIR}"/scripts/*.sh; do
  bash -n "${script}"
done
echo "Shell syntax OK."

python3 - <<'EOF'
import json

path = "server-profiles/pingfederate-agentcore/instance/bulk-config/data.json.subst"
with open(path) as f:
    doc = json.load(f)

ops = doc["operations"]
ids = {op["resourceType"] for op in ops}
required = {
    "/idp/adapters",
    "/idp/tokenProcessors",
    "/oauth/accessTokenManagers",
    "/oauth/tokenExchange/processor/policies",
    "/oauth/tokenExchange/processor/settings",
    "/oauth/accessTokenMappings",
    "/oauth/clients",
}
missing = required - ids
assert not missing, f"bulk config missing operations for: {missing}"

# Every resource type that carries item ids: collect them.
def items_for(rt):
    for op in ops:
        if op["resourceType"] == rt:
            return op["items"]
    return []

proc_ids = {i["id"] for i in items_for("/idp/tokenProcessors")}
assert {"AgentCorePingFederateUserProcessor", "AgentCoreAwsStsTokenProcessor"} <= proc_ids, proc_ids

atm_ids = {i["id"] for i in items_for("/oauth/accessTokenManagers")}
assert {"AgentCoreDelegatedATM", "AgentCoreUserATM"} <= atm_ids, atm_ids

client_ids = {i["clientId"] for i in items_for("/oauth/clients")}
assert "${PF_CLI_CLIENT_ID}" in client_ids and "${PF_AGENT_CLIENT_ID}" in client_ids, client_ids

tepps = items_for("/oauth/tokenExchange/processor/policies")
assert tepps and tepps[0]["actorTokenRequired"] is True
mappings = items_for("/oauth/accessTokenMappings")
assert any(m["context"]["type"] == "AUTHORIZATION_CODE" for m in mappings)
print("Bulk config structure OK.")
EOF
echo "Bulk config OK."

if command -v helm >/dev/null 2>&1; then
  # Full render of the umbrella chart (ping-devops subchart + our ingress
  # and certificate templates).
  helm repo add pingidentity https://helm.pingidentity.com/ --force-update >/dev/null 2>&1 || true
  if helm template pf "${ROOT_DIR}/helm/pingfederate" \
      --set-string pf.publicHost=pf.example.com >/dev/null 2>&1; then
    echo "helm render OK (umbrella chart incl. ingress + certificate)."
  else
    echo "helm render failed:" >&2
    helm template pf "${ROOT_DIR}/helm/pingfederate" --set-string pf.publicHost=pf.example.com 2>&1 | tail -5 >&2
    exit 1
  fi
else
  echo "helm is not installed; skipped helm render validation."
fi

echo "Static validation passed."
