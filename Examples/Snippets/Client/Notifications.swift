import Foundation
import MCP

// Snippets for docs/client.md: notifications, subscriptions, logging,
// cancellation, progress, batching, capabilities and errors.

// MARK: - Notifications and subscriptions

/// The tools the client last listed.
actor ToolCache {
    private(set) var tools: [Tool] = []
    private(set) var refreshes = 0

    func refresh(from client: Client) async throws {
        tools = try await client.listTools().tools
        refreshes += 1
    }
}

/// Refetches the tool list when the server says it changed.
func watchToolList(_ client: Client, cache: ToolCache) async {
    // snippet: list-changed
    await client.onNotification(ToolListChangedNotification.self) { _ in
        // The notification carries no list: fetch it again. Handlers run on
        // the client's receive loop, so send requests from a new task.
        Task {
            do { try await cache.refresh(from: client) } catch { print("refresh failed: \(error)") }
        }
    }
    // endsnippet
}

/// Opens a `subscriptions/listen` stream by hand (2026-07-28).
func listenForChanges(_ client: Client) async throws -> SubscriptionFilter {
    // snippet: listen
    await client.onNotification(ResourceUpdatedNotification.self) { message in
        print("changed: \(message.params.uri)")
    }
    let subscription = try await client.listen(
        .init(toolsListChanged: true, resourceSubscriptions: ["file:///notes.txt"]))

    // What the server agreed to send; kinds it does not support are absent.
    let honored = subscription.notifications
    print(honored.toolsListChanged == true, honored.resourceSubscriptions ?? [])

    // Stop the stream when done.
    await subscription.cancel()
    // endsnippet
    return honored
}

/// Subscribes to one resource at either protocol era.
func watchNotes(_ client: Client) async throws -> Set<String> {
    // snippet: subscribe-resource
    await client.onNotification(ResourceUpdatedNotification.self) { message in
        Task {
            guard let contents = try? await client.readResource(uri: message.params.uri) else { return }
            print("\(message.params.uri) now has \(contents.count) parts")
        }
    }
    // resources/subscribe at 2025-11-25; a listen stream per URI at 2026-07-28.
    try await client.subscribeToResource(uri: "file:///notes.txt")
    let subscribed = await client.subscribedResourceURIs  // 2026-07-28 streams only
    // ...
    try await client.unsubscribeFromResource(uri: "file:///notes.txt")
    // endsnippet
    return subscribed
}

// MARK: - Logging

/// Receives server log messages at `info` and above.
func receiveLogs(_ client: Client, into log: LogInbox) async throws {
    // snippet: logging
    await client.onNotification(LogMessageNotification.self) { message in
        let params = message.params
        await log.add("[\(params.level.rawValue)] \(params.logger ?? "-"): \(params.data)")
    }
    // logging/setLevel at 2025-11-25; at 2026-07-28 the level is sent in the
    // _meta of every later request.
    try await client.setLoggingLevel(.info)
    // endsnippet
}

/// Collected log lines.
actor LogInbox {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}

// MARK: - Cancellation and progress

/// Cancels a long tool call after `timeout`.
func cancelLongCall(_ client: Client, timeout: Duration = .seconds(5)) async throws -> Bool {
    // snippet: cancel
    var cancelled = false
    let context: RequestContext<CallTool.Result> = try await client.callTool(
        name: "slow", arguments: ["seconds": 30])

    // Give up after `timeout`, for example. A Stop button works the same way.
    let timer = Task {
        try await Task.sleep(for: timeout)
        try await client.cancelRequest(context.requestID, reason: "Timed out")
    }
    defer { timer.cancel() }

    do {
        _ = try await context.value
    } catch is CancellationError {
        cancelled = true  // a response that arrives later is ignored
    }
    // endsnippet
    return cancelled
}

/// Receives progress notifications for one call.
func callWithProgress(_ client: Client, into updates: ProgressInbox) async throws -> [Tool.Content] {
    // snippet: progress
    let token = ProgressToken.unique()
    await client.onNotification(ProgressNotification.self) { message in
        let params = message.params
        guard params.progressToken == token else { return }
        await updates.add(params.progress, of: params.total)
    }
    let (content, _) = try await client.callTool(
        name: "index", arguments: ["path": "/src"],
        meta: Metadata(progressToken: token))
    // endsnippet
    return content
}

/// Collected progress values.
actor ProgressInbox {
    private(set) var values: [Double] = []
    func add(_ progress: Double, of total: Double?) { values.append(progress) }
}

// MARK: - Batching

/// Sends three tool calls in one JSON-RPC batch (2025-03-26 and earlier peers).
func callInBatch(_ client: Client) async throws -> [CallTool.Result] {
    // snippet: batch
    // withBatch's closure is @Sendable, so collect the tasks in an actor.
    let collected = TaskCollector<CallTool.Result>()
    try await client.withBatch { batch in
        for word in ["one", "two", "three"] {
            let task = try await batch.addRequest(
                CallTool.request(.init(name: "echo", arguments: ["text": .string(word)])))
            await collected.append(task)
        }
    }
    // The batch is sent when the closure returns; await each result.
    var results: [CallTool.Result] = []
    for task in await collected.tasks {
        results.append(try await task.value)
    }
    // endsnippet
    return results
}

/// Tasks collected inside a `withBatch` closure.
actor TaskCollector<Output: Sendable> {
    private(set) var tasks: [Task<Output, Error>] = []
    func append(_ task: Task<Output, Error>) { tasks.append(task) }
}

// MARK: - Capabilities and extensions

/// Declares capabilities and an extension, then reads the server's.
func connectWithCapabilities(transport: any Transport) async throws -> (Client, [String: Value]?) {
    // snippet: capabilities
    let client = Client(
        name: "my-client", version: "1.0.0",
        capabilities: .init(
            sampling: .init(tools: .init()),
            elicitation: .init(form: .init(), url: .init()),
            roots: .init(listChanged: true),
            extensions: ["com.example/audit": ["level": "full"]]))
    try await client.connect(transport: transport)

    let server = await client.serverCapabilities
    if let audit = server?.extensions?["com.example/audit"] {
        print("the server supports com.example/audit: \(audit)")
    }
    // endsnippet
    return (client, server?.extensions)
}

// MARK: - Errors

// snippet: errors
/// Describes the errors a client sees.
func describe(_ error: Error) -> String {
    guard let error = error as? MCPError else {
        return "not an MCP error: \(error)"  // for example CancellationError
    }
    switch error {
    case .resourceNotFound(let uri, _):
        return "no resource at \(uri)"
    case .unsupportedProtocolVersion(let supported, let requested):
        return "\(requested ?? "-") not served; the server serves \(supported)"
    case .missingRequiredClientCapabilities(let required, _):
        return "declare these capabilities: \(required)"
    case .urlElicitationRequired(_, let elicitations):
        return "open \(elicitations.map(\.url)) first"
    case .headerMismatch(let detail):
        return "HTTP headers do not match the body: \(detail ?? "")"
    case .connectionClosed, .transportError:
        return "transport failure: \(error)"
    default:
        // code is the JSON-RPC code; data is the error's data member.
        return "[\(error.code)] \(error.localizedDescription) \(error.data.map { "\($0)" } ?? "")"
    }
}
// endsnippet
