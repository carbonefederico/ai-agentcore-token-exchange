# Limitation: AgentCore Identity cannot perform a credential-free token exchange

**Status:** confirmed empirically on 2026-10-30, eu-central-1, AgentCore CLI 1.0.0 /
botocore 1.43.x, against a PingFederate 13.1 OAuth server.
**Consequence for this POC:** the outbound exchange is performed directly by the
agent code (`agent/main.py`), not by AgentCore Identity. See SPEC.md for the
current flow.

## What we wanted

The POC's design goal was a fully secretless on-behalf-of exchange driven by
AgentCore Identity:

- AgentCore validates the AWS IAM identity JWT (`sts:GetWebIdentityToken`) and
  uses it as the RFC 8693 **actor token** — this part works as designed.
- The PingFederate OAuth client has **client authentication = NONE** (a public
  client): the request identifies itself with `client_id` only and carries **no
  client credentials**. Identity comes from the actor token itself.

## What AgentCore actually sends

The credential provider's `clientAuthenticationMethod` controls what AgentCore
attaches to the outbound token request. The possible values:

| Value | What lands on the wire |
|---|---|
| `CLIENT_SECRET_BASIC` | `Authorization: Basic` header with the secret |
| `CLIENT_SECRET_POST` | `client_secret` form parameter |
| `AWS_IAM_ID_TOKEN_JWT` | `client_assertion` (the STS JWT, duplicated as a credential) |
| `PRIVATE_KEY_JWT` | `client_assertion` (private-key-signed JWT) |
| *(omitted)* | server defaults to `CLIENT_SECRET_BASIC` and **rejects the config** with `clientSecret is required for CLIENT_SECRET_BASIC and CLIENT_SECRET_POST authentication methods` |

There is no mode that sends `client_id` alone. Every option attaches
credentials, and a client-auth=NONE OAuth server correctly rejects requests
that present credentials:

```
invalid_client: Invalid client or client credentials.
```

## The `NO_CLIENT` escape hatch exists in docs but not in the service

The API reference documents `OnBehalfOfAuthenticationConfig` with
`clientAuthenticationMethod: NO_CLIENT` ("omits the clientId and clientSecret
during the on-behalf-of token exchange") as an override inside
`onBehalfOfTokenExchangeConfig`. On the live service:

- The current CLI/botocore models do not accept the member (`Unknown parameter
  ... must be one of: grantType, tokenExchangeGrantTypeConfig`).
- A raw sigv4 POST bypassing the model is accepted (HTTP 200) but the field is
  **silently dropped** — the stored provider config has no trace of it, and the
  wire behavior is unchanged.

Two CLI versions were checked (2.35.5 bundled model and the current API docs):
the docs are ahead of the deployed service.

## Why not just change PingFederate instead?

Two options were evaluated and rejected:

1. **Client auth = PRIVATE_KEY_JWT** (the STS JWT as RFC 7523 client
   assertion). Functionally secretless (the "key" is AWS-signed, nothing
   stored), but PingFederate's JWT client-auth validator applies RFC 7523
   shape rules out of the box — `typ: client-authentication+jwt` and
   `iss == client_id` — which AWS STS identity tokens violate (`typ: JWT`,
   `iss: <sts issuer>`). The settings that relax them
   (`jwtClientAuthenticationExpectedType`, `issuerMustBeEqualToClientId`) live
   in a PingFederate **config store** that is neither console- nor
   REST-publishable in 13.1, and PF prunes unknown config-store files at every
   boot. Dead end without fragile server-image hacking.

2. **Client auth = SECRET.** Works trivially, but reintroduces a shared secret,
   which is exactly what the POC set out to avoid.

## The working alternative (implemented)

The agent performs the exchange itself (`agent/main.py`):

1. Read the user JWT from the invocation's `Authorization` header (validated by
   the Runtime's custom JWT authorizer).
2. Call `sts:GetWebIdentityToken` (the runtime role already has this
   permission with an audience condition).
3. POST the RFC 8693 request **directly to PingFederate** with `client_id`
   only (client auth NONE), the user JWT as `subject_token`, and the AWS
   identity JWT as `actor_token`.

This is still secretless end to end — AWS signs the actor token at request
time, nothing is stored or shared — and it removes AgentCore Identity from the
outbound path. Verified by manual replay against the same PF instance before
implementation: a `client_id`-only request passes client authentication and
proceeds to actor-token validation.

## How to re-verify this limitation later

```bash
# 1. No-credential provider config is rejected server-side:
aws bedrock-agentcore-control update-oauth2-credential-provider --name <p> \
  --credential-provider-vendor CustomOauth2 \
  --oauth2-provider-config '{"customOauth2ProviderConfig":{"oauthDiscovery":{...},"clientId":"..."}}'
# -> ValidationException: clientSecret is required for CLIENT_SECRET_BASIC/POST

# 2. NO_CLIENT is silently dropped (raw API call, then read back):
# GET the provider afterwards - onBehalfOfAuthenticationConfig absent.

# 3. AgentCore's wire request always fails on a client-auth=NONE server:
#    PF audit log shows invalid_client on the exchange POST.
```

If a future AgentCore release ships a working `NO_CLIENT` override (or a
`NONE` provider auth method), the original design in SPEC.md can be restored
by re-enabling the `GetResourceOauth2Token` call in `agent/main.py` and
recreating the credential provider.
