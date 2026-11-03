# Current design — AgentCore ⇄ PingFederate secretless exchange

**Authoritative as of 2026-11-03 (commit `e7c6162`).** `SPEC.md` and
`README.md` describe the original design (2026-10-28) and are kept as
background; the project was redesigned twice since they were written. This
file documents what the repo actually deploys today and lists every artifact
that is behind.

## The design in one paragraph

The outbound exchange is still brokered by **AgentCore Identity** (the agent
calls `GetResourceOauth2Token`, no OAuth code in the agent), but the
credential material changed: the agent client authenticates to PingFederate
with a **KMS-signed `private_key_jwt` client assertion** (PingFederate holds
only the KMS public key, inline as a JWKS), and the RFC 8693 **actor token is
a PingFederate-issued `client_credentials` token** obtained by AgentCore
Identity's M2M leg — not the AWS IAM identity JWT. No client secret is
stored anywhere; the AWS STS identity JWT is no longer part of the outbound
path. This is the KMS fallback that `SPEC.md` originally documented as
"documented, not part of the POC".

## End-to-end flow

```
CLI (cli/demo_cli.py)
  1. Authorization Code login at PingFederate as client `agentcore-demo-cli`
     (confidential: client secret; PKCE is sent but not required server-side).
     User token: AgentCoreWebATM, aud = https://agentcore.demo.internal/invoke,
     RS256 at+jwt, 15 min. Cached on disk in tokens.cache (git-ignored).
  2. POST to the AgentCore Runtime invoke URL with
     Authorization: Bearer <user token> (no SigV4 — the bearer IS the auth).
AgentCore Runtime
  3. Custom JWT authorizer validates the token against PingFederate's OIDC
     discovery endpoint (allowedAudience = the invoke audience); the
     Authorization header is forwarded (requestHeaderAllowlist).
Hosted agent (agent/main.py)
  4. Reads the workload access token from the SDK context and calls
     GetResourceOauth2Token (ON_BEHALF_OF_TOKEN_EXCHANGE,
     provider pingfederate-obo-poc2, scopes demo:read).
AgentCore Identity (outbound, as client_id = the runtime execution role ARN)
  5. M2M actor leg: signs a private_key_jwt client assertion with the
     customer-managed KMS key (kms:Sign with the runtime role's credentials)
     and obtains a client_credentials access token from PingFederate.
  6. RFC 8693 exchange: subject_token = the inbound PF user JWT,
     actor_token = the PF-issued client_credentials token
     (typed urn:ietf:params:oauth:token-type:access_token),
     client authentication = the KMS-signed assertion.
PingFederate
  7. TEPP AgentCoreTokenExchangePolicy (actorTokenRequired: true):
     - subject via PfUserTokenProcessor (issuer/JWKS = this PF,
       audience = the invoke audience);
     - actor via PfClientTokenProcessor (PF-issued JWT, no audience
       requirement, exposes client_id) — two mappings, one per actor type
       (jwt and access_token);
     - contract: subject ← subject.sub, subject_act ← actor.client_id.
  8. AgentCoreTokenExchangeMapping issues the delegated token from
     AgentCoreDelegatedATM: sub = user, act = { sub: <runtime role ARN> },
     aud = requested resource (RFC 8707), scope demo:read,
     RS256 at+jwt, 15 min.
Hosted agent → CLI
  9. Decodes the token (signature NOT verified — display only) and returns
     the claims; the CLI prints them.
```

## Component reference

### PingFederate (server profile = source of truth)

Deployed by `scripts/deploy.sh` from
`server-profiles/pingfederate-agentcore/instance/bulk-config/data.json.subst`
(full-state bulk config, re-imposed at every admin restart). Host:
`https://ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com`.

| Object | ID | Key settings |
|---|---|---|
| Password credential validator | `AgentCoreDemoUsersPCV` | Local demo user (`demouser`) |
| IdP adapter | `AgentCoreLoginAdapter` | HTML form backed by the PCV; default authn tree maps `username` → `AgentCoreApc.subject` |
| JWT token processor | `PfUserTokenProcessor` | Validates PF-issued user tokens (exchange subject); issuer/JWKS = this PF engine, audience = the invoke audience |
| JWT token processor | `PfClientTokenProcessor` | Validates PF-issued **actor** tokens (issuer = this PF, no audience check); `client_id` exposed as an extended attribute |
| Access token managers | `AgentCoreDelegatedATM` / `AgentCoreWebATM` | Both RS256 `at+jwt`, 15 min. Delegated: aud ← requested `resource` (RFC 8707), selection URI `https://demo.example.internal/resource`. Web: aud fixed to the invoke audience |
| Token Exchange Processor Policy | `AgentCoreTokenExchangePolicy` | `actorTokenRequired: true`; two processor mappings — (jwt → jwt) and (jwt → access_token) — so the M2M actor token validates either way; `subject_act` ← actor `client_id` |
| Access token mapping | `AgentCoreTokenExchangeMapping` | TEPP context: `sub` ← TEPP subject, `aud` ← `context.OAuthResources`, `act` built from `subject_act` |
| Access token mapping | `authz_req\|apc.AgentCoreApc\|AgentCoreWebATM` | Auth-code leg: `sub` ← APC subject |
| OIDC policy | `AgentCoreOidcPolicy` | id_token 5 min, `sub` ← `USER_KEY` |
| OAuth client | `agentcore-demo-cli` | **Confidential** (`clientAuth: SECRET`, demo secret), grants `AUTHORIZATION_CODE` + `REFRESH_TOKEN`, redirect `http://127.0.0.1:8400/callback` |
| OAuth client | the runtime role ARN (hardcoded in `data.json.subst`) | The agent: `clientAuth: PRIVATE_KEY_JWT`, **inline JWKS** = public key of the KMS key (kid `agentcore-pf-poc-1`, RS256), grants `TOKEN_EXCHANGE` + `CLIENT_CREDENTIALS` (the latter feeds the M2M actor leg), restricted scope `demo:read` |
| config store | `oauth-credentials-validator.xml` | `issuerMustBeEqualToClientId=false`, `jwtClientAuthenticationExpectedType=JWT`; registered into `data-default.zip` by the profile's `hooks/07-apply-server-profile.sh` override (PF prunes config-store files absent from the zip at every boot) |

### AWS side

- **Runtime**: `exchange_agent` (Python 3.14, CodeZip from `agent/`,
  HTTP, OTEL enabled), declared in `agentcore/agentcore.json` with
  `CREDENTIAL_PROVIDER_NAME=pingfederate-obo-poc2` and the custom JWT
  authorizer (discovery = PF engine host, `allowedAudience` =
  `https://agentcore.demo.internal/invoke`). Deployed by the AgentCore CLI
  through the CDK app in `agentcore/cdk/`.
- **Execution role**: created by the AgentCore CLI/CDK; `cdk-stack.ts` adds
  the grants — workload access tokens, `GetResourceOauth2Token` on the
  provider, Secrets Manager read of the provider secret,
  **`kms:Sign`/`kms:DescribeKey` on the customer-managed key**
  (`arn:aws:kms:eu-central-1:574076504146:key/5ef87a2b-677a-40b3-b811-61bb2684c68a`).
- **Credential provider**: `pingfederate-obo-poc2` (CustomOauth2,
  `private_key_jwt` client auth + M2M client-credentials actor leg). Created
  **out-of-band** (console/CLI) — no script in the repo creates it or the
  KMS key. Re-verify with:
  `aws bedrock-agentcore-control get-oauth2-credential-provider --name pingfederate-obo-poc2`.

### Secrets inventory

| Secret/key | Where it lives | Notes |
|---|---|---|
| CLI client secret | hardcoded in `data.json.subst` (`cli-demo-secret`) | Demo-grade; the CLI is confidential, so "no client secrets anywhere" no longer holds |
| Agent client | no secret — KMS-key-based client auth | The SPEC's KMS fallback, now the mainline; PF holds only the public key (inline JWKS) |
| KMS private key | AWS KMS only | Never leaves AWS; AgentCore Identity signs via `kms:Sign` |
| tokens.cache | local disk (git-ignored) | User access + refresh tokens persist between demo runs — the earlier "tokens stay in memory" claim is outdated |

## Design evolution

| Design | When | Commits | Client auth (outbound) | Actor token | Where documented |
|---|---|---|---|---|---|
| A — Identity-brokered, AWS JWT everywhere | Oct 28 | `228e3c4` | AWS IAM identity JWT as RFC 7523 assertion (no client ID) | the same AWS JWT | `SPEC.md`, `README.md` (as written) |
| B — Agent-direct, client auth NONE | Oct 30 | `47863f9` | none (`client_id` only) | AWS JWT | `docs/agentcore-obo-limitation.md` ("working alternative") |
| C — Identity-brokered, AWS JWT as assertion | Oct 30 | `fec3308`, `71e2adc`, `0a564d7` | AWS JWT as `private_key_jwt` assertion + config-store relaxations (`issuerMustBeEqualToClientId=false`, `jwtClientAuthenticationExpectedType=JWT`) | AWS JWT | the "clean final test" of the AWS-JWT variant |
| D — Identity-brokered, KMS + PF-issued actor (**current**) | Oct 30 – Nov 2 | `eec5d71` → `e7c6162` | KMS-signed `private_key_jwt`, inline JWKS on the PF client | PF-issued `client_credentials` token (M2M leg, typed `access_token`), `act.sub` ← actor `client_id` | this file |

Design B was abandoned because AgentCore Identity's credential providers
always attach client credentials (there is no credential-free mode; the
documented `NO_CLIENT` override is silently dropped by the live service —
see [agentcore-obo-limitation.md](agentcore-obo-limitation.md) for the API
findings, which remain valid). The C→D pivot reason is not recorded beyond
the commit messages; D keeps the secretless property while letting
PingFederate validate the actor as its own token and identify the agent from
`client_id`.

## Artifacts behind the current design

Updated 2026-11-03: the dead AWS-JWT-variant tooling was removed
(`AwsStsTokenProcessor`, `aws/setup-identity.sh`, `pf_phase0_exchange.py`,
`scripts/smoke.sh`, the STS helpers in `pf_phase0_common.py`, the CDK
`sts:GetWebIdentityToken` grant, `deploy.sh`'s `AWS_STS_*` /
`PF_AGENT_CLIENT_ID` wiring, the redundant profile p12). What remains stale:

| Artifact | What is stale |
|---|---|
| `SPEC.md` | Describes design A end to end (verdict table, architecture, acceptance criteria). Its KMS `private_key_jwt` "fallback" clause is now the implemented design. |
| `README.md` | Same as SPEC (original-design run steps); see the banner at its top. |
| `agent/main.py` | Flow is current, but the hardcoded response strings still announce `AWS_IAM_ID_TOKEN_JWT (no client secret)` — cosmetic only. |
| `aws/teardown.sh` | Corrected for the current design (deletes `pingfederate-obo-poc2` by default, no STS federation step); the KMS key is documented as out-of-band. |

## Running what actually works today

1. **PingFederate**: `./scripts/validate.sh`, ensure
   `server-profiles/pingfederate-agentcore/` is pushed to the GitHub repo
   pinned in `helm/pingfederate/values.yaml` (branch `main`), then
   `./scripts/deploy.sh` and `./scripts/verify.sh`. The profile needs no
   external values (hostnames are image-provided; the KMS client material is
   inline). Do not hand-edit PF config in the console — the full-state
   profile re-imposes it on every admin restart.
2. **AWS one-time (out-of-band, not scripted)**: the KMS key and the
   `pingfederate-obo-poc2` provider exist already; recreate them manually if
   starting from scratch (see the CDK comments for the exact shape).
3. **Agent**: edit `agentcore/agentcore.json` if the PF host changed, then
   `agentcore configure && agentcore deploy && agentcore status` — note the
   runtime ID for the CLI. The CDK stack attaches the IAM grants, including
   `kms:Sign`.
4. **CLI**:
   ```bash
   python3 -m venv .venv && source .venv/bin/activate
   pip install -r requirements.txt
   cp config.example.env config.env
   # then set in config.env:
   #   PF_BASE_URL, PF_CLI_CLIENT_ID=agentcore-demo-cli,
   #   PF_CLI_CLIENT_SECRET=cli-demo-secret, AGENT_RUNTIME_NAME=<from status>
   python3 cli/demo_cli.py
   ```
5. **Expected result**: claims with `sub: demouser`,
   `act.sub: arn:aws:iam::574076504146:role/AgentCore-tokenexchangeag-...`
   (the runtime execution role ARN), `aud` = the requested resource,
   `scope: demo:read`.

## Pointers

- `SPEC.md` — original specification (design A): objective, compatibility
  verdict, phased plan, acceptance criteria.
- [agentcore-obo-limitation.md](agentcore-obo-limitation.md) — why design B
  failed: AgentCore Identity cannot perform a credential-free exchange;
  the `NO_CLIENT` escape hatch exists in docs but not in the service.
- `server-profiles/pingfederate-agentcore/` — the deployable PingFederate
  configuration (source of truth for the PF side).
