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
- The end state: `tests/demo_cli.py` logs a user in, invokes the agent, and
  prints the delegated token's claims showing user + agent identity.
- Full architecture: **[docs/architecture.md](docs/architecture.md)** —
  flow, components, token shape, and design rationale.

## Logical architecture

```mermaid
flowchart LR
    CLI["Demo CLI\ntests/demo_cli.py"]

    subgraph aws["AWS"]
        direction TB
        RT["AgentCore Inbound Token Validator"]
        AG["Hosted Agent - AgentCore"]
        ID["AgentCore Outbound Token Generator"]
        KMS["KMS\nclient-assertion key"]
        STS["STS\nIAM identity JWT issuer"]
    end

    PF["PingFederate k8s\nlogin + token exchange + ATM"]

    CLI -- "1. authz-code + PKCE, browser" --> PF
    PF -- "2. user JWT" --> CLI
    CLI -- "3. invoke, Bearer user JWT" --> RT
    RT -- "4. forward" --> AG
    AG -- "5. GetResourceOauth2Token" --> ID
    ID -- "6. sign client assertion" --> KMS
    ID -- "7. actor token: sts:GetWebIdentityToken" --> STS
    ID -- "8. RFC 8693 exchange: assertion + subject + actor" --> PF
    PF -- "fetch actor-token verification keys: STS JWKS" --> STS
    PF -- "9. delegated token" --> ID
    ID -- "10. access token" --> AG
    AG -- "11. claims only" --> CLI
```

## The tokens

Four tokens participate in the demo:

**1. User token — issued by PingFederate after the browser login**
(`tests/demo_cli.py`, Authorization Code + PKCE as the confidential client
`agentcore-demo-cli`). This is the exchange's **subject token**; AgentCore
Runtime validates it with its custom JWT authorizer before forwarding it:

```json
{
  "iss": "https://ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com",
  "aud": "https://agentcore.demo.internal/invoke",
  "sub": "demouser",
  "client_id": "agentcore-demo-cli",
  "scope": "openid demo:read",
  "iat": 1793712826,
  "exp": 1793713726
}
```

**2. Client assertion — signed by AWS KMS, sent as `private_key_jwt` client
authentication** on the exchange request. AgentCore Identity signs it with
the customer-managed KMS key (`kms:Sign`); PingFederate validates it
against the client's inline public-key JWKS. Lifetime is ~90 seconds and it
is minted fresh per exchange:

```json
{
  "iss": "arn:aws:iam::574076504146:role/AgentCore-tokenexchangeag-ApplicationRuntimeExchang-cR6Ap8URe01B",
  "sub": "arn:aws:iam::574076504146:role/AgentCore-tokenexchangeag-ApplicationRuntimeExchang-cR6Ap8URe01B",
  "aud": "https://ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com/as/token.oauth2",
  "jti": "<uuid>",
  "iat": 1793711082,
  "nbf": 1793711082,
  "exp": 1793711172
}
```

**3. Actor token — the AWS IAM identity JWT**, obtained by AgentCore
Identity via `sts:GetWebIdentityToken` (audience = the PingFederate token
endpoint, ≤ 5 minutes). This is the AWS-signed proof of the agent's
workload identity; PingFederate validates it against the account's STS
issuer/JWKS and maps its `sub` into `act.sub`:

```json
{
  "iss": "https://a1d2bfe2-6e32-49b2-ab3c-aefda84f2188.tokens.sts.global.api.aws",
  "aud": "https://ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com/as/token.oauth2",
  "sub": "arn:aws:iam::574076504146:role/AgentCore-tokenexchangeag-ApplicationRuntimeExchang-cR6Ap8URe01B",
  "https://sts.amazonaws.com/": {
    "aws_account": "574076504146",
    "org_id": "o-yodmnogh9l",
    "principal_id": "arn:aws:iam::574076504146:role/AgentCore-tokenexchangeag-ApplicationRuntimeExchang-cR6Ap8URe01B",
    "source_region": "eu-central-1"
  },
  "jti": "<uuid>",
  "iat": 1793713047,
  "nbf": 1793713047,
  "exp": 1793713347
}
```

**4. Delegated token — issued by PingFederate's token-exchange policy**,
combining all three inputs. This is what a downstream resource server would
receive: the user who is being acted for (`sub`), the agent that acts
(`act.sub`, from the AWS JWT), the scope the policy allows, and the
audience (`aud`) — the backend resource the agent declared in the
`resources` parameter of `GetResourceOauth2Token` (here a hypothetical MCP
resource; the delegated ATM selects on this URI):

```json
{
  "iss": "https://ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com",
  "sub": "demouser",
  "act": {
    "sub": "arn:aws:iam::574076504146:role/AgentCore-tokenexchangeag-ApplicationRuntimeExchang-cR6Ap8URe01B"
  },
  "aud": "https://demo.example.internal/resource",
  "client_id": "arn:aws:iam::574076504146:role/AgentCore-tokenexchangeag-ApplicationRuntimeExchang-cR6Ap8URe01B",
  "scope": "demo:read",
  "iat": 1793714119,
  "exp": 1793715019
}
```

The `aud` chain: the **agent** — which knows which backend it needs —
passes the target URI in `GetResourceOauth2Token`'s `resources` parameter;
AgentCore Identity carries it into the token-exchange request (RFC 8707
`resource`); PingFederate's delegated ATM selects on the registered
resource URI and its token mapping stamps the delegated token's `aud` from
it. A `resource` that no ATM claims is rejected with `invalid_target`.

## What the deployed agent actually does

The agent deployed to AgentCore Runtime is a **harness, not a product**: it
does nothing meaningful beyond exercising identity. On each invocation it
(1) takes the workload access token provided by the SDK context, (2) calls
`GetResourceOauth2Token` to trigger the exchange above, (3) decodes the
delegated token and returns its claims to the CLI. No LLM call, no
downstream API. The LLM/tool reference code — showing how the delegated
token would be used in a real agent (a Bedrock turn whose tool calls the
protected resource with the delegated token) — ships **commented out** in
`agent/main.py` with a disclaimer; enabling it is out of scope for this
POC.

## Repository layout

```
docs/architecture.md                  Architecture: flow, components, rationale
docs/agentcore-obo-limitation.md      Why credential-free client auth is impossible
agent/main.py                         The hosted agent (LLM stub disabled)
agentcore/agentcore.json              AgentCore CLI runtime config
agentcore/cdk/                        CDK app: IAM grants (KMS sign, token vault)
tests/demo_cli.py                     The smoke test: login → invoke → claims
tests/pf_common.py                    Shared login helpers (PKCE flow, token cache)
tests/pf_preflight.py                 Read-only PingFederate preflight checks
server-profiles/pingfederate-agentcore/  Declarative PF config (bulk config)
helm/pingfederate/values.yaml         Overrides for Ping's official chart
scripts/                              deploy / verify / validate / uninstall
scripts/teardown-aws.sh               AgentCore stack + provider removal
tests/config.example.env              Smoke-test config template → copy to tests/config.env
.env.example                          Helm deployment template → copy to .env
requirements.txt                      CLI/preflight dependencies (requests, boto3)
```

## Prerequisites

- Kubernetes cluster, `kubectl`, Helm 3; `nginx-public` ingress class
- Ping DevOps user/key for the license (export or `.env`)
- A git repository hosting `server-profiles/pingfederate-agentcore/`
  (`helm/pingfederate/values.yaml` pins it)
- AWS credentials for IAM, Bedrock AgentCore, ECR (you create the KMS key
  and credential provider in Step 2)
- [AgentCore CLI](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-cli.html)
  (`pip install bedrock-agentcore-starter-toolkit`)
- python3, docker

## Step 1 — PingFederate on k8s

Three commands deploy a complete authorization server:

```bash
./scripts/validate.sh    # lint: shell, bulk-config JSON, helm render
./scripts/deploy.sh      # helm install of the ping-devops chart: 1 admin + 1 engine
./scripts/verify.sh      # confirm the bulk config imported and the engine is Ready
```

`deploy.sh` pulls the configuration from the GitHub repo pinned in
`helm/pingfederate/values.yaml` (the server profile in this repo — push it
first if you changed it). At startup the admin node imports the profile as
one bulk config, which creates **everything the demo needs**:

- a local demo user you can log in with: **`demouser` / `2FederateM0re`**
  (form login; credentials live in the profile's bulk config),
- the OAuth client the CLI uses: **`agentcore-demo-cli`**, confidential,
  secret `cli-demo-secret`, Authorization Code + PKCE + refresh tokens,
- the OAuth client for the agent: `client_id` = the agent's AWS role ARN,
  authenticated by `private_key_jwt` — PingFederate holds only the KMS
  public key (inline in the profile),
- the token-exchange policy: the user JWT is the subject, the AWS identity
  JWT is the mandatory actor, and the resulting token carries both
  identities plus the audience of the requested resource,
- the token minting rules: RS256 `at+jwt`, 15-minute lifetime, and the
  resource URI the agent may target (`https://demo.example.internal/resource`,
  a stand-in for a real MCP server or API).

PingFederate is then reachable at
`https://<release>-pingfederate-engine.ping-devops.com` (release name =
this folder's name). Object-by-object detail:
[server-profiles/pingfederate-agentcore/README.md](server-profiles/pingfederate-agentcore/README.md).

## Step 2 — AWS identity pieces

Two AWS objects exist outside the repo and must exist before the agent
runs. Create them in the console/CLI (about five minutes):

1. **A customer-managed KMS key** (RSA, `SIGN_VERIFY`) — AgentCore Identity
   signs the agent's `private_key_jwt` client assertion with it; the
   private key never leaves KMS. Note its key ID: it is pinned in
   `agentcore/cdk/lib/cdk-stack.ts` (the `KmsSignClientAssertion` grant),
   and its **public key is embedded in the server profile** (the agent
   client's inline JWKS, kid `agentcore-pf-poc-1`) — if you create a new
   key, update both places.
2. **The OAuth2 credential provider** `pingfederate-obo-poc`
   (Bedrock AgentCore Identity console, CustomOauth2): discovery URL =
   your PingFederate engine's `/.well-known/openid-configuration`,
   client authentication = `PRIVATE_KEY_JWT` (KMS), and for the
   on-behalf-of flow `TOKEN_EXCHANGE` with
   `actorTokenContent = AWS_IAM_ID_TOKEN_JWT` — this is what makes AgentCore
   fetch an AWS identity JWT to act as the exchange's actor token.

Also record the account's **STS issuer** (from
`aws iam get-outbound-web-identity-federation-info`; enable it first if
needed) as `AWS_STS_ISSUER`/`AWS_STS_JWKS_URL` in `.env` — `scripts/deploy.sh`
passes them to PingFederate, which validates actor tokens against that JWKS.

What the runtime itself gets — its execution role, the `kms:Sign` /
`sts:GetWebIdentityToken` / token-vault grants — is created by the
agentcore CLI in the next step, driven by
`agentcore/cdk/lib/cdk-stack.ts`; nothing to do by hand.

## Step 3 — Deploy the agent (AgentCore CLI)

One command deploys the agent container and its IAM role:

```bash
agentcore deploy
agentcore status         # wait for READY; note the runtime ID (…-AbCdEfGhIp)
```

Before deploying, `agentcore/agentcore.json` points the pieces at each
other: the **custom JWT authorizer** validates inbound tokens against
PingFederate's OIDC discovery endpoint and accepts only the invoke
audience (`allowedAudience`); the `Authorization` header is allowlisted so
the validated user JWT reaches the agent; and the env vars name the
credential provider (`pingfederate-obo-poc`), the exchange scope
(`demo:read`), and the backend resource the agent requests
(`https://demo.example.internal/resource`). If your PF host differs, edit
`discoveryUrl` and `allowedAudience` there first.

## Step 4 — Run the demo

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp tests/config.example.env tests/config.env   # set PF_BASE_URL + AGENT_RUNTIME_NAME

python3 tests/pf_preflight.py           # optional: checks PF answers before the flow
python3 tests/demo_cli.py               # login → invoke agent → claims
```

The CLI opens a browser: log in as **`demouser` / `2FederateM0re`**. It
then invokes the agent with the resulting user JWT and prints the
delegated token's claims. Expected output:

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
  "sub": "demouser",
  "act": { "sub": "arn:aws:iam::<account>:role/AgentCore-tokenexchangeag-..." },
  "aud": "https://demo.example.internal/resource",
  "scope": "demo:read",
  ...
}
RESULT: SUCCESS
```

`sub` proves the user identity, `act.sub` the agent's AWS role, `aud` the
backend the agent requested — the three facts a downstream resource server
would check.

## Teardown

```bash
./scripts/teardown-aws.sh  # AgentCore stack (agentcore CLI) + credential provider
./scripts/uninstall.sh     # PingFederate release
```

The KMS key is not deleted by teardown (it may hold other grants); remove
it in the console if you no longer need it.

## Security

No client secret is stored for the agent: it authenticates with a KMS-signed
assertion whose private key never leaves AWS KMS, and the PF client holds
only the public key. The CLI is a confidential demo client (secret lives in
the server profile). Tokens are cached locally in `tests/tokens.cache`
(git-ignored); scripts print decoded claims, never raw tokens. `.env` and
`tests/config.env` are git-ignored. The PingFederate Admin API is used read-only
(preflight); configuration flows exclusively from the server profile.
