# Server Cards (SEP-2127)

A Server Card is a static JSON document that describes a remote MCP server before a client
connects: identity, HTTP endpoints, and the protocol versions they serve. It is outside the
protocol: no capability declares it, and no message carries it.

Source: the `modelcontextprotocol/ext-server-card` repository (formerly
`experimental-ext-server-card`) at `526201bbc80231daa40ffcdecfc9da4e54e5dc93` (2026-08-12), which
is also the snapshot SEP-2127 cites. `schema.ts` is the source of truth; `docs/discovery.md` gives
the serving rules. The tests use the repository's examples, copied by
`scripts/server-card-examples.mjs` with their SHA-256.

## The document

`ServerCard` (`Base/ServerCard.swift`) has the fields of `schema.ts`: `$schema` (only
`ServerCard.schemaURL`), `name`, `version`, `description`, `title`, `websiteUrl`, `repository`,
`icons` (the SDK's `Icon`), `remotes` and `_meta`. Decoding needs the four required fields and
ignores unknown ones. `Remote.TransportType` and `Input.Format` are open structs.

`validate()` checks what decoding does not: the `$schema` value, the name pattern
(`^[a-zA-Z0-9.-]+/[a-zA-Z0-9._-]+$`, 3 to 200 characters), version length and ranges (`^`, `~`,
comparison operators, `*`, an `x` component), description and title lengths, URIs, and the remote
URL pattern. An unknown transport type is not an error, so a later revision does not break older
clients.

## Serving

`ServerCardValidator` (`HTTPServer/ServerCardValidator.swift`) validates the card when it is
created and answers `<endpointPath>/server-card`:

| Request | Response |
|---|---|
| GET | 200, the card, `Content-Type: application/mcp-server-card+json`, `ETag`, `Cache-Control: public, max-age=<maxAge>` |
| GET with a matching `If-None-Match` | 304, no body |
| HEAD | The headers of the GET, with `Content-Length` (the body is empty) |
| OPTIONS | 204 (CORS preflight; `If-None-Match` is not a CORS-safelisted header) |
| Other methods | 405, `Allow: GET, HEAD, OPTIONS` |

Every answer has `Access-Control-Allow-Origin: *`, `Access-Control-Allow-Methods: GET`,
`Access-Control-Allow-Headers: Content-Type, If-None-Match` and `Access-Control-Expose-Headers:
ETag`, as `discovery.md` requires. The ETag is the first 16 bytes of the SHA-256 of the encoded
card. `If-None-Match` uses the weak comparison of RFC 9110 and accepts `*`.

The validator does not check `Accept`: RFC 9110 lets a server ignore it, and a 406 would gain
nothing for a document with one representation.

An application calls `response(to:)` before its MCP endpoint. As an `HTTPRequestValidator` it
also works first in a transport's pipeline, like `ProtectedResourceMetadataValidator`; for that,
`StatelessHTTPServerTransport` passes a validator's 304 for methods other than POST, and
`StatefulHTTPServerTransport` runs the validators for methods other than GET, POST and DELETE
(the preflight, HEAD), and returns their 2xx and 304 answers.

A card that does not encode as JSON (a non-finite number in `_meta`) is refused when the
validator is created, like one that breaks the format.

`ServerCard(info:endpoint:protocolVersions:name:description:)` builds a card from
`Server.Info`. `Server.Info.name` is often not reverse-DNS, and `Server.init` sets no
description, so both can be passed.

## Fetching

`ServerCard.fetch(from:ifNoneMatch:session:)` sends `Accept: application/mcp-server-card+json`
and `If-None-Match` when given; requires a host and `https`, or `http` on a loopback host, for
the URL, and refuses a private or reserved IP literal host (`OAuthURLValidator.isPrivateIPHost`,
which allows loopback), as for a redirect target: the URL can come from an AI Catalog. Host names
are not resolved (no DNS rebinding protection). It decodes and validates. Errors are
`ServerCardError` with an open-struct `Reason`.

- Redirects: each hop is checked before it is requested, with the rule of OAuth discovery
  (`OAuthRedirectGuard`): the target must be `https`, or loopback `http` when the previous hop is
  loopback `http`, and its host must not be a private IP literal. A refused redirect throws
  `insecureURL`, judged from the hop that sent it; the final URL is checked again.
- Size: the body is streamed (`URLSession.responseBody`, `ResponseBody.collect(limit:)`) and the
  read stops after 1 MiB + 1 byte; a larger `Content-Length` is refused before the body is read.
  Both throw `tooLarge`.
- On swift-corelibs-foundation the request runs in a session with the given session's
  configuration and a `StreamingSessionDelegate` that applies the redirect check; it gets the
  session's `httpAdditionalHeaders`, so `URLProtocol` mocks see them.

`cardURL(forEndpoint:)` appends `/server-card` to the endpoint path (kept percent-encoded),
without query or fragment.
`Remote.url(resolving:)` fills `{variable}` placeholders: the given value, then the variable's
`value`, then its `default`; a required or undeclared variable without a value throws. Values
are percent-encoded except for unreserved characters (RFC 6570 simple expansion), so a value
cannot add a path, query, fragment or user, or move the host; a placeholder that starts the URL
(`{base}/mcp`) stands for the scheme and host and is inserted as given. Whether a placeholder
starts the URL is its position in the template, so one after an empty `{base}` is still encoded.

A card is advisory. `mismatches(with:)` compares it with a `server/discover` result: `name`,
`version` and `title` against `serverInfo` (when the server sends it), and each remote's
`supportedProtocolVersions` against `supportedVersions`. Versions the card leaves out are not
reported: only a card that claims more than the server serves can steer a client wrong.

## Not implemented

- AI Catalog discovery (`/.well-known/ai-catalog.json`): a separate specification. The
  application reads the catalog and passes the card URL.
- Resolving header values (`KeyValueInput.value` with `{variable}`).
- The MCP Registry's `server.json`, which SEP-2127 leaves out of scope.

## Open questions

- The extension evolves on its own schedule. Pin a new commit with
  `scripts/server-card-examples.mjs` and update this note and the doc comment of `ServerCard`.
- No other SDK has released Server Cards (Python #2951 and Go #1024 are unmerged), and the
  conformance harness has no scenario, so the only external check is the extension's examples.
