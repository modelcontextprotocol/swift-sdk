# OAuth client

## Context

MCP authorization uses OAuth 2.1 between an MCP client and the authorization server (AS) that
protects an MCP server. The client discovers the AS from Protected Resource Metadata (PRM,
RFC 9728) and AS metadata (RFC 8414 or OpenID Connect discovery), registers if needed (dynamic
client registration, RFC 7591, or a Client ID Metadata Document, CIMD), obtains a token with PKCE
(RFC 7636) and a resource indicator (RFC 8707), and retries the request.

The SDK implements the client side in `Sources/MCP/Base/Authorization/`. On the server side it
provides HTTP validators: `ProtectedResourceMetadataValidator` serves PRM and
`BearerTokenValidator` checks tokens with an application closure.

This major version adds issuer checks (RFC 8414 §3.3, RFC 9207, SEP-2468),
`application_type` (SEP-837), authorization server migration (SEP-2352) and the 2025-03-26
fallback endpoints.

## Goals

- Authorization is opt-in and does not change unauthenticated code paths.
- `HTTPClientTransport` knows only a small protocol; the OAuth logic is replaceable.
- Every network step is a component that tests can replace.
- Reject metadata and responses from a server other than the one discovered (mix-up defense).
- Follow a resource that moves to another AS without a restart.

## Design

### Layers

```swift
public protocol HTTPClientAuthorizer: AnyObject, Sendable {
    var maxAuthorizationAttempts: Int { get }
    func validateEndpointSecurity(for endpoint: URL) throws
    func authorizationHeader(for endpoint: URL) -> String?
    func handleChallenge(statusCode: Int, headers: [String: String], endpoint: URL,
                         operationKey: String?, session: URLSession) async throws -> Bool
    func prepareAuthorization(for endpoint: URL, session: URLSession) async throws  // default no-op
}
```

`HTTPClientTransport(endpoint:authorizer:)` calls, for each POST and before opening the GET
stream: `validateEndpointSecurity`, `prepareAuthorization` (errors ignored), then sets
`Authorization` from `authorizationHeader`. On 401 or 403 it calls `handleChallenge` and retries
while the result is `true` and fewer than `maxAuthorizationAttempts` attempts were made. Errors
from `handleChallenge` become `MCPError.internalError("Authorization flow failed: …")`.

`OAuthAuthorizer` is the built-in implementation, configured with `OAuthConfiguration`:

| Setting | Default |
|---|---|
| `grantType` | `.clientCredentials`; or `.authorizationCode` |
| `authentication` | required: `.clientSecretBasic`, `.clientSecretPost`, `.none(clientID:)`, `.privateKeyJWT` |
| `retryPolicy` | 3 authorization attempts, 2 scope step-ups |
| `endpointOverrides` | none; PRM URL, AS issuer, token endpoint, resource |
| `authorizationRedirectURI` | random loopback `http://127.0.0.1:<port>/callback` |
| `clientName`, `applicationType` | `"mcp-swift-sdk"`, inferred |
| `accessTokenProvider` | none; supplies an external token after discovery |
| `authorizationDelegate` | none; presents the authorization URL |
| `proactiveRefreshWindowSeconds` | 60 |

### Components

| Component | Visibility | Default |
|---|---|---|
| `TokenStorage` | public | `InMemoryTokenStorage` |
| `OAuthScopeSelecting` | public | `DefaultOAuthScopeSelector` |
| `OAuthWWWAuthenticateParsing` | public | `DefaultOAuthWWWAuthenticateParser` |
| `OAuthMetadataDiscovering` | public | `DefaultOAuthMetadataDiscovery` (well-known URLs, canonical resource URI, resource matching) |
| `OAuthURLValidating` | internal | `OAuthURLValidator` (HTTPS or loopback, private IP checks, redirect URI) |
| `OAuthDiscoveryFetching` | internal | `OAuthDiscoveryClient` |
| `OAuthTokenRequesting` | internal | `OAuthTokenEndpointClient` |
| `OAuthClientRegistering` | internal | `OAuthClientRegistrar` |
| `OAuthAuthorizationCodeFlowing` | internal | `OAuthAuthorizationCodeFlow` |

The public convenience initializer takes the public components. The internal initializer takes
all of them; tests use it.

`OAuthAuthorizer` is a class marked `@unchecked Sendable`. The transport runs each POST in its own
task, so calls overlap: every mutable property is behind a lock, and `handleChallenge` and
`prepareAuthorization` run one at a time through `AsyncGate`. One authorizer serves one resource.

### Challenge handling

401:

`handleChallenge` and `prepareAuthorization` run through `AsyncGate`, one at a time. The token
a request was sent with is the one in its `Authorization` header: `HTTPClientTransport` passes it
through `handleChallenge(statusCode:headers:endpoint:operationKey:sentAuthorization:session:)`
(an `HTTPClientAuthorizer` requirement whose default calls the method without it; there the
stored token is read before waiting). When another challenge replaced it meanwhile, the request
retries with the new token. A waiter whose task is cancelled leaves the gate's queue and throws
`CancellationError`. Every mutable property is read and written under a lock.

The authorizer counts the challenges that ran to the end and keeps the error of the last one. A
challenge that waited while another ended with an error, and finds no unexpired token, throws
that error instead of running the same flow again: one prompt for an authorization the user
cancelled. A cancelled challenge is not counted.

1. If the stored token has a refresh token, the challenge names no other PRM URL, the token is
   not the one the last refresh returned, and AS metadata is cached: refresh at that AS.
   Success → retry.
2. Re-read the PRM (`refresh: true` when a token is stored). A failed re-read keeps the cached
   PRM; a PRM that no longer lists the selected AS resets the selection and clears the token.
3. If no refresh was tried yet and a token is still stored (the PRM still lists its AS), refresh
   at the selected AS, also when it is the token the last refresh returned. Success → retry. AS
   metadata that is unavailable (`OAuthMetadataUnavailable`: a network error, an unexpected
   status) or a cancelled read fails the challenge and keeps the stored tokens.
4. Clear the token. Select scopes (challenge `scope`, else `scopes_supported`).
5. If `accessTokenProvider` returns a token, store it and retry.
6. Resolve AS metadata, register if needed, run the grant, store the token with its AS.

`refreshAccessToken` refreshes only when the token's AS equals the selected AS; a token without
an AS only when an AS or token endpoint override is configured.

403 is handled only with `error="insufficient_scope"`. When another challenge stored an unexpired
token with the required scopes while this one waited, the request retries with it. Otherwise the
requested scopes are the union of the token's scopes and the challenge's. Attempts are counted
per resource, operation (the JSON-RPC method) and scope set, up to `maxScopeUpgradeAttempts`.

`prepareAuthorization` refreshes a token that expires within `proactiveRefreshWindowSeconds`,
when a refresh token and AS metadata are known. It checks the expiry again once it holds the
gate, so concurrent requests refresh once.

### Discovery order

PRM candidates, first 2xx response with non-empty `authorization_servers` wins:

1. `resource_metadata` from the `WWW-Authenticate` challenge (must be HTTPS or loopback, not a
   private IP);
2. `endpointOverrides.protectedResourceMetadataURL`;
3. `/.well-known/oauth-protected-resource<endpoint path>`;
4. `/.well-known/oauth-protected-resource`.

A candidate that answers 404 or 410 is absent. Any other outcome (network error, timeout, other
status, invalid body) makes the fetch unavailable: `OAuthMetadataUnavailable` is thrown if no
candidate succeeds, and cancellation is rethrown. Only when every candidate is absent, and only on
first discovery, a synthetic PRM names the endpoint's origin as the AS and is marked `isFallback`
(2025-03-26 servers). A PRM `resource` must match the endpoint's canonical resource
URI, else `protectedResourceMismatch`. A new challenge URL drops the cached PRM, AS selection and
AS metadata.

AS candidates: `endpointOverrides.authorizationServerURL`, else the selected AS, else the PRM's
`authorization_servers` in order. Candidates that fail validation or are private IPs are skipped.
Metadata URLs per candidate:

| Issuer | URLs, in order |
|---|---|
| with path `/p` | `/.well-known/oauth-authorization-server/p`, `/.well-known/openid-configuration/p`, `/p/.well-known/openid-configuration` |
| root | `/.well-known/oauth-authorization-server`, `/.well-known/openid-configuration` |

### Issuer checks

- **AS metadata (RFC 8414 §3.3, SEP-2468).** Metadata is used only when its `issuer` matches
  the candidate it was fetched for. `OAuthIssuer.matches` is a string comparison, except that a
  root issuer may differ by a trailing slash (`https://as.example` and `https://as.example/`). If
  the only metadata found names another issuer, discovery throws
  `authorizationServerIssuerMismatch`. The old fallback that accepted another issuer is removed.
- **Authorization response (RFC 9207).** `perform` and `extractCode` take an
  `OAuthAuthorizationCodeFlow.ExpectedIssuer(issuer:isRequired:)`. The issuer is the metadata
  `issuer` (or the selected AS). An `iss` parameter must equal it exactly
  (`authorizationResponseIssuerMismatch`). A missing `iss` is rejected only when the metadata has
  `authorization_response_iss_parameter_supported: true` (`authorizationResponseMissingIssuer`).

### Registration: DCR and CIMD

Registration runs only when `authentication` is `.none(clientID:)`, once per AS:

| Condition | Action |
|---|---|
| AS supports CIMD and `clientID` is a URL but not `https` with a path | `invalidClientIDMetadataURL` |
| `clientID` is an `https` URL with a path and the AS supports CIMD | no registration; the URL is the client id |
| no `registration_endpoint`, `clientID` is a CIMD URL | `cimdNotSupported` |
| no `registration_endpoint` otherwise | no registration |
| `registration_endpoint` present | DCR |

The DCR body has `client_name`, `application_type`, `grant_types`, `token_endpoint_auth_method`,
and for the authorization code grant `response_types: ["code"]` and `redirect_uris`. The returned
`client_id` replaces the configured one. A `client_secret_expires_at` in the past triggers a new
registration. A registration that throws resets the attempt, so the next flow registers again; a
server without a registration endpoint is not asked again.

`application_type` (SEP-837): `OAuthConfiguration.applicationType` when set. Otherwise `web` for
the authorization code grant with an `https` redirect URI on a non-loopback host, and `native` in
every other case (the Python SDK's default).

### PKCE and the authorization code grant

- The AS metadata must list `S256` in `code_challenge_methods_supported`; a missing list or one
  without S256 throws.
- The verifier has 64 characters from the RFC 7636 unreserved set, drawn without modulo bias.
- The authorization URL carries `response_type=code`, `client_id`, `redirect_uri`, `state` (a
  UUID), `resource`, `code_challenge`, `code_challenge_method=S256` and `scope`.
- With an `authorizationDelegate`, the delegate presents the URL and returns the redirect URL.
  Without one, the flow sends a GET without following redirects and reads `Location`. The
  delegate, like `accessTokenProvider`, runs under the gate: it must not send requests through the
  transport it authorizes, since they would wait for the challenge it is part of.
- `extractCode` checks the redirect base (scheme, host, port, path), `state`, `iss`, then reads
  `code`.
- Every token request carries `resource`.

### Authorization server migration (SEP-2352)

- A 401 with a stored token refreshes first, and re-reads PRM when the refresh is refused or the
  refreshed token is rejected again. After that re-read, a refreshed token is refreshed again when
  the PRM still lists its AS.
- If the selected AS is no longer listed, the selection and AS metadata are reset and the stored
  token is cleared.
- `authorizationHeader` clears a stored token whose AS differs from the selected one.
- A refresh token is used only at the AS that issued it.
- Registered credentials are bound to `registrationIssuer`. When the AS changes, authentication
  returns to the configured value and registration runs again at the new AS.
- Pre-registered credentials (anything other than `.none`) are kept, as in the Python SDK.

### 2025-03-26 fallback

When every PRM candidate is absent, the synthetic PRM is `isFallback`. If every AS metadata URL
is then absent too (404 or 410) and no AS override is set, `OAuthAuthorizationServerMetadata.defaultEndpoints(issuer:)`
supplies `/authorize`, `/token` and `/register` at the origin, with S256.

### URL safety

The MCP endpoint, discovery URLs and AS endpoints must be HTTPS or loopback HTTP. A challenge's
PRM URL, AS candidates, the authorization endpoint and the token endpoint are rejected when the
host is a private or link-local IP literal (`isPrivateIPHost`). Host names are not resolved, so
DNS rebinding is not covered. The redirect URI is validated before the flow starts.

## Alternatives considered

- **Accept AS metadata with a different issuer.** The previous code did. It allows an AS mix-up,
  and SEP-2468 forbids it. Removed.
- **Normalized `iss` comparison.** RFC 9207 requires simple string comparison. Only the metadata
  check allows the root trailing slash, as Python's `issuers_match` does.
- **Reset all credentials on AS change.** Rejected for pre-registered credentials: the
  application configured them on purpose. Registered credentials are reset because they belong
  to the old AS.
- **Always `native`.** Rejected: OpenID Connect Dynamic Client Registration limits `native`
  clients to custom-scheme or loopback redirect URIs, so an `https` redirect on a public host
  belongs to a `web` client.
- **An actor for `OAuthAuthorizer`.** Not done: the protocol's synchronous `authorizationHeader`
  would become `async`. A lock per property plus a gate for the async flows gives the same
  guarantees without changing the protocol.

## Open questions

- The `private_key_jwt` helper uses CryptoKit. Without it (Linux) it throws
  `cryptographyUnavailable`. swift-crypto is now a dependency of the library and could provide
  P-256 there.
- A missing `authorization_endpoint` throws `tokenEndpointMissing`.
- `TokenStorage` holds one token, so one authorizer serves one resource.
- Deferred extensions, not scored for conformance tiers: DPoP (SEP-1932), enterprise-managed
  authorization, workload identity `jwt-bearer` ([ROADMAP.md](../ROADMAP.md)).
