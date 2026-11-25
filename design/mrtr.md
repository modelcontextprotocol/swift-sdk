# Multi round-trip requests (SEP-2322)

## Context

At 2026-07-28 a server cannot send requests to the client. When `tools/call`, `prompts/get` or
`resources/read` needs input (an elicitation, a sampling call, the client's roots), the server
returns an input-required result:

```json
{"resultType": "input_required",
 "inputRequests": {"confirm": {"method": "elicitation/create", "params": {...}}},
 "requestState": "<opaque>"}
```

The client fulfills each request, then sends the same method again with a new id,
`inputResponses` keyed like the requests, and `requestState` echoed verbatim. The round repeats
until the result is complete.

Clients at 2025-11-25 and earlier do not know this result. They expect the server to send
`elicitation/create`, `sampling/createMessage` and `roots/list` itself during the call. The Go
SDK's `design/mrtr.md` covers the same feature; this note follows its structure.

## Goals

- Must have: correct wire representation at 2026-07-28, including results with only
  `requestState` or neither field; no change for code that does not use the feature.
- One handler for both eras.
- Few new public types.
- Client code unchanged: the registered sampling, elicitation and roots handlers answer input
  requests too.
- Safe handling of `requestState`, which the client holds between rounds.

## Design

### Wire types (`Base/MultiRoundTrip.swift`)

```swift
public enum InputRequest: Hashable, Sendable, Codable {   // {"method", "params"}
    case elicitation(CreateElicitation.Parameters)
    case sampling(CreateSamplingMessage.Parameters)
    case listRoots
    public static func elicitation(message: String, requestedSchema: Elicitation.RequestSchema = .init()) -> InputRequest
}

public enum InputResponse: Hashable, Sendable, Codable {  // the plain result
    case elicitation(CreateElicitation.Result)
    case sampling(CreateSamplingMessage.Result)
    case roots(ListRoots.Result)
    public var elicitation: CreateElicitation.Result? { get }
    public var sampling: CreateSamplingMessage.Result? { get }
    public var roots: [Root]? { get }
}
```

An input response on the wire does not name its method. Decoding picks the kind by shape: an
object with `roots` is a roots result, one with `action` an elicitation result, one with `content`
or `model` a sampling result. Anything else, and an object with one of these keys that does not
decode as that kind (a result of a later kind may reuse the key), is `.unknown`.

### Parameters and results

`CallTool`, `GetPrompt` and `ReadResource` are the carriers (`MRTR.carriers`).

| Type | Added members |
|---|---|
| `Parameters` | `var inputResponses: [String: InputResponse]?`, `var requestState: String?` |
| `Result` | `var inputRequests: [String: InputRequest]?`, `var requestState: String?`, `var resultType: ResultType { get }`, `static func inputRequired(_:requestState:_meta:)` |

- `resultType` is computed. A private `declaredResultType` stores the discriminator that
  `inputRequired` sets. Without it, a result is `input_required` when `inputRequests` or
  `requestState` is set, else `complete`.
- The declared value keeps load-shedding results (`input_required` with neither field) intact
  when the client decodes them.
- A decoded `"complete"` is stored as `nil`, so a decoded result and a constructed one compare
  equal.
- An input-required result encodes only `resultType`, `inputRequests`, `requestState` and
  `_meta`. Content is omitted.
- `inputResponses: null` in parameters is a decoding error, answered with -32602.

A handler asks for input like this:

```swift
await server.withMethodHandler(CallTool.self) { params in
    if let answer = params.inputResponses?["confirm"]?.elicitation, answer.action == .accept {
        return CallTool.Result(content: [.text(text: "Deployed \(params.requestState ?? "")", annotations: nil, _meta: nil)])
    }
    return .inputRequired(["confirm": .elicitation(message: "Deploy?")], requestState: "build-1234")
}
```

### Server boundary

`withMethodHandler` wraps carrier handlers in `serveRoundTrips`, which runs outside the actor:

| Step | Stateless request | Handshake request |
|---|---|---|
| Incoming state | `requestState` is unsealed; failure → -32602 `Invalid or expired requestState`, reason logged | `inputResponses` and `requestState` from the client are dropped |
| Handler result with content and input | -32603 | -32603 |
| `input_required` with neither field | -32603 | -32603 |
| Input requests the client cannot serve | -32021 with `requiredCapabilities` | — |
| Outgoing | state sealed; result returned to the client | the bridge fulfills the requests and calls the handler again |

The capability check uses the request's `clientCapabilities`: elicitation needs `elicitation`
(`elicitation.url` for URL mode; `elicitation.form`, or a declaration with neither, which the
decoder reads as form, for form mode; any declaration for a mode the SDK does not know), sampling
needs `sampling`, roots needs `roots`. For an unknown mode, `requiredCapabilities` names
`elicitation` with no sub-capability.

The bridge, for handshake clients:

- Sends every input request with `send(CreateElicitation/CreateSamplingMessage/ListRoots)`,
  concurrently in a task group. The requests carry the call's id as `relatedRequestID`, so over
  HTTP they travel on the call's SSE stream.
- Checks the requests against the session's client capabilities, as at 2026-07-28, whatever
  `strict` says (-32021).
- A client error fails the call with -32603 that names the method. Cancelling the call cancels
  the task group; each outstanding request is removed from the pending responses and withdrawn
  with `notifications/cancelled`.
- A state-only result waits 50 ms, doubling up to 250 ms, before the next call, like the client
  loop. The loop checks cancellation before each handler call.
- Calls the handler again with the responses and the plaintext `requestState` of the previous
  round. State is never sealed for handshake clients, because it never leaves the server.
- At most 10 handler calls (`MRTR.maxRounds`); then -32603.
- Batches are handled in a task, not in the receive loop, so a batched carrier can wait for the
  client's answers.

So one handler serves both eras. The Go SDK bridges the same way. The Python SDK answers -32603
when a handler returns an input-required result to a pre-2026 session.

### Client loop

`Client.send(_:)` for a carrier with `Configuration.multiRoundTrip.isEnabled` (default `true`):

1. Send the request. While the result is `input_required`:
2. Count the round. More than `maxRounds` (default 10) → -32603.
3. More than `maxInputRequests` (default 16) input requests → -32603 before any handler runs.
   With input requests: run the registered handlers for their methods concurrently. A missing
   handler throws -32601. A handler error fails the call.
4. Without input requests (state only, or neither): sleep 50 ms, doubling up to 250 ms. The
   delay resets when a round brings requests.
5. Send a new request with a new id, the caller's `_meta`, the responses, and the state echoed
   verbatim (omitted when absent).

`roundTrips` maps the first id to the current one. `send(_:)` registers it before it returns, and
keeps a canceller for the task that runs the rounds. `cancelRequest(firstID)` cancels the round in
flight and that task, which cancels running handlers and the state-only wait; `disconnect()`
cancels every such task. With the loop disabled, `send(_:)` returns input-required results, and
`callTool`, `getPrompt` and `readResource` throw -32600.

### `requestState` sealing

The client holds `requestState` between rounds, so what comes back is client input. A handler may
put a build id, a cursor or an approval decision in it. Unprotected, a client could forge,
replay or move it to another request.

`RequestStateBoundary` seals outgoing state and verifies incoming state. Handlers read and write
plaintext.

Claims (JSON, sorted keys):

| Claim | Content |
|---|---|
| `v` | envelope version, 1 |
| `iat`, `exp` | issue time and expiry in seconds; `exp = iat + timeToLive` (default 600 s) |
| `m` | method |
| `t` | tool or prompt name, or resource URI |
| `a` | base64url of the first 16 bytes of SHA-256 of the sorted-keys JSON of `arguments` (`{}` for `resources/read` or when absent) |
| `aud` | `RequestStateProtection.audience`, default the server name |
| `p` | optional principal: base64url(salt ‖ SHA-256(label ‖ salt ‖ principal)[0..<16]), 8-byte random salt |
| `s` | the handler's plaintext state |
| `jti` | 16 random bytes, base64url: the token's id for `RequestStateProtection.consume` |

Verification fails for: codec failure, malformed claims, `iat` more than 60 s in the future,
expiry, a different method, target or arguments digest, a different audience, or a principal
mismatch (including present on one side only). The principal comparison is constant-time. Every
failure gives the same -32602 to the client. The arguments digest is computed once per request
from the typed parameters, and only after the token is authenticated.

A token is valid for any number of echoes until `exp`, so a client can repeat a round or go back
to an earlier one. `RequestStateProtection.consume`, when set, is called with `jti` and `exp` after
verification; `false` rejects the token as replayed. One-time use is opt-in because it breaks a
client's retry of a round whose response was lost.

Token format of `AESGCMRequestStateCodec`:

```
v1.<base64url(keyID[4] ‖ nonce[12] ‖ ciphertext ‖ tag[16])>
```

- Key: HKDF-SHA256 of the secret, info `mcp/request-state/v1/aes-256-gcm`, 32 bytes.
- Key id: first 4 bytes of SHA-256(`mcp/request-state/v1/kid:` ‖ derived key).
- Associated data: `v1.` ‖ key id.
- Secrets must have at least 32 bytes (`minimumKeyLength`); an empty list, a short key or a
  duplicate key throws.
- The format matches the Python SDK. The claims envelope differs slightly.

Key rotation: `keys[0]` seals, every key verifies.

1. Deploy `[old, new]` everywhere: every instance can verify `new`.
2. Deploy `[new, old]`: `new` seals, `old` state still verifies.
3. One time-to-live after step 2 is complete, deploy `[new]`.

Configuration:

```swift
Server(name: "s", version: "1", requestStateProtection: .ephemeral())  // default
Server(name: "s", version: "1",
       requestStateProtection: try RequestStateProtection(keys: [current, previous]))
Server(name: "s", version: "1",
       requestStateProtection: RequestStateProtection(codec: MyCodec()))
Server(name: "s", version: "1", requestStateProtection: nil)            // no sealing
```

`RequestStateCodec` is the extension point:

```swift
public protocol RequestStateCodec: Sendable {
    func seal(_ payload: Data) throws -> String
    func unseal(_ token: String) throws -> Data
}
```

A codec must provide integrity and should provide confidentiality. `unseal` must throw
`InvalidRequestState` for any token it did not mint unchanged. Both methods are synchronous:
cache key material instead of calling a key service per token.

Why sealing is on by default:

- Most handlers that use `requestState` store something they would not accept from a client.
  Opt-in protection would leave them exposed by default.
- The ephemeral key needs no configuration and suits one process (stdio, one HTTP instance).
- The failure mode is safe: after a restart, or on another instance, the state does not verify,
  and the client starts the request again.
- Servers with several instances pass shared keys. `nil` remains for state that cannot affect
  authorization, resource access or business logic.

## Alternatives considered

Swift's choice is the Go proposal's main design: public fields on the existing result types, a
private discriminator, a runtime check, a server bridge and an opt-out client loop. The
discriminator is set by a static factory, `inputRequired(_:requestState:_meta:)`, because Swift
results are structs with `let` content.

- **A separate result type (`CallTool.Result | InputRequiredResult`)**, as in the Python SDK.
  `Method` has one associated `Result` type. A union would change `Result` for three methods to
  an enum, which breaks every handler, every `send(_:)` caller and the `callTool`, `getPrompt`
  and `readResource` return types.
- **Hidden fields with getters and a constructor function** (Go alternative "Unexported
  fields"). It prevents content plus input, but the result type would look empty to code that
  does not call the getter, and it differs from every other result type. The runtime check
  (-32603) covers the misuse.
- **An error type (`throw InputRequired(...)`)** (Go alternative). Input-required is not an
  error in the protocol, and the server maps unknown errors to -32603. Rejected.
- **New registration functions with a dedicated handler type** (Go alternative "New
  functions"). More public API for the same wire behavior.
- **An opt-in client loop** (Go alternative "Exported middleware"). Registered handlers would
  stop working at 2026-07-28 until the application opts in. The loop is on by default.
- **Suspending the handler and resuming on retry**, so that `requestElicitation` keeps working at
  2026-07-28. Rejected, as in Go: the server would hold state between rounds, and a retry may
  reach another instance.
- **Unsealed state by default**, with sealing opt-in. Rejected; see above.

## Open questions

- The bridge limit (10) is fixed. The client limit is configurable.
- A handler cannot return a load-shedding result (`input_required` with neither field); the
  server answers -32603. The client accepts such results from other servers.
- Shape-based `InputResponse` decoding depends on result shapes staying disjoint.
- `requestState` is limited to `String`. Structured state must be encoded by the handler.
