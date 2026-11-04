# Architecture — AgentCore ⇄ PingFederate delegated token exchange

## The scenario

Agents are becoming the ones doing the work: an agent acts on behalf of a
user, or on behalf of another agent, and to get anything done it must call
resources — APIs, MCP servers, downstream services. Those calls need a
security token that says who the work is being done **for** and what is
doing it: if the token only identifies a person, the caller cannot tell
which agent ran; if it only identifies an agent, the call is not
attributable to anyone. OAuth token exchange (RFC 8693) exists for this:
the agent presents the token of whoever it acts for as the **subject**, its
own credentials as the **actor**, and receives one short-lived token
carrying both identities (`sub` + `act.sub`).

This demo applies that concept to an agent deployed to **AWS Bedrock
AgentCore**, with **PingFederate** as the authorization server. The demo
includes a dummy agent — it receives the user's invocation, triggers the
exchange, and returns the resulting token's claims to the caller; it calls
no downstream resource and runs no model. The point being demonstrated is
the **issuance** of the delegated token: how a secretless agent (no stored
credentials of any kind) proves itself to PingFederate, how the user's and
the agent's identities end up in one token, and what that token looks
like. A real deployment would continue from there — the resource server
validating the token's `sub`, `act.sub`, and `aud` — but no resource
server exists in this project and nothing consumes the token.

## The problem this solves

Beyond attributing the action, the exchange must not create new secrets.
The conventional fix — a client credential for the agent — puts a
long-lived secret inside the agent runtime: one more thing to leak and
rotate. This design stores nothing: the agent's "credential" is minted at
call time by the platform it runs on. AgentCore Identity signs the client
assertion with a KMS key (the private key never leaves AWS), obtains an
AWS-signed identity JWT from STS as the actor token, and drives the whole
RFC 8693 exchange against PingFederate — so the agent code never touches
OAuth, signs nothing, and holds no secrets.

## Components

```
┌──────────────┐   Authorization Code + PKCE     ┌─────────────────────┐
│ CLI client   │ ───────────────────────────────▶ │ PingFederate (k8s)  │
│ (smoke test) │   confidential client            │ server-profiles/    │
└──────┬───────┘                                  └─────────▲───────────┘
       │ Bearer user JWT                                    │ 5: RFC 8693
       ▼ 2,3: validate + forward                            │ exchange
┌───────────────────────┐                          ┌─────────┴───────────┐
│ AgentCore Runtime     │    4: GetResourceOauth2  │ AgentCore Identity  │
│ custom JWT authorizer │ ───────────────────────▶ │ KMS assertion +     │
└───────────────────────┘                          │ AWS JWT actor token │
     │ workload token                              └─────┬────────┬──────┘
     ▼                                            kms:Sign │        │ sts:GetWebIdentityToken
┌───────────────────────┐                                  ▼        ▼
│ Hosted agent          │                          ┌────────┐ ┌──────────────┐
│ agent/main.py         │                          │ AWS KMS│ │ AWS STS      │
└───────────────────────┘                          └────────┘ └──────────────┘
```

1. **CLI client** (`tests/demo_cli.py`) logs the user in at PingFederate with
   Authorization Code (confidential client `agentcore-demo-cli`, secret from
   the server profile; PKCE sent). The user token is cached in
   `tests/tokens.cache` between runs.
2. **AgentCore Runtime** validates the inbound JWT with its custom authorizer
   (PingFederate OIDC discovery, audience = the invoke audience) and
   forwards the `Authorization` header to the agent.
3. **Hosted agent** (`agent/main.py`) holds no credentials and no OAuth
   logic: it calls `GetResourceOauth2Token` (`ON_BEHALF_OF_TOKEN_EXCHANGE`)
   with the workload access token from the SDK context and returns the
   decoded claims. LLM/tool reference code ships commented out.
4. **AgentCore Identity** is the OAuth client for the whole outbound leg:
   - signs a `private_key_jwt` client assertion with the customer-managed
     **KMS key** (`kms:Sign`; the private key never leaves AWS);
   - obtains the **AWS IAM identity JWT** from
     `sts:GetWebIdentityToken` (audience = the PF token endpoint, ≤ 5 min);
   - runs the **RFC 8693 exchange in a single PingFederate call**: subject =
     the inbound user JWT, actor = the AWS IAM identity JWT, client
     authentication = the KMS-signed assertion.
5. **PingFederate** validates all three inputs and issues the delegated
   token.

The agent never calls STS, never signs anything, and never sees a client
secret. Signing material lives in AWS KMS (client assertion) and AWS STS
(actor token).

## The delegated token

Issued by PingFederate (`AgentCoreDelegatedATM`, RS256 `at+jwt`, 15 min):

| Claim | Value | Source |
|---|---|---|
| `sub` | the user (`demouser`) | subject token's `sub` |
| `act.sub` | the agent (runtime execution role ARN) | actor token's `sub` (the AWS identity JWT) |
| `aud` | the requested resource URI (RFC 8707) | the `resources` parameter the agent passes to `GetResourceOauth2Token`, carried as the exchange's `resource` |
| `scope` | `demo:read` | TEPP-allowed scope |

## PingFederate configuration

Defined entirely in
`server-profiles/pingfederate-agentcore/` (bulk config, full-state — the
image re-imposes it at every admin restart). See that directory's README for
the object-by-object table. The load-bearing pieces:

- **TEPP `AgentCoreTokenExchangePolicy`** — `actorTokenRequired: true`;
  single mapping: subject via `PfUserTokenProcessor` (PF-issued user
  tokens), actor via `AwsStsTokenProcessor` (AWS STS identity JWTs,
  issuer/JWKS pinned to the account's outbound federation). Contract:
  `subject` ← subject `sub`, `subject_act` ← actor `sub`.
- **Agent client** — registered with no secret: `PRIVATE_KEY_JWT` client
  auth, inline JWKS holding the **public key of the KMS key**. Three
  config-store settings make it accept the platform-signed assertion:
  `issuerMustBeEqualToClientId=false` and `jwtClientAuthenticationExpectedType=JWT`
  (in `oauth-credentials-validator.xml`) relax the RFC 7523 shape rules,
  and the token-endpoint URL in `AdditionalAllowedAudiences` (in
  `org.sourceid.oauth20.domain.AuthzServerManagerImpl.xml`) admits the
  assertion's `aud`, which AgentCore sets to the full token endpoint. Both
  files ship in the profile and are registered into `data-default.zip` by
  the profile's hook override — the config store cannot be managed via
  console, REST API, or bulk config, and PF restores zip entries over
  loose files at boot.
- **`client_id` = the runtime execution role ARN** — AgentCore Identity
  presents itself as the role AWS gave the runtime, so PingFederate can
  bind the actor identity to a real AWS workload.

## AWS side

- **Runtime** declared in `agentcore/agentcore.json` (HTTP protocol,
  `Authorization` header allowlist, custom JWT authorizer), deployed with
  the AgentCore CLI through the CDK app in `agentcore/cdk/`.
- **IAM grants** (in `cdk-stack.ts`): workload access tokens,
  `GetResourceOauth2Token` on the provider, Secrets Manager read of the
  provider secret, `kms:Sign`/`kms:DescribeKey` on the KMS key, and
  `sts:GetWebIdentityToken` (audience-conditioned) for the actor token.
- **Script-created setup** (`scripts/setup-aws.sh`, see the README's
  Step 1): the KMS key and the `pingfederate-obo-poc` credential provider
  (CustomOauth2, `private_key_jwt` client auth bound to the KMS key +
  `AWS_IAM_ID_TOKEN_JWT` actor token content). The provider combines both
  settings — the snippet omits the key binding (`privateKeyJwtConfig`)
  because the local AWS CLI's service model predates it; the script drives
  the provider API through a raw signed request:

  ```json
  {
    "name": "pingfederate-obo-poc",
    "credentialProviderVendor": "CustomOauth2",
    "oauth2ProviderConfigInput": {
      "customOauth2ProviderConfig": {
        "oauthDiscovery": {
          "discoveryUrl": "https://<pf-host>/.well-known/openid-configuration"
        },
        "clientAuthenticationMethod": "PRIVATE_KEY_JWT",
        "onBehalfOfTokenExchangeConfig": {
          "grantType": "TOKEN_EXCHANGE",
          "tokenExchangeGrantTypeConfig": {
            "actorTokenContent": "AWS_IAM_ID_TOKEN_JWT"
          }
        }
      }
    }
  }
  ```

  AWS documents the two settings in separate examples; their combination
  was verified live (2026-11-03) and is the working configuration.

## Design decisions and their rationale

- **AgentCore Identity performs the exchange, not the agent.** The agent
  must hold no OAuth logic and no credentials. AgentCore's credential
  providers do not support credential-free client authentication (the
  documented `NO_CLIENT` override is silently dropped by the live service —
  see [agentcore-obo-limitation.md](agentcore-obo-limitation.md)), so the
  client authenticates with a KMS-signed `private_key_jwt` assertion: no
  stored secret, and PingFederate holds only the public key.
- **AWS-signed actor token (current design).** The actor token in the
  exchange is the AWS IAM identity JWT itself (`sts:GetWebIdentityToken`):
  the agent's identity in the delegated token is vouched for by AWS, not by
  a PingFederate-issued stand-in, and the exchange is a single PF call.
  PingFederate validates it with a JWT token processor pinned to the
  account's STS issuer + JWKS, and the TEPP maps `subject_act` ← actor
  `sub` (the runtime role ARN). An earlier iteration used a PF-issued
  `client_credentials` token as actor (two PF calls per exchange); it
  works, but the AWS-signed variant is the one that reflects the actual
  trust chain.
- **Confidential CLI client with PKCE.** The demo client is confidential
  (secret in the server profile); PKCE is sent regardless. A public client
  would remove the secret but the demo profile keeps the shape a real
  deployment would use.
- **Full-state bulk config over console/API changes.** Configuration is
  declarative and version-controlled; nothing drifts, and every admin
  restart re-imposes it.

## Running it

See the [README](../README.md) for prerequisites, deployment steps
(PingFederate via Helm, the agent via the AgentCore CLI) and the demo run.
`tests/pf_preflight.py` checks the PingFederate side before attempting the
flow;
`scripts/teardown-aws.sh` and `scripts/uninstall.sh` remove everything.

## References

AWS:

- Client authentication methods (`private_key_jwt`, KMS):
  https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/client-auth-methods.html
- On-behalf-of token exchange:
  https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/on-behalf-of-token-exchange.html
- Inbound JWT authorizer:
  https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/inbound-jwt-authorizer.html

PingFederate:

- Token exchange grant (RFC 8693):
  https://docs.pingidentity.com/pingfederate/12.3/introduction_to_pingfederate/pf_token_exchange_grant.html
- OAuth client configuration (`private_key_jwt`, JWKS):
  https://docs.pingidentity.com/pingfederate/13.1/administrators_reference_guide/pf_configuring_oauth_clients.html
- JWT Token Processor 2.0:
  https://docs.pingidentity.com/pingfederate/12.3/administrators_reference_guide/pf_configuring_jwt_token_processor_20_instance.html
