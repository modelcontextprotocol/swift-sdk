# Server features

This guide covers the server side of MCP in the Swift SDK: tools, prompts, resources, notifications, multi round-trip requests, caching, completion, logging and the server lifecycle. One `Server` serves clients of both protocol eras: the `initialize` handshake (2025-11-25 and earlier) and stateless 2026-07-28 requests. Each section states where the eras differ. For transports, authorization, cancellation and progress, see [protocol.md](protocol.md). For the client side, see [client.md](client.md).

## Creating a server

A `Server` is an actor. You create it with a name, a version and the capabilities it provides, register handlers, and start it on a transport.

%include Examples/Snippets/Server/Server.swift create-server

The parameters of `Server.init`:

| Parameter | Purpose |
| --- | --- |
| `name`, `version`, `title`, `description`, `websiteUrl`, `icons` | Sent as `serverInfo` in the `initialize` result, and as `_meta["io.modelcontextprotocol/serverInfo"]` on every stateless result, icons included: prefer `https` icon URLs to large `data:` URLs, which every result repeats. |
| `instructions` | Usage hints for the client's model. Sent in the `initialize` and `server/discover` results. |
| `capabilities` | The features the server provides. See [Capabilities and extensions](#capabilities-and-extensions). |
| `configuration` | `strict`, served protocol versions and cache hints. |
| `requestStateProtection` | How `requestState` is sealed. See [Protecting requestState](#protecting-requeststate). |

`Server.Configuration` has these fields:

| Field | Default | Effect |
| --- | --- | --- |
| `strict` | `false` | Handshake era only: requests other than `initialize` and `ping` before `initialize` fail with -32600 "Server is not initialized", and notifications before it are ignored. Server-to-client requests check the client's declared capabilities. No effect behind a `StatelessHTTPServerTransport`. |
| `protocolVersions` | `Version.stateless + Version.handshake` | The revisions the server serves, newest first. `initialize` negotiates among the handshake revisions in this list. With no handshake revision, `initialize` and every handshake-era request fail with -32022. |
| `cacheHints`, `defaultCacheHint` | `[:]`, `.uncached` | See [Cacheable results](#cacheable-results). |

A server for handshake clients only lists `Version.handshake`:

%include Examples/Snippets/Server/Server.swift configuration

### How the server tells the eras apart

The server classifies every request by `_meta["io.modelcontextprotocol/protocolVersion"]`:

- Absent, or a handshake revision: the request belongs to the `initialize` connection.
- Any other version: a stateless request. It must also carry `io.modelcontextprotocol/clientCapabilities`. `io.modelcontextprotocol/clientInfo` and `io.modelcontextprotocol/logLevel` are optional.

The two eras behave as follows:

| | 2025-11-25 and earlier | 2026-07-28 |
| --- | --- | --- |
| Opening | `initialize`, then `notifications/initialized` | None. Clients may send `server/discover`, which the SDK answers. |
| Client identity and capabilities | From `initialize`, for the whole connection | From the `_meta` of each request |
| `initialize`, `ping`, `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe` | Served | -32601 |
| `server/discover`, `subscriptions/listen` | -32601 | Served by the SDK |
| Methods of undeclared capabilities | The handler runs if one is registered | -32601 "capability not declared by the server" |
| Server-to-client requests | Allowed | -32600. Return input requests instead. |
| Results | As the handler returns them | The SDK adds `resultType`, `_meta.serverInfo` and cache hints |
| `Configuration.strict` | Applies | Does not apply |

Classification errors:

| Code | Cause |
| --- | --- |
| -32602 | `protocolVersion` is not a non-empty string; `clientCapabilities` is missing or not an object; `clientInfo` is present but invalid. |
| -32022 | The version is not in `Configuration.protocolVersions`. `data` has `supported` (the configured list) and `requested`. |

Over HTTP, one `Server` on a `StatelessHTTPServerTransport` serves stateless requests, and a `Server` per session on a `StatefulHTTPServerTransport` serves handshake clients. See [protocol.md](protocol.md#routing-both-eras-on-one-endpoint) for routing.

## Tools

A tool is a function the client's model can call. A server lists its tools in a `tools/list` handler and runs them in a `tools/call` handler. Declare the `tools` capability.

### Tool definitions

`Tool` has a `name`, an optional `title` and `description`, an `inputSchema` (a JSON Schema object as a `Value`), an optional `outputSchema`, `annotations` and `icons`. `Value` accepts Swift literals, so a schema reads like JSON:

%include Examples/Snippets/Server/Tools.swift tools-list

- `description` has no default value: pass `nil` when the tool has none. A `nil` description is left out of the JSON.
- `annotations` are hints for clients (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, `title`). Clients must not trust them from untrusted servers.
- The SDK does not validate arguments against `inputSchema`. Check them in the handler.

### Calling tools

There is one handler per method. A server with several tools switches on `params.name`. `params.arguments` is a `[String: Value]?`; read it with `stringValue`, `intValue`, `doubleValue`, `numberValue` (an integer or a double, as `Double`), `boolValue`, `arrayValue` and `objectValue`.

%include Examples/Snippets/Server/Tools.swift tools-call

### Tool result content

`CallTool.Result.content` is a list of `Tool.Content` blocks:

| Case | Wire `type` | Use |
| --- | --- | --- |
| `.text(text:annotations:_meta:)` | `text` | Text for the model |
| `.image(data:mimeType:annotations:_meta:)` | `image` | Base64-encoded image |
| `.audio(data:mimeType:annotations:_meta:)` | `audio` | Base64-encoded audio |
| `.resource(resource:annotations:_meta:)` | `resource` | An embedded resource, with its text or blob |
| `.resourceLink(uri:name:title:description:mimeType:annotations:)` | `resource_link` | A link the client may read with `resources/read` |

%include Examples/Snippets/Server/Tools.swift tools-content

The factories with a `metadata:` label, such as `.text(_:metadata:)`, are deprecated. Use the cases above.

### Structured content

A tool with an `outputSchema` returns its data in `structuredContent`. `CallTool.Result(content:structuredContent:isError:_meta:)` takes any `Codable` value and throws if it cannot be encoded. Send the same data as text too, for clients that read only `content`.

%include Examples/Snippets/Server/Tools.swift tools-structured

The SDK does not check `structuredContent` against `outputSchema`.

### Errors and isError

A tool can fail in two ways:

| Failure | How | What the client receives |
| --- | --- | --- |
| The tool ran and failed | Return a result with `isError: true` | A normal result. The model reads the content and can correct its call. |
| The request is wrong | Throw an `MCPError` | A JSON-RPC error with that code |

Other errors thrown by a handler become -32603 with the error's `localizedDescription` as the message. A handler that throws `CancellationError` sends no response: this is how a cancelled request ends.

Errors the SDK returns before the handler runs:

| Code | Cause |
| --- | --- |
| -32602 | The parameters do not decode as `CallTool.Parameters` (for example, `name` is missing). |
| -32601 | No `tools/call` handler, or (2026-07-28) the `tools` capability is not declared. |
| -32020 | (2026-07-28, HTTP) An `Mcp-Param-*` header does not match its argument. |

### Header parameters

At 2026-07-28 over HTTP, a client copies selected `tools/call` arguments into `Mcp-Param-<Name>` headers, so that gateways can route on them without reading the body (SEP-2243). Mark the argument in the input schema with `"x-mcp-header": "<Name>"`. Only `string`, `integer` and `boolean` properties reachable through `properties` from the schema root can be mirrored; `$ref` is not followed. Header names must be HTTP tokens and unique, case-insensitively. A tool has at most 64 annotations (`MCPRequestHeaders.maxAnnotations`), nested at most 32 `properties` deep (`maxSchemaDepth`).

%include Examples/Snippets/Server/Tools.swift tools-headers

What the SDK does at 2026-07-28:

- On `tools/list`, it drops tools whose annotations are invalid and logs a warning. Handshake clients receive them unchanged. `Tool.headerParameters()` throws `MCPRequestHeaders.InvalidAnnotation` for the same tools, so check your tools at startup.
- On `tools/call` over an HTTP transport, it compares each `Mcp-Param-*` header with the argument and answers -32020 (HTTP 400) on a mismatch: a missing header, a header for an absent argument, invalid Base64, or a different value. To find the schemas, the first call that needs them runs your `tools/list` handler through all its pages, up to 100, after the `statelessRequestHook`. Concurrent calls share that pass. The schemas are kept until you send `ToolListChangedNotification` or replace the `tools/list` handler, so send the notification when the list changes. A call without arguments and without `Mcp-Param-*` headers skips the lookup.
- The check fails closed: a call with `Mcp-Param-*` headers gets -32020 when the tool is not in the listing or the listing cannot be read (the handler throws, or there are more than 100 pages), and a call to a tool dropped for an invalid annotation always gets -32020.
- `StatelessHTTPServerTransport` checks `Mcp-Method` and `Mcp-Name` against the body and also answers -32020.

## Prompts

A prompt is a message template the user selects in the client. Every prompt has a name and a list of string arguments. Declare the `prompts` capability, list prompts in a `prompts/list` handler and expand them in a `prompts/get` handler.

%include Examples/Snippets/Server/Prompts.swift prompts-register

- `params.arguments` is a `[String: String]?`.
- `Prompt.Argument.required` is information for the client. The SDK does not enforce it. Throw `MCPError.invalidParams` (-32602) for a missing argument or an unknown prompt.
- At 2026-07-28 `prompts/get` without the `prompts` capability fails with -32601.

### Prompt message content

A message is `.user(_:)` or `.assistant(_:)` with one `Prompt.Message.Content`. A string literal is text content.

| Case | Wire `type` |
| --- | --- |
| `.text(text:)` | `text` |
| `.image(data:mimeType:)` | `image` (base64) |
| `.audio(data:mimeType:)` | `audio` (base64) |
| `.resource(resource:annotations:_meta:)` | `resource` |
| `.resourceLink(uri:name:title:description:mimeType:annotations:)` | `resource_link` |

%include Examples/Snippets/Server/Prompts.swift prompts-content

## Resources

A resource is data identified by a URI that the client can read, such as a file or a database schema. Declare the `resources` capability and register handlers for `resources/list`, `resources/templates/list` and `resources/read`.

%include Examples/Snippets/Server/Resources.swift resources-register

- `Resource` has `name`, `uri`, and optional `title`, `description`, `mimeType`, `size`, `annotations`, `icons` and `_meta`.
- Throw `MCPError.resourceNotFound(uri:)` for an unknown URI. It is -32602 with `data.uri` (SEP-2164).
- At 2026-07-28 these methods without the `resources` capability fail with -32601.

### Binary resources

`Resource.Content.text(_:uri:mimeType:_meta:)` sends `text`. `Resource.Content.binary(_:uri:mimeType:_meta:)` takes `Data` and sends it base64-encoded in `blob`. Clients decode `blob` themselves.

### Resource templates

A `Resource.Template` describes a family of URIs with an RFC 6570 `uriTemplate`, such as `file:///project/{path}`. The SDK does not match URIs against templates: the `resources/read` handler receives the concrete URI and decides what it refers to. Offer completions for template variables with a [completion](#completion) handler.

### Resource subscriptions

A client can ask to be told when a resource changes. The two eras use different methods.

**2025-11-25 and earlier.** The client sends `resources/subscribe` and `resources/unsubscribe`. The SDK has no built-in handlers for them: register both, or the client gets -32601. Use them to start and stop watching the source.

%include Examples/Snippets/Server/Resources.swift resources-subscribe

**2026-07-28.** These methods answer -32601. The client opens a `subscriptions/listen` stream with the URIs it wants. The SDK serves the stream; you register nothing. The SDK honors resource URIs only when the server declares `resources.subscribe: true`.

**Notifying in both eras.** Call `notify` with `ResourceUpdatedNotification` when a resource changes:

%include Examples/Snippets/Server/Resources.swift resources-updated

- Listen streams receive the update only if their filter lists the URI.
- On an `initialize` connection the SDK sends the update whether or not the client subscribed. Clients ignore updates for URIs they did not subscribe to; if yours must not see them, check the subscription before calling `notify`.
- The notification reports only the change. The client reads the resource again.

## List-changed notifications

A server whose tools, prompts or resources change at run time tells clients with `notifications/tools/list_changed`, `notifications/prompts/list_changed` or `notifications/resources/list_changed`. The SDK does not send them for you: call `notify` after each change. Declare `listChanged: true` on the matching capability.

%include Examples/Snippets/Server/Notifications.swift list-changed

`Server.notify(_:)` delivers a notification as follows:

| Situation | Delivery |
| --- | --- |
| The server has an `initialize` session | On the connection. Called from a handler, on the stream of the request being handled (HTTP). |
| Stateless clients | Only on `subscriptions/listen` streams whose filter asks for that kind |
| No transport (before `start` or after `stop`) | Throws -32603 "Server connection not initialized" |

Other notifications, such as progress and log messages, always go on the connection.

### Listen streams

At 2026-07-28 there is no session and no standalone GET stream. A client opens a `subscriptions/listen` request whose response is a stream of notifications (SEP-2575). The SDK serves it:

1. It computes the honored filter: list changes only for capabilities declared with `listChanged: true`, resource URIs only with `resources.subscribe: true`.
2. It sends `notifications/subscriptions/acknowledged` with the honored filter as the first message.
3. It forwards every matching notification passed to `notify`. Each carries `_meta["io.modelcontextprotocol/subscriptionId"]`, the JSON-RPC id of the listen request.
4. The stream ends when the client cancels or disconnects, or when the server calls `closeSubscriptions()` or `stop()`. `closeSubscriptions()` ends every stream with the listen result. `stop()` does too, and waits until those results are sent before it closes the transport.

Each stream buffers the newest 256 notifications and drops older ones. The notifications mean "fetch again", so a dropped duplicate loses nothing.

At handshake, `subscriptions/listen` fails with -32601 "requires protocol version 2026-07-28 or later".

## Multi round-trip requests

A `tools/call`, `prompts/get` or `resources/read` handler sometimes needs input from the client: a user confirmation, a model completion or the client's roots. At 2026-07-28 a server cannot send requests to the client. Instead, the handler returns an input-required result (SEP-2322):

1. The handler returns `.inputRequired(_:requestState:_meta:)` with input requests keyed by names it chooses, and optional `requestState`.
2. The client fulfills each request and sends the same request again, with `inputResponses` under the same keys and `requestState` echoed.
3. The SDK calls the handler again. The handler finds the answers in `params.inputResponses` and the state in `params.requestState`.

%include Examples/Snippets/Server/MultiRoundTrip.swift mrtr-handler

The pieces:

| Type | Values |
| --- | --- |
| `InputRequest` | `.elicitation(_:)` (also `.elicitation(message:requestedSchema:)` for a form), `.sampling(_:)`, `.listRoots` |
| `InputResponse` | Read with `.elicitation`, `.sampling` or `.roots` |
| `requestState` | A string the handler writes and reads as plaintext. The SDK seals it on the way out. |
| `resultType` | `.inputRequired` on such results, `.complete` otherwise |

A result may carry `requestState` without input requests. The client then retries with the state and no responses, which lets a long operation continue in steps.

### Several requests in one round

A round may ask for several things. Swift clients and the handshake bridge fulfill them concurrently.

%include Examples/Snippets/Server/MultiRoundTrip.swift mrtr-several

### Handshake clients

The same handler serves earlier clients. For a handshake client, the SDK fulfills the input requests itself: it sends `elicitation/create`, `sampling/createMessage` or `roots/list` to the client, concurrently, and calls the handler again with the responses and the plaintext `requestState`. The client sees one `tools/call` with the final result.

- The bridge calls the handler at most 10 times. When the 10th call still asks for input, the call fails with -32603 "tools/call asked for input 10 times" (or the method name of the call).
- A result with only `requestState` is retried after 50 ms, doubling up to 250 ms, as a 2026-07-28 client does.
- The bridge checks the client's declared capabilities as at 2026-07-28, whatever `strict` says: a request the client cannot fulfill fails the call with -32021 before anything is sent.
- A failing client request fails the original call with -32603 "The client failed `<method>`: ...".
- When the client cancels the call, the outstanding requests are withdrawn with `notifications/cancelled`, and the handler is not called again.
- Batched requests are handled off the receive loop, so a batched call can wait for the client's answers.
- `inputResponses` and `requestState` sent by a handshake client are not part of its protocol. The SDK drops them before the handler runs.

At 2026-07-28 the client runs the rounds. The Swift client sends at most `Client.Configuration.multiRoundTrip.maxRounds` (10) retries.

### Client capabilities

At 2026-07-28 the SDK checks each input request against the capabilities the client declared in the request's `_meta`. A request the client cannot fulfill fails the call with -32021 and `data.requiredCapabilities`. A URL elicitation needs `elicitation.url`. Check the capabilities first to return a useful result instead:

%include Examples/Snippets/Server/MultiRoundTrip.swift mrtr-capabilities

### Errors

| Code | Cause |
| --- | --- |
| -32603 | The result has both content and input requests or `requestState`. Content is `content`, `structuredContent` or `isError` for tools; `messages` or `description` for prompts; `contents`, `ttlMs` or `cacheScope` for resources. |
| -32603 | `.inputRequired()` with neither input requests nor `requestState` |
| -32603 | (Handshake) The 10th handler call still asks for input |
| -32603 | (Handshake) The client failed one of the bridged requests |
| -32021 | (Handshake) An input request needs a capability the client did not declare |
| -32021 | (2026-07-28) An input request needs a capability the client did not declare |
| -32602 | (2026-07-28) "Invalid or expired requestState" |
| -32602 | `inputResponses` is `null` |

### Protecting requestState

The client holds `requestState` between rounds, so what comes back is client input. By default the SDK seals the state with AES-256-GCM before it leaves the server and verifies each echo before the handler runs. Handlers read and write plaintext. Each sealed token is bound to:

- a time window: the time-to-live (default 600 seconds), renewed each round;
- the request: the method, the tool or prompt name or resource URI, and a digest of the arguments;
- the audience: the server name, or `RequestStateProtection.audience`;
- the principal, when `RequestStateProtection.principal` returns one for the request.

Any failure is answered with -32602 "Invalid or expired requestState". The reason (expired, request binding, audience, principal, unknown key, replayed) goes to the server log as a warning, never to the client.

A token can be echoed again until it expires: a client can repeat a round, or send an earlier round's token to go back. To accept each token once, pass `consume` to `RequestStateProtection`: it receives each verified token's unique id and expiry and returns whether the id is new; `false` rejects the token as replayed. When it throws, for example because the store cannot be reached, the round fails with -32603 instead. Back it with a store that every instance with the keys shares, and keep ids until their expiry. A client that retries a round after a lost response must then start the request again. Sealing applies to stateless requests only: the handshake bridge keeps the state in the server.

The default, `.ephemeral()`, uses a random key held by this process. It suits a single process, such as a stdio server or one HTTP instance. State from another instance, or from before a restart, is rejected, and the client must start the request again.

Servers with several instances share keys of at least 32 random bytes:

%include Examples/Snippets/Server/MultiRoundTrip.swift mrtr-shared-keys

- `keys[0]` seals; every key verifies. To rotate, deploy `[old, new]` on every instance, then `[new, old]`, then `[new]` one time-to-live later.
- `RequestStateProtection(keys:)` and `AESGCMRequestStateCodec(keys:)` throw -32600 for an empty list, a key shorter than `AESGCMRequestStateCodec.minimumKeyLength` (32 bytes), or a duplicate key.
- `principal` receives the `Server.HandlerContext`. Derive it from verified authentication, such as the subject of a validated bearer token, never from a header the client sets. State sealed for one principal fails for another. State sealed with a principal fails when none is returned, and the reverse.
- Servers that share keys but must not accept each other's state set different `audience` values.

A token is `v1.` followed by base64url(key id ‖ nonce ‖ ciphertext ‖ tag).

To use your own scheme, for example keys from a key service, implement `RequestStateCodec`. `seal` and `unseal` are synchronous, so cache key material. `unseal` throws `InvalidRequestState` for a token it did not mint unchanged. The SDK still adds and checks the claims (expiry, binding, audience, principal) inside the payload.

%include Examples/Snippets/Server/MultiRoundTrip.swift mrtr-codec

`requestStateProtection: nil` turns protection off. The state crosses the wire as written and comes back unchecked:

%include Examples/Snippets/Server/MultiRoundTrip.swift mrtr-unprotected

## Tasks

A task lets a tool call outlive its request: the server answers at once with a task, and the client polls it until the result is ready. Tasks exist at two revisions, with different wire forms:

| | 2025-11-25 (SEP-1686) | 2026-07-28 (`io.modelcontextprotocol/tasks`, SEP-2663) |
|---|---|---|
| Who decides | The client asks with `task` on `tools/call` | The server, for clients that declare the extension |
| Declared as | `capabilities.tasks` in `initialize` | `extensions["io.modelcontextprotocol/tasks"]` in `server/discover` |
| Result | `tasks/result`, which waits for the task | Inlined in `tasks/get` |
| Input during the task | Server requests sent on the `tasks/result` stream | `inputRequests` in `tasks/get`, answered with `tasks/update` |
| Tool error (`isError`) | The task fails | The task completes |
| Listing | `tasks/list`, with a principal | None |

One handler serves both. Set the server up with `withTasks(_:)`, declare each tool's `execution.taskSupport` in `tools/list`, and return `runAsTask` from the `tools/call` handler:

%include Examples/Snippets/Server/Tasks.swift tasks-server

`runAsTask` creates a task when the client can use one: it declared the extension (2026-07-28) or sent `task` (2025-11-25). The result then describes the task, and the work runs on after the handler returns. Otherwise the work runs inline and its result is returned. The `TaskContext` the work receives:

| Member | Effect |
|---|---|
| `requestInput(_:)`, `elicit(message:requestedSchema:)` | Asks the client and waits. In a task the requests are reported with the task; inline they go to the client directly (handshake), or fail with -32021 at 2026-07-28, where inline work cannot ask. The SDK renames a key the task used before. |
| `setStatusMessage(_:)` | Sets the task's `statusMessage`. |
| `reportProgress(_:total:message:)` | Progress for the call's token: for the task's lifetime at 2025-11-25, nothing in a 2026-07-28 task. |
| `isTask`, `taskID`, `request` | Whether the work runs as a task, its id, and the context of the request that started it. |

The work's outcome becomes the task's: a returned result completes it (a 2025-11-25 task with an `isError` result fails), an `MCPError` fails it as is, any other error fails it with -32603, and cancelling the task cancels the work.

Which tools may run as tasks comes from the `tools/list` handler's output, read once and kept until the tool list changes:

| `execution.taskSupport` | 2025-11-25 | 2026-07-28 |
|---|---|---|
| absent or `forbidden` | A call with `task`: -32601 | Never a task |
| `optional` | The client's choice | A task for clients that declare the extension |
| `required` | A call without `task`: -32601 | Clients that do not declare the extension: -32021 |

`execution` reaches clients only at 2025-11-25; the SDK removes it from `tools/list` at other revisions. A tool whose work asks for input should be `required`: at 2026-07-28 inline work cannot ask.

### Task managers

A `TaskManager` runs the work and keeps the tasks in a `TaskStore` (`InMemoryTaskStore` by default). Give every `Server` of the process the same manager: a stateful HTTP server creates one per session, and a task outlives the session that created it.

%include Examples/Snippets/Server/Tasks.swift tasks-manager

| `TaskManager.Configuration` | Default | Effect |
|---|---|---|
| `defaultTTL` | 1 hour | A task's lifetime when the client asks for none |
| `maximumTTL` | 24 hours | A longer lifetime the client asks for is shortened |
| `pollInterval` | 1 second | The interval suggested to clients |
| `maxActiveTasks` | 1000 | At the limit, a `required` tool or a 2025-11-25 call with `task` fails with -32603 "Too many tasks are running"; any other call runs inline |
| `maxActiveTasksPerPrincipal` | 100 | The same, per principal; only with a principal |
| `sendsStatusNotifications` | `true` | 2025-11-25: the server that created a task sends `notifications/tasks/status` when its status changes |

Without `principal`, any client that knows a task id can read, answer and cancel the task. Ids carry 128 random bits, and 2025-11-25 clients cannot list tasks. With one, a task is visible only to the principal that created it (-32602, as for an unknown task, to anyone else), and 2025-11-25 clients may list theirs. A task is a durable handle, not durable execution: its work runs in this process. After a restart, a stored task that was working has no work behind it.

### Work outside the task

Work that another system runs, such as a job queue, finishes the task itself with `TaskManager.complete(_:with:)` or `fail(_:with:)`. Both also end the task's work, which waits with `untilFinished()`:

%include Examples/Snippets/Server/Tasks.swift tasks-external

### Task methods and errors

| Method | 2025-11-25 | 2026-07-28 |
|---|---|---|
| `tasks/get` | The task | The task with its outcome or `inputRequests` |
| `tasks/update` | -32601 | Records the responses, any subset; unknown keys are ignored; empty acknowledgement |
| `tasks/cancel` | The cancelled task; a finished task: -32602 | Empty acknowledgement, for a finished task too |
| `tasks/result` | Waits, then the call's result with related-task `_meta`, or its error; a cancelled task: -32603 | -32601 |
| `tasks/list` | The caller's tasks, 100 a page, with a principal; -32601 without | -32601 |

At 2026-07-28 a client that did not declare the extension gets -32021 for `tasks/get`, `tasks/update` and `tasks/cancel`, before any task is looked up, and for a listen stream that names tasks. An unknown, expired or foreign task id is -32602. A response in `tasks/update` that does not fit its request is -32602. Over HTTP, `Mcp-Name` must carry the task id (-32020 otherwise).

### Notifications

At 2025-11-25 the server that created a task sends `notifications/tasks/status` on its connection each time the status changes. At 2026-07-28 a client names tasks in `SubscriptionFilter.taskIds` on a `subscriptions/listen` stream; the acknowledgement keeps the caller's own tasks, and each change arrives as `notifications/tasks` with the task as `tasks/get` returns it. Both are optional for clients, which keep polling.

## Requests to the client

Handshake clients accept requests from the server. `Server` has methods for them:

| Method | Request | Client capability |
| --- | --- | --- |
| `requestSampling(messages:modelPreferences:systemPrompt:includeContext:temperature:maxTokens:stopSequences:_meta:)` | `sampling/createMessage` | `sampling` |
| `requestElicitation(message:requestedSchema:mode:_meta:)` | `elicitation/create` (form) | `elicitation` |
| `requestElicitation(message:url:elicitationId:_meta:)` | `elicitation/create` (URL) | `elicitation` |
| `listRoots()` | `roots/list` | `roots` |

%include Examples/Snippets/Server/MultiRoundTrip.swift server-requests

- Call them from a handler, so that over HTTP the request goes on the stream of the request being handled.
- In strict mode they fail with -32601 when the client did not declare the capability. Otherwise the request is sent, and a client without a handler answers with an error.
- At 2026-07-28 they throw -32600 "... cannot be sent at protocol version 2026-07-28". Use [multi round-trip requests](#multi-round-trip-requests), which serve both eras.
- `notifications/roots/list_changed` exists only in the handshake era. Stateless clients send their roots per request.

## Cacheable results

At 2026-07-28 the results of `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read` and `server/discover` carry cache hints (SEP-2549):

- `ttlMs`: how long the client may reuse the result, in milliseconds. 0 means stale at once.
- `cacheScope`: `.public` (any client, and shared caches, may reuse it) or `.private` (only this client).

The SDK fills in hints the handler leaves `nil`, from `Configuration.cacheHints` keyed by method name, else `Configuration.defaultCacheHint`. The default is `CacheHint.uncached`: `ttlMs` 0, `.private`.

%include Examples/Snippets/Server/Caching.swift cache-configuration

A handler sets its own hints on the result; they win over the configuration:

%include Examples/Snippets/Server/Caching.swift cache-result

- The SDK fills in hints for stateless requests only. Hints a handler sets are encoded for handshake clients too.
- Input-required results get no hints.
- Every stateless result also gets `resultType: "complete"` (unless the handler set another) and `_meta["io.modelcontextprotocol/serverInfo"]`.
- `ttlMs` values below 0 in the configuration are sent as 0.

## Completion

A server can suggest values for prompt arguments and resource template variables as the user types. Declare the `completions` capability and register a `completion/complete` handler. `params.ref` names the prompt (`.prompt`) or template (`.resource`), `params.argument` has the name and the partial value, and `params.context?.arguments` has the arguments already resolved.

%include Examples/Snippets/Server/Utilities.swift completion

- Return at most 100 values. The SDK does not enforce the limit.
- At 2026-07-28 `completion/complete` without the `completions` capability fails with -32601.

## Logging

A server sends log messages to the client with `Server.log(level:logger:data:)`. `data` is a `Value` or any `Codable` value. `LogLevel` is `Comparable`, from `.debug` to `.emergency`. Declare the `logging` capability so that clients know they may set a level.

The eras choose the level differently:

| | 2025-11-25 and earlier | 2026-07-28 |
| --- | --- | --- |
| How the client sets the level | `logging/setLevel` request, once | `_meta["io.modelcontextprotocol/logLevel"]` on each request |
| Who stores it | The SDK, per connection, when the server declares `logging` | The SDK, per request |
| Who filters | `log` drops messages below the level; before the client sets one, it sends every message | `log` called from the handler drops messages below the level, and all messages when the request set none |
| `logging/setLevel` | Served by the SDK, or by your `SetLoggingLevel` handler; without the `logging` capability, -32601 | -32601 |

%include Examples/Snippets/Server/Utilities.swift logging-level

Outside a handler there is no request: `log` applies the connection's `logging/setLevel` level, if any. The messages are `notifications/message` notifications; called from a handler, they go on the stream of the request being handled.

## Handler context

`Server.currentHandlerContext` is a task-local `Server.HandlerContext`, set while a handler runs and `nil` elsewhere. It describes the request being handled:

| Property | Handshake request | Stateless request |
| --- | --- | --- |
| `protocolVersion` | The version negotiated by `initialize` (`nil` before it) | From `_meta` |
| `clientCapabilities` | From `initialize` | From `_meta` |
| `clientInfo` | From `initialize` | From `_meta`, if sent |
| `logLevel` | `nil` | From `_meta`, if sent |
| `isStateless` | `false` | `true` |
| `profile` | `ProtocolProfile` of `protocolVersion`: flags such as `allowsServerRequests`, `usesSubscriptionsListen`, `usesStandardHeaders` | Same |
| `httpContext` | The `HTTPRequest`, if the transport provides one | Same |

Read capabilities from the context, not from what one client sent earlier: at 2026-07-28 each request declares its own.

%include Examples/Snippets/Server/Context.swift handler-context

### HTTP context

`httpContext` is the originating `HTTPRequest` (method, headers, body, path) when the transport conforms to `HTTPContextProviding`. `StatefulHTTPServerTransport` and `StatelessHTTPServerTransport` do; `StdioTransport` and `InMemoryTransport` do not, so it is `nil` there. `HTTPRequest.header(_:)` looks headers up case-insensitively.

%include Examples/Snippets/Server/Context.swift http-context

`Task.detached` does not inherit task-locals. Capture the context before you detach. A plain `Task { }` started in a handler inherits it.

## Capabilities and extensions

The SDK does not infer capabilities from the handlers you register. Declare them in `Server.init`. The server sends them in the `initialize` and `server/discover` results, and checks them on each stateless request.

| Capability | Methods | Options |
| --- | --- | --- |
| `tools` | `tools/list`, `tools/call` | `listChanged` |
| `prompts` | `prompts/list`, `prompts/get` | `listChanged` |
| `resources` | `resources/list`, `resources/templates/list`, `resources/read` | `listChanged`, `subscribe` |
| `completions` | `completion/complete` | |
| `logging` | `logging/setLevel` (handshake) | |
| `tasks` (2025-11-25) | `tasks/get`, `tasks/result`, `tasks/cancel`, `tasks/list` | derived by `withTasks(_:)`; see [Tasks](#tasks) |

At 2026-07-28 the SDK answers -32601 for the methods of an undeclared capability, and listen streams honor only the declared `listChanged` and `subscribe` options. At handshake a registered handler runs whether or not the capability is declared, so declare every capability you implement.

`experimental` carries non-standard features as `[String: Value]`. `extensions` declares protocol extensions keyed by identifier, with extension-defined settings (SEP-2133). Clients declare theirs the same way; read them per request from the handler context.

%include Examples/Snippets/Server/Context.swift capabilities

## Pagination

`tools/list`, `prompts/list`, `resources/list` and `resources/templates/list` can return their items in pages. The request carries an optional `cursor`; the result carries `nextCursor` when more items follow. The cursor is an opaque string chosen by the server. Answer -32602 for a cursor you did not issue.

%include Examples/Snippets/Server/Context.swift pagination

- The SDK does not paginate for you: a handler that ignores `cursor` returns everything in one page.
- The [header parameter](#header-parameters) check pages through `tools/list` to find a tool's schema, up to 100 pages.
- Clients loop until `nextCursor` is `nil`. See [client.md](client.md#calling-tools).

## Lifecycle

`start(transport:initializeHook:statelessRequestHook:)` registers the built-in handlers, connects the transport and starts the receive loop. It returns once the loop is running. `waitUntilCompleted()` returns when the loop ends, for example when the transport closes. `stop()` ends the listen streams, cancels the loop, fails pending server-to-client requests with -32603 "Server disconnected" and disconnects the transport.

%include Examples/Snippets/Server/Server.swift lifecycle-run

### The initialize hook

The hook runs when a handshake client sends `initialize`, with its `Client.Info` and `Client.Capabilities`, before the server answers. Throw from it to refuse the client: the error goes back as the `initialize` error. Stateless clients never send `initialize`, so the hook never runs for them; check stateless clients with the `statelessRequestHook` of `start(transport:initializeHook:statelessRequestHook:)`, in the handlers, from the handler context, or in the HTTP layer. Without a stateless hook, a server with an initialize hook refuses stateless requests with -32022, and behind a `StatelessHTTPServerTransport`, where no session ties a request to its `initialize`, handshake requests other than `initialize` with -32600.

The `statelessRequestHook` of `start` runs before each stateless request, with `Server.currentHandlerContext` set, so it can read the HTTP request, and gets `nil` client info when the request carries none. Throw from it to refuse the request: an `MCPError` goes back as is, any other error as -32600.

`initialize` errors:

| Code | Cause |
| --- | --- |
| -32600 | "Server is already initialized": a second `initialize` on the same connection or session. Behind a `StatelessHTTPServerTransport` every `initialize` is answered. |
| -32022 | `Configuration.protocolVersions` lists no handshake revision |
| any | The error the hook threw |

The server answers with the requested version if it is a handshake revision in `Configuration.protocolVersions`, otherwise with the first handshake revision in that list.

### Built-in handlers and registration

`start` registers method handlers for `initialize`, `ping`, `server/discover`, `subscriptions/listen` and, with the `logging` capability, `logging/setLevel`, and adds a notification handler for `notifications/cancelled`. A handler of yours for one of these methods is kept, whether you registered it before or after `start`. Replace a built-in handler only on purpose, as in [protocol_versions.md](protocol_versions.md#stateless-only); a `SetLoggingLevel` handler of yours means `log` no longer knows the level.

- `withMethodHandler(_:handler:)` keeps one handler per method. A second registration for the same method replaces the first.
- `onNotification(_:handler:)` adds a handler; several handlers for one notification all run. Errors they throw are logged.
- Register handlers before `start`, so that the first request finds them. Registering later works too.
- Each request runs in its own task, so handlers run concurrently. The `Server` actor serializes only its own state; protect yours with an actor.

### Shutdown

Call `stop()` when the process should exit, for example from a signal handler or a [Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle) `Service`. The snippet above stops the server when its task is cancelled, which is what a `ServiceGroup` does on SIGTERM. `stop()` calls `closeSubscriptions()` first. To end listen streams without stopping the server, for example before a rolling restart, call `closeSubscriptions()`.

See [testing.md](testing.md) for running a server against a client in-process, and [troubleshooting.md](troubleshooting.md) for common errors.
