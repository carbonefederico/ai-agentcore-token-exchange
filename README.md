# AgentCore ⇄ PingFederate delegated token exchange

A proof of concept for **delegated, secretless OAuth between an AI agent on
AWS Bedrock AgentCore and APIs protected by PingFederate**.

The problem: an agent acting for a user must call downstream APIs with a
token that proves **both** who the user is and which agent acted for them —
without storing any secret in the agent. The solution: the OAuth 2.0 Token
Exchange grant (RFC 8693). The agent's platform identity (AWS KMS-signed)
authenticates the exchange, the user's token is the subject, and
PingFederate issues one short-lived token carrying both identities
(`sub` = user, `act.sub` = agent). AgentCore Identity drives the whole
outbound flow, so the agent code holds no OAuth logic and no credentials.

- What gets built: PingFederate on k8s (declarative server profile), an
  agent on AgentCore Runtime, a demo CLI — and the identity wiring between
  them (KMS key, credential provider, IAM grants).
- The end state: `cli/demo_cli.py` logs a user in, invokes the agent, and
  prints the delegated token's claims showing user + agent identity.
- Full architecture: **[docs/architecture.md](docs/architecture.md)** —
  flow, components, token shape, and design rationale.

## Repository layout

```
docs/architecture.md                  Architecture: flow, components, rationale
docs/agentcore-obo-limitation.md      Why credential-free client auth is impossible
agent/main.py                         The hosted agent (LLM stub disabled)
agentcore/agentcore.json              AgentCore CLI runtime config
agentcore/cdk/                        CDK app: IAM grants (KMS sign, token vault)
cli/demo_cli.py                       The demo CLI client
pf_common.py                          Shared helpers (login, token cache, config)
pf_preflight.py                       Read-only PingFederate preflight checks
server-profiles/pingfederate-agentcore/  Declarative PF config (bulk config)
helm/pingfederate/values.yaml         Overrides for Ping's official chart
scripts/                              deploy / verify / validate / uninstall
aws/teardown.sh                       AgentCore stack + provider removal
config.example.env                    CLI/preflight config template → copy to config.env
.env.example                          Helm deployment template → copy to .env
requirements.txt                      CLI/preflight dependencies (requests, boto3)
```

## Prerequisites

- Kubernetes cluster, `kubectl`, Helm 3; `nginx-public` ingress class
- Ping DevOps user/key for the license (export or `.env`)
- A git repository hosting `server-profiles/pingfederate-agentcore/`
  (`helm/pingfederate/values.yaml` pins it)
- AWS credentials for IAM, Bedrock AgentCore, ECR; a customer-managed KMS
  key (RS256) — the key ID is pinned in `agentcore/cdk/lib/cdk-stack.ts`
- [AgentCore CLI](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-cli.html)
  (`pip install bedrock-agentcore-starter-toolkit`)
- python3, docker

## Step 1 — PingFederate on k8s

```bash
./scripts/validate.sh
./scripts/deploy.sh                     # 1 admin + 1 engine, bulk config at startup
./scripts/verify.sh                     # confirm import + engine Ready
```

The profile is self-contained: hostname variables are image-provided and
the KMS client material is inline. It provisions the demo form login, the
token processors, the token-exchange policy (actor token mandatory), the
confidential CLI client, and the agent client (KMS public key,
`private_key_jwt`). See
[server-profiles/pingfederate-agentcore/README.md](server-profiles/pingfederate-agentcore/README.md).

## Step 2 — AWS identity setup (out-of-band)

The KMS key and the `pingfederate-obo-poc2` credential provider
(CustomOauth2, `private_key_jwt` + M2M actor leg) are created out-of-band;
`agentcore/cdk/lib/cdk-stack.ts` documents the IAM shape.

## Step 3 — Deploy the agent (AgentCore CLI)

```bash
# edit agentcore/agentcore.json: discoveryUrl → your PF host,
#   allowedAudience → the AgentCore invoke audience
agentcore deploy
agentcore status         # wait for READY; note the runtime ID for the CLI
```

The runtime is declared with `requestHeaderAllowlist: ["Authorization"]`
(forwards the validated user JWT), `protocol: HTTP`, and the custom JWT
authorizer against PingFederate's OIDC discovery endpoint.

## Step 4 — Run the demo

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp config.example.env config.env        # PF_BASE_URL, AGENT_RUNTIME_NAME, etc.

python3 pf_preflight.py                 # optional: endpoints + PF config checks
python3 cli/demo_cli.py                 # login → invoke agent → claims
```

Expected CLI output:

```
Authenticating user with PingFederate...
Authentication successful.
Invoking AgentCore agent...
Agent invoked successfully.
AgentCore Identity:
  Outbound token exchange: SUCCESS
  Authentication method:   KMS-signed private_key_jwt (no client secret)
Exchanged PingFederate token claims:
{
  "act": { "sub": "arn:aws:iam::<account>:role/AgentCore-tokenexchangeag-..." },
  "aud": "<DEMO_RESOURCE_URI>",
  "scope": "demo:read",
  "sub": "demouser"
}
RESULT: SUCCESS
```

The agent source also contains the LLM/tool reference code, **commented
out** with a disclaimer: the demo's goal is the delegated exchange; that
code shows how the exchanged token would be used downstream by a real agent.

## Teardown

```bash
./aws/teardown.sh        # runtime (agentcore CLI) + credential provider;
                         # the KMS key is out-of-band and not removed
./scripts/uninstall.sh   # PingFederate release
```

## Security

No client secret is stored for the agent: it authenticates with a KMS-signed
assertion whose private key never leaves AWS KMS, and the PF client holds
only the public key. The CLI is a confidential demo client (secret lives in
the server profile). Tokens are cached locally in `tokens.cache`
(git-ignored); scripts print decoded claims, never raw tokens. `.env` and
`config.env` are git-ignored. The PingFederate Admin API is used read-only
(preflight); configuration flows exclusively from the server profile.
