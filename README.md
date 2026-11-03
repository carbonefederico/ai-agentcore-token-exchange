# AgentCore Secretless Identity Federation — POC

Secretless, delegated OAuth token exchange between **AWS Bedrock AgentCore**
and **PingFederate** (k8s). AgentCore Identity brokers the outbound exchange:
the agent client authenticates to PingFederate with a **KMS-signed
`private_key_jwt` assertion** (PingFederate holds only the KMS public key,
inline as a JWKS), and the RFC 8693 **actor token is a PingFederate-issued
`client_credentials` token** from AgentCore Identity's M2M leg. No client
secret is stored anywhere; no AWS STS identity token is involved.

See **[docs/current-design.md](docs/current-design.md)** for the end-to-end
flow, the component reference, and the design-evolution table. The original
2026-10-28 specification (AWS-JWT design) is kept in
**[SPEC.md](SPEC.md)**; `docs/agentcore-obo-limitation.md` records why
credential-free client authentication is impossible with AgentCore Identity.

## Repository layout

```
SPEC.md                                Original spec (AWS-JWT design) — superseded
docs/current-design.md                 Current design: flow, components, evolution
docs/agentcore-obo-limitation.md       Why credential-free client auth is impossible
config.example.env                     CLI/preflight config template → copy to config.env
.env.example                           Helm deployment template → copy to .env
requirements.txt                       CLI/preflight dependencies (requests, boto3)
pf_phase0_common.py                    Shared helpers (login, token cache, config)
pf_phase0_preflight.py                 Read-only PingFederate preflight checks
agent/main.py                          The hosted agent (LLM stub disabled)
agentcore/agentcore.json               AgentCore CLI runtime config
agentcore/cdk/                         CDK app: IAM grants (KMS sign, token vault)
helm/pingfederate/values.yaml          Overrides for Ping's official chart
server-profiles/pingfederate-agentcore/  Declarative PF config (bulk config)
scripts/                               deploy / verify / validate / uninstall
aws/teardown.sh                        AgentCore stack + provider removal
cli/demo_cli.py                        The demo CLI client
```

## Prerequisites

- Kubernetes cluster and a working `kubectl` context; Helm 3
- Ingress controller (`nginx-public` class); the chart templates the public
  Ingress for PingFederate
- Ping DevOps user/key for the license — operator-level, from your own
  environment (export or `.env`; the chart fails without it)
- A git repository hosting `server-profiles/pingfederate-agentcore/`
  (`helm/pingfederate/values.yaml` pins it)
- AWS credentials for IAM (KMS key), Bedrock AgentCore, ECR
- [AgentCore CLI](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-cli.html)
  (`pip install bedrock-agentcore-starter-toolkit`) for the agent deployment
- A customer-managed KMS key (RS256) for the `private_key_jwt` client
  assertion — created out-of-band; the key ID is pinned in
  `agentcore/cdk/lib/cdk-stack.ts`
- python3, docker (for the CLI client and the agent build)

## Step 1 — PingFederate on k8s

```bash
./scripts/validate.sh
./scripts/deploy.sh                     # 1 admin + 1 engine, bulk config at startup
./scripts/verify.sh                     # confirm import + engine Ready
```

The profile needs no external values: the hostname variables are
image-provided and the KMS client material is inline. The bulk config
provisions the demo form login, the PF user/client token processors, two JWT
access token managers, the TEPP (`actorTokenRequired: true`), both access
token mappings, the confidential CLI client (`agentcore-demo-cli`), and the
agent client (KMS public key inline, `PRIVATE_KEY_JWT`,
`TOKEN_EXCHANGE` + `CLIENT_CREDENTIALS`). See
[server-profiles/pingfederate-agentcore/README.md](server-profiles/pingfederate-agentcore/README.md).

## Step 2 — AWS identity setup (out-of-band)

The KMS key and the `pingfederate-obo-poc2` credential provider (CustomOauth2,
`private_key_jwt` client auth, M2M client-credentials actor leg) were created
out-of-band and are not scripted in this repo. Recreate them manually if
starting from scratch; `agentcore/cdk/lib/cdk-stack.ts` documents the exact
IAM shape (token vault, Secrets Manager, `kms:Sign`).

## Step 3 — Deploy the agent (AgentCore CLI)

```bash
# edit agentcore/agentcore.json: discoveryUrl → your PF host,
#   allowedAudience → the AgentCore invoke audience
agentcore configure      # binds the project (agentcore/ + aws-targets.json)
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

python3 pf_phase0_preflight.py          # optional: endpoints + PF config checks
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

The agent source also contains the LLM/tool reference code, **commented out**
with a disclaimer: the demo's goal is the secretless exchange; that code
shows how the exchanged token would be used downstream by a real agent.

## Teardown

```bash
./aws/teardown.sh        # runtime (agentcore CLI) + credential provider;
                         # the KMS key is out-of-band and not removed
./scripts/uninstall.sh   # PingFederate release
```

## Security

No client secrets are stored: the CLI is a confidential demo client (secret
lives in the server profile), the agent authenticates with a KMS-signed
assertion whose private key never leaves AWS KMS, and AgentCore Identity
holds the exchange together. The PF client for the agent holds only the KMS
public key. Tokens are cached locally in `tokens.cache` (git-ignored) for
convenience; scripts print decoded claims, never raw tokens. `.env` and
`config.env` are git-ignored. The PingFederate Admin API is used read-only
(preflight); configuration flows exclusively from the server profile.
