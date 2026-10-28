# AgentCore Secretless Identity Federation — POC (PingFederate Edition)

## Objective

Build a proof of concept demonstrating secretless authentication and OAuth token
exchange between AWS Bedrock AgentCore and PingFederate.

The agent uses AgentCore Identity's native outbound OAuth token exchange
capability. The agent authenticates to PingFederate with an **AWS-issued IAM
identity JWT** (`sts:GetWebIdentityToken`) used in two roles:

* **Client authentication** — the AWS JWT is the RFC 7523 `client_assertion`
  (`clientAuthenticationMethod: AWS_IAM_ID_TOKEN_JWT`). No client ID, no
  client secret, no managed keys.
* **Workload identity proof** — the AWS JWT is also the RFC 8693
  **actor token**, validated by PingFederate against the AWS-published JWKS.

The POC must demonstrate both user identity delegation and agent workload
identity. No secrets are configured on the PingFederate client.

## PingFederate compatibility verdict

Verified against current PingFederate documentation (12.3 / 13.x) and current
AWS documentation on 2026-10-28.

| Requirement | Status | Notes |
|---|---|---|
| RFC 8693 token exchange grant | ✅ Supported | `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`; policy implemented as a Token Exchange Processor Policy (TEPP) |
| PingFederate user JWT as `subject_token` | ✅ Supported | `subject_token_type=urn:ietf:params:oauth:token-type:jwt`; validated by PingFederate's own JWT token processor |
| AWS-issued JWT as `actor_token` | ✅ Supported | JWT Token Processor 2.0 instance with external issuer (AWS STS account issuer URL) + AWS JWKS URL; TEPP actor-token processor mapping produces the `act` claim |
| AWS-issued JWT as `client_assertion` | ⚠️ Conditional | PingFederate `private_key_jwt` client auth validates assertions against a client-registered JWKS URL — point it at the AWS STS JWKS. Default validation requires `iss == sub == client_id`; the AWS JWT has `sub = <IAM role ARN>` and `iss = <account STS issuer>`, so the client must be registered with `client_id = <IAM role ARN>` and the global configStore flag `issuerMustBeEqualToClientId` set to `false`. Verified parameters; end-to-end acceptance is a Phase 0 gate. |

Design consequence: the PingFederate client for the agent is registered with
**no secret** — token endpoint authentication is the AWS JWT client assertion,
signature-checked against the AWS account's STS JWKS. The same AWS issuer
trust (JWT Token Processor 2.0 + JWKS) serves both the client-assertion
validation and the actor-token validation.

Fallback (documented, not part of the POC): if Phase 0 proves PingFederate
cannot accept the AWS JWT as client assertion even with the configuration
above, the documented fallback is AgentCore's `PRIVATE_KEY_JWT` method backed
by a customer-managed KMS key. This substitutes a managed key for the AWS
workload identity and requires explicit platform-team approval — it must not
be substituted silently, and a client secret is never an option.

## Architecture

```
CLI Client
    |
    | 1. Authenticate user with PingFederate (k8s)
    |    Authorization Code + PKCE (public client)
    |
    | 2. Invoke AgentCore Runtime with PingFederate user JWT
    v
AWS AgentCore Runtime
    |
    | 3. Validate inbound user JWT (custom JWT authorizer,
    |    PingFederate OIDC discovery URL)
    v
Hosted Agent
    |
    | 4. Request outbound OAuth token (ON_BEHALF_OF_TOKEN_EXCHANGE)
    v
AgentCore Identity
    |
    | 5. Obtain AWS IAM identity JWT (sts:GetWebIdentityToken,
    |    audience = PingFederate token endpoint)
    |
    | 6. Authenticate to PingFederate: client_assertion = AWS IAM
    |    identity JWT (RFC 7523) — no client secret, no client ID
    |
    | 7. POST {pf}/as/token.oauth2 — RFC 8693 token exchange
    |    subject_token = PingFederate user JWT
    |    actor_token   = AWS IAM identity JWT
    v
PingFederate (k8s, token exchange policies preconfigured)
    |
    | 8.  Validate client assertion against AWS STS JWKS
    |     (client registered with client_id = IAM role ARN, no secret)
    | 9.  Validate subject token (PingFederate-issued) — TEPP subject processor
    | 10. Validate actor token (AWS STS issuer + AWS JWKS) — TEPP actor processor
    | 11. Issue delegated JWT access token:
    |       sub = user, act.sub = agent IAM role ARN, aud, scope
    v
AgentCore Identity
    |
    | 12. Return access token
    v
Hosted Agent
    |
    | 13. Decode token and extract claims
    | 14. Return claims to CLI
    v
CLI Client
    |
    | 15. Display claims
```

Network assumptions: the AgentCore Runtime runs with `PUBLIC` network mode;
the PingFederate runtime engine must be reachable from AWS over HTTPS with a
valid publicly trusted certificate (e.g. `https://pf.example.com`, runtime
port 9031 or 443 behind a TLS-terminating load balancer in the k8s ingress).
PingFederate must be able to fetch the AWS STS JWKS (public internet).

## Components

### 1. CLI Demo Client

Python command-line client that:

* Authenticates a user with PingFederate using Authorization Code + PKCE as a
  **public client** (no client secret; PKCE required).
  * Endpoints taken from `https://pf.example.com/.well-known/openid-configuration`.
  * Local loopback redirect (`http://localhost:<port>/callback`) with a
    short-lived local listener.
* Obtains a PingFederate user access token (JWT) with audience = the
  AgentCore Runtime API audience.
* Invokes the deployed AgentCore Runtime with
  `Authorization: Bearer <user access token>`.
* Receives the claims returned by the agent and displays them as readable
  JSON.

The CLI must not perform workload identity federation or token exchange.

### 2. AgentCore Hosted Agent

Minimal Python HTTP agent deployed to AWS Bedrock AgentCore Runtime
(container in ECR). When invoked, the agent must:

1. Receive the authenticated request with the forwarded inbound user token.
2. Call `GetWorkloadAccessTokenForJWT` with the inbound PingFederate user JWT.
3. Call `GetResourceOauth2Token` with
   `oauth2Flow = ON_BEHALF_OF_TOKEN_EXCHANGE`, the credential provider name,
   and the requested scopes, passing the workload access token.
4. Receive the PingFederate-issued delegated access token.
5. Decode the JWT (signature not verified — display only) and return its
   claims to the CLI.

The agent must not:

* Call AWS STS directly.
* Implement OAuth token exchange itself.
* Manage OAuth client secrets or private keys.
* Invoke the LLM at runtime (the LLM and tool code ships disabled — see
  *LLM reference code* below).

AgentCore Identity must handle the entire outbound authentication and token
exchange process. Tokens must never be logged or persisted; only decoded
claims leave the agent.

#### LLM reference code (included, disabled)

The goal of this demo is the secretless token exchange. To show where the
exchanged token would be used in a real agentic workload, the agent source
must also contain the following code, **commented out**, with the disclaimer
below as the leading comment block:

* A single-turn LLM invocation via Amazon Bedrock (e.g. Strands Agents with
  a pinned model ID).
* One hardcoded tool whose implementation calls the downstream demo resource
  with the exchanged token — `Authorization: Bearer <exchanged token>` — so
  the resource server sees `sub` = user, `act.sub` = agent IAM role.

Required disclaimer at the top of the disabled block:

```python
# DISCLAIMER — disabled on purpose.
# The goal of this demo is the secretless OAuth token exchange between
# AgentCore Identity and PingFederate. Everything above proves identity
# delegation. The code below shows how the exchanged token would be used
# downstream in a real agentic flow: the LLM invokes a tool that calls the
# protected resource with the delegated token (sub = user, act.sub = agent
# IAM role). It is NOT enabled in this demo. Enabling it requires
# bedrock:InvokeModel permissions on the agent role, a reachable downstream
# resource, and moving LLM integration out of this POC's out-of-scope list.
```

Keep the stub dumb: single turn, one hardcoded prompt, one tool — no memory,
no MCP, no session state, no model-driven scope decisions.

### 3. AgentCore Identity Configuration

Custom OAuth2 credential provider targeting PingFederate.

| Parameter | Value |
|---|---|
| Provider | Custom OAuth2 (`CustomOauth2`) |
| OAuth server | PingFederate (k8s) |
| OAuth discovery | `https://pf.example.com/.well-known/openid-configuration` |
| OAuth flow | `ON_BEHALF_OF_TOKEN_EXCHANGE` |
| Grant type | `TOKEN_EXCHANGE` (mapped to `urn:ietf:params:oauth:grant-type:token-exchange`) |
| Client authentication | `AWS_IAM_ID_TOKEN_JWT` (RFC 7523 client assertion = AWS IAM identity JWT) |
| Client ID / client secret | **Not set** — not required for the OBO token-exchange flow with this auth method |
| Actor token content | `AWS_IAM_ID_TOKEN_JWT` |
| Subject token | Inbound PingFederate user JWT (`urn:ietf:params:oauth:token-type:jwt`) |
| Token audience / scopes | Configurable (PingFederate resource / `demo:read`) |

Provisioning (AWS CLI):

```bash
aws bedrock-agentcore-control create-oauth2-credential-provider \
  --cli-input-json '{
    "name": "pingfederate-obo-poc",
    "credentialProviderVendor": "CustomOauth2",
    "oauth2ProviderConfigInput": {
      "customOauth2ProviderConfig": {
        "oauthDiscovery": {
          "discoveryUrl": "https://pf.example.com/.well-known/openid-configuration"
        },
        "clientAuthenticationMethod": "AWS_IAM_ID_TOKEN_JWT",
        "onBehalfOfTokenExchangeConfig": {
          "grantType": "TOKEN_EXCHANGE",
          "tokenExchangeGrantTypeConfig": {
            "actorTokenContent": "AWS_IAM_ID_TOKEN_JWT"
          }
        }
      }
    }
  }'
```

Notes:

* AWS documentation shows `clientAuthenticationMethod: AWS_IAM_ID_TOKEN_JWT`
  (no `clientId`, no secret) and `onBehalfOfTokenExchangeConfig` in separate
  examples; **Phase 1 must confirm the combined configuration is accepted**
  before proceeding.
* With `clientAuthenticationMethod = AWS_IAM_ID_TOKEN_JWT`, AgentCore Identity
  calls `sts:GetWebIdentityToken` with the credential provider's token
  endpoint (the PingFederate token endpoint URL) as the `aud` claim and sends
  the resulting JWT as the RFC 7523 `client_assertion`.
* With `actorTokenContent = AWS_IAM_ID_TOKEN_JWT`, AgentCore Identity obtains
  an AWS JWT the same way and sends it as `actor_token` with type
  `urn:ietf:params:oauth:token-type:jwt`.
* Prerequisites: account-level outbound web identity federation enabled, and
  `sts:GetWebIdentityToken` granted to the agent's execution role (see §5).
* Runtime call sequence (from AWS docs):

  ```bash
  aws bedrock-agentcore get-workload-access-token-for-jwt \
      --workload-name sample-workload --user-token "<inbound-jwt>"

  aws bedrock-agentcore get-resource-oauth2-token \
      --resource-credential-provider-name pingfederate-obo-poc \
      --oauth2-flow ON_BEHALF_OF_TOKEN_EXCHANGE \
      --scopes "demo:read" \
      --workload-identity-token "<workload-access-token>"
  ```

AgentCore Identity must:

* Obtain the agent's AWS identity JWT using `sts:GetWebIdentityToken`.
* Authenticate to PingFederate using the AWS JWT as the RFC 7523 client
  assertion — no client secret, no client ID.
* Include the AWS JWT as the actor token in the RFC 8693 exchange.
* Include the inbound user JWT as the subject token.
* Return the exchanged access token to the agent.

### 4. PingFederate Configuration (k8s, preconfigured)

Assumptions:

* PingFederate 12.3+ (verified against 12.3/13.1 docs) deployed on Kubernetes
  using the official Ping Identity Docker image and Helm chart.
* Token exchange policies are **preconfigured by the platform team before the
  POC starts**. The POC verifies the configuration (read-only admin API
  checks); it does not provision PingFederate objects.
* Configuration is managed through the Admin REST API (`/pf-admin-api/v1`).
* Runtime base URL: `https://pf.example.com` (TLS via ingress/load balancer);
  discovery at `https://pf.example.com/.well-known/openid-configuration`;
  token endpoint at `https://pf.example.com/as/token.oauth2`.

Preconfigured PingFederate objects:

| Object | Key settings |
|---|---|
| OAuth client `agentcore-demo-cli` (public) | Grants: `authorization_code` with PKCE required; token endpoint auth: none (public client); redirect URI: `http://localhost:<port>/callback`; scopes: `openid profile demo:read` |
| OAuth client for the agent — **no secret** | `client_id` = the agent's IAM role ARN (e.g. `arn:aws:iam::123456789012:role/agentcore-demo-agent`); grants: `urn:ietf:params:oauth:grant-type:token-exchange`; token endpoint auth: **Private Key JWT**; **JWKS URL** = `{aws-sts-issuer}/.well-known/jwks.json`; signing algorithms: RS256 and ES384 (AWS STS issues both); replay prevention: **off** (see verification items); allowed scope: `demo:read` |
| JWT Token Processor instance (AWS STS) | Type: JWT Token Processor 2.0; issuer: the account-specific AWS STS issuer URL (exact value returned by `iam enable-outbound-web-identity-federation`); JWKS URL: `{issuer}/.well-known/jwks.json`; algorithms: ES384, RS256; audience: `https://pf.example.com/as/token.oauth2` |
| Token Exchange Processor Policy (TEPP) | Client: the agent client; subject token processor: PingFederate's JWT processor (PingFederate-issued user tokens); actor token processor: the AWS STS JWT processor; `actorTokenRequired: true`; mapping: `sub` ← subject `sub`; `act.sub` ← actor `sub` (agent IAM role ARN); `aud` ← target resource; scope enforcement |
| Access Token Management instance | JWT access tokens; RS256 or ES384; `typ: at+jwt`; lifetime ≤ 15 minutes |

AWS JWKS wiring: enabling outbound web identity federation yields the
account-specific issuer URL (e.g.
`https://<id>.tokens.sts.global.api.aws`). Both the agent client's JWKS URL
and the JWT Token Processor point at `{issuer}/.well-known/jwks.json`, which
publishes the EC (ES384) and RSA (RS256) verification keys.

Global configStore setting (platform-team decision — affects every client on
the server):

```text
POST /pf-admin-api/v1/configStore/oauth-credentials-validator/issuerMustBeEqualToClientId
{ "id": "issuerMustBeEqualToClientId", "stringValue": "false", "type": "STRING" }
```

Required because the AWS JWT's `iss` (account STS issuer) differs from the
client ID (the IAM role ARN). With the client ID registered as the IAM role
ARN, the assertion's `sub` still equals the client ID (RFC 7523 §2.2
compliance); the flag relaxes only the issuer comparison. Test order in
Phase 0: first attempt with the flag at its default — if PingFederate's
check is issuer-only, the flag may not be needed; enable it only if the
assertion is rejected on `iss`.

Verification script (preflight): read-only Admin API calls asserting each
object above exists with the expected fields; fails fast with a precise
message otherwise.

PingFederate must:

* Authenticate CLI users using Authorization Code + PKCE.
* Issue user access tokens accepted by AgentCore Runtime (see §5 authorizer).
* Authenticate the agent client via the AWS JWT client assertion — validated
  against the AWS STS JWKS — with **no client secret configured**.
* Validate AWS-issued JWTs used as actor tokens: signature against the AWS
  STS JWKS; issuer, audience (`https://pf.example.com/as/token.oauth2`),
  expiration, and workload identity claims (`sub` = IAM role ARN,
  `aws_account`, optionally `org_id`).
* Enforce the TEPP: actor token mandatory; user and agent identities both
  present in the issued token.

The resulting delegated token must preserve:

* User identity (`sub`).
* Agent identity (`act.sub`, from the AWS JWT's IAM role ARN).
* Target audience.
* Granted scopes.

Compatibility requirement: the only PingFederate limitation encountered is
the `iss == sub == client_id` default on client assertions, resolved by
registering the client with `client_id = <IAM role ARN>` plus the configStore
flag above. That flag is a global, documented PingFederate setting — the
platform team must sign off on enabling it in the target environment. If
Phase 0 shows the assertion is still rejected, fall back per the fallback
clause in the compatibility verdict; never substitute a client secret.

Open verification items (Phase 0 / Phase 1 gates):

1. Client resolution: whether PingFederate resolves the client from the
   assertion alone when the token request carries no `client_id` form
   parameter (AgentCore omits it in this flow). Registering the client ID as
   the IAM role ARN is what makes resolution possible — verify it works.
2. Issuer check: whether PingFederate accepts `sub == client_id` with
   `iss != client_id`, or requires `issuerMustBeEqualToClientId = false`.
3. Signing algorithm: which algorithm AgentCore requests from STS (RS256 or
   ES384) and that the PF client accepts it (both are published in the AWS
   JWKS).
4. Replay prevention: whether AgentCore Identity caches the STS JWT across
   exchanges. If it does, a fixed `jti` would trip PingFederate's replay
   prevention — keep it **disabled** for this client (as preconfigured).

### 5. AWS Infrastructure

Scripts and configuration to:

* Enable IAM outbound web identity federation
  (`aws iam enable-outbound-web-identity-federation`) and capture the
  account issuer URL via `GetOutboundWebIdentityFederationInfo`.
* Create a dedicated IAM execution role for the agent with:
  * `sts:GetWebIdentityToken`, conditioned on
    `sts:IdentityTokenAudience = https://pf.example.com/as/token.oauth2` and
    `sts:DurationSeconds ≤ 300`.
  * AgentCore Identity data-plane permissions
    (`GetWorkloadAccessTokenForJWT`, `GetResourceOauth2Token`).
* Configure the outbound OAuth credential provider (see §3).
* Configure inbound JWT authentication on the runtime:

  ```json
  "authorizerConfiguration": {
    "customJWTAuthorizer": {
      "discoveryUrl": "https://pf.example.com/.well-known/openid-configuration",
      "allowedClients": ["agentcore-demo-cli"],
      "allowedAudience": ["<runtime-api-audience>"]
    }
  }
  ```

  Note the API spelling: `allowedAudience` (singular field, array value) and
  `allowedClients` (plural). At least one restriction is required; if several
  are set, all must pass.
* Build and push the agent container to ECR and deploy the runtime
  (`create-agent-runtime`, `PUBLIC` network mode).
* Retrieve and persist the deployed runtime ARN/URL for the CLI.
* Remove all created AWS resources (runtime, credential provider, IAM
  role/policies). Disabling outbound web identity federation is
  account-level: the teardown script must prompt before disabling it.

Use current AWS documentation and supported tooling.

## Security Requirements

* No static AWS credentials.
* No OAuth client secrets — the CLI uses a public client + PKCE; the agent
  authenticates with its AWS-issued IAM identity JWT as client assertion.
* No application-managed private keys — all signing material is held by AWS
  STS.
* Agent authentication must use its AWS workload identity (client assertion
  and actor token).
* AgentCore Identity must perform the OAuth exchange.
* Validate inbound user authentication (AgentCore custom JWT authorizer).
* Validate AWS workload identity at PingFederate (AWS STS issuer + JWKS, for
  both the client assertion and the actor token).
* Do not log or persist access tokens.
* Do not return raw tokens to the CLI.
* Restrict audiences, scopes and token lifetimes (STS token ≤ 5 min; exchanged
  token ≤ 15 min; audience- and scope-conditioned IAM policies).

## Expected Output

```
Authenticating user with PingFederate...
Authentication successful.
Invoking AgentCore agent...
Agent invoked successfully.
AgentCore Identity:
  Outbound token exchange: SUCCESS
  Client authentication: AWS_IAM_ID_TOKEN_JWT (no client secret)
  Actor token: AWS_IAM_ID_TOKEN_JWT (sts:GetWebIdentityToken)
Exchanged PingFederate token claims:
{
  "iss": "https://pf.example.com",
  "sub": "<pf-user-id>",
  "act": {
    "sub": "arn:aws:iam::123456789012:role/agentcore-demo-agent"
  },
  "aud": "<target-resource>",
  "scope": "demo:read",
  "exp": 1234567890
}
RESULT: SUCCESS
```

The displayed claims are illustrative; actual claims depend on the TEPP and
Access Token Management configuration.

## Acceptance Criteria

1. CLI authenticates a user with PingFederate using Authorization Code + PKCE
   as a public client.
2. CLI invokes AgentCore with the PingFederate user access token.
3. AgentCore validates the inbound JWT via the custom JWT authorizer.
4. Agent requests an outbound token through AgentCore Identity
   (`ON_BEHALF_OF_TOKEN_EXCHANGE`).
5. AgentCore Identity obtains an AWS-signed workload identity JWT via
   `sts:GetWebIdentityToken` (audience = PingFederate token endpoint).
6. AgentCore Identity authenticates to PingFederate with no client secret,
   no client ID, and no managed keys — the AWS-issued IAM identity JWT as
   RFC 7523 client assertion.
7. AgentCore Identity performs the RFC 8693 token exchange with the user JWT
   as `subject_token` and the AWS JWT as `actor_token`.
8. PingFederate validates both identities: the agent's AWS JWT (signature
   against the AWS STS JWKS; issuer/audience/subject) for the client
   assertion and the actor token, and the user token (its own issuer), with
   the TEPP enforcing a mandatory actor token.
9. PingFederate issues a delegated JWT access token carrying `sub` (user),
   `act.sub` (agent IAM role ARN), audience, and scopes.
10. Agent returns the exchanged token claims to the CLI; no raw tokens are
    displayed, logged, or persisted.
11. No application-managed secrets or private keys are used anywhere in the
    flow.
12. Agent source includes the LLM/tool reference code, commented out, with
    the required disclaimer — and no LLM call executes at runtime.

## Deliverables

* Python CLI demo client.
* Python AgentCore hosted agent (container), including the disabled LLM/tool
  reference code with disclaimer.
* AgentCore Identity outbound OAuth configuration (CLI/JSON).
* AWS infrastructure and deployment scripts (including teardown).
* PingFederate preflight verification script (Admin API read-only) and
  configuration instructions for the platform team.
* README with setup, execution, verification and cleanup instructions.

## Out of Scope

* LLM execution at runtime — the LLM/tool reference code ships in the agent
  but commented out (see Component 2); enabling it is out of scope for this
  POC.
* MCP servers.
* Privilege Gateway.
* SPIFFE/SPIRE.
* Agent-to-agent communication.
* Provisioning PingFederate objects (preconfigured platform responsibility).
* The KMS `private_key_jwt` fallback (documented in the compatibility
  verdict; only if Phase 0 rejects the AWS assertion).

## Implementation Guidance

Use official AWS AgentCore and PingFederate documentation to verify all API
parameters, authentication methods and supported OAuth flows. Documentation
verified on 2026-10-28:

AWS:

* Client authentication methods (incl. `AWS_IAM_ID_TOKEN_JWT`, client ID not
  required for OBO): https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/client-auth-methods.html
* On-behalf-of token exchange (`TOKEN_EXCHANGE`, `actorTokenContent`):
  https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/on-behalf-of-token-exchange.html
* Inbound JWT authorizer: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/inbound-jwt-authorizer.html
* Outbound identity federation overview: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound.html
* Getting started (enable, `GetWebIdentityToken`, JWKS/discovery endpoints):
  https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound_getting_started.html
* Token claims (`iss`, `sub`, `aud`, AWS claims):
  https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound_token_claims.html

PingFederate:

* Token exchange grant (RFC 8693, actor token): https://docs.pingidentity.com/pingfederate/12.3/introduction_to_pingfederate/pf_token_exchange_grant.html
* Securing AI agents with PingFederate (TEPP actor mapping):
  https://developer.pingidentity.com/identity-for-ai/use-cases/idai-securing-agents-pingfed.html
* OAuth client configuration (`private_key_jwt`, JWKS URL, `issuerMustBeEqualToClientId`):
  https://docs.pingidentity.com/pingfederate/13.1/administrators_reference_guide/pf_configuring_oauth_clients.html
* JWT Token Processor 2.0 (external issuer + JWKS): https://docs.pingidentity.com/pingfederate/12.3/administrators_reference_guide/pf_configuring_jwt_token_processor_20_instance.html
* OIDC discovery endpoint (runtime port / issuer path): https://docs.pingidentity.com/pingfederate/12.3/developers_reference_guide/pf_oauth_authorization_server_metadata_endpoint.html

## Phased Plan

Prioritize validating the native AgentCore Identity configuration before
implementing the complete demo.

**Phase 0 — PingFederate policy validation (no AWS code).** Using curl:
obtain a user token (auth code + PKCE), obtain an AWS STS JWT
(`aws sts get-web-identity-token` — note: regional STS endpoint only, not the
global endpoint), then against the preconfigured TEPP:

1. POST the RFC 8693 exchange with the AWS JWT as `client_assertion` (RFC
   7523) and as `actor_token` — no secret, no client ID in the request.
   Validates the client-assertion path, the issuer/flag decision, and client
   resolution before any AgentCore work.
2. If step 1 is rejected, retry with the `issuerMustBeEqualToClientId` flag
   enabled (platform-team sign-off required) and retest.
3. POST the exchange with only subject + actor tokens (authenticated via the
   assertion as in step 1) and verify the issued token's `sub` / `act.sub` /
   `aud` / `scope`.

**Phase 1 — AgentCore Identity validation.** Create the IAM role and enable
outbound federation, create the credential provider (§3 — no client ID, no
secret), and drive `GetResourceOauth2Token` from a local script with a
Phase-0 user token. Gate: confirm the combined
`AWS_IAM_ID_TOKEN_JWT` client auth + `TOKEN_EXCHANGE` grant +
`AWS_IAM_ID_TOKEN_JWT` actor content provider configuration is accepted and
the exchange succeeds against the preconfigured PingFederate client.

**Phase 2 — Full POC.** Runtime deployment with the custom JWT authorizer,
hosted agent, CLI, README, teardown.

Success means demonstrating end-to-end, secretless, delegated OAuth token
exchange using AWS AgentCore's native identity capabilities and PingFederate
as the authorization server.
