# Interop with the Go, Python and TypeScript SDKs

Real clients and servers of the SDKs, run against each other. The
conformance harness checks the Swift SDK against a mock peer; this matrix
checks it against the Go and Python SDKs' own implementations, in both
protocol eras, over Streamable HTTP and stdio, and against the TypeScript
SDK's task runtime (2025-11-25), the only other one with tasks, and its MCP
Apps server helpers (`ext-apps`).

```sh
scripts/run-interop.sh                   # report in .build/interop/report.md
scripts/run-interop.sh --update-results  # also writes interop/RESULTS.md
scripts/run-interop.sh --check           # fails when the results differ from RESULTS.md (CI)
```

`RESULTS.md` is recorded on macOS; Linux produces the same rows
([../design/linux.md](../design/linux.md)).

Needs Swift, Go 1.25 or later, `uv`, Node 20 or later with `npm`, `curl`,
`perl`, `python3`, `sha256sum` or `shasum`, and network access on the first
run. Nothing else is
installed globally: Go modules go to the module cache, the Python SDK to
`.build/interop/py-venv`, the TypeScript SDK to `.build/interop/ts`.
Behind a TLS-intercepting proxy, `export UV_SYSTEM_CERTS=1`.

The servers use fixed ports (3101, 3111, 3201, 3202, 3211, 3301, 3311, 3401
and 8000); the script stops when one is already in use, and checks that each
server it starts is the process answering. The report counts a cell as failed
when a check fails, when it has no meta line or no checks, and when the client
exited with an error (a crash, or the 300-second limit) without reporting a
failed check.

## Pinned SDKs

| SDK | Version | Pinned in |
|---|---|---|
| Go | `v1.8.0` | [go-client/go.mod](go-client/go.mod), from the Go module proxy. The conformance server and two examples are `tool` dependencies, built at the same version. |
| Python | `v2.3.0` | [python-client/requirements.in](python-client/requirements.in): `mcp` from PyPI, the conformance server from the tag's commit on GitHub. Installed from [requirements.txt](python-client/requirements.txt), a lock with hashes for every dependency and for the conformance server's build backend (built without build isolation or the index). The example servers are downloaded once from the same commit and checked against [examples.sha256](python-client/examples.sha256). |
| TypeScript | `1.32.2`, `ext-apps` `1.7.5` | [ts-client/package.json](ts-client/package.json): `@modelcontextprotocol/sdk`, `@modelcontextprotocol/ext-apps` and `zod` from npm, exact versions. Installed with `npm ci` from [package-lock.json](ts-client/package-lock.json), which has an integrity hash for every package. 1.x speaks 2025-11-25 only. `ext-apps` 2.x needs the TypeScript SDK v2 packages, which also serve 2025-11-25 only; 1.7.5, the last 1.x release, runs on the pinned SDK and has the same wire for the `apps` checks. |

To test another release, change the version in the pin files: `go get
github.com/modelcontextprotocol/go-sdk@vX` and `go mod tidy` for Go; for
Python, the `mcp` version and the commit in `requirements.in`, then the lock
(the command is in `requirements.in`) and `examples.sha256`; for TypeScript,
the versions in `package.json`, then `npm install --package-lock-only` in
`ts-client/`.

## Layout

| Path | What |
|---|---|
| `swift-client/` | `mcp-interop-client`, the check battery on the Swift SDK |
| `go-client/` | `go-interop-client`, the same battery on the Go SDK |
| `python-client/client.py` | the same battery on the Python SDK |
| `ts-client/client.mjs` | the `tasks` and `apps` profiles on the TypeScript SDK |
| `ts-client/server.mjs` | the task tools on the TypeScript SDK's task runtime, and the apps fixture on the `ext-apps` server helpers |
| `report.py` | turns the JSON lines of a run into the Markdown report |
| `RESULTS.md` | the last recorded report |
| `../scripts/run-interop.sh` | builds, starts the servers, runs the matrix |

Servers:

| Server | Address | Eras |
|---|---|---|
| Swift `mcp-everything-server` | `http://127.0.0.1:3101/mcp`, and `--stdio` | both |
| Go `conformance/everything-server`, stateful | `http://127.0.0.1:3201/` (`-stateless=false`) | 2025-11-25 only |
| Go `conformance/everything-server`, stateless (its default) | `http://127.0.0.1:3202/`, and stdio | both; no server-to-client requests at 2025-11-25 over HTTP |
| Python `mcp-everything-server` | `http://127.0.0.1:3301/mcp` | both |
| TypeScript `ts-client/server.mjs` (tasks and apps profiles only) | `http://127.0.0.1:3401/mcp`, and `--stdio` | 2025-11-25 |
| Examples: Swift `HelloServer`, Go `examples/server/hello`, Python `direct_execution.py` (stdio), Python `mcpserver_quickstart.py` (HTTP, port 8000) | | negotiated |

The three everything-servers implement the conformance harness's fixture, so
they share tool, resource and prompt names. Each client runs against every
server, its own SDK included (marked "control" in the report), so a failure
can be told apart from a bug in the battery. The SDKs' own example clients run
too: Swift `HelloClient` against Go `hello`, Go `listfeatures` against Swift
and Python servers.

## Checks

Every client prints one JSON object per line: a `meta` line (client, era,
negotiated version, server), then `{"check", "status", "detail"}` per check.
`--era handshake` pins 2025-11-25 (`initialize`), `--era stateless` pins
2026-07-28 (`server/discover`), `auto` lets the client negotiate. `--profile`
selects the battery; the three clients take the same flags (Go accepts
`--flag` and `-flag`).

| Profile | What it covers |
|---|---|
| `everything` (report: `basic`) | every tool, resource and prompt of the fixture |
| `advanced` | concurrency, cancellation, notifications, subscriptions, transport edges |
| `connect` | era negotiation (`--expect-era handshake\|stateless\|unsupported`) |
| `session` | a server restart between two calls (`--pause-file`) |
| `tasks` | the task tools of the Swift everything-server (SEP-1686, SEP-2663) |
| `apps` | the MCP Apps view and tools (SEP-1865) |
| `tool` | one tool call on an example server |

### `everything`

| Check | Era | Passes when |
|---|---|---|
| `connect` | both | the client connects at the pinned era |
| `ping` / `discover` | handshake / stateless | `ping` succeeds, or a `server/discover` request returns a non-empty `supportedVersions` |
| `tools-list` | both | the ten core tools are listed |
| `tool-simple-text`, `tool-image`, `tool-audio`, `tool-embedded-resource`, `tool-multiple-content` | both | the content blocks have the expected types |
| `tool-error` | both | `test_error_handling` returns `isError: true` |
| `logging-set-level` | handshake | `logging/setLevel` succeeds (stateless requests carry `logLevel` in `_meta`) |
| `tool-logging`, `tool-progress` | both | `notifications/message`, `notifications/progress` arrive during the call |
| `tool-sampling`, `tool-elicitation` | handshake | the server's request reaches the client's handler, and the answer comes back in the result |
| `mrtr-elicitation`, `mrtr-sampling`, `mrtr-list-roots`, `mrtr-multiple-inputs`, `mrtr-multi-round` | stateless | the client answers the `input_required` rounds (SEP-2322) and the tool completes |
| `unknown-tool`, `unknown-resource` | both | the server rejects them: an `isError` result or `-32602` for the tool, `-32602` or `-32002` (the 2025-11-25 code) for the resource; any other error fails |
| `resources-list`, `resource-static-text`, `resource-static-binary`, `resource-templates-list`, `resource-template-read` | both | the static and template resources read back |
| `prompts-list`, `prompt-simple`, `prompt-arguments`, `prompt-embedded-resource`, `prompt-image` | both | the prompts return the expected messages |

### `advanced`

| Check | Era | Passes when |
|---|---|---|
| `concurrent-calls` | both | 16 calls in flight at once (8 with progress, 4 text, 4 image) all complete, and each progress token receives its own notifications |
| `concurrent-input` | both | 8 concurrent calls that each need sampling or elicitation (server-to-client requests at 2025-11-25, `input_required` rounds at 2026-07-28) all complete |
| `cancel-then-continue` | both | a call cancelled after 20 ms leaves the connection usable: the next call answers |
| `tools-list-changed`, `prompts-list-changed` | both | `test_trigger_*_change` produces a `list_changed` notification within 3 s (skipped when the server does not declare `listChanged`) |
| `resource-subscribe` | both | `resources/subscribe` succeeds (2025-11-25), or `subscriptions/listen` is honored (2026-07-28) |
| `resource-updated` | both | `notifications/resources/updated` for `test://watched-resource` arrives within 8 s (only the Go server updates it; `--watched-updates`) |
| `reconnection` | both, HTTP | `test_reconnection` closes the response stream mid-call; the client resumes it with `Last-Event-ID` and gets the result |
| `mcp-param-header`, `mcp-param-header-unicode` | stateless, HTTP | `test_x_mcp_header` accepts the `Mcp-Param-Region` header the client derives from the tool's `x-mcp-header` annotation (SEP-2243), ASCII and non-ASCII |
| `streaming-elicitation` | both | `test_streaming_elicitation` completes |

The Go everything-server is the only one that updates `test://watched-resource`
(every 3 s). Its stateless HTTP server cannot send server-to-client requests at
2025-11-25, so it runs `advanced` only at 2026-07-28; the stateful one only at
2025-11-25.

### `connect`

Each client negotiates (`--era auto`) against every server, and must pick
2026-07-28 against the servers that serve both eras (`--expect-era
stateless`) and 2025-11-25 against the Go stateful server, which has no
2026-07-28 (`--expect-era handshake`). Pinned to
2026-07-28 against that server (`--expect-era unsupported`), the client must
not exchange 2026-07-28 messages with it. Three outcomes pass: an
unsupported-version error at connect (Swift: `-32022`), a fallback to the
handshake (Go: `ProtocolVersion` is a preference), or a clear rejection of the
first request (Python: a pinned mode adopts the version without a probe).
An error counts only when it is `-32022` or says the protocol version is
unsupported or not supported.

The `-32022` retry, where a client proposes a version the server rejects and
retries with one from the error's `supported` list, cannot be reached: each
SDK supports exactly one 2026-07-28 version. The Swift SDK's unit tests cover
it.

### `tasks`

Every client runs against the Swift everything-server, in both eras (the
TypeScript client at 2025-11-25 only), and against the TypeScript task server
at 2025-11-25, over HTTP and stdio. The Swift and TypeScript clients run the
task lifecycle: at 2025-11-25 they augment calls with `task` and read the
outcome with `tasks/result`, which also carries the server's input requests;
at 2026-07-28 the Swift client declares the extension and answers
`inputRequests` with `tasks/update`. The Go and Python SDKs have no tasks
runtime: their clients skip the lifecycle checks and run the last two, which
any client that does not use tasks must pass. A check whose tool the server
lacks is skipped (the TypeScript server has no `protocol_error_job` and no
`test_tool_with_task`).

| Check | Era | Passes when |
|---|---|---|
| `task-create` | both | `slow_compute` returns a working task, and the client drives it to its result |
| `task-input` | both | `confirm_delete`'s elicitation reaches the client's handler and the task completes |
| `task-partial-input` | both | `multi_input` asks two questions at once; both are answered and the task completes |
| `task-tool-error` | both | `failing_job`'s tool error comes back as an `isError` result |
| `task-protocol-error` | both | `protocol_error_job`'s failure comes back as -32603 |
| `task-cancel` | both | a cancelled task reads as cancelled; driving it throws (Swift), cancelling it again is -32602 (TypeScript) |
| `task-mrtr-composition` | stateless | `test_tool_with_task` asks for a name with `input_required`, then runs as a task |
| `task-list` | handshake | `tasks/list` returns the tasks the checks created (skipped when the server does not declare `tasks.list`) |
| `task-tool-inline` | both | a client without tasks calls `slow_compute` and gets the result inline |
| `task-required-refused` | both | a client without tasks is refused `failing_job` (required): -32021 at 2026-07-28, -32601 at 2025-11-25 |

The Swift everything-server binds tasks to the HTTP session that created them,
so it declares `tasks.list` at 2025-11-25.

### `apps`

Every client runs against the Swift everything-server, in both eras (the
TypeScript client at 2025-11-25 only), and against the TypeScript server at
2025-11-25, over HTTP and stdio. Both servers serve the same fixture: the
view `ui://interop/weather.html` with `_meta.ui` (`csp.connectDomains`,
`prefersBorder`) on the `resources/list` entry and on the content item;
`show_weather`, which renders in it; and `refresh_weather`, for the view only
(`visibility: ["app"]`). The TypeScript server registers them with
`registerAppResource` and `registerAppTool`, which also writes the
deprecated flat key `_meta["ui/resourceUri"]`; the Swift server writes only
`_meta.ui`. Each client declares `extensions["io.modelcontextprotocol/ui"]`
with `mimeTypes: ["text/html;profile=mcp-app"]`. The Swift client uses the
SDK's types (`Tool.ui`, `readAppResource`); the others read the raw `_meta`.

| Check | Era | Passes when |
|---|---|---|
| `apps-tools` | both | `show_weather` refers to the view and has no visibility; `refresh_weather` refers to it with `["app"]` |
| `apps-list` | both | the view is listed with the MIME type `text/html;profile=mcp-app` and the fixture's `_meta.ui` |
| `apps-read` | both | the read returns the HTML with the MIME type and the fixture's `_meta.ui` on the content item (Swift: and the CSP from it) |
| `apps-call` | both | `show_weather` answers with text, and its text says that the server saw the client declare the extension (`getUiCapability` on TypeScript, `clientUISettings` on Swift) |

### `session`

The runner starts a dedicated server, the client makes a call
(`session-before`), writes `ready` to the pause file and waits; the runner
restarts the server and writes `go`. The client's session ID is now unknown
(HTTP 404 at 2025-11-25).

| Check | Passes when |
|---|---|
| `session-expired` | the next call recovers, or fails with an error saying the session was not found, expired or terminated, within 10 s; another error or a hang fails |
| `session-reconnect` | a new client connects and calls a tool |

No client re-initializes on its own after a 404; each reports an error.

### `tool`

The example servers run the `tool` profile: `tools-list` and one `tool-call`
with an expected text.

## Findings (Go `v1.8.0`, Python `v2.3.0`, TypeScript `1.32.2`, `ext-apps` `1.7.5`)

[RESULTS.md](RESULTS.md) has the full report and names the Swift SDK commit
it ran against: 149 client-server cells (45
`basic`, 30 `advanced`, 15 `connect`, 15 `session`, 22 `tasks`, 22 `apps`),
1921 checks, and four example clients.

- **The Swift SDK passes every check that depends on it**, as the client or
  the server, against every SDK, over HTTP and stdio, at 2025-11-25 and
  2026-07-28. The 19 failures are all in the Go or TypeScript SDK or caused
  by them.
- **TypeScript server, `task-required-refused`:** fails for every client. A
  `tools/call` without `task` to a tool registered with `taskSupport:
  "required"` comes back as a tool result with `isError: true` whose text
  names -32601 (to the Go client, which sends no `arguments`, a -32603
  error), where 2025-11-25 says the server MUST answer -32601. The
  TypeScript client itself refuses such a call before sending it (-32600).
  TypeScript server bug.
- **Tasks, 2025-11-25, Swift and TypeScript:** each SDK's client drives the
  other's tasks: creation, polling, input delivered on the `tasks/result`
  stream, a tool error as a failed task whose `tasks/result` is the
  `isError` result, cancellation (-32602 for a second one) and listing. The
  TypeScript SDK binds tasks to the session; its client does not call
  `tasks/result` for a failed task, so `callToolStream` reports a tool error
  as an error, not as the `isError` result. The battery reads it with
  `getTaskResult`.
- **MCP Apps, both eras:** every client reads the same view, metadata and
  tools from the Swift server and from the TypeScript server on the
  `ext-apps` helpers, and both servers see each client's declaration (the
  Swift server at 2026-07-28 too, from the request's `_meta`). The `ext-apps` helpers also write the
  deprecated flat key `_meta["ui/resourceUri"]`; the Swift SDK reads it only
  when `_meta.ui` has no `resourceUri`, and never writes it. No
  incompatibility found.
- **Two Swift bugs found and fixed.** Both predate the 2026-07-28 work. The fix
  is part of the 2025-11-25 reliability changes, and the 2026-07-28 client adds
  its rule for that revision:
  - *Connection limit.* `HTTPClientTransport` used
    `URLSessionConfiguration.default`, which allows 6 connections per host. At
    2025-11-25 over HTTP/1.1, five or more concurrent calls that each waited
    for a sampling or elicitation reply held every connection, so the replies
    could not be sent, and the calls deadlocked (`concurrent-input`). The
    default configuration now allows 64.
  - *Stream resumption.* When a POST response stream ended before its
    response, the transport restarted the GET session stream with the last
    event ID of any stream, and a request whose stream the server could not
    replay waited forever. The transport now resumes the stream itself, with
    its own `Last-Event-ID`, and fails the request with -32603 when the server
    cannot replay it (`reconnection`). At 2026-07-28, which has no
    resumability, the request fails at once.
- **Go stateless HTTP server at 2025-11-25:** `tool-sampling` and
  `tool-elicitation` fail for every client, Go's included. The Go handler with
  `Stateless: true` cannot send server-to-client requests; the conformance
  server is run with `-stateless=false` for that. Go design. The elicitation
  error says `client does not support elicitation`, which is misleading: the
  stateless session has no stored `initialize` parameters.
- **Go client and Python server at 2026-07-28:** `mrtr-list-roots` and
  `mrtr-multiple-inputs` fail with `unexpected end of JSON input`. The Python
  server sends the `roots/list` input request without `params`, which is
  optional; the Go client decodes `params` unconditionally
  (`InputRequestMap.UnmarshalJSON`, `mcp/protocol.go`). The Swift client
  accepts both forms, and the Swift server sends `params`. Go client bug.
- **Go stateful server, `reconnection`:** fails for every client. The Go
  conformance server keeps no events (no `EventStore`), so a GET with
  `Last-Event-ID` gets 400. Each client reports a clear error: Swift -32603,
  Go `request terminated without response`, Python `SSE stream ended without
  a response`.
- **Go client, `Mcp-Param-*` headers:** the Go client derives them only from
  tools in its `ListTools` cache, which a `tools/list_changed` notification
  clears. A call made before listing again goes without the headers and the
  server rejects it (-32020). The battery lists the tools before the header
  checks, as a client does after `list_changed`. The Swift client keeps the
  last tool list.
- **Era negotiation:** pinned to 2026-07-28 against a server without it, the
  three clients differ, and all are allowed: Swift fails at connect with
  -32022, Go falls back to 2025-11-25 (`ProtocolVersion` is a preference),
  Python adopts the version without a probe and the first request fails.
- **Python client, pinned mode:** `mode="2026-07-28"` adopts a synthesized
  `DiscoverResult` with empty capabilities, and `session.discover()` returns
  it, so `server_capabilities` is empty. The battery calls `send_discover` to
  learn the server's capabilities, and in the `discover` check.
- **Python server, 2025-11-25:** declares no `listChanged` for tools and
  prompts, and sends no `list_changed`; at 2026-07-28 it declares and sends
  them. The battery skips those checks.
- **Sessions:** after a server restart no client initializes a new session on
  its own; each reports an error, and a new client connects. The Swift client
  reports `-32603 Session expired`.
- **Logging at 2025-11-25:** the Go server sends `notifications/message` only
  after `logging/setLevel`; the Python and Swift servers send them without.
  Both are allowed. The Swift client's `Configuration.logLevel` applies only to
  2026-07-28 requests, so a 2025-11-25 client that wants logs from a Go server
  must call `setLoggingLevel`.
- **`ping` at 2026-07-28:** the Go client refuses it ("not supported in the
  new protocol"); the Swift client's `ping()` sends `server/discover` instead.
  The battery checks `ping` only at 2025-11-25.
- **Swift fixture:** the first run found two names that differed from the
  harness and the other SDKs: the template `test://template/{id}` (now
  `test://template/{id}/data`) and the resource `test://watched` (now
  `test://watched-resource`). The fixture also gained `--stdio`.
