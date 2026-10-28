# PingFederate server profile — AgentCore secretless token exchange

Declarative PingFederate configuration imported at admin startup by the
Ping Identity image (bulk config). Full-state: every admin restart re-imposes
it. Do not hand-edit configuration in the admin console — changes are lost on
redeploy. See the sibling perf project's `docs/pingfederate-configuration.md`
for the format in depth.

## Objects provisioned

| Object | ID | Purpose |
|---|---|---|
| IdP adapter (Simple) | `DemoFormAdapter` | Username/password form for the CLI's Authorization Code + PKCE login (demo credentials from `DEMO_USERNAME`/`DEMO_PASSWORD`) |
| JWT token processor | `AgentCorePingFederateUserProcessor` | Validates PingFederate-issued user tokens (the exchange subject token); issuer = `OUTPUT_ISSUER`, JWKS = `OUTPUT_JWKS_URL` |
| JWT token processor | `AgentCoreAwsStsTokenProcessor` | Validates AWS STS identity JWTs (the actor token): issuer = the account's STS issuer, JWKS = AWS-published, audience = the PF token endpoint |
| Access token managers | `AgentCoreDelegatedATM`, `AgentCoreUserATM` | JWT output tokens, RS256, `at+jwt`; delegated ATM's `aud` comes from the requested `resource` (RFC 8707), user ATM's `aud` is fixed to `RUNTIME_API_AUDIENCE` |
| Token Exchange Processor Policy | `AgentCoreTokenExchangePolicy` | `actorTokenRequired: true`; subject type `urn:ietf:params:oauth:token-type:jwt` via the PF user processor; actor type `urn:...:jwt` via the AWS processor; contract: `subject` ← subject `sub`, `subject_act` ← actor `sub` |
| Access token mapping | `AgentCoreTokenExchangeMapping` | Builds the delegated token: `sub` ← TEPP subject; `aud` ← `context.OAuthResources`; `act` ← `{ "sub": <actor sub> }` |
| Access token mapping | `AgentCoreAuthCodeMapping` | User tokens: `sub` ← adapter `username` |
| OAuth client | `${PF_CLI_CLIENT_ID}` | **Public** client (`clientAuth: NONE`), `AUTHORIZATION_CODE` + `requireProofKeyForCodeExchange: true`, redirect = loopback `PF_CLI_REDIRECT_URI` |
| OAuth client | `${PF_AGENT_CLIENT_ID}` | The agent, registered with **no secret**: `clientAuth: PRIVATE_KEY_JWT`, JWKS URL = the AWS STS JWKS. `client_id` must equal the agent's IAM role ARN (the JWT's `sub`); grant `TOKEN_EXCHANGE`; exclusive scope `demo:read` |

## Required substitution variables

`DEMO_USERNAME`, `DEMO_PASSWORD`, `PF_ADMIN_PUBLIC_HOSTNAME` (image-provided),
`AWS_STS_ISSUER`, `AWS_STS_JWKS_URL`, `PF_TOKEN_ENDPOINT_AUDIENCE`,
`OUTPUT_ISSUER`, `OUTPUT_JWKS_URL`, `RUNTIME_API_AUDIENCE`,
`DEMO_RESOURCE_URI`, `PF_CLI_CLIENT_ID`, `PF_CLI_REDIRECT_URI`,
`PF_AGENT_CLIENT_ID`, `PING_IDENTITY_PASSWORD`.
All are supplied by `scripts/deploy.sh` from `.env`.

## Files

- `instance/bulk-config/data.json.subst` — the configuration above.

## Notes

- **No TLS key material anywhere.** The engines serve 9031 over their
  default certificate; nothing validates it — external TLS terminates on
  the ingress (nginx-public class, cert-manager Let's Encrypt certificate,
  templated by the chart), and nginx does not verify the upstream cert.
  Both the self-referential JWKS fetch (the
  `AgentCorePingFederateUserProcessor` reading `OUTPUT_JWKS_URL`) and
  AgentCore's authorizer see only the ingress certificate, which the PF
  JVM trusts by default.
- The engine pods must be able to resolve and reach the public hostname
  `PF_PUBLIC_HOSTNAME` from inside the cluster (hairpin through the load
  balancer) for the self-JWKS fetch to work. Verify once with
  `scripts/smoke.sh` — it exercises exactly this fetch path.
- The AWS STS JWKS needs no truststore changes (publicly trusted cert).
- Replay prevention is **off** on the agent client: AgentCore Identity may
  cache its STS identity JWT across exchanges, and a repeated `jti` would be
  rejected if enforcement were enabled.
- The `issuerMustBeEqualToClientId` global setting: with the agent client's
  `client_id` registered as the IAM role ARN, the assertion's `sub` matches
  the client ID; if PingFederate additionally requires `iss == client_id`,
  the platform team must flip the configStore flag
  (`oauth-credentials-validator/issuerMustBeEqualToClientId = false`) — a
  documented, global change requiring sign-off. See SPEC.md Phase 0.
