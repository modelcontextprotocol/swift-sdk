# Request headers (SEP-2243)

## Context

At 2026-07-28 a Streamable HTTP request carries routing data in headers, so that proxies and load
balancers can route and authorize without parsing the JSON body:

- `Mcp-Method`: the JSON-RPC method of every POST.
- `Mcp-Name`: `params.name` of `tools/call` and `prompts/get`, `params.uri` of `resources/read`.
- `Mcp-Param-<Name>`: a copy of a `tools/call` argument whose input schema property has
  `"x-mcp-header": "<Name>"`.

The server must reject a request whose headers are missing or disagree with the body, with
-32020 (HTTP 400). Clients must ignore tools whose annotations are invalid.

## Goals

- Clients send the headers without application code.
- Servers validate them before a handler runs.
- One codec for values on both sides, so that what the client encodes the server decodes to the
  same string.
- No source change for existing `Transport` conformers.

## Design

### Codec: `MCPRequestHeaders`

`Sources/MCP/Base/Transports/MCPRequestHeaders.swift` holds names, value encoding and the
annotation rules. It is public so that custom transports and proxies can use it.

Encoding (`encode(_:)`): a value is sent as-is when it is non-empty, printable ASCII
(0x20–0x7E), has no leading or trailing space, and does not itself look like the wrapper.
Otherwise it is sent as `=?base64?<Base64 of UTF-8>?=`. Empty values are wrapped because some
HTTP stacks drop empty headers.

Decoding (`decode(_:)`):

- Trims surrounding whitespace.
- A value without the wrapper is returned as-is.
- A wrapped value must be canonical Base64 (re-encoding gives the same text) and valid UTF-8.
  Otherwise the result is `nil`, which the server reports as a mismatch.

Rendering (`render(_:)`) turns an argument into header text: strings as-is, booleans as
`true`/`false`, integers in decimal (integral doubles below 2^53 as integers). `null`, other
numbers, arrays and objects have no header form.

### Annotations

`MCPRequestHeaders.parameters(in:)` reads a tool input schema:

- It walks `properties` from the root, recursively, in sorted key order. `$ref` is not followed;
  other composition keywords are not searched.
- Each property with `x-mcp-header` yields a `Parameter(headerName:path:type:)`.
- Invalid annotations throw `InvalidAnnotation`: a non-string or empty name, a name that is not an
  RFC 9110 token, a property type other than `string`, `integer` or `boolean`, or a name that
  duplicates another case-insensitively.

`Tool.headerParameters()` applies this to `inputSchema`.

### Client

| Step | Where | What |
|---|---|---|
| Standard headers | `HTTPClientTransport.post` | When `Version.profile(for: version).usesStandardHeaders`, set `Mcp-Method` and, where defined, `Mcp-Name` (encoded). The version comes from the message's `_meta`. |
| Schema cache | `Client.dispatch` → `recordTools` | Every `tools/list` result on a stateless connection fills `toolHeaderParameters[tool.name]`. Tools with invalid annotations are removed from the result returned to the caller, and their cache entry is cleared. A warning is logged. |
| Parameter headers | `Client.dispatch` | For `tools/call` on a stateless connection, `MCPRequestHeaders.parameterHeaders` builds `Mcp-Param-*` from the cached parameters and the call's arguments. Absent, `null` and non-primitive arguments send no header. |
| Sending | `Transport.send(_:additionalHeaders:)` | Used only when there are headers. `HTTPClientTransport` sends them on the request's POST. The default implementation ignores them and calls `send(_:)`, so a custom or wrapping transport implements the method to receive or forward them. |

The cache is filled only by `tools/list` results the client has received. A `tools/call` for a
tool that was never listed sends no `Mcp-Param-*` headers.

### Server

Standard headers are checked in `StatelessHTTPServerTransport` after the validation pipeline,
before the `MCP-Protocol-Version`/`_meta` comparison, and before the message reaches `Server`:

- Applies when the `MCP-Protocol-Version` header names a version with `usesStandardHeaders`.
- Missing `Mcp-Method`, or a value that differs from the body's method (case-sensitive, whitespace
  trimmed): -32020.
- For methods with a name value: missing `Mcp-Name`, or a decoded value that differs: -32020.
- Applies to requests and notifications.
- The checks read the body the server receives. The transport parses the POST body once with
  `JSONSerialization` and re-serializes it, then classifies the message, compares the headers and
  the `_meta` version, and dispatches that one form. Parsers resolve duplicate member names
  differently (`JSONSerialization` keeps the last on Linux, `JSONDecoder` the first), so checking
  one parse and dispatching another would let `{"name":"a","name":"b"}` pass `Mcp-Name: a` and
  run `b`. Notifications and responses are forwarded in that form only when their headers were
  checked; otherwise byte for byte.

Parameter headers are checked in `Server.parameterHeaderError`, because only the server knows the
schema:

1. Applies to stateless `tools/call` requests that have an `HTTPRequest` context.
2. Skipped when the call has no arguments and no `Mcp-Param-*` header was sent.
3. Find the tool's `inputSchema` by calling the registered `tools/list` handler, following
   `nextCursor`, at most 100 pages. The handler runs with the same `_meta` and `HandlerContext` as
   the call.
4. No `tools/list` handler, or no such tool (the pass failed or stopped at 100 pages): refused with
   -32020 when `Mcp-Param-*` headers were sent, otherwise no check. A tool hidden for an invalid
   annotation: always refused with -32020.
5. `MCPRequestHeaders.validate`: a header must be present exactly when its argument is present and
   not `null`; its decoded value must equal the rendered argument. The first mismatch is answered
   with `MCPError.headerMismatch` (-32020, HTTP 400). The handler does not run.

On stateless `tools/list`, the server removes tools with invalid annotations from the result and
logs a warning, so that it never advertises a tool clients must ignore.

```swift
let tool = Tool(
    name: "get_weather",
    description: "Weather for a region",
    inputSchema: [
        "type": "object",
        "properties": ["region": ["type": "string", "x-mcp-header": "Region"]],
    ])
// tools/call {"region": "Zürich"} carries: Mcp-Param-Region: =?base64?WsO8cmljaA==?=
```

### Error code and status

`MCPError.headerMismatch(String?)` has code -32020 and puts the detail in `data.detail`.
`StatelessHTTPServerTransport` answers it with 400. The same code covers an `MCP-Protocol-Version`
header that disagrees with `_meta` ([stateless.md](stateless.md)).

## Alternatives considered

- **A tool registry in `Server`.** The SDK registers handlers by method, so it has no tool list
  of its own. A registry would make schema lookup cheap, but it would be a second way to define
  tools. Paging the application's `tools/list` handler reuses the source of truth.
- **Caching the schema on the server.** Not done. The `tools/list` handler may return per-client
  or changing lists, and there is no invalidation signal inside one request.
- **Checking parameter headers in the transport.** The transport has no access to handlers.
  The check runs in `Server`, where `HandlerContext.httpContext` provides the headers.
- **Downcasting to `HTTPClientTransport`.** Replaced by `Transport.send(_:additionalHeaders:)`.
  With the downcast, a wrapping transport (a logger, a decorator) or a custom Streamable HTTP
  transport received a `tools/call` without its headers, and a conforming server answered -32020.
  The requirement has a default that ignores the headers, so existing conformers compile
  unchanged.
- **Lenient Base64 decoding.** Rejected. Canonical-only decoding means one header text per
  value, so comparisons are exact.

## Open questions

- `tools/call` before any `tools/list` sends no `Mcp-Param-*` headers, and a server that requires
  them answers -32020. The client could list tools on demand.
- The server calls the `tools/list` handler on every stateless `tools/call` with arguments. Cost
  is linear in the number of pages before the tool.
- A custom transport whose `send(_:additionalHeaders:)` keeps the default sends no parameter
  headers.
- Annotations under `$ref`, `allOf`, `anyOf` or `oneOf` are not found.
