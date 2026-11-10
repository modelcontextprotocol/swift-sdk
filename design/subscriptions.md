# Notification streams (SEP-2575)

## Context

Protocol 2026-07-28 removes the standalone GET stream and `resources/subscribe`. A client that
wants list-changed or resource-updated notifications opens a `subscriptions/listen` request. The
response stream of that request carries:

1. `notifications/subscriptions/acknowledged`, with the subset of the requested filter the server
   honors;
2. matching `notifications/{tools,prompts,resources}/list_changed` and
   `notifications/resources/updated`;
3. the result, only when the server ends the stream gracefully.

Every message on the stream carries `_meta["io.modelcontextprotocol/subscriptionId"]`, the
JSON-RPC id of the listen request. Over HTTP the client ends the stream by closing the response.

## Goals

- Server handlers keep calling `server.notify(...)`. The SDK routes the notification to the
  right streams in both eras.
- No lost events between registration and the acknowledgement.
- A cancelled or disconnected stream releases its server task.
- Client code that registers list-changed handlers works in both eras.
- `subscribeToResource(uri:)` works in both eras.

## Design

### Wire types (`Base/Subscriptions.swift`)

```swift
public struct SubscriptionFilter: Hashable, Codable, Sendable {
    public var toolsListChanged: Bool?
    public var promptsListChanged: Bool?
    public var resourcesListChanged: Bool?
    public var resourceSubscriptions: [String]?
}
public enum SubscriptionsListen: Method { /* Parameters(notifications:), Result(_meta:) */ }
public struct SubscriptionsAcknowledgedNotification: Notification { /* Parameters(notifications:) */ }
```

`Metadata.subscriptionID` reads and writes the `_meta` key as an `ID`. The internal
`SubscriptionEvent` (`toolsListChanged`, `promptsListChanged`, `resourcesListChanged`,
`resourceUpdated(uri:)`) is the server's routing unit.

### Server: listener registry

`Server.start` registers `serveListen` as the `subscriptions/listen` handler. It is a
stateless-only method; a handshake request gets -32601.

1. Compute the honored filter. A list kind is honored when requested and the server declares
   `listChanged` for it. `resourceSubscriptions` is honored when non-empty and the server declares
   `resources.subscribe`. Unhonored kinds are `nil`.
2. Create an `AsyncStream<SubscriptionEvent>` with `bufferingNewest(256)` and store it in
   `listeners` under a new token.
3. Send the acknowledgement with `relatedRequestID` set to the listen request.
4. Forward each event as a notification with `subscriptionId` set to the request id.
5. When the event stream finishes, call `Task.checkCancellation()`, then return
   `SubscriptionsListen.Result` with `subscriptionId` in `_meta`.
6. `defer` removes the listener.

Registration happens before the acknowledgement, so an event published in between is buffered.
The acknowledgement is still the first message, because only the handler task writes to this
stream.

`Server.notify(_:)`:

- Maps the notification to a `SubscriptionEvent` by method; only `resources/updated` reads its
  parameters. Other notifications are sent as before.
- Yields the event to every listener whose filter matches (`resourceUpdated` matches by URI).
  `notify(_:to:)` yields it only to listeners whose `HandlerContext` the closure accepts.
- Sends it on the connection only when the server has completed `initialize`. Without a
  handshake there is no connection-level stream to send it on.

Stream end:

| Trigger | Path | Client sees |
|---|---|---|
| `server.closeSubscriptions()` or `server.stop()` | event streams finish; handler returns; `handleRequest` sends the result, then `notifications/cancelled` for the listen id except on `StatelessHTTPServerTransport` | the result, then (stdio and other message streams) the cancellation; `Subscription.finished()` returns |
| `notifications/cancelled` for the listen id | handler task cancelled; `for await` ends; `checkCancellation` throws | no result |
| HTTP client closes the response | `StatelessHTTPServerTransport` SSE `onTermination(.cancelled)` → `abandon` yields `notifications/cancelled` for the internal id | stream closed by the client itself |

The cancellation after the result follows cancellation.mdx (2026-07-28): a server MUST send
`notifications/cancelled` referencing a `subscriptions/listen` request when it tears that stream
down. Over HTTP the end of the response is the teardown. A stream the client cancelled gets
nothing more.

`StatelessHTTPServerTransport` gives each exchange an internal id, so the handler stamps the
internal id in `subscriptionId`. `JSONRPCMessageFields.replacingSubscriptionID` restores the
client's id in `params._meta` and `result._meta` on the way out.

The SDK does not implement HTTP. An adapter must cancel the response stream, or the task that
awaits `handleRequest(_:)`, when the connection closes; `conformance/everything-server/HTTPApp.swift`
does it in `channelInactive`. The transport refuses a listen POST without `text/event-stream` in
`Accept` (406), and writes a `: keep-alive` comment on each open SSE stream every
`keepAliveInterval` (15 s), so that idle streams outlive client (`URLSession` waits 60 s for data
by default) and proxy timeouts. `HTTPClientTransport` also gives listen POSTs an idle timeout of
one hour.

### Client: `listen(_:)` and `Subscription`

```swift
let subscription = try await client.listen(.init(toolsListChanged: true))
// subscription.notifications is the honored filter
await subscription.cancel()
```

- Throws -32600 on handshake connections.
- `connect(transport:)` registers an `onNotification` handler for the acknowledgement, which
  forwards it to the waiter for its `subscriptionId`.
- `listen` sends the request with `send(_:)`, then waits for the first of two outcomes: the
  acknowledgement, or the request ending first (error or result). Both are yielded into one
  `AsyncStream<Result<SubscriptionFilter, Error>>`.
- If the caller is cancelled while waiting, the `for await` loop ends, `listen` cancels the
  request and throws `CancellationError`.
- Notifications on the stream go to the handlers registered with `onNotification`, like any
  other notification.
- `Subscription.cancel()` calls `Client.cancelRequest(id)`. On a stateless HTTP connection that
  aborts the POST (`HTTPClientTransport.cancelRequest`) and sends no `notifications/cancelled`.
  On other transports it sends `notifications/cancelled`.
- `Subscription.finished()` waits for the request: it returns on a graceful end and throws on
  failure or cancellation.

### Pitfall: waiting with a task group

The obvious way to wait for either outcome is a task group: one child awaits the
acknowledgement, the other awaits `context.value` of the listen request. That wait cannot be
cancelled. Cancelling the group cancels its children, but a child suspended on `Task.value` of an
unstructured task keeps waiting until that task finishes, and the group does not return before
all children do. A cancelled caller would hang until the server ended the stream. `AsyncStream`
iteration ends when the consuming task is cancelled, so `listen` uses a stream of outcomes and a
separate unstructured task that feeds it.

### Client: background stream

One background stream carries everything the client listens for by itself: the list kinds that
have at least one handler and that the server declares with `listChanged`, and the URIs passed to
`subscribeToResource(uri:)`. `refreshNotificationStream()` runs after `connect`, when
`onNotification` registers a list-changed handler, and on subscribe and unsubscribe. It does
nothing on handshake connections.

- If the wanted filter equals the current one (open or opening), nothing happens. Otherwise the
  generation counter increments and a background task opens a new stream with `listen`.
- An opening whose generation is stale is cancelled, unless no stream is open and something is
  wanted: then it serves until its successor is acknowledged.
- A successful opening is installed; the previous stream is retired: cancelled, and until it
  ends its notifications are delivered when the client still wants them (a list kind with a
  handler, a subscribed URI) and dropped otherwise. An event the server published before it
  registered the successor exists only on the retired stream, so it is kept; one published during
  the overlap arrives on both streams and may be handled twice. Both kinds are refetch hints.
- A failed opening keeps the previous stream and its filter, fails the `subscribeToResource` calls
  still waiting for a URI that only it named (and unsubscribes those URIs), and schedules a retry.
  Established subscriptions stay: after the stream dropped, a failed reopen keeps them and the
  client keeps reopening with backoff.
- A stream that ends, with an error or with its result, is forgotten and reopened after a delay
  of 1 s, doubled after each further end up to 60 s. The count is reset when a stream ends after
  staying open for at least 60 s, not when a stream is acknowledged: a server that acknowledges
  each stream and drops or closes it at once sees growing delays. A server ends streams with
  their result on `stop()` and `closeSubscriptions()`, as for a restart, so those are reopened
  too.

### Client: resource subscriptions

| Call | Handshake | Stateless |
|---|---|---|
| `subscribeToResource(uri:)` | `resources/subscribe` | adds the URI to the background stream; returns after an acknowledgement that names it; no-op if already served; -32600 if the URI is not honored |
| `unsubscribeFromResource(uri:)` | `resources/unsubscribe` | replaces the stream with one without the URI; no-op if not subscribed |
| `subscribedResourceURIs` | empty | subscribed URIs the open stream serves |

`disconnect()` cancels the background stream and fails waiting subscribe calls before closing the
transport, and again afterwards for a call made while it was closing. After `disconnect()`,
`subscribeToResource(uri:)` throws instead of waiting.

## Alternatives considered

- **Honor every requested kind**, as the Python SDK does. Rejected: the acknowledgement would
  promise notifications that a server without the capability never sends.
- **Send list-changed notifications on the connection at 2026-07-28 too.** Rejected: there is no
  connection-level stream, and the stateless transport drops messages without a related request.
- **An unbounded event buffer.** Rejected. Events are refetch triggers, so keeping the newest 256
  bounds memory for a slow consumer.
- **One listen stream per resource URI.** Rejected: each holds a connection (64 per host by
  default, HTTP/1.1) and a server task pair, so a client with many subscriptions starves its own
  requests. One stream is replaced on each change of the URI set instead.
- **No reopening of failed streams**, as in the Go SDK. Rejected: a network error or an idle
  timeout would silently stop list-change and resource notifications. Streams the server ends
  with a result are reopened with the same backoff, so a server that ends streams on purpose
  sees at most one reopen a minute.

## Open questions

- With `bufferingNewest(256)`, a consumer that falls behind on many distinct URIs loses older
  `resources/updated` events, not only duplicates.
- On handshake connections the SDK does not track `resources/subscribe`. The application
  registers `ResourceSubscribe` and `ResourceUnsubscribe` handlers and decides whom to notify.
