# Client features

This guide covers the `Client` actor: connecting at either protocol era, calling server features, answering server requests (roots, sampling, elicitation), multi round-trip requests, notifications and subscriptions, and the errors a client sees. The snippets are compiled and run by `Examples/Tests/ClientSnippetTests.swift` against an in-process server; names such as `workspace`, `cache` and `generate` stand for application code defined next to them in `Examples/Snippets/Client`.

1. [Connecting](#connecting)
1. [Calling tools](#calling-tools)
1. [Prompts, resources and completions](#prompts-resources-and-completions)
1. [Roots](#roots)
1. [Sampling](#sampling)
1. [Elicitation](#elicitation)
1. [Multi round-trip requests](#multi-round-trip-requests)
1. [Tasks](#tasks)
1. [Skills](#skills)
1. [Server Cards](#server-cards)
1. [MCP Apps](#mcp-apps)
1. [Notifications and subscriptions](#notifications-and-subscriptions)
1. [Logging](#logging)
1. [Cancellation and progress](#cancellation-and-progress)
1. [Batching](#batching)
1. [Capabilities and extensions](#capabilities-and-extensions)
1. [Errors](#errors)

## Connecting

`Client(name:version:title:description:websiteUrl:icons:capabilities:configuration:)` describes the client. `connect(transport:)` connects the transport, starts the receive loop, opens the protocol connection and returns a `Client.ConnectionInfo` (see [Connection state](#connection-state)). The result is discardable. With the default configuration the client sends `server/discover` and connects at 2026-07-28 when the server serves it, and otherwise falls back to `initialize`.

%include Examples/Snippets/Client/Client.swift connect

`Client.Configuration` has four settings, all set in the initializer:

| Setting | Default | Effect |
|---|---|---|
| `strict` | `false` | Check the server's capabilities before sending. See [Strict mode](#strict-mode). |
| `protocolMode` | `.automatic` | How `connect` opens the connection. See [Protocol modes](#protocol-modes). |
| `logLevel` | `nil` | The lowest log level requested in the `_meta` of each 2026-07-28 request. See [Logging](#logging). |
| `discoveryTimeout` | 10 seconds | How long `.automatic` waits for the answer to `server/discover` before it sends `initialize`. `nil` waits indefinitely. Time `HTTPClientTransport` spends authorizing the request, such as a user signing in, does not count. |
| `multiRoundTrip` | `.init()` (enabled, 10 rounds) | How input-required results are answered. See [Multi round-trip requests](#multi-round-trip-requests). |

`Client.Configuration.default` and `.strict` are the default configuration with `strict` off and on.

### Protocol modes

| Mode | First request | Result |
|---|---|---|
| `.automatic` (default) | `server/discover` at `Version.stateless[0]` (2026-07-28) | 2026-07-28 when the server serves it; otherwise falls back to `initialize`. |
| `.handshake` | `initialize` with `Version.latestHandshake` (2025-11-25), then `notifications/initialized` | The version the server returns. |
| `.stateless(version)` | `server/discover` at `version` | `version`, or an error. Never retries with another version and never falls back. |

`.automatic` falls back to `initialize` when:

- the `server/discover` result lists no stateless version;
- the server answers -32022 (`unsupportedProtocolVersion`) and its `data.supported` list is empty or contains a handshake version;
- the server answers with any other JSON-RPC error, for example -32601 from a server that predates `server/discover`;
- `HTTPClientTransport` reports HTTP 400, 404 or 405 without a JSON-RPC error for the request: how a server that serves only the handshake refuses a request without a session;
- no answer arrives within `discoveryTimeout`. A late answer is ignored. The timeout starts again when the request's authorization ends.

On -32022, `.automatic` first retries once with the first stateless version in the server's `data.supported` list (servers list versions newest first). `.stateless(version)` never retries: it connects at `version` or throws. Other transport errors are rethrown, so the caller can retry: authorization failures, 401 and 403 after the authorization attempts, 408, 429, 5xx, `transportError` and errors that are not `MCPError`, such as a `URLError`. Other requests and `connect` as a whole have no timeout.

%include Examples/Snippets/Client/Client.swift connect-automatic

With `.stateless`, a server that does not serve the version makes `connect` throw `unsupportedProtocolVersion(supported:requested:)`:

%include Examples/Snippets/Client/Client.swift connect-stateless

Use `.handshake` for a server that answers `server/discover` incorrectly, or to keep the 2025-11-25 behavior, such as server-to-client requests and session-based HTTP. An SDK server serves both eras by default (`Server.Configuration.protocolVersions` is `Version.stateless + Version.handshake`). See [protocol_versions.md](protocol_versions.md).

### Connection state

After `connect`, these actor properties describe the server:

| Property | 2025-11-25 | 2026-07-28 |
|---|---|---|
| `negotiatedProtocolVersion` | From the `initialize` result | The version `server/discover` accepted |
| `serverCapabilities` | From the `initialize` result | From the `server/discover` result |
| `serverInfo` | From the `initialize` result | From `_meta["io.modelcontextprotocol/serverInfo"]` of the discover result; `nil` when absent |
| `isStateless` | `false` | `true` |

`connect` returns the same information as a `Client.ConnectionInfo`.

### What changes at 2026-07-28

When `isStateless` is `true`:

- Every request carries `io.modelcontextprotocol/protocolVersion`, `clientCapabilities`, `clientInfo` and, when set, `logLevel` in `_meta`. Keys already present in the request's own `_meta` win.
- `HTTPClientTransport` drops the session ID and the GET stream, and adds the `Mcp-Method` and `Mcp-Name` headers.
- `ping()` sends `server/discover`, because `ping` does not exist.
- `setLoggingLevel(_:)` stores the level for later requests instead of sending `logging/setLevel`.
- `notifyRootsChanged()` does nothing.
- The server cannot send requests. Roots, sampling and elicitation arrive as input requests (see [Multi round-trip requests](#multi-round-trip-requests)).
- List-changed and resource-updated notifications arrive only on `subscriptions/listen` streams (see [Notifications and subscriptions](#notifications-and-subscriptions)).

### Transports

`connect` accepts any `Transport`. A client usually launches a server and talks to it over stdio, or connects to a Streamable HTTP endpoint:

%include Examples/Snippets/Client/Client.swift transports

`StdioTransport()` without arguments uses the current process's standard input and output. Tests use `InMemoryTransport.createConnectedPair()`. See [protocol.md](protocol.md) for transports and authorization, and [testing.md](testing.md) for in-memory tests.

### Strict mode

With `strict: true`, `listTools`, `callTool`, `listPrompts`, `getPrompt`, `listResources`, `listResourceTemplates`, `readResource`, `subscribeToResource`, `unsubscribeFromResource` (2025-11-25 only), `setLoggingLevel` and both `complete` methods check `serverCapabilities` first. When the capability is missing they throw `MCPError.methodNotFound` without sending anything; before `connect` the detail is "Server capabilities not initialized". The default configuration sends the request and lets the server answer.

%include Examples/Snippets/Client/Client.swift strict

### Disconnecting

%include Examples/Snippets/Client/Client.swift ping-disconnect

`disconnect()` closes every `subscriptions/listen` stream, fails pending requests with `MCPError.internalError("Client disconnected")`, stops the receive loop and disconnects the transport.

### Connection errors

| Error | Cause |
|---|---|
| `unsupportedProtocolVersion` (-32022) | `.stateless(version)` and the server does not serve `version`. `data.supported` lists what it serves. |
| `internalError("Client connection not initialized")` | A method was called before `connect` or after `disconnect`. |
| `transportError`, `connectionClosed`, `internalError` of an HTTP status | The transport failed. `.automatic` rethrows the error of `server/discover` unless it is an HTTP 400, 404 or 405 refusal. |

## Calling tools

`listTools(cursor:)` returns one page of tools, a `ListTools.Result`: its `tools`, and the `nextCursor` for the next page.

%include Examples/Snippets/Client/Tools.swift list-tools

`callTool(name:arguments:meta:)` returns the `CallTool.Result`: `content`, `structuredContent`, `isError` and `_meta`. `startToolCall(name:arguments:meta:)` returns at once with a `RequestContext`, for cancellation; see [Cancellation and progress](#cancellation-and-progress).

%include Examples/Snippets/Client/Tools.swift call-tool

`isError == true` means the tool ran and failed; the content describes the failure for the model. A protocol failure, such as an unknown tool or invalid arguments, is thrown as an `MCPError` with the code the server chose.

### Structured content

A tool with an `outputSchema` returns `structuredContent` as well:

%include Examples/Snippets/Client/Tools.swift call-structured

### Header parameters

At 2026-07-28 over Streamable HTTP, a tool can ask for some arguments to be mirrored into HTTP headers (SEP-2243), so that gateways can route without parsing the body. The input schema marks the argument with `"x-mcp-header": "<Name>"`. The client handles this itself:

- On every `tools/list` result at 2026-07-28, it records the annotated arguments of each tool. A first page (no cursor) replaces what earlier listings recorded; `connect` and `disconnect` clear them.
- On `tools/call` through `HTTPClientTransport`, or a custom transport that implements `send(_:additionalHeaders:)`, it sends `Mcp-Param-<Name>` for each annotated argument that is present and not null. Strings are sent as-is, booleans as `true`/`false`, integers in decimal. A value that is empty, is not printable ASCII, has a leading or trailing space, or looks like an encoded value is sent as `=?base64?<Base64 of UTF-8>?=`.
- It drops a tool with an invalid annotation from the `tools/list` result and logs a warning. An annotation is invalid when its value is empty or not a string, is not an HTTP token, or repeats another name of the tool case-insensitively, when the property type is not `string`, `integer` or `boolean`, or when the tool has more than 64 annotations or nests `properties` more than 32 deep. The warning names the property path, not the annotation.

`Tool.headerParameters()` returns the parsed annotations:

%include Examples/Snippets/Client/Tools.swift header-parameters

Annotations are read only on properties reachable through `properties` from the schema root; `$ref` is not followed. At 2025-11-25 no headers are sent and no tools are dropped.

Errors:

- `headerMismatch` (-32020): the server found a missing or different `Mcp-Param-*` header. The usual cause is calling a tool the client has not listed on this connection, so it has no recorded annotations. Call `listTools()` before calling tools with annotated arguments.
- `Tool.headerParameters()` throws `MCPRequestHeaders.InvalidAnnotation` for an invalid annotation. At 2025-11-25 such tools are not dropped, so expect the error there.

## Prompts, resources and completions

Prompts: `listPrompts(cursor:)` and `getPrompt(name:arguments:)`. Prompt arguments are strings.

%include Examples/Snippets/Client/Tools.swift prompts

Resources: `listResources(cursor:)`, `listResourceTemplates(cursor:)` and `readResource(uri:)`. A `Resource.Content` holds `text` or a Base64 `blob`.

%include Examples/Snippets/Client/Tools.swift resources

Completions: `complete(promptName:argumentName:argumentValue:context:)` and `complete(resourceURI:argumentName:argumentValue:context:)` return a `Complete.Result.Completion` with up to 100 `values`, an optional `total` and `hasMore`. `context` passes arguments already resolved.

%include Examples/Snippets/Client/Tools.swift completions

Differences between eras:

- `getPrompt` and `readResource`, like `callTool`, may receive input-required results at 2026-07-28. The loop answers them (see [Multi round-trip requests](#multi-round-trip-requests)).
- At 2026-07-28, list results and `resources/read` may carry cache hints, `ttlMs` and `cacheScope` (SEP-2549), on the results these methods return.

Errors:

- `resourceNotFound(uri:message:)` (-32602 with `data.uri`, SEP-2164): no resource at the URI. An older server's -32002 with `data.uri` decodes to the same case.
- `methodNotFound` (-32601): in strict mode, the server did not declare `prompts`, `resources` or `completions`; otherwise, the server has no handler.

## Roots

Roots, sampling and logging are deprecated by the specification (SEP-2577). They work on every revision that has them; see [Deprecated by the specification](rough_edges.md#deprecated-by-the-specification).

Roots tell the server which directories or files the user made available. Declare the `roots` capability and register a handler that returns the current list. The SDK does not infer capabilities from handlers.

%include Examples/Snippets/Client/Features.swift roots

How the request reaches the handler:

| | 2025-11-25 | 2026-07-28 |
|---|---|---|
| Server asks | Sends `roots/list` to the client | Returns an input-required result with a `roots/list` input request |
| Client answers | The handler's result is the response | The loop calls the same handler and retries the request |
| `notifyRootsChanged()` | Sends `notifications/roots/list_changed` | Does nothing; the server reads roots per request |

The SDK supports roots, sampling and logging at both eras.

Errors:

- No handler at 2025-11-25: the client answers -32601 "Unknown method: roots/list".
- No handler at 2026-07-28: the loop throws `methodNotFound("No handler registered for roots/list")` and does not retry.
- Capability not declared at 2026-07-28: an SDK server answers `missingRequiredClientCapabilities` (-32021).

## Sampling

Sampling lets the server ask the client's model for a completion. Declare `sampling` and register `withSamplingHandler`. The parameters carry `messages`, `systemPrompt`, `maxTokens`, `modelPreferences`, `includeContext`, `temperature`, `stopSequences`, `tools`, `toolChoice` and `metadata`. The result names the model, the stop reason, the role and the content.

%include Examples/Snippets/Client/Features.swift sampling

The specification expects the client to let the user review the request and the completion. The SDK leaves that to the handler.

`Client.Capabilities.Sampling` has `tools` and `context` sub-capabilities (SEP-1577). A client that declares `tools` handles `tools`, `toolChoice` and the `.toolUse` and `.toolResult` content blocks in its handler. When the model calls tools, the handler returns one `.toolUse` block for each call, with the stop reason `.toolUse`. The server runs the tools and sends a new request with their results.

The client checks each sampling request before the handler runs. It answers with -32602, and the handler does not run, when:

- The request has `tools` or `toolChoice`, and `capabilities` has no `sampling.tools`.
- The messages break the rules for tools. Tool uses are in assistant messages, tool results in user messages. A message with tool results holds only tool results. Each tool use has a result in the next message, which is a user message. Each tool result answers a tool use in the message before it.

At 2026-07-28 the call that received the input request fails with that error. The client does not refuse an `includeContext` it did not declare `context` for: it can ignore the field.

The two eras differ as for [Roots](#roots): `sampling/createMessage` from the server at 2025-11-25, a `sampling/createMessage` input request at 2026-07-28, the same handler for both. The errors are the same, with `sampling/createMessage` as the method.

## Elicitation

Elicitation lets the server ask the user for input. There are two modes:

- Form: the server sends a message and a flat JSON Schema (`Elicitation.RequestSchema`). The client shows a form and returns the content.
- URL: the server sends a URL for the user to open, for example a sign-in page. The client asks for consent and opens it. The content never passes through the client.

Declare the modes in `Client.Capabilities.Elicitation`. `Elicitation()` declares form only; pass `url: .init()` for URL mode. When a peer sends an empty `elicitation` object, it decodes as form only.

%include Examples/Snippets/Client/Features.swift elicitation

The result's `action` is `.accept`, `.decline` or `.cancel`. Only a form `.accept` carries `content`. The two eras differ as for [Roots](#roots).

### URL elicitation required

A server can refuse a request until the user completes URL elicitations. It answers with `urlElicitationRequired` (-32042), whose `data.elicitations` lists `URLElicitationInfo` values (`elicitationId`, `url`, `message`). The SDK neither opens the URLs nor retries.

%include Examples/Snippets/Client/Features.swift url-elicitation-required

The server may send `notifications/elicitation/complete` with the `elicitationId` when the out-of-band flow ends. Retry the original request then, or when the user says they are done.

Errors:

- `missingRequiredClientCapabilities` (-32021) at 2026-07-28: a URL input request reached a client that declared only form mode, or an input request reached a client without `elicitation`.
- No handler: as for [Roots](#roots), with `elicitation/create` as the method.

## Multi round-trip requests

At 2026-07-28 a server cannot send requests (SEP-2322). When `tools/call`, `prompts/get` or `resources/read` needs input, the server returns a result with `resultType: "input_required"`, `inputRequests` and an opaque `requestState`. `inputRequests` maps keys chosen by the server to `elicitation/create`, `sampling/createMessage` or `roots/list` requests. The client fulfills them and sends the request again, with a new JSON-RPC id, the same `_meta`, `inputResponses` under the same keys, and `requestState` echoed unchanged. This repeats until the result is complete.

### Automatic loop

By default `send(_:)`, and so `callTool`, `getPrompt` and `readResource`, run this loop:

- Input requests in one result run concurrently through the handlers registered with `withElicitationHandler`, `withSamplingHandler` and `withRootsHandler`.
- A result with `requestState` and no input requests means the server is not done. The client waits 50 ms before retrying, doubling up to 250 ms, and resets the delay after a round with input requests.
- The loop stops with an error after `maxRounds` retries, and before any handler runs when a result carries more than `maxInputRequests` input requests.

The same handlers answer both eras. At 2025-11-25 an SDK server sends the input requests to the client itself, so the client code does not change:

%include Examples/Snippets/Client/MultiRoundTrip.swift mrtr-auto

`Client.Configuration.MultiRoundTrip`:

| Field | Default | Effect |
|---|---|---|
| `isEnabled` | `true` | When `false`, `send(_:)` returns input-required results, and `callTool`, `getPrompt` and `readResource` throw `invalidRequest("<method> requires input; enable Configuration.multiRoundTrip or use send(_:)")`. |
| `maxRounds` | `10` | The most retries before `internalError("<method>: the server asked for input more than <n> times")`. |
| `maxInputRequests` | `16` | The most input requests in one result; more fail the call with `internalError("<method>: the server asked for <n> inputs at once, more than <max>")` before any handler runs. |

### Manual loop

With the loop disabled, inspect `resultType`, fulfill `inputRequests` and retry:

%include Examples/Snippets/Client/MultiRoundTrip.swift mrtr-manual

Keep the method, name and arguments unchanged between rounds. An SDK server seals `requestState` with AES-GCM and binds it to the method and arguments; a changed, tampered or expired state (the default lifetime is 600 seconds) is rejected with -32602 "Invalid or expired requestState". At 2025-11-25 an SDK server sends its input requests to the client itself before replying, so the manual loop never sees an input-required result; register the handlers for that case.

### Cancelling a round trip

`cancelRequest(_:reason:)` with the `requestID` of the first request cancels the round in flight and stops the loop: running elicitation, sampling and roots handlers are cancelled, a wait between state-only rounds ends, and no further round is sent. Between rounds, nothing is sent to the server. The exchange is registered when `send(_:)` returns, so a cancellation right after it is not lost. `disconnect()` stops every exchange the same way. See [Cancellation and progress](#cancellation-and-progress).

### Round-trip errors

| Error | Cause |
|---|---|
| `methodNotFound` "No handler registered for `<method>`" | An input request has no handler. Thrown by the client; the request is not retried. |
| `missingRequiredClientCapabilities` (-32021) | The client did not declare the capability an input request needs. `data.requiredCapabilities` lists it. |
| `invalidParams` (-32602) "Invalid or expired requestState" | `requestState` was changed, or the server no longer accepts it. |
| `internalError` (-32603) | A server handler returned both content and input requests, `maxRounds` was exceeded, or a result carried more than `maxInputRequests` input requests. From an SDK server at 2025-11-25: a client handler failed one of the server's input requests. |
| `invalidRequest` (-32600) "... requires input ..." | The loop is disabled and a convenience method got an input-required result. |

## Tasks

A server may run a tool call as a task: it answers at once with a task, and the result comes later. `Client.Configuration.tasks` opts in; it is `nil` by default.

%include Examples/Snippets/Client/Tasks.swift client-tasks

- At 2026-07-28 the client declares the `io.modelcontextprotocol/tasks` extension in each request, and the server decides which calls become tasks. Without `tasks`, a server runs the work inline or refuses a tool that requires tasks with -32021.
- At 2025-11-25 the client asks for a task with `task` on `tools/call`, as `augmentation` says: `.whenRequired` (the default) for tools listed with `execution.taskSupport: "required"`, `.whenSupported` also for `"optional"`, `.never` for none. An unknown `taskSupport` counts as `"forbidden"`. It asks only when the server declares `tasks.requests.tools.call` and the client has listed the tool on this connection. `requestedTTL` sets `task.ttl`.

`callTool` returns a task's result as it returns any other: it polls `tasks/get` at the interval the server suggests, kept between `minimumPollInterval` (100 ms) and `maximumPollInterval` (30 s), `defaultPollInterval` (1 s) when the server suggests none. A task notification from the server ends a wait early, and a closed connection ends it with the connection's error. The task's input requests go to the handlers registered with `withElicitationHandler`, `withSamplingHandler` and `withRootsHandler`, at both revisions: at 2026-07-28 the client answers `inputRequests` with `tasks/update`, any it has not answered yet; at 2025-11-25 it calls `tasks/result` once the task waits for input or finished, and the server sends its requests on that stream.

| Outcome | `callTool` |
|---|---|
| Completed | Returns the tool's result, which may report `isError` |
| Failed with a protocol error | Throws the `MCPError` |
| Failed with a tool error (2025-11-25) | Returns the `isError` result, from `tasks/result` |
| Cancelled | Throws `TaskCancelledError` |

When a handler throws, or the Swift task that calls `callTool` is cancelled, the client sends `tasks/cancel` and rethrows.

### Following a task

`startToolCall` returns the result that creates the task as is; `client.task(_:)` gives a `TaskHandle` to follow it, and `client.task(id:)` one for a task known by its id, for example after a restart:

%include Examples/Snippets/Client/Tasks.swift client-task-handle

| Call | Method | Revisions |
|---|---|---|
| `getTask(_:)`, `TaskHandle.snapshot()` | `tasks/get` | both; at 2026-07-28 the snapshot carries `result`, `error` or `inputRequests` |
| `updateTask(_:inputResponses:)`, `TaskHandle.update(_:)` | `tasks/update` | 2026-07-28 |
| `cancelTask(_:)`, `TaskHandle.cancel()` | `tasks/cancel` | both; returns the cancelled task at 2025-11-25, `nil` at 2026-07-28 |
| `taskResult(_:)` | `tasks/result` | 2025-11-25 |
| `listTasks(cursor:)` | `tasks/list` | 2025-11-25, when the server declares `tasks.list` |
| `TaskHandle.result()` | the loop `callTool` runs | both |

To receive `notifications/tasks` at 2026-07-28, name the tasks in `SubscriptionFilter.taskIds` when you [listen](#listening-by-hand); at 2025-11-25 the server sends `notifications/tasks/status` on its own. Register `onNotification(TaskUpdatedNotification.self)` or `onNotification(TaskStatusNotification.self)` to see them.

## Skills

A server that declares the skills extension (SEP-2640) serves skills: directories of files with a `SKILL.md` that teaches the model a workflow. The client lists them, and loads one when the model needs it:

%include Examples/Snippets/Client/Skills.swift client-skills

| Call | Method | Notes |
|---|---|---|
| `listSkills(cursor:)`, `listAllSkills()` | `skills/list` | Entries: the `SKILL.md` URI, the frontmatter, the files with digests and sizes. The listing may be empty or partial |
| `getSkill(uri:)` | `skills/get` | The entry of one skill, listed or not; -32602 for a URI that is not a skill |
| `readResourceDirectory(uri:cursor:)` | `resources/directory/read` | Only when the server declares `directoryRead` |
| `loadSkill(_:options:)`, `loadSkill(uri:options:)` | `resources/read` of `SKILL.md` | Verified; see below |

Each throws -32601 without a request when the server does not declare the extension (`serverSkills` is `nil`), or `directoryRead` for directory reads.

`loadSkill` reads the skill's `SKILL.md`, and nothing else, then checks it against the entry: its length against `size`, its SHA-256 against `digest`, and its YAML frontmatter, field by field, against the entry's `frontmatter`. The `LoadedSkill` it returns holds the entry and the verified content. `read(_:)` resolves a path against the skill's root, fetches the file and verifies it the same way; a file the entry does not list, or a path that leaves the skill, is refused without a request. For a dynamic skill, `read(uri:)` refuses a URI outside the root, or with a `.` or `..` segment (`%2e%2e` too). `directory(_:)` lists a directory from the entry. Nothing is fetched on connection or on listing.

`SkillVerificationError.reason` says what failed: `sizeMismatch`, `digestMismatch`, `frontmatterMismatch`, `unlistedFile`, `invalidEntry` (no valid `resources`, or a manifest without the `SKILL.md`, with a file outside the skill's root or with a negative size), `dynamicSkill`, `tooLarge` or `unreadable`. A digest or size mismatch can also mean the skill changed since the listing: get the current entry with `getSkill(uri:)` and load again.

| `Client.SkillLoading` | Default | Effect |
|---|---|---|
| `allowsDynamic` | `false` | Load skills whose `resources` is `dynamic`. Their content has no digests; reads count against 16 MiB |
| `acceptsYAML11Frontmatter` | `false` | Also accept frontmatter that matches when read as YAML 1.1, from a server that used PyYAML |
| `enforcesLimits` | `true` | Refuse skills of more than 512 files or 16 MiB |

The SDK verifies; the host decides. Ask the user before a skill is used, and bind the approval to `Skill.manifestFingerprint`, which changes when any file does. Identify a skill by the server and its URI, never by its name: two servers, or two skills of one server, may share a name. A `SKILL.md` read with plain `readResource(uri:)` is not a loaded skill.

## Server Cards

A Server Card describes a server before the client connects (SEP-2127): its name, version, endpoints and the protocol versions they serve. `ServerCard.fetch(from:session:)` gets one:

%include Examples/Snippets/Client/ServerCards.swift server-card

- The request asks for `application/mcp-server-card+json`. The URL must have a host and be `https`, or `http` on a loopback host, and its host must not be a private or reserved IP address such as `10.0.0.5` or `169.254.169.254`; loopback hosts are allowed for local development. A redirect is followed only to `https`, or from loopback `http` to loopback `http`, and never to a private IP address; any other throws before it is requested. Host names are not resolved, so a name whose address is private is fetched. The body is read up to 1 MiB. A larger card, an answer other than 200, a body that is not a card, and a card that breaks a rule of the format throw `ServerCardError`.
- `fetch(from:ifNoneMatch:session:)` sends the `ETag` of an earlier fetch, and returns `.notModified` when the card did not change. Keep a card for its `Cache-Control` time.
- `ServerCard.cardURL(forEndpoint:)` gives the recommended location, `<endpoint>/server-card`. The SDK does not read AI Catalogs: get the card's URL from the catalog yourself.
- `Remote.url(resolving:)` fills in the `{variable}` placeholders of a remote's URL: from the values you pass, then the variable's `value`, then its `default`. A required variable, or a variable the remote does not declare, without a value throws. Values are percent-encoded except for letters, digits and `-._~`, so a value cannot change the host or add a path or query; a placeholder at the start of the URL, as in `{base}/mcp`, is inserted as given, and the others are encoded even when it is empty. The result can be `http` on any host, since a card may list a plaintext endpoint: the `https` rule of `fetch` covers the card, not its remotes, so check the scheme before you connect when the connection needs TLS.
- A card is advisory: do not use it for security decisions. After connecting, `mismatches(with:)` lists what `server/discover` contradicts: the name, the version, the title, and protocol versions the server does not serve. Prefer the live values.

## MCP Apps

A host that renders the HTML views of MCP Apps (SEP-1865) declares the extension in its capabilities, reads each tool's `ui`, and reads the views with `readAppResource(uri:listing:)`:

%include Examples/Snippets/Client/Apps.swift client-apps

- `Client.Capabilities.ui` writes `extensions["io.modelcontextprotocol/ui"]`. `UIExtensionSettings()` declares `text/html;profile=mcp-app`, the only view type of the specification. At 2026-07-28 the client sends it with each request.
- `Tool.ui` reads `_meta.ui`, and the deprecated flat key `_meta["ui/resourceUri"]` when `_meta.ui` has no `resourceUri`; the SDK never writes the flat key.
- Do not give the agent a tool for which `isVisibleToModel` is `false`. When a view calls a tool, refuse a tool for which `isCallableFromApp` is `false`, and every tool of another server.
- `readAppResource(uri:listing:)` throws `AppResourceError` without a request for a URI that does not start with `ui://` in lowercase, and after the read for content that is not an HTML view. The view's metadata is the content item's `_meta.ui` or, when it has none, the `resources/list` entry's. Pass the entry when you have it; otherwise the client reads up to 100 `resources/list` pages to find it.
- `AppResourceContents.contentSecurityPolicy` is the policy for the view's frame: the specification's construction from `csp`, or its restrictive default without `csp`. Origins that could add a directive are dropped. You can make the policy stricter, but do not allow more. `permissions?.policyFeatures` are the features for the frame's `allow` attribute.

The SDK does not render views and does not implement the View-Host bridge (`ui/*` messages).

## Notifications and subscriptions

`onNotification(_:handler:)` registers a handler for one notification type. Several handlers per type are allowed; they run in registration order, and an error thrown by one is logged.

Handlers do not run on the client's receive loop, so they may await requests on the same client. Notification handlers run one at a time, in arrival order; a slow one delays later notifications, so start a `Task` for long work. Notifications wait for their handler in a queue without a size limit, so a handler that does not return keeps every later notification, and the responses that wait for their progress, in memory. Responses do not wait for them, with one exception: a request with a progress token is answered after the progress notifications for that token that arrived before its response were handled. For a request sent from a notification handler the result comes first, and its progress after the handler returns. So a notification handler must not await a request with a progress token that was sent outside a notification handler: when its progress notifications are queued behind the handler, its response waits for them and the handler waits forever. Start a `Task` for that wait instead. Log notifications are not ordered with results.

At 2025-11-25 each roots, sampling or elicitation request from the server runs in its own task. At most `Configuration.maxConcurrentServerRequests` (4) run at once; up to 64 more wait, and further ones are refused with -32603. A request whose id is already in progress is refused with -32600. When the server sends `notifications/cancelled` for one, its task is cancelled, or it is dropped while it waits, and no response is sent; a cancelled handler keeps its place in the limit until it returns. A `ping` from the server is answered at once, outside the limit. At 2026-07-28 the server cannot send requests: the client answers them with -32601; these handlers run in the task of the request that received the input-required result.

Cancelling the task that awaits `RequestContext.value`, or a convenience method such as `callTool`, cancels the request, as `cancelRequest(_:reason:)` does.

### List changes

The server sends `notifications/tools/list_changed`, `prompts/list_changed` or `resources/list_changed` when a list changes. The notification carries no list: fetch it again.

%include Examples/Snippets/Client/Notifications.swift list-changed

| | 2025-11-25 | 2026-07-28 |
|---|---|---|
| Delivery | On the connection | Only on `subscriptions/listen` streams |
| Client action | None | Opens a background stream automatically |

At 2026-07-28 the client keeps one background listen stream for the list kinds that have a handler and that the server declares with `listChanged`, and for the URIs passed to `subscribeToResource(uri:)`. It opens or replaces the stream after `connect`, when a list-changed handler is registered, and on subscribe and unsubscribe. A replacement is opened first and the old stream closes once the new one is acknowledged. Until it ends, notifications on the old stream are still delivered when the client wants them (a list kind with a handler, a subscribed URI), so a notification sent during the replacement may arrive twice; both kinds only signal that something should be fetched again. When the replacement cannot be opened, the old stream stays open and the client retries. A stream that ends, for example on a network error or when the server ends it with its result as it does on `stop()`, is reopened after 1 second, then after delays that double up to 60 seconds. The delay is reset only when a stream ends after staying open for at least 60 seconds, so a server that acknowledges each stream and drops or closes it at once is not asked again every second. A failed reopen keeps the subscribed resources, and the client keeps retrying. Listen POSTs have an idle timeout of one hour.

### Listening by hand

`listen(_:)` opens a `subscriptions/listen` stream (SEP-2575) and returns once the server acknowledges it with `notifications/subscriptions/acknowledged`:

%include Examples/Snippets/Client/Notifications.swift listen

- `Subscription.notifications` is the filter the server honored. An SDK server honors list kinds whose `listChanged` it declared, and resource URIs when it declared `resources.subscribe`.
- Notifications on the stream go to the `onNotification` handlers. Each carries the stream's id in `_meta["io.modelcontextprotocol/subscriptionId"]` (`message._meta?.subscriptionID`), which equals `Subscription.id`.
- `cancel()` closes the stream: over `HTTPClientTransport` it closes the HTTP response stream; on other transports it sends `notifications/cancelled`.
- `finished()` returns when the server ends the stream and throws when it fails or is cancelled.
- At 2025-11-25 `listen` throws `invalidRequest` (-32600).

### Resource subscriptions

`subscribeToResource(uri:)` asks for `notifications/resources/updated` when a resource changes:

%include Examples/Snippets/Client/Notifications.swift subscribe-resource

| | 2025-11-25 | 2026-07-28 |
|---|---|---|
| `subscribeToResource(uri:)` | Sends `resources/subscribe` | Adds the URI to the background listen stream and waits for the acknowledgement of a stream that names it; does nothing if the URI is already subscribed |
| `unsubscribeFromResource(uri:)` | Sends `resources/unsubscribe` | Replaces the stream with one without the URI; updates may arrive until the replacement is acknowledged; does nothing if the URI is not subscribed |
| `subscribedResourceURIs` | Always empty | The subscribed URIs the open stream serves |

At 2026-07-28, `subscribeToResource` throws `invalidRequest("The server does not send updates for <uri>")` when the server's acknowledgement omits the URI, and the error that kept the stream from opening otherwise. When the server ends the stream, `subscribedResourceURIs` is empty until the client reopens it after the backoff delay; subscribing again reopens it at once. When the stream fails, the subscriptions are kept and the client reopens the stream for them; only a `subscribeToResource` call still waiting for its acknowledgement fails when that reopening fails. Cancelling the task that waits in `subscribeToResource` ends the call with `CancellationError` and drops the URI again when that call added it. After `disconnect()`, `subscribeToResource` throws.

## Logging

Servers with the `logging` capability send `notifications/message`. Register a handler for `LogMessageNotification` and choose the lowest level with `setLoggingLevel(_:)`:

%include Examples/Snippets/Client/Notifications.swift logging

| | 2025-11-25 | 2026-07-28 |
|---|---|---|
| `setLoggingLevel(_:)` | Sends `logging/setLevel` | Sets `Client.logLevel`; later requests carry it in `_meta` |
| Default | The server decides | `Configuration.logLevel` is `nil`: an SDK server sends no log notifications |

At 2026-07-28 log notifications belong to the request that caused them. Set `logLevel` in the configuration to receive them from the first request on; `Client.logLevel` starts with it. `setLoggingLevel` requires the `logging` capability in strict mode.

## Cancellation and progress

### Cancellation

`send(_:)` and `startToolCall(name:arguments:meta:)` return a `RequestContext` with the `requestID` and the result (`value`). `cancelRequest(_:reason:)` cancels the request:

%include Examples/Snippets/Client/Notifications.swift cancel

- The pending `value` throws `CancellationError`, and a response that arrives later is ignored.
- The client sends `notifications/cancelled` with the id and reason. At 2026-07-28 over `HTTPClientTransport` it closes the request's HTTP stream instead, which cancels the request on the server.
- Cancellation is advisory: the server may have finished already.
- In a multi round-trip exchange, pass the first `requestID`; the client cancels the current round.
- The request is registered before `send` returns, so `cancelRequest` always ends `value`. A request cancelled before the transport sent it is not sent, and no notification is sent for it. The notification never overtakes its request.

A `notifications/cancelled` from the server stops the handler of the server-to-client request with that id. When there is no such request, it ends the matching pending request with `CancellationError`.

### Progress

To receive progress for a request, put a progress token in its `_meta` and handle `ProgressNotification`:

%include Examples/Snippets/Client/Notifications.swift progress

`ProgressToken` is a string or an integer; `ProgressToken.unique()` makes a UUID string. Each notification carries `progress`, an optional `total` and an optional `message`. The handler receives the notifications of every request, so compare the token. Progress works the same at both eras; at 2026-07-28 over HTTP the notifications arrive on the request's response stream.

## Batching

`withBatch(body:)` sends several requests as one JSON-RPC array. `Batch.addRequest(_:)` returns a `Task` for each result; the batch is sent when the closure returns.

%include Examples/Snippets/Client/Notifications.swift batch

JSON-RPC batching was removed from the specification in 2025-06-18. Use it only with peers that accept batches; an SDK server does. Each request gets what `send(_:)` adds: the 2026-07-28 `_meta` envelope, the header parameters and the multi round-trip loop. On a stateless connection the requests are sent one by one, because each 2026-07-28 request carries its own HTTP headers. A request cancelled with `cancelRequest(_:reason:)` before the batch is sent is left out. When the closure throws, the requests it added fail with the same error and nothing is sent.

`withBatch` throws `internalError("Client connection not initialized")` when not connected. An empty batch sends nothing.

## Capabilities and extensions

`Client.Capabilities` declares what the client supports:

| Field | Declares |
|---|---|
| `roots` (`listChanged`) | A roots handler, and whether the client sends `notifications/roots/list_changed` |
| `sampling` (`tools`, `context`) | A sampling handler, and support for tool use and context inclusion |
| `elicitation` (`form`, `url`) | An elicitation handler and its modes |
| `experimental` | Non-standard features, as JSON values |
| `extensions` | Protocol extensions keyed by identifier, with extension-defined settings (SEP-2133) |

Declare a capability for each handler you register; nothing is inferred. `capabilities` and `configuration` are actor properties: set them in the initializer.

%include Examples/Snippets/Client/Notifications.swift capabilities

| | 2025-11-25 | 2026-07-28 |
|---|---|---|
| Sent | Once, in `initialize` | In `_meta["io.modelcontextprotocol/clientCapabilities"]` of every request |
| Checked by an SDK server | In strict mode, before it sends a request to the client | On every input-required result; -32021 when a capability is missing |

The server's capabilities and extensions are in `serverCapabilities` after `connect`.

## Errors

Requests throw `MCPError` for protocol errors, `CancellationError` for cancelled requests, and other errors from the transport or from decoding. `MCPError.code` and `MCPError.data` are the JSON-RPC `code` and `data` members.

%include Examples/Snippets/Client/Notifications.swift errors

| Case | Code | Typical cause for a client |
|---|---|---|
| `parseError` | -32700 | The server could not parse the message. |
| `invalidRequest` | -32600 | Thrown locally by `listen` at 2025-11-25, by `subscribeToResource` for an unhonored URI, and by convenience methods for input-required results with the loop disabled. From a server: a malformed request. |
| `methodNotFound` | -32601 | Strict mode and a missing server capability; a missing input-request handler; a method the server does not have, or removed at 2026-07-28 (`ping`, `logging/setLevel`, `resources/subscribe`). |
| `invalidParams` | -32602 | Invalid arguments; an invalid `requestState`. |
| `internalError` | -32603 | Not connected; disconnected while pending; too many rounds; a server failure. |
| `resourceNotFound(uri:message:)` | -32602 | No resource at the URI (`data.uri`). |
| `headerMismatch` | -32020 | `Mcp-*` headers do not match the body. See [Header parameters](#header-parameters). |
| `missingRequiredClientCapabilities` | -32021 | The request needs capabilities the client did not declare (`data.requiredCapabilities`). |
| `unsupportedProtocolVersion(supported:requested:)` | -32022 | The server does not serve the requested version (`data.supported`). |
| `urlElicitationRequired(message:elicitations:)` | -32042 | Complete the listed URL elicitations, then retry. |
| `serverError(code:message:data:)` | other | Any other code, including -32000 and -32001 received from a server. |
| `connectionClosed`, `transportError` | -32000, -32001 | Local transport failures; never decoded from the wire. |

See [troubleshooting.md](troubleshooting.md) for causes and fixes.
