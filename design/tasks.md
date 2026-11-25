# Tasks (SEP-1686, SEP-2663)

## Context

A task lets a request outlive its JSON-RPC exchange: the server answers at once with a task
handle, and the client polls it until the outcome is ready. Two revisions define tasks, and
their wire forms are not compatible:

| | v1: 2025-11-25 (SEP-1686, core, experimental) | v2: 2026-07-28 (SEP-2663, `io.modelcontextprotocol/tasks`) |
|---|---|---|
| Who decides | The requestor: `params.task {ttl}`, allowed by `Tool.execution.taskSupport` | The server, per request, for clients that declare the extension |
| Negotiation | `capabilities.tasks {list, cancel, requests.tools.call}` in `initialize` | `extensions[tasks]` in per-request `_meta` and `server/discover` |
| Create result | `{"task": {taskId, status, ttl, pollInterval, ...}}` | Flat, `resultType: "task"`, `ttlMs`, `pollIntervalMs` |
| Outcome | `tasks/result`, which blocks until terminal, with related-task `_meta` | Inlined in `tasks/get` (`result` or `error`) |
| Input during the task | Server requests with related-task `_meta`, on the `tasks/result` stream | `inputRequests` in `tasks/get`, answered with `tasks/update` |
| Tool `isError` | Status `failed`; `tasks/result` returns the result | Status `completed` |
| Cancel | Returns the task; cancelled before the reply; terminal: -32602 | Empty acknowledgement; terminal: acknowledgement |
| `tasks/list` | Yes, when tasks are bound to callers | Removed (-32601) |
| Push | `notifications/tasks/status` at any time | `notifications/tasks` on `subscriptions/listen` streams that name the task |
| Progress | The request's token stays valid for the task's lifetime | Not sent |
| Required tool, no task | -32601 | -32021 with `data.requiredCapabilities.extensions` |
| Routing | | `Mcp-Name` = `taskId` |

Revisions before 2025-11-25 have no tasks: the work runs inline. The conformance harness tests
only v2, as a server (the `tasks-*` scenarios of the default leg), and v1 only by its absence at
2026-07-28. The TypeScript SDK 1.x has a v1 runtime; the interop `tasks` profile runs the
Swift and TypeScript clients and servers against each other at 2025-11-25.

## Goals

- One handler for every revision: the SDK chooses the wire form and the gating.
- The SDK derives the task capabilities and per-revision gating from one declaration per tool
  (`execution.taskSupport`).
- `Client.callTool` returns the final result at either revision; a low-level handle for
  applications that follow tasks themselves.
- No public type named `Task` (it would shadow `Swift.Task` in every file that imports `MCP`).
- Open structs for every value set a later revision may extend (VERSIONING.md).

## Design

### One model, two wire forms (`Base/TaskTypes.swift`)

`TaskSnapshot` is the task as the server reports it: the create result, `tasks/get`, and both
status notifications. An internal `generation` selects the encoding: `ttl`/`pollInterval` and
no outcome for v1; `ttlMs` (`null` when unlimited) and `pollIntervalMs`, plus the outcome from
`tasks/get`, for v2. Decoding accepts both forms and records which it read. `TaskStatus` and
`TaskSupport` are open structs. `CallTool.Result.task` carries the task a result creates:
`resultType == "task"` (v2) or a top-level `task` without `content` (v1) decodes into it.

The method types: `GetTask`, `UpdateTask` (v2), `CancelTask` (result: the task at v1, an empty
acknowledgement at v2), `GetTaskPayload` (`tasks/result`, v1), `ListTasks` (v1),
`TaskStatusNotification` (v1) and `TaskUpdatedNotification` (v2). `ProtocolProfile` gains
`usesTaskAugmentation` (v1) and `usesTasksExtension` (v2); code reads the internal
`taskGeneration` instead of comparing versions.

### Storage and work (`Server/TaskManager.swift`)

`TaskRecord` is the neutral stored form: status, outcome (`result` value or `MCPError`),
outstanding `inputRequests`, owner, the creating revision, TTL and poll interval. A tool error
completes the record; the v1 snapshot reports it as `failed`.

`TaskManager` (an actor) runs the work and keeps state behind a `TaskStore`
(`InMemoryTaskStore` by default). One manager serves every `Server` of a process: a stateful
HTTP transport creates a `Server` per session, and a v1 task must outlive the session. While
a task runs, an in-memory cache is authoritative and store writes are serialized, so a
`tasks/get` right after the create result resolves (SEP-2663's durable creation). Waiting for
input (`ResponseSlot` per `requestInput` call), the work's Swift `Task` and change waiters stay
in memory: a task is a durable handle, not durable execution.

Limits: `maxActiveTasks`, `maxActiveTasksPerPrincipal` (only with a principal), default and
maximum TTL (a v1 requested `ttl` is clamped). Expiry on access, plus a sweep of the store
every 64 creations, and of the running tasks before a limit refuses a call; an expired task's
work is cancelled and its change waiters woken. At a limit, a `required` tool or a v1 augmented
call fails with -32603 before the work starts, and any other call runs inline (the
cost: inline work can hold an HTTP request as long as it runs). Inline is the answer only where
every client accepts it: a 2026-07-28 client that declared the extension handles either result
(the server decides), and so does a v1 call without `task`. A v1 client that sent `task`
expects a `CreateTaskResult` (2025-11-25: a receiver that accepts the request MUST return one);
the TypeScript client parses the reply as one and fails on a tool result, after the work ran,
so a retry runs it twice. A `required` tool is one its author never runs inline: its work may
outlast the request, and at 2026-07-28 inline work cannot ask for input.

Auth binding: an optional `principal` closure, as in `RequestStateProtection`. A task is
visible only to its owner, and a foreign task reads as unknown (-32602), so its existence does
not leak. A caller the closure returns `nil` for gets no tasks (none created, none visible,
an empty list): callers without a principal are not one principal. Without a principal, tasks
rely on 128-bit random ids, and v1 does not declare `tasks.list` (2025-11-25: receivers that
cannot identify requestors SHOULD NOT). There is no session default: it would break v1 tasks
read from a new session, and 2026-07-28 has no sessions.

### The handler API

```swift
await server.withTasks(manager)
server.withMethodHandler(CallTool.self) { params in
    try await Server.runAsTask { task in        // TaskContext
        let answer = try await task.elicit(message: "Continue?")
        return CallTool.Result(content: [.text(text: "done")])
    }
}
```

`Server` decides, before the handler runs, how a `tools/call` may run as a task (`TaskRuntime`
on the `HandlerContext`). It reads the tool's `execution.taskSupport` from the `tools/list`
handler's output, in the same pass as the `x-mcp-header` parameters: once per call, with the
caller's context, so a per-caller list is honored:

| `taskSupport` | v1 | v2 |
|---|---|---|
| absent, `forbidden`, unknown | -32601 when augmented | never a task |
| `optional` | the client's choice | a task for declaring clients |
| `required` | -32601 when not augmented | -32021 for non-declaring clients |

`runAsTask` creates a task when the runtime accepts one and runs the body inline otherwise. The
work runs without `Server.currentHandlerContext`; `TaskContext.request` carries the creating
request's context. `requestInput` namespaces keys (`key`, `key#2`, ...) so a key is never
reused in a task's lifetime. Inline, the body asks through the handshake bridge (server
requests), or fails with -32021 at 2026-07-28, where inline work cannot ask: tools that ask
mid-run should be `required`. A `requestInput` call the work cancels withdraws its requests.
External jobs finish the task with `TaskManager.complete(_:with:)` or `fail(_:with:)`, which
also cancel the work; the body waits with `TaskContext.untilFinished()`.

### Serving each revision

- v2: `tasks/get`, `tasks/update` and `tasks/cancel`; -32021 for undeclared clients in the
  stateless gate, before any lookup. `tasks/result` and `tasks/list` are in `removedMethods`,
  `tasks/update` in `statelessOnlyMethods`. `server/discover` gets `extensions[tasks]` and no
  `tasks` slot.
- v1: `initialize` gets `capabilities.tasks` (`list` only with a principal). `tasks/result`
  loops: claim the outstanding input not being delivered (`delivering`), send it with
  related-task `_meta` on its own stream (`fulfill(_:relatedTask:)`), record the answers; else
  wait for a change of the record (`waitForChange(from:)` compares the active record, so a
  change between the read and the wait is not missed; a task stored by another process is read
  again at its poll interval). Delivery ends when the task finishes or expires, withdrawing the
  requests with `notifications/cancelled`. A request the client answers with an error fails the
  waiting `requestInput`; one cut off by the stream or the connection ending (a transport
  error, `stop()`) is released for the next `tasks/result`. Then the call's result with
  related-task `_meta`, or the stored error; cancelled: -32603.
- `tools/list` keeps `execution` only at 2025-11-25.
- `Mcp-Name` carries `params.taskId` for the three v2 methods (`MCPRequestHeaders`, the
  stateless transport's probe and `HTTPClientTransport`).

### Notifications

The manager hands each change to each observer in order (one `AsyncStream` per observer). A
server observes once it created a v1 task or a listen stream names a v2 task, and stops on
`stop()`. v1: the server that created the task sends `notifications/tasks/status` on its
connection when the status changes (`sendsStatusNotifications`), without related-task
metadata. v2: `SubscriptionFilter.taskIds`; the acknowledgement keeps the caller's own v2 tasks;
each change is a `SubscriptionEvent.task` with the detailed snapshot, sent as
`notifications/tasks`.

### Client (`Client/ClientTasks.swift`)

- `Configuration.tasks` (`nil` by default) stamps the extension into each 2026-07-28 request's
  capabilities. At 2025-11-25, `augmentation` (`whenRequired`, `whenSupported`, `never`) adds
  `task` when the server declares `tasks.requests.tools.call` and the client listed the tool
  (`toolTaskSupport`, from every `tools/list`).
- `callTool` drives a returned task with `TaskHandle.result()`: poll `tasks/get` at the clamped
  interval, ended early by a task notification (or one that arrived before the wait). v2:
  the create result has no outcome or input, so a task created in another state than `working`
  is read with `tasks/get` first; answer unanswered `inputRequests` with the registered
  handlers and `tasks/update`. v1: once the task waits for input or finished, `tasks/result`;
  the server's requests on that stream reach the same handlers. Completed: the tool result; failed: the `MCPError` (v1 with a tool
  error: the `isError` result); cancelled: `TaskCancelledError`. Any other error in the loop,
  including a throwing handler or Swift cancellation, sends a best-effort `tasks/cancel`.
- Low level: `startToolCall` returns the create result; `task(_:)`, `task(id:)`, `getTask`,
  `updateTask`, `cancelTask`, `taskResult`, `listTasks`.

## Alternatives considered

- **A public `Task` type, or `MCPTask`.** The first shadows `Swift.Task`; the prefix is used
  nowhere else. `TaskSnapshot`, `TaskRecord`, `TaskHandle`, `TaskContext`.
- **The `Server` owns the work.** A stateful HTTP server lives one session; v1 task ids must
  survive a reconnect. Hence the shared `TaskManager`.
- **A `CallTool.Result.task(...)` marker the handler returns.** It carries no work and lets a
  handler send a task to a client that cannot use one. `runAsTask` decides.
- **A per-call task policy beside `execution.taskSupport`.** Two sources of truth for one rule.
- **The application declares the task capabilities.** Capabilities are sent verbatim, so
  `tasks` would reach 2025-06-18 clients and the v1 slot 2026-07-28 ones.
- **v1 input sent at once on the GET stream or stdio, as well as on `tasks/result`.** Sending
  both ways duplicates JSON-RPC ids. The SDK sends it only on `tasks/result`, as the TypeScript
  SDK does.
- **Binding tasks to the session by default.** Breaks v1 reconnects; 2026-07-28 has no sessions.
- **Every call inline at a limit.** A v1 client that sent `task` cannot read a tool result in
  reply (above), and a `required` tool would run in a way its author ruled out. The -32603 is
  sent before the work starts, so retrying is safe.

## Open questions

- Tasks hosted by the client (v1 task-augmented sampling and elicitation) are not implemented.
  They need `Client.Capabilities.tasks`, `task` on the sampling and elicitation parameters,
  background execution outside the server-request slots, client task handlers and a server
  requestor API, and have no harness or interop coverage; 2026-07-28 removes them.
- SEP-2663 says a server serving both revisions SHOULD let 2026-07-28 clients that declare only
  the legacy capability `tasks/get` and `tasks/cancel` tasks created at 2025-11-25. The SDK reads
  a task only at its own generation.
- A durable `TaskStore` keeps tasks across restarts, but a working task's work does not resume.
  The store's owner marks such tasks failed when it loads.
- `tasks/list` pages by the id of the first task of the next page, read from the full list each
  time: fine for the in-memory store, a scan for large stores.
