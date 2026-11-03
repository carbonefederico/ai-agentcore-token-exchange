# PingFederate server profile — AgentCore secretless token exchange

Declarative PingFederate configuration imported at admin startup by the
Ping Identity image (bulk config). Full-state: every admin restart re-imposes
it. Do not hand-edit configuration in the admin console — changes are lost on
redeploy. The overall design is documented in
[docs/architecture.md](../../docs/architecture.md).

## Objects provisioned

| Object | ID | Purpose |
|---|---|---|
| Password credential validator | `AgentCoreDemoUsersPCV` | Local demo user (`demouser`) |
| IdP adapter | `AgentCoreLoginAdapter` | HTML form backed by the PCV; the default authn tree maps `username` → `AgentCoreApc.subject` |
| Authentication policy contract | `AgentCoreApc` | Carries `subject` from the login tree into the token mappings |
| JWT token processor | `PfUserTokenProcessor` | Validates PingFederate-issued **user** tokens (the exchange subject token); issuer/JWKS = this PF engine, audience = the AgentCore invoke audience |
| JWT token processor | `AwsStsTokenProcessor` | Validates AWS STS identity JWTs (the exchange **actor** token): issuer = the account's STS issuer, JWKS = AWS-published, audience = the PF token endpoint |
| Access token managers | `AgentCoreDelegatedATM`, `AgentCoreWebATM` | JWT output tokens, RS256, `at+jwt`, 15 min. Delegated ATM's `aud` comes from the requested `resource` (RFC 8707); web ATM's `aud` is fixed to the invoke audience |
| Token Exchange Processor Policy | `AgentCoreTokenExchangePolicy` | `actorTokenRequired: true`; single mapping — subject as `jwt` (PF user tokens via `PfUserTokenProcessor`), actor as `jwt` (AWS STS identity JWTs via `AwsStsTokenProcessor`); contract: `subject` ← subject `sub`, `subject_act` ← actor `sub` |
| Access token mapping | `AgentCoreTokenExchangeMapping` | Builds the delegated token: `sub` ← TEPP subject; `aud` ← `context.OAuthResources`; `act` ← `{ "sub": <actor client_id> }` |
| Access token mapping | `authz_req\|apc.AgentCoreApc\|AgentCoreWebATM` | User tokens from the auth-code leg: `sub` ← APC `subject` |
| OIDC policy | `AgentCoreOidcPolicy` | id_token policy for the login leg (5 min, `sub` ← `USER_KEY`) |
| OAuth client | `agentcore-demo-cli` | **Confidential** client (`clientAuth: SECRET`), `AUTHORIZATION_CODE` + `REFRESH_TOKEN`, redirect `http://127.0.0.1:8400/callback` |
| OAuth client | the runtime role ARN (literal in `data.json.subst`) | The agent: `clientAuth: PRIVATE_KEY_JWT`, **inline JWKS** = the KMS key's public key (kid `agentcore-pf-poc-1`, RS256); grant `TOKEN_EXCHANGE`; restricted scope `demo:read` |

## Substitution variables

`PF_ADMIN_PUBLIC_HOSTNAME` and `PF_ENGINE_PUBLIC_HOSTNAME`
(image-provided). Everything else is a literal in `data.json.subst` — the
variables from earlier revisions (`DEMO_USERNAME`, `AWS_STS_*`, `PF_CLI_*`,
`PF_AGENT_CLIENT_ID`, …) are gone.

## Files

- `instance/bulk-config/data.json.subst` — the configuration above. The
  runtime SSL server keypair is embedded inline as `fileData` (base64); no
  key material file lives in the profile.
- `hooks/07-apply-server-profile.sh` — profile override of the image's stock
  hook: merges `instance/` and registers the config-store XML into
  `data-default.zip` (PF prunes config-store files absent from the zip at
  every boot).
- `instance/server/default/data/config-store/oauth-credentials-validator.xml`
  — client-assertion validator relaxations for the agent client
  (`issuerMustBeEqualToClientId=false`, `jwtClientAuthenticationExpectedType=JWT`),
  registered by the hook.

## Notes

- **No TLS key material managed by operators.** The engines serve 9031 over
  the inline self-signed certificate (nothing validates it directly);
  external TLS terminates on the ingress (nginx-public class, cert-manager
  Let's Encrypt certificate), and nginx does not verify the upstream cert.
  Both the self-referential JWKS fetch (the `PfUserTokenProcessor` and
  `PfUserTokenProcessor` reading the engine's own JWKS) and AgentCore's
  authorizer see only the ingress certificate, which the PF JVM trusts by
  default.
- The engine pods must be able to resolve and reach the public hostname
  `PF_ENGINE_PUBLIC_HOSTNAME` from inside the cluster (hairpin through the
  load balancer) for the self-JWKS fetch to work.
- Replay prevention is **off** on the agent client: AgentCore Identity may
  cache its KMS-signed client assertion across exchanges, and a repeated
  `jti` would be rejected if enforcement were enabled.
- The config-store relaxations live in
  `instance/server/default/data/config-store/oauth-credentials-validator.xml`
  and are registered into `data-default.zip` by the profile hook. If PF
  boots without them, the agent client's `private_key_jwt` validation
  reverts to strict `typ`/`iss` checks and the exchange fails on
  `invalid_client`.
