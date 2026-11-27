# Rough edges

This file lists known API decisions and gaps, kept for compatibility or
deferred, with their workarounds. Each item describes the current code. Some
will change in a later major version.

## Server API

- Behind a `StatelessHTTPServerTransport`, handshake clients are served
  without a session: every `initialize` is answered, but the server keeps no
  client info or capabilities, so `Server.currentHandlerContext` has none for
  their requests, and there is no GET stream for messages outside a request.

  **Workaround**: route `initialize` clients to a
  `StatefulHTTPServerTransport`, with one `Server` per session.

- `Configuration.strict` defaults to `false`: in the handshake era a server
  serves requests sent before `initialize`.

- In the handshake era, `requestSampling` and `requestElicitation` send the
  request also when the server handles no client request, for example from a
  background task. SEP-2260 forbids this, but 2025-11-25 and earlier allow it.
  The SDK logs one warning for each method. At 2026-07-28 these calls, and
  `listRoots`, throw -32600. Outside a handler the server goes by the
  connection: it throws once the connection has served a stateless request,
  or when the server serves no handshake revision. Behind a
  `StatelessHTTPServerTransport` they also throw outside a handler, as there is
  no stream to send the request on.

  **Workaround**: call them from the handler of the request that needs the
  answer, or return input requests from that handler.

## Content and results

- `Client.Capabilities.Elicitation()` declares form elicitation, and decoding
  `"elicitation": {}` gives `form` too, for compatibility with clients that
  predate the `form` and `url` sub-capabilities.

## Errors

- `MCPError.connectionClosed` (-32000) and `transportError` (-32001) are local
  errors that use codes from the implementation-defined range. Decoded from
  the wire, -32000 and -32001 are `serverError(code:message:data:)`.

- `serverError(code:message:data:)` is the case for every code without its
  own case, including errors from clients. A received -32021 also uses it when
  `requiredCapabilities` cannot be decoded; -32042 uses it when its data cannot
  fit `urlElicitationRequired` without losing fields. Other known codes may
  still discard extra data. Its `localizedDescription` starts with `Server error:`.

- `resourceNotFound` and `invalidParams` share -32602. Decoding picks
  `resourceNotFound` when `data` has a `uri` and no `detail`.

## Deprecated by the specification

The specification deprecates these features
([deprecated features](https://modelcontextprotocol.io/specification/2026-07-28/deprecated)). They
work on every revision that has them. The SDK marks their entry points with
`@available(*, deprecated)`, and logs a notice the first time the peer declares a deprecated
capability: the server for a client's `roots` or `sampling`, the client for a server's `logging`.
Each notice is logged once for each process.

| Feature | Deprecated by | Earliest removal | What the SDK does | Migration |
| --- | --- | --- | --- | --- |
| Roots | SEP-2577 | First revision on or after 2027-07-28 | `Server.listRoots()`, `Client.withRootsHandler(_:)` and `notifyRootsChanged()` are deprecated. `Root`, `ListRoots`, `InputRequest.listRoots` and `Client.Capabilities.roots` carry a note. | Pass directories or files in tool arguments, resource URIs or server configuration. |
| Sampling | SEP-2577 | First revision on or after 2027-07-28 | `Server.requestSampling(...)` and `Client.withSamplingHandler(_:)` are deprecated. `Sampling`, `CreateSamplingMessage`, `InputRequest.sampling` and `Client.Capabilities.sampling` carry a note. | Call the API of an LLM provider from the server. |
| Logging | SEP-2577 | First revision on or after 2027-07-28 | `Server.log(level:logger:data:)` and `Client.setLoggingLevel(_:)` are deprecated. `LogLevel`, `SetLoggingLevel`, `LogMessageNotification`, `Server.Capabilities.logging` and the `logLevel` accessors carry a note. | Log to stderr (stdio), or use OpenTelemetry. |
| `includeContext` `thisServer` and `allServers` | SEP-2596 | With sampling | The two cases of `Sampling.ContextInclusion` are deprecated. They still decode and encode. | Omit `includeContext`, or use `.none`. |
| HTTP+SSE transport (2024-11-05) | SEP-2596 | Three months after SEP-2596 became Final | Not implemented. | Streamable HTTP: `HTTPClientTransport` and the HTTP server transports. |
| Dynamic client registration | PR #2858 | First revision on or after 2027-07-28 | Used when the client ID is empty, and when it is a client ID metadata document URL that the authorization server does not support. A plain client ID is a pre-registered client. | An https `clientID` URL with a client ID metadata document. |

Types and capabilities carry a documentation note instead of `@available`: the SDK uses them
itself on every revision, so a native marker would warn in the SDK's own code.

## Not implemented

| Item | Status |
|---|---|
| Tasks hosted by the client (2025-11-25 task-augmented sampling and elicitation) | Not implemented; 2026-07-28 removes them. |
| A verified cache for skill files | Not implemented; see [design/skills.md](../design/skills.md#open-questions). |
| DPoP: algorithms other than ES256 | Not implemented. Proofs are ES256 with a P-256 `DPoPSigningKey`. |
| An OpenID Connect sign-in helper for enterprise-managed authorization | Not planned. `enterpriseManaged` takes the user's ID token from the application. |

The capability structs carry `extensions`, so an application can declare and
read extension settings. The SDK implements these, none of them scored for a
conformance tier:

| Extension | SDK | Conformance |
|---|---|---|
| `io.modelcontextprotocol/tasks` (SEP-2663), and the experimental tasks of 2025-11-25 (SEP-1686) | [Tasks](server.md#tasks) | The 10 `tasks-*` server scenarios; 2025-11-25 against the TypeScript SDK in the interop `tasks` profile |
| `io.modelcontextprotocol/skills` (SEP-2640) | [Skills](server.md#skills) | The 3 `sep-2640-*` server and 4 client scenarios |
| Server Cards (SEP-2127), outside the protocol | [Server Cards](server.md#server-cards) | No scenario; the examples of the extension |
| `io.modelcontextprotocol/ui`, MCP Apps (SEP-1865), without the View-Host bridge | [MCP Apps](server.md#mcp-apps) | No scenario; the interop `apps` profile, against the ext-apps server helpers on the TypeScript SDK |
