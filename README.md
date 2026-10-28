# AgentCore Secretless Identity Federation — POC

Secretless, delegated OAuth token exchange between **AWS Bedrock AgentCore**
and **PingFederate** (k8s). The agent authenticates to PingFederate with an
AWS-issued IAM identity JWT — as the RFC 7523 client assertion *and* as the
RFC 8693 actor token — and AgentCore Identity brokers the whole exchange. No
client secrets, no client ID (AgentCore side), no managed private keys.

See **[SPEC.md](SPEC.md)** for the architecture, the verified compatibility
verdict, security requirements, and the phased plan.

## Repository layout

```
SPEC.md                                Architecture, verdict, acceptance criteria
config.example.env                     Phase 0 config template → copy to config.env
.env.example                           Deployment config template → copy to .env
requirements.txt                       Phase 0 dependencies (boto3, requests)
pf_phase0_common.py                    Shared helpers (login, STS JWT, exchange)
pf_phase0_preflight.py                 Read-only PingFederate + AWS preflight
pf_phase0_exchange.py                  Raw RFC 8693 exchange test (no AgentCore)
helm/pingfederate/values.yaml          Overrides for Ping's official chart
server-profiles/pingfederate-agentcore/  Declarative PF config (bulk config)
scripts/                               deploy / verify / smoke / keys / teardown
agent/main.py                          The hosted agent (LLM stub disabled)
agentcore.json + aws-targets.json      AgentCore CLI deployment config
aws/setup-identity.sh                  Federation, IAM role, credential provider
aws/teardown.sh                        Removal of everything the POC created
cli/demo_cli.py                        The demo CLI client
```

## Prerequisites

- Kubernetes cluster and a working `kubectl` context; Helm 3
- Ingress controller (`nginx-public` class) with cert-manager and the
  `letsencrypt-pdo` ClusterIssuer — the chart templates the public Ingress
  and Certificate for PingFederate
- Ping DevOps user/key for the license — operator-level, from your own
  environment (export or `.env`; `scripts/deploy.sh` fails fast if missing)
- A git repository hosting `server-profiles/pingfederate-agentcore/`
- AWS credentials with permissions for IAM, STS, Bedrock AgentCore
- [AgentCore CLI](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-cli.html)
  (`pip install bedrock-agentcore-starter-toolkit`) for the agent deployment
- python3, openssl, docker (for the CLI client and the keys)

## Step 1 — PingFederate on k8s

```bash
cp .env.example .env                    # fill in; AWS_STS_ISSUER comes from step 2
# push server-profiles/pingfederate-agentcore/ to your profiles repo,
# set SERVER_PROFILE_URL/PATH in .env
./scripts/validate.sh
./scripts/deploy.sh                     # 1 admin + 2 engines, bulk config at startup
./scripts/verify.sh                     # confirm import + 2 Ready engines
```

The bulk config provisions: the demo form adapter, the PingFederate user
token processor and the AWS STS token processor, two JWT access token
managers, the TEPP (`actorTokenRequired: true`), both access token mappings,
the public PKCE CLI client, and the secretless agent client
(`client_id` = the agent IAM role ARN, `PRIVATE_KEY_JWT` auth, JWKS URL =
the AWS STS JWKS). See
[server-profiles/pingfederate-agentcore/README.md](server-profiles/pingfederate-agentcore/README.md).

## Step 2 — AWS identity setup

```bash
aws sso login                           # or your usual AWS login
./aws/setup-identity.sh
```

This enables outbound web identity federation (prints the STS issuer URL —
copy it into `.env` and redeploy PF if you ran step 1 first), creates the
`agentcore-demo-agent` role (conditioned `sts:GetWebIdentityToken`, AgentCore
Identity data-plane permissions), and creates the secretless custom OAuth2
credential provider (`AWS_IAM_ID_TOKEN_JWT` client auth, `TOKEN_EXCHANGE`
grant, `AWS_IAM_ID_TOKEN_JWT` actor token — no client ID, no secret).

## Step 3 — Deploy the agent (AgentCore CLI)

```bash
# edit agentcore.json: discoveryUrl → your PF host,
#   allowedAudience → RUNTIME_API_AUDIENCE from .env
agentcore configure      # binds the project (uses agentcore.json + aws-targets.json)
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

# Optional but recommended before the full demo:
python3 pf_phase0_preflight.py
python3 pf_phase0_exchange.py           # proves the PF-side exchange with curl-equivalent HTTP

python3 cli/demo_cli.py                 # PKCE login → invoke agent → claims
```

Expected CLI output:

```
Authenticating user with PingFederate...
Authentication successful.
Invoking AgentCore agent...
Agent invoked successfully.
AgentCore Identity:
  Outbound token exchange: SUCCESS
  Authentication method:   AWS_IAM_ID_TOKEN_JWT (no client secret)
Exchanged PingFederate token claims:
{
  "act": { "sub": "arn:aws:iam::<account>:role/agentcore-demo-agent" },
  "aud": "<DEMO_RESOURCE_URI>",
  "scope": "demo:read",
  "sub": "demouser"
}
RESULT: SUCCESS
```

The agent source also contains the LLM/tool reference code, **commented out**
with a disclaimer: the demo's goal is the secretless exchange; that code
shows how the exchanged token would be used downstream by a real agent
(single Bedrock turn, one tool carrying the delegated token).

## Teardown

```bash
./aws/teardown.sh        # runtime (agentcore CLI), provider, IAM role;
                         # prompts before disabling outbound federation
./scripts/uninstall.sh   # PingFederate release
```

## Security

No client secrets anywhere; the CLI is a public PKCE client, the agent
authenticates with its AWS-issued IAM identity JWT. Signing material lives
only in AWS STS. Tokens stay in memory — scripts print decoded claims, never
raw tokens. `.env` and `config.env` are git-ignored. The PingFederate Admin
API is used read-only (preflight); configuration flows exclusively from the
server profile.
