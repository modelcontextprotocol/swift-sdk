# Linux status

Where the SDK on Linux differs from macOS, measured with `scripts/ci-linux.sh` on
2026-10-24 (Swift 6.1.3, arm64, conformance `0.2.0-alpha.11`, Go SDK v1.8.0, Python
SDK v2.3.0). This records the gap. Closing it is deferred: the plan keeps one set of
conformance baselines and one `interop/RESULTS.md` for both platforms, so Linux
CI is red on the legs below until the client transport is fixed.

## Summary

| Job | ubi9 (`swift:6.1-rhel-ubi9`) | `swift:6.1-noble` |
|---|---|---|
| `build-test` (734 tests, hello example) | pass | not run |
| `docs` (DocC, `weave --check`) | pass | not run |
| `conformance-2026-07-28`, both modes | pass | hangs (client, below) |
| `conformance-2025-11-25` | server pass; client fails 6 scenarios | not run |
| `conformance-default` | server pass; client fails the same 6 | not run |
| `tier-2025-11-25` | server 30/30; client 13/18 (macOS: 18/18) | not run |
| `tier-2026-07-28` | pass | not run |
| `interop` | every Swift-client HTTP cell differs (below) | not run |

The server side, stdio, and every Go and Python client match macOS exactly. All of
the gap is the Swift client over Streamable HTTP.

## Root cause: the Linux HTTP client does not stream

`HTTPClientTransport` has a separate Linux path (`Sources/MCP/Base/Transports/HTTPClientTransport.swift`):

- `send` uses `session.data(for:)` instead of `session.bytes(for:)` (around line 340),
  so a response is read only once the server ends it.
- An SSE response body is passed to the client as one message, verbatim
  (`"SSE responses aren't fully supported on Linux"`, around line 410). The client
  cannot decode `event: message\ndata: {...}` and drops it ("Unexpected message
  received by client", `Client.swift:386`). Any reply a server sends as SSE is lost.
- The GET stream is never opened (`startListeningForServerEvents`, around line 629),
  so there is no server-to-client channel outside a request, and no reconnection.

At 2026-07-28 the conformance harness answers with JSON, so the client conformance
leg passes. Interop servers stream SSE at both revisions, so interop shows the gap
at 2026-07-28 too.

## Conformance: the 6 client scenarios (2025-11-25 wire)

| Scenario | Failing checks | Symptom |
|---|---|---|
| `tools_call` | `tool-add-numbers` | SSE reply to `tools/call` dropped |
| `elicitation-sep1034-client-defaults` | all 5 `client-elicitation-sep1034-*-default` | the server's elicitation request arrives inside an SSE reply |
| `sse-retry` | `client-sse-graceful-reconnect` | no GET reconnection after the stream closes |
| `auth/scope-step-up` | `scope-step-up-initial`, `scope-step-up-escalation` | the client never gets far enough to authorize |
| `auth/scope-retry-limit` | `scope-retry-limit` | same |
| `json-schema-2020-12-preservation` | `json-schema-2020-12-client-tool-found`, `-echo-completed` | the `tools/list` SSE reply is dropped (not tier-scored) |

The bare (default-wire) leg fails the same 6. Its `tasks-*` server failures are
already in `conformance/baseline.yml` and match macOS.

## Interop: Swift client over HTTP

Compared with `interop/RESULTS.md` (macOS), only rows with the Swift client over
HTTP change:

- 2025-11-25 (handshake): `connect` times out after 20 s against every server
  (Swift, Go stateful and stateless, Python), because the `initialize` reply is SSE.
  The `connect` and `session` profiles fail the same way.
- 2026-07-28 (stateless): it connects to the Swift and Python servers, but
  `tool-logging`, `tool-progress`, `concurrent-calls` and `resource-subscribe` time
  out, and `tools-list-changed`/`prompts-list-changed` see no notification:
  everything that needs a streamed response or a listen stream. Against the Go
  stateless server, `connect` times out.

## `swift:6.1-noble`: a hang

On the Ubuntu 24.04 image the 2026-07-28 client leg hangs in `json-schema-ref-no-deref`:
the client process sleeps until killed, every time (three solo runs), and the
harness's `--timeout` does not stop it. The same scenario passes on ubi9. Swift
is 6.1.3 on both, but FoundationNetworking links the system libcurl, which is
7.76.1 on ubi9 and 8.5.0 on noble; that is the likely difference.
`scripts/ci-linux.sh --job-timeout` (default 30 minutes) stops such a job.

## Reproduce

```sh
scripts/ci-linux.sh conformance --spec-version 2025-11-25 --mode client --solo-attempts 0
scripts/ci-linux.sh interop      # then diff .build/linux/*/interop/report.md interop/RESULTS.md
scripts/ci-linux.sh --image swift:6.1-noble --job-timeout 5 conformance-2026-07-28
```
