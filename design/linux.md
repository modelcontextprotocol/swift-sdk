# Linux status

The SDK behaves the same on Linux and macOS: every CI job passes on both, against one set of
conformance baselines and one `interop/RESULTS.md`. Measured with `scripts/ci-linux.sh --strict
all` on 2026-10-24 (Swift 6.1.3, conformance `0.2.0-alpha.11`, Go SDK v1.8.0, Python SDK
v2.3.0).

| Job | ubi9 arm64 | ubi9 amd64 (emulated) | `swift:6.1-noble` arm64 | macOS |
|---|---|---|---|---|
| `build-test` | 949 tests | 949 tests | 949 tests | 965 tests |
| `docs` (DocC, `weave --check`) | pass | pass | pass | pass |
| every conformance leg, both modes | pass | pass | pass | pass |
| tier 2025-11-25 (client / server) | 18/18, 30/30 | 18/18, 30/30 | 18/18, 30/30 | 18/18, 30/30 |
| tier 2026-07-28 (client / server) | 32/32, 37/37 | 32/32, 37/37 | 32/32, 37/37 | 32/32, 37/37 |
| `interop --check` | matches | matches | matches | matches |

ubi9 is Red Hat UBI 9 with Swift 6.1 (`swift:6.1-rhel-ubi9`, libcurl 7.76);
noble is Ubuntu 24.04 (libcurl 8.5). The 16 tests that run only on macOS are the
`NetworkTransport` tests.

## How the HTTP client reads responses

`HTTPClientTransport` has one code path for both platforms. It reads every response body as it
arrives (`ResponseBody`) and parses `text/event-stream` with its own `ServerSentEventParser`:

- Apple platforms: `URLSession.bytes(for:)`.
- swift-corelibs-foundation has no `bytes(for:)` and no per-task delegates. The transport keeps
  a second session with the same configuration and a `StreamingSessionDelegate`, which hands
  each data task's response to the caller waiting for it and its chunks to that task's body.
  A second response for one task fails it rather than join the two bodies.

A session traps (corelibs) or raises (Apple platforms) when a task is created after it was
invalidated. `disconnect()` invalidates both sessions through `StreamingSession.Lifetime`: a task
being created holds the invalidation until it exists, later ones throw, and `connect()` builds new
sessions. The parser discards an event the body ends before its blank line (a server or proxy
that cuts the stream), so its `id` never becomes the `Last-Event-ID`; a line, or the data of one
event, over 16 MiB fails the request without a resumption.

Until this change the Linux path used `data(for:)`: it read a response only once the server
ended it, passed an SSE body to the client as one message (which the client dropped), and never
opened the GET stream. That failed 6 client scenarios at 2025-11-25 (`tools_call`,
`elicitation-sep1034-client-defaults`, `sse-retry`, `auth/scope-step-up`,
`auth/scope-retry-limit`, `json-schema-2020-12-preservation`) and the Swift client's HTTP
interop rows, and on noble it hung the 2026-07-28 client in `json-schema-ref-no-deref`. All of
these pass now.

## swift-corelibs-foundation behavior the SDK depends on

Checked on ubi9 and noble:

- `URLRequest.timeoutInterval` is an idle timeout, as on Apple platforms: a stream that keeps
  sending is not cut, and one silent for longer fails with `NSURLErrorTimedOut`. The request's
  value wins over `timeoutIntervalForRequest`, as on Apple platforms. The listen POST's
  `listenIdleTimeout` (one hour) therefore works on both.
- `URLSessionConfiguration.httpAdditionalHeaders` are added while the request is sent, after a
  `URLProtocol` sees it. The SDK copies them into each request it sends on Linux
  (`URLRequest.addingAdditionalHeaders(of:)`, for the transport's requests and the OAuth
  requests), so a `URLProtocol` sees the same headers as on Apple platforms.
- A `URLProtocol` that calls its client after the task was cancelled traps
  (`TaskRegistry.swift: Trying to access a behaviour for a task that in not in the registry`).
  The test mocks (`MockURLProtocol`, `IsolatedMockURLProtocol`) check `stopLoading()` before
  each callback and do not hold a lock during one: corelibs can call `stopLoading()` from its
  work queue while a callback waits for that queue.

## Differences by design

- `NetworkTransport` uses Network.framework and exists on Apple platforms only.
- `StdioTransport` takes `FileDescriptor` from `System` on Apple platforms and from
  `SystemPackage` elsewhere.

## Reproduce

```sh
scripts/ci-linux.sh --strict all                                  # RHEL UBI 9, this Mac's architecture
scripts/ci-linux.sh --image swift:6.1-noble --strict all          # Ubuntu 24.04
scripts/ci-linux.sh --platform linux/amd64 --job-timeout 90 --strict all   # x86_64, emulated
```
