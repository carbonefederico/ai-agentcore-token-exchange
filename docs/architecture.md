# Architecture — AgentCore ⇄ PingFederate delegated token exchange

Delegated, secretless OAuth access between an AI agent on **AWS Bedrock
AgentCore** and a resource server protected by **PingFederate**. The agent
invokes downstream resources with a single token that carries both who the
**user** is and which **agent** acted for them — the shape required for
auditable agent actions (`sub` + `act.sub`, RFC 8693).

## The problem this solves

An agent acting on a user's behalf needs to call APIs as the user. The naive
options all fail:

- Sharing the user's token with the agent leaks user credentials to the
  agent runtime.
- A service account for the agent loses the user's identity — actions are
  no longer attributable to a person.
- Long-lived client secrets on the agent are a leak risk and rotation burden.

The solution is the OAuth 2.0 Token Exchange grant (RFC 8693): a party the
authorization server already trusts (the agent, via its platform identity)
presents the user's token as the **subject** and its own credentials as the
**actor**, and receives a fresh, short-lived token carrying both identities.
AgentCore Identity performs this exchange automatically so the agent code
never touches OAuth.

## Components

```
┌──────────────┐   Authorization Code + PKCE     ┌─────────────────────┐
│ CLI client   │ ───────────────────────────────▶ │ PingFederate (k8s)  │
│ cli/         │   confidential client            │ server-profiles/    │
└──────┬───────┘                                  └─────────▲───────────┘
       │ Bearer user JWT                                    │ 7,8: RFC 8693
       ▼ 2,3: validate + forward                            │ exchange
┌───────────────────────┐                          ┌─────────┴───────────┐
│ AgentCore Runtime     │    4: GetResourceOauth2  │ AgentCore Identity  │
│ custom JWT authorizer │ ───────────────────────▶ │ KMS-signed client   │
└───────────────────────┘                          │ assertion + M2M leg │
     │ 5,6: workload token                         └─────────┬───────────┘
     ▼                                                        │ kms:Sign
┌───────────────────────┐                                     ▼
│ Hosted agent          │                            ┌────────────────┐
│ agent/main.py         │                            │ AWS KMS        │
└───────────────────────┘                            └────────────────┘
```

1. **CLI client** (`cli/demo_cli.py`) logs the user in at PingFederate with
   Authorization Code (confidential client `agentcore-demo-cli`, secret from
   the server profile; PKCE sent). The user token is cached in
   `tokens.cache` between runs.
2. **AgentCore Runtime** validates the inbound JWT with its custom authorizer
   (PingFederate OIDC discovery, audience = the invoke audience) and
   forwards the `Authorization` header to the agent.
3. **Hosted agent** (`agent/main.py`) holds no credentials and no OAuth
   logic: it calls `GetResourceOauth2Token` (`ON_BEHALF_OF_TOKEN_EXCHANGE`)
   with the workload access token from the SDK context and returns the
   decoded claims. LLM/tool reference code ships commented out.
4. **AgentCore Identity** is the OAuth client for the whole outbound leg:
   - signs a `private_key_jwt` client assertion with the customer-managed
     **KMS key** (`kms:Sign`; the private key never leaves AWS) and obtains
     a `client_credentials` token from PingFederate (the M2M actor leg);
   - runs the **RFC 8693 exchange**: subject = the inbound user JWT, actor =
     that PF-issued `client_credentials` token, authenticated by the
     KMS-signed assertion.
5. **PingFederate** validates all three inputs and issues the delegated
   token.

The agent never calls STS, never signs anything, and never sees a client
secret. Signing material lives only in AWS KMS.

## The delegated token

Issued by PingFederate (`AgentCoreDelegatedATM`, RS256 `at+jwt`, 15 min):

| Claim | Value | Source |
|---|---|---|
| `sub` | the user (`demouser`) | subject token's `sub` |
| `act.sub` | the agent (runtime execution role ARN) | actor token's `client_id` |
| `aud` | the requested resource URI (RFC 8707) | `resource` parameter |
| `scope` | `demo:read` | TEPP-allowed scope |

## PingFederate configuration

Defined entirely in
`server-profiles/pingfederate-agentcore/` (bulk config, full-state — the
image re-imposes it at every admin restart). See that directory's README for
the object-by-object table. The load-bearing pieces:

- **TEPP `AgentCoreTokenExchangePolicy`** — `actorTokenRequired: true`;
  subject via `PfUserTokenProcessor` (PF-issued user tokens), actor via
  `PfClientTokenProcessor` (PF-issued tokens, exposes `client_id`), with two
  mappings because AgentCore Identity sends the actor as an `access_token`
  type. Contract: `subject` ← subject `sub`, `subject_act` ← actor
  `client_id`.
- **Agent client** — registered with no secret: `PRIVATE_KEY_JWT` client
  auth, inline JWKS holding the **public key of the KMS key**. Two relaxations
  in the config store (`issuerMustBeEqualToClientId=false`,
  `jwtClientAuthenticationExpectedType=JWT`) let it accept the
  platform-signed assertion. These live in
  `instance/server/default/data/config-store/oauth-credentials-validator.xml`,
  registered into `data-default.zip` by the profile's hook override — the
  config store cannot be managed via console, REST API, or bulk config, and
  PF prunes loose files in it at boot.
- **`client_id` = the runtime execution role ARN** — AgentCore Identity
  presents itself as the role AWS gave the runtime, so PingFederate can
  bind the actor identity to a real AWS workload.

## AWS side

- **Runtime** declared in `agentcore/agentcore.json` (HTTP protocol,
  `Authorization` header allowlist, custom JWT authorizer), deployed with
  the AgentCore CLI through the CDK app in `agentcore/cdk/`.
- **IAM grants** (in `cdk-stack.ts`): workload access tokens,
  `GetResourceOauth2Token` on the provider, Secrets Manager read of the
  provider secret, and `kms:Sign`/`kms:DescribeKey` on the KMS key.
- **Out-of-band setup** (not scripted): the KMS key and the
  `pingfederate-obo-poc2` credential provider (CustomOauth2,
  `private_key_jwt` + M2M actor leg). The CDK comments document the IAM
  shape.

## Design decisions and their rationale

- **AgentCore Identity performs the exchange, not the agent.** The agent
  must hold no OAuth logic and no credentials. AgentCore's credential
  providers do not support credential-free client authentication (the
  documented `NO_CLIENT` override is silently dropped by the live service —
  see [agentcore-obo-limitation.md](agentcore-obo-limitation.md)), so the
  client authenticates with a KMS-signed `private_key_jwt` assertion: no
  stored secret, and PingFederate holds only the public key.
- **PF-issued actor token instead of an AWS STS identity JWT.** The STS
  variant required a global PingFederate config-store relaxation
  (`issuerMustBeEqualToClientId`) plus per-client `typ` handling and tied
  the flow to account-level outbound federation. With the PF-issued
  `client_credentials` token, PingFederate validates the actor as its own
  token, the agent identity arrives in the standard `client_id` claim, and
  the exchange depends on nothing outside the cluster and AWS KMS.
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
`pf_preflight.py` checks the PingFederate side before attempting the flow;
`aws/teardown.sh` and `scripts/uninstall.sh` remove everything.

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
