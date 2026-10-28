// mcp-interop-client: runs the interop check battery (interop/README.md)
// against an MCP server built with any SDK, and prints one JSON object per
// line: a `meta` line, then one line per check.
//
//   mcp-interop-client --url http://127.0.0.1:3001/mcp [--era handshake|stateless|auto]
//   mcp-interop-client --era stateless --stdio path/to/server [args...]
//   mcp-interop-client --profile tool --tool greet --args '{"name":"Swift"}' --expect Swift --stdio ...
//
// Profiles:
//   everything  the feature battery against each SDK's conformance everything-server
//   advanced    concurrency, cancellation, notifications, subscriptions, transport edges
//   connect     era negotiation only; --expect-era handshake|stateless|unsupported
//   session     2025-11-25 session expiry: --pause-file F; the runner restarts the server
//   tasks       tasks (SEP-1686, SEP-2663) against the Swift everything-server
//   apps        MCP Apps (SEP-1865): the view and tools of the apps fixture
//   tool        one tool call, for the SDKs' example servers
//
// INTEROP_LOG=trace (or debug, info) logs the HTTP transport on stderr.

import Foundation
import Logging
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(System)
    import System
#else
    import SystemPackage
#endif

// MARK: - Arguments

struct Options {
    var url: URL?
    var stdio: [String] = []
    var era = "auto"
    var profile = "everything"
    var tool = ""
    var toolArguments: [String: Value] = [:]
    var expect = ""
    var timeout: Double = 20
    var expectEra: String?
    var watchedUpdates = false
    var pauseFile: String?

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw Failure("missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--url": options.url = URL(string: try value())
            case "--era": options.era = try value()
            case "--profile": options.profile = try value()
            case "--tool": options.tool = try value()
            case "--args":
                options.toolArguments = try JSONDecoder().decode(
                    [String: Value].self, from: Data(try value().utf8))
            case "--expect": options.expect = try value()
            case "--timeout": options.timeout = Double(try value()) ?? 20
            case "--expect-era": options.expectEra = try value()
            case "--watched-updates": options.watchedUpdates = true
            case "--pause-file": options.pauseFile = try value()
            case "--stdio":
                options.stdio = Array(arguments[(index + 1)...])
                index = arguments.count
                continue
            default: throw Failure("unknown argument \(arguments[index])")
            }
            index += 1
        }
        guard options.url != nil || !options.stdio.isEmpty else {
            throw Failure("pass --url or --stdio")
        }
        return options
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Whether `error` rejects the protocol version: -32022, or a message that
/// says the protocol version is unsupported (not, say, a media type).
func rejectsProtocolVersion(_ error: Error) -> Bool {
    let text = "\(error)"
    let lower = text.lowercased()
    return text.contains("-32022")
        || (lower.contains("protocol version") && (lower.contains("unsupported") || lower.contains("not supported")))
}

/// Whether `error` says the server no longer knows the session.
func reportsLostSession(_ error: Error) -> Bool {
    "\(error)".range(of: "session (not found|expired|terminated)", options: [.regularExpression, .caseInsensitive])
        != nil
}

/// A check that does not apply to this server; reported as `skip`.
struct Skip: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

// MARK: - Output

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Counts handler invocations and notifications by name: `logs`,
/// `progress`, `sampling`, `elicitation`, `roots`.
actor Counters {
    private var counts: [String: Int] = [:]
    private var tokens: [String: Int] = [:]
    func add(_ name: String) { counts[name, default: 0] += 1 }
    func get(_ name: String) -> Int { counts[name, default: 0] }
    /// Progress notifications per progress token.
    func addToken(_ token: String) { tokens[token, default: 0] += 1 }
    func tokenCounts() -> [String: Int] { tokens }
}

// MARK: - Checks

enum Era: String { case handshake, stateless }

struct Battery: Sendable {
    let client: Client
    let era: Era
    let counters: Counters
    let timeout: Double
    var isHTTP = true
    var watchedUpdates = false

    /// Runs one check; `body` returns a detail string or throws.
    func check(_ id: String, only: Era? = nil, _ body: @escaping @Sendable () async throws -> String) async {
        if let only, only != era {
            emit(["check": id, "status": "skip", "detail": "\(only.rawValue) only"])
            return
        }
        do {
            let detail = try await withTimeout(timeout) { try await body() }
            emit(["check": id, "status": "pass", "detail": detail])
        } catch let skip as Skip {
            emit(["check": id, "status": "skip", "detail": skip.reason])
        } catch {
            emit(["check": id, "status": "fail", "detail": "\(error)"])
        }
    }

    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message()) }
    }

    func callTool(_ name: String, _ arguments: [String: Value]? = nil, meta: Metadata? = nil)
        async throws -> CallTool.Result
    {
        try await client.callTool(name: name, arguments: arguments, meta: meta)
    }

    func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }
            .joined(separator: " ")
    }

    func kinds(_ content: [Tool.Content]) -> [String] {
        content.map {
            switch $0 {
            case .text: "text"
            case .image: "image"
            case .audio: "audio"
            case .resource: "resource"
            case .resourceLink: "resource_link"
            case .unknown(let type, _): type
            }
        }
    }

    func runEverything() async {
        await check("ping", only: .handshake) {
            try await client.ping()
            return "ok"
        }
        await check("discover", only: .stateless) {
            let result = try await client.send(ServerDiscover.request(.init())).value
            try require(!result.supportedVersions.isEmpty, "no supportedVersions")
            return result.supportedVersions.joined(separator: ",")
        }
        await check("tools-list") {
            let names = Set(try await client.listTools().tools.map(\.name))
            let core = [
                "test_simple_text", "test_image_content", "test_audio_content", "test_embedded_resource",
                "test_multiple_content_types", "test_tool_with_logging", "test_tool_with_progress",
                "test_error_handling", "test_sampling", "test_elicitation",
            ]
            let missing = core.filter { !names.contains($0) }
            try require(missing.isEmpty, "missing \(missing)")
            return "\(names.count) tools"
        }
        await check("tool-simple-text") {
            let result = try await callTool("test_simple_text")
            try require(result.isError != true && !text(result.content).isEmpty, "kinds \(kinds(result.content))")
            return text(result.content)
        }
        for (id, name, kind) in [
            ("tool-image", "test_image_content", "image"), ("tool-audio", "test_audio_content", "audio"),
            ("tool-embedded-resource", "test_embedded_resource", "resource"),
        ] {
            await check(id) {
                let result = try await callTool(name)
                try require(kinds(result.content) == [kind], "kinds \(kinds(result.content))")
                if case .image(let data, let mime, _, _) = result.content[0] { return "\(mime), \(data.count) b64" }
                if case .audio(let data, let mime, _, _) = result.content[0] { return "\(mime), \(data.count) b64" }
                if case .resource(let resource, _, _) = result.content[0] { return resource.uri }
                return kind
            }
        }
        await check("tool-multiple-content") {
            let found = kinds(try await callTool("test_multiple_content_types").content)
            try require(Set(found).isSuperset(of: ["text", "image", "resource"]), "kinds \(found)")
            return found.joined(separator: ",")
        }
        await check("tool-error") {
            let result = try await callTool("test_error_handling")
            try require(result.isError == true, "isError \(String(describing: result.isError))")
            return text(result.content)
        }
        await check("logging-set-level", only: .handshake) {
            // Stateless requests carry the level in `_meta` (Configuration.logLevel).
            try await client.setLoggingLevel(.debug)
            return "debug"
        }
        await check("tool-logging") {
            let before = await counters.get("logs")
            _ = try await callTool("test_tool_with_logging")
            try await settle()
            let received = await counters.get("logs") - before
            try require(received > 0, "no notifications/message")
            return "\(received) log notifications"
        }
        await check("tool-progress") {
            let before = await counters.get("progress")
            _ = try await callTool("test_tool_with_progress", meta: Metadata(progressToken: .string("interop-1")))
            try await settle()
            let received = await counters.get("progress") - before
            try require(received > 0, "no notifications/progress")
            return "\(received) progress notifications"
        }
        await check("tool-sampling", only: .handshake) {
            let result = try await callTool("test_sampling", ["prompt": "Say hello"])
            try require(result.isError != true, "isError: \(text(result.content))")
            try require(text(result.content).contains("interop sampling reply"), text(result.content))
            return text(result.content)
        }
        await check("tool-elicitation", only: .handshake) {
            let result = try await callTool("test_elicitation", ["message": "Who are you?"])
            try require(result.isError != true, "isError: \(text(result.content))")
            try require(text(result.content).contains("accept"), text(result.content))
            return text(result.content)
        }
        for (id, name, handler) in [
            ("mrtr-elicitation", "test_input_required_result_elicitation", "elicitation"),
            ("mrtr-sampling", "test_input_required_result_sampling", "sampling"),
            ("mrtr-list-roots", "test_input_required_result_list_roots", "roots"),
            ("mrtr-multiple-inputs", "test_input_required_result_multiple_inputs", "elicitation"),
            ("mrtr-multi-round", "test_input_required_result_multi_round", "elicitation"),
        ] {
            await check(id, only: .stateless) {
                let before = await counters.get(handler)
                let result = try await callTool(name)
                try require(result.isError != true, "isError: \(text(result.content))")
                let calls = await counters.get(handler) - before
                try require(calls > 0, "handler not called")
                return "\(calls) handler calls: \(text(result.content).prefix(80))"
            }
        }
        await check("unknown-tool") {
            do {
                let result = try await callTool("interop_no_such_tool")
                try require(result.isError == true, "accepted")
                return "isError result"
            } catch let error as MCPError where error.code == -32602 {
                // Only the spec's unknown-tool code: a crashed server or an
                // HTTP 5xx also reaches the client as an MCPError.
                return "JSON-RPC error \(error.code)"
            }
        }
        await check("resources-list") {
            let uris = Set(try await client.listResources().resources.map(\.uri))
            let missing = ["test://static-text", "test://static-binary"].filter { !uris.contains($0) }
            try require(missing.isEmpty, "missing \(missing); have \(uris.sorted())")
            return uris.sorted().joined(separator: ",")
        }
        await check("resource-static-text") {
            let contents = try await client.readResource(uri: "test://static-text").contents
            try require(contents.first?.text?.isEmpty == false, "no text")
            return contents[0].text!
        }
        await check("resource-static-binary") {
            let contents = try await client.readResource(uri: "test://static-binary").contents
            try require(contents.first?.blob?.isEmpty == false, "no blob")
            return "\(contents[0].mimeType ?? "?"), \(contents[0].blob!.count) b64"
        }
        await check("resource-templates-list") {
            let templates = try await client.listResourceTemplates().templates.map(\.uriTemplate)
            try require(templates.contains("test://template/{id}/data"), "have \(templates)")
            return templates.joined(separator: ",")
        }
        await check("resource-template-read") {
            let contents = try await client.readResource(uri: "test://template/42/data").contents
            try require(contents.first?.text?.contains("42") == true, "text \(contents.first?.text ?? "nil")")
            return contents[0].text!
        }
        await check("unknown-resource") {
            do {
                _ = try await client.readResource(uri: "test://interop-missing")
                throw Failure("accepted")
            } catch let error as MCPError where error.code == -32602 || error.code == -32002 {
                // Resource not found: -32602 at 2026-07-28, -32002 at 2025-11-25.
                return "JSON-RPC error \(error.code)"
            }
        }
        await check("prompts-list") {
            let names = Set(try await client.listPrompts().prompts.map(\.name))
            let core = [
                "test_simple_prompt", "test_prompt_with_arguments", "test_prompt_with_embedded_resource",
                "test_prompt_with_image",
            ]
            let missing = core.filter { !names.contains($0) }
            try require(missing.isEmpty, "missing \(missing)")
            return "\(names.count) prompts"
        }
        await check("prompt-simple") {
            let messages = try await client.getPrompt(name: "test_simple_prompt").messages
            try require(!messages.isEmpty, "no messages")
            return "\(messages.count) messages"
        }
        await check("prompt-arguments") {
            let messages = try await client.getPrompt(
                name: "test_prompt_with_arguments", arguments: ["arg1": "alpha", "arg2": "beta"]
            ).messages
            let texts = messages.compactMap { if case .text(let text) = $0.content { text } else { nil } }
                .joined(separator: " ")
            try require(texts.contains("alpha") && texts.contains("beta"), texts)
            return texts
        }
        await check("prompt-embedded-resource") {
            let messages = try await client.getPrompt(
                name: "test_prompt_with_embedded_resource", arguments: ["resourceUri": "test://static-text"]
            ).messages
            let resources = messages.compactMap {
                if case .resource(let resource, _, _) = $0.content { resource.uri } else { nil }
            }
            try require(!resources.isEmpty, "no embedded resource")
            return resources.joined(separator: ",")
        }
        await check("prompt-image") {
            let messages = try await client.getPrompt(name: "test_prompt_with_image").messages
            let images = messages.filter { if case .image = $0.content { true } else { false } }
            try require(!images.isEmpty, "no image")
            return "\(images.count) images"
        }
    }

    /// Waits until `condition` holds, polling every 50 ms.
    func waitFor(_ seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    func runAdvanced() async {
        // Header parameters (SEP-2243) come from the tool list.
        await check("tools-list") { "\(try await client.listTools().tools.count) tools" }

        await check("concurrent-calls") {
            let tokens = (0..<8).map { "interop-c\($0)" }
            let before = await counters.tokenCounts()
            let results = try await withThrowingTaskGroup(of: String.self) { group in
                for token in tokens {
                    group.addTask {
                        let result = try await callTool(
                            "test_tool_with_progress", meta: Metadata(progressToken: .string(token)))
                        try require(result.isError != true, "\(token): isError")
                        return "progress"
                    }
                }
                for _ in 0..<4 {
                    group.addTask {
                        let result = try await callTool("test_simple_text")
                        try require(!text(result.content).isEmpty, "simple text: empty")
                        return "text"
                    }
                    group.addTask {
                        let result = try await callTool("test_image_content")
                        try require(kinds(result.content) == ["image"], "image: \(kinds(result.content))")
                        return "image"
                    }
                }
                var done: [String] = []
                for try await result in group { done.append(result) }
                return done
            }
            try await settle()
            let after = await counters.tokenCounts()
            let silent = tokens.filter { after[$0, default: 0] == before[$0, default: 0] }
            try require(silent.isEmpty, "no progress for \(silent)")
            let stray = after.keys.filter { $0.hasPrefix("interop-c") && !tokens.contains($0) }
            try require(stray.isEmpty, "progress for unknown tokens \(stray)")
            return "\(results.count) calls, progress kept apart for \(tokens.count) tokens"
        }

        await check("concurrent-input") {
            let calls: [(String, [String: Value]?)] =
                era == .handshake
                ? Array(repeating: ("test_sampling", ["prompt": "Say hello"]), count: 4)
                    + Array(repeating: ("test_elicitation", ["message": "Who are you?"]), count: 4)
                : Array(repeating: ("test_input_required_result_sampling", nil), count: 4)
                    + Array(repeating: ("test_input_required_result_elicitation", nil), count: 4)
            let before = await counters.get("sampling") + counters.get("elicitation")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (name, arguments) in calls {
                    group.addTask {
                        let result = try await callTool(name, arguments)
                        try require(result.isError != true, "\(name): \(text(result.content))")
                    }
                }
                try await group.waitForAll()
            }
            let handled = await counters.get("sampling") + counters.get("elicitation") - before
            try require(handled >= calls.count, "\(handled) handler calls for \(calls.count) tools")
            return "\(calls.count) calls, \(handled) handler calls"
        }

        await check("cancel-then-continue") {
            let context = try await client.startToolCall(
                name: "test_tool_with_progress", arguments: nil,
                meta: Metadata(progressToken: .string("interop-cancel")))
            try await Task.sleep(nanoseconds: 20_000_000)
            try await client.cancelRequest(context.requestID, reason: "interop cancel")
            let outcome: String
            do {
                _ = try await withTimeout(5) { try await context.value }
                outcome = "completed before the cancel"
            } catch let failure as Failure {
                throw Failure("cancelled call did not settle: \(failure)")
            } catch {
                outcome = "cancelled"
            }
            let next = try await callTool("test_simple_text")
            try require(!text(next.content).isEmpty, "the next call failed")
            return "\(outcome); next call answered"
        }

        for (id, tool, notification, capability) in [
            ("tools-list-changed", "test_trigger_tool_change", "toolsChanged", "tools"),
            ("prompts-list-changed", "test_trigger_prompt_change", "promptsChanged", "prompts"),
        ] {
            await check(id) {
                let capabilities = await client.serverCapabilities
                let declared =
                    capability == "tools" ? capabilities?.tools?.listChanged : capabilities?.prompts?.listChanged
                guard declared == true else { throw Skip("the server does not declare \(capability).listChanged") }
                // At 2026-07-28 the client opens the listen stream in the background.
                if era == .stateless { try await Task.sleep(nanoseconds: 500_000_000) }
                let before = await counters.get(notification)
                _ = try await callTool(tool)
                let received = await waitFor(3) { await counters.get(notification) > before }
                try require(received, "no list_changed notification within 3 s")
                return "notified"
            }
        }

        await check("resource-subscribe") {
            guard await client.serverCapabilities?.resources?.subscribe == true else {
                throw Skip("the server does not declare resources.subscribe")
            }
            try await client.subscribeToResource(uri: "test://watched-resource")
            return era == .stateless ? "listen stream acknowledged" : "resources/subscribe"
        }
        await check("resource-updated") {
            guard watchedUpdates else { throw Skip("the server never updates test://watched-resource") }
            let received = await waitFor(8) { await counters.get("resourceUpdated") > 0 }
            try require(received, "no notifications/resources/updated within 8 s")
            return "\(await counters.get("resourceUpdated")) updates"
        }

        await check("reconnection") {
            guard isHTTP else { throw Skip("HTTP only") }
            let result = try await callTool("test_reconnection")
            try require(text(result.content).contains("Reconnection test completed"), text(result.content))
            return text(result.content)
        }
        for (id, region) in [("mcp-param-header", "eu-west-1"), ("mcp-param-header-unicode", "Zürich 東京")] {
            await check(id, only: .stateless) {
                guard isHTTP else { throw Skip("HTTP only") }
                // Header bindings come from the tool list; list_changed above invalidated it.
                _ = try await client.listTools()
                let result = try await callTool("test_x_mcp_header", ["region": .string(region)])
                try require(result.isError != true && text(result.content).contains(region), text(result.content))
                return text(result.content)
            }
        }
        await check("streaming-elicitation") {
            let result = try await callTool("test_streaming_elicitation")
            try require(result.isError != true, text(result.content))
            return text(result.content)
        }
    }

    func runTool(_ options: Options) async {
        await check("tools-list") {
            let names = try await client.listTools().tools.map(\.name)
            try require(names.contains(options.tool), "have \(names)")
            return names.joined(separator: ",")
        }
        await check("tool-call") {
            let result = try await callTool(options.tool, options.toolArguments)
            try require(result.isError != true, "isError: \(text(result.content))")
            try require(text(result.content).contains(options.expect), text(result.content))
            return text(result.content)
        }
    }

    /// Notifications are delivered asynchronously; give them a moment.
    func settle() async throws { try await Task.sleep(nanoseconds: 300_000_000) }
}

/// Resumes a continuation once: with the body's result or with the timeout.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Runs `body` with a time limit. A body that ignores cancellation, such as a
/// wait for a lost response, is abandoned rather than awaited.
func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T)
    async throws -> T
{
    try await withCheckedThrowingContinuation { continuation in
        let once = Once(continuation)
        let work = Task {
            do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.resume(.failure(Failure("timed out after \(Int(seconds)) s")))
            work.cancel()
        }
    }
}

/// A plausible answer for every field of an elicitation form.
func answer(_ schema: Elicitation.RequestSchema) -> [String: Value] {
    var content: [String: Value] = [:]
    for (name, property) in schema.properties {
        let object = property.objectValue ?? [:]
        if let options = object["enum"]?.arrayValue, let first = options.first {
            content[name] = first
            continue
        }
        if let items = object["items"]?.objectValue,
            let first = (items["enum"]?.arrayValue ?? items["anyOf"]?.arrayValue?.compactMap {
                $0.objectValue?["const"]
            })?.first
        {
            content[name] = [first]
            continue
        }
        if let first = object["oneOf"]?.arrayValue?.first?.objectValue?["const"] {
            content[name] = first
            continue
        }
        switch object["type"]?.stringValue {
        case "number", "integer": content[name] = 1
        case "boolean": content[name] = true
        default: content[name] = name.lowercased().contains("email") ? "interop@example.com" : "interop"
        }
    }
    return content
}

// MARK: - Main

// MARK: - Tasks

/// The tasks the checks created, for `task-list`.
actor TaskIDs {
    private(set) var all: [String] = []
    func add(_ id: String) { all.append(id) }
}

extension Battery {
    /// The tasks profile. `client` uses tasks; the common checks use a
    /// second client that does not.
    func runTasks(_ options: Options) async {
        // The client augments 2025-11-25 calls by the tools' listed task support.
        let tools = Set((try? await client.listTools().tools.map(\.name)) ?? [])
        @Sendable func needs(_ name: String) throws {
            if !tools.contains(name) { throw Skip("the server has no \(name)") }
        }
        let ids = TaskIDs()
        await check("task-create") {
            try needs("slow_compute")
            let created = try await client.startToolCall(
                name: "slow_compute", arguments: ["seconds": 1, "label": "interop"]
            ).value
            guard let task = created.task else { throw Failure("no task: \(kinds(created.content))") }
            await ids.add(task.taskId)
            try require(task.status == .working, "status \(task.status)")
            let result = try await client.task(task).result()
            try require(text(result.content).contains("Computed interop"), text(result.content))
            return "\(task.status) -> \(text(result.content))"
        }
        await check("task-input") {
            try needs("confirm_delete")
            let before = await counters.get("elicitation")
            let result = try await callTool("confirm_delete", ["filename": "interop.txt"])
            try require(await counters.get("elicitation") > before, "elicitation handler not called")
            try require(text(result.content) == "Deleted interop.txt", text(result.content))
            return text(result.content)
        }
        await check("task-partial-input") {
            try needs("multi_input")
            let before = await counters.get("elicitation")
            let result = try await callTool("multi_input")
            let calls = await counters.get("elicitation") - before
            try require(calls == 2, "\(calls) elicitation calls")
            return text(result.content)
        }
        await check("task-tool-error") {
            try needs("failing_job")
            let result = try await callTool("failing_job")
            try require(result.isError == true, "isError \(String(describing: result.isError))")
            return text(result.content)
        }
        await check("task-protocol-error") {
            try needs("protocol_error_job")
            do {
                let result = try await callTool("protocol_error_job")
                throw Failure("returned \(text(result.content))")
            } catch let error as MCPError {
                try require(error.code == -32603, "code \(error.code)")
                return "JSON-RPC error \(error.code)"
            }
        }
        await check("task-cancel") {
            try needs("slow_compute")
            let created = try await client.startToolCall(
                name: "slow_compute", arguments: ["seconds": 60, "label": "interop-cancel"]
            ).value
            guard let task = created.task else { throw Failure("no task") }
            await ids.add(task.taskId)
            try await client.cancelTask(task.taskId)
            let status = try await client.getTask(task.taskId).status
            try require(status == .cancelled, "status \(status)")
            do {
                _ = try await client.task(task).result()
                throw Failure("the cancelled task returned a result")
            } catch is TaskCancelledError {
                return "cancelled"
            }
        }
        await check("task-mrtr-composition", only: .stateless) {
            try needs("test_tool_with_task")
            let result = try await callTool("test_tool_with_task")
            try require(text(result.content) == "Hello, interop!", text(result.content))
            return text(result.content)
        }

        await check("task-list", only: .handshake) {
            guard await client.serverCapabilities?.tasks?.list != nil else {
                throw Skip("the server does not declare tasks.list")
            }
            var listed: Set<String> = []
            var cursor: String?
            repeat {
                let page = try await client.listTasks(cursor: cursor)
                listed.formUnion(page.tasks.map(\.taskId))
                cursor = page.nextCursor
            } while cursor != nil
            let missing = await ids.all.filter { !listed.contains($0) }
            try require(missing.isEmpty, "missing \(missing)")
            return "\(listed.count) tasks"
        }

        // A client that does not use tasks.
        let plainCounters = Counters()
        let plain = await makeClient(options, plainCounters)
        let connection: Connection
        do {
            connection = try Connection(options)
            _ = try await withTimeout(timeout) { try await plain.connect(transport: connection.transport) }
        } catch {
            for id in ["task-tool-inline", "task-required-refused"] {
                emit(["check": id, "status": "fail", "detail": "second client: \(error)"])
            }
            return
        }
        defer { connection.close() }
        await check("task-tool-inline") {
            let result = try await plain.callTool(name: "slow_compute", arguments: ["seconds": 0, "label": "interop"])
            try require(result.task == nil, "a task for a client without tasks")
            try require(text(result.content).contains("Computed interop"), text(result.content))
            return text(result.content)
        }
        await check("task-required-refused") {
            let expected = era == .stateless ? -32021 : -32601
            do {
                let result = try await plain.callTool(name: "failing_job")
                throw Failure("returned \(text(result.content))")
            } catch let error as MCPError {
                try require(error.code == expected, "code \(error.code), expected \(expected)")
                return "JSON-RPC error \(error.code)"
            }
        }
        await plain.disconnect()
    }
}

// MARK: - MCP Apps

/// The apps fixture (conformance/everything-server/Apps.swift,
/// interop/ts-client/server.mjs).
enum AppsFixture {
    static let viewURI = "ui://interop/weather.html"
    static let meta = UIResourceMeta(csp: .init(connectDomains: ["https://api.example.com"]), prefersBorder: true)
}

extension Battery {
    /// The apps profile: the client declares the extension and reads the
    /// fixture as a host does.
    func runApps() async {
        await check("apps-tools") {
            let tools = try await client.listTools().tools
            guard let show = tools.first(where: { $0.name == "show_weather" }),
                let refresh = tools.first(where: { $0.name == "refresh_weather" })
            else { throw Failure("no show_weather and refresh_weather") }
            try require(show.ui?.resourceUri == AppsFixture.viewURI, "show_weather ui \(String(describing: show.ui))")
            try require(show.isVisibleToModel && show.isCallableFromApp, "show_weather visibility \(String(describing: show.ui?.visibility))")
            try require(refresh.ui?.resourceUri == AppsFixture.viewURI, "refresh_weather ui \(String(describing: refresh.ui))")
            try require(!refresh.isVisibleToModel && refresh.isCallableFromApp, "refresh_weather visibility \(String(describing: refresh.ui?.visibility))")
            let flat = show._meta?["ui/resourceUri"] != nil
            return "show_weather -> \(AppsFixture.viewURI), refresh_weather app-only" + (flat ? ", flat key too" : "")
        }
        await check("apps-list") {
            let resources = try await client.listResources().resources
            guard let view = resources.first(where: { $0.uri == AppsFixture.viewURI }) else {
                throw Failure("\(AppsFixture.viewURI) is not listed")
            }
            try require(view.mimeType == UIResource.mimeType, "mimeType \(view.mimeType ?? "none")")
            try require(view.ui == AppsFixture.meta, "listing ui \(String(describing: view.ui))")
            return "\(view.uri) with _meta.ui"
        }
        await check("apps-read") {
            let view = try await client.readAppResource(uri: AppsFixture.viewURI)
            try require(view.html.contains("interop weather view"), view.html)
            try require(view.content.ui == AppsFixture.meta, "content ui \(String(describing: view.content.ui))")
            try require(
                view.contentSecurityPolicy.contains("connect-src 'self' https://api.example.com;"),
                view.contentSecurityPolicy)
            return "\(view.html.utf8.count) bytes, CSP from _meta.ui"
        }
        await check("apps-call") {
            let result = try await callTool("show_weather", ["city": "Oslo"])
            let reply = text(result.content)
            try require(reply == "Weather in Oslo: sunny (view declared)", reply)
            return reply
        }
    }
}

func makeClient(_ options: Options, _ counters: Counters, tasks: Bool = false, apps: Bool = false) async -> Client {
    let mode: Client.ProtocolMode =
        switch options.era {
        case "handshake": .handshake
        case "stateless": .stateless(Version.v2026_07_28)
        default: .automatic
        }
    var capabilities = Client.Capabilities(
        sampling: .init(), elicitation: .init(form: .init()), roots: .init(listChanged: false))
    if apps { capabilities.ui = UIExtensionSettings() }
    let client = Client(
        name: "swift-interop-client", version: "1.0.0",
        capabilities: capabilities,
        configuration: .init(
            protocolMode: mode, logLevel: .debug,
            tasks: tasks ? .init(minimumPollInterval: .milliseconds(50), augmentation: .whenSupported) : nil))
    await client.onNotification(LogMessageNotification.self) { _ in await counters.add("logs") }
    await client.onNotification(ProgressNotification.self) { message in
        await counters.add("progress")
        switch message.params.progressToken {
        case .string(let token): await counters.addToken(token)
        case .integer(let token): await counters.addToken("\(token)")
        }
    }
    await client.onNotification(ToolListChangedNotification.self) { _ in await counters.add("toolsChanged") }
    await client.onNotification(PromptListChangedNotification.self) { _ in await counters.add("promptsChanged") }
    await client.onNotification(ResourceUpdatedNotification.self) { _ in await counters.add("resourceUpdated") }
    await client.withSamplingHandler { _ in
        await counters.add("sampling")
        return CreateSamplingMessage.Result(
            model: "interop-model", stopReason: .endTurn, role: .assistant,
            content: .text("interop sampling reply"))
    }
    await client.withElicitationHandler { parameters in
        await counters.add("elicitation")
        guard case .form(let form) = parameters else { return .init(action: .decline) }
        return .init(action: .accept, content: answer(form.requestedSchema))
    }
    await client.withRootsHandler {
        await counters.add("roots")
        return [Root(uri: "file:///tmp/interop", name: "interop")]
    }
    return client
}

/// A server connection: HTTP, or a child process over stdio. Used from the
/// main task only.
final class Connection: @unchecked Sendable {
    let transport: any Transport
    private var process: Process?
    private var toServer: Pipe?

    init(_ options: Options) throws {
        if let url = options.url {
            // INTEROP_LOG=trace|debug|info: transport log on stderr.
            var logger: Logger?
            if let level = ProcessInfo.processInfo.environment["INTEROP_LOG"].flatMap(Logger.Level.init) {
                var log = Logger(label: "interop.transport") { StreamLogHandler.standardError(label: $0) }
                log.logLevel = level
                logger = log
            }
            transport = HTTPClientTransport(endpoint: url, streaming: true, logger: logger)
            return
        }
        let input = Pipe()
        let output = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: options.stdio[0])
        child.arguments = Array(options.stdio.dropFirst())
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        process = child
        toServer = input
        transport = StdioTransport(
            input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor))
    }

    func close() {
        try? toServer?.fileHandleForWriting.close()
        process?.terminate()
    }
}

/// Waits for the runner to write `go` to the pause file.
func pause(at path: String) async throws {
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path))
    for _ in 0..<1200 {
        if let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains("go") { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw Failure("the runner did not resume")
}

func run() async throws -> Int32 {
    let options: Options
    do {
        options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        emit(["check": "arguments", "status": "fail", "detail": "\(error)"])
        return 2
    }

    let counters = Counters()
    let client = await makeClient(
        options, counters, tasks: options.profile == "tasks", apps: options.profile == "apps")
    let connection = try Connection(options)
    defer { connection.close() }

    do {
        _ = try await withTimeout(options.timeout) { try await client.connect(transport: connection.transport) }
    } catch {
        emit(["meta": ["client": "swift", "era": options.era] as [String: Any]])
        if options.expectEra == "unsupported" {
            emit(["check": "connect", "status": rejectsProtocolVersion(error) ? "pass" : "fail", "detail": "\(error)"])
            return 0
        }
        emit(["check": "connect", "status": "fail", "detail": "\(error)"])
        return 1
    }
    let version = await client.negotiatedProtocolVersion ?? "?"
    let server = await client.serverInfo
    let era: Era = await client.isStateless ? .stateless : .handshake
    emit([
        "meta": [
            "client": "swift", "era": era.rawValue, "protocolVersion": version,
            "server": "\(server?.name ?? "?") \(server?.version ?? "")",
        ] as [String: Any]
    ])
    if options.expectEra == "unsupported" {
        // The client must not speak 2026-07-28 to a server without it: an error at
        // connect (above), a fallback to the handshake, or a rejected first request.
        if era == .handshake {
            emit(["check": "connect", "status": "pass", "detail": "fell back to \(version) (handshake)"])
        } else {
            do {
                _ = try await withTimeout(options.timeout) { try await client.listTools() }
                emit(["check": "connect", "status": "fail", "detail": "\(version) accepted, expected unsupported"])
            } catch {
                emit([
                    "check": "connect", "status": rejectsProtocolVersion(error) ? "pass" : "fail",
                    "detail": "first request rejected: \(error)",
                ])
            }
        }
        return 0
    }
    let expected = options.expectEra ?? (options.era == "auto" ? nil : options.era)
    emit([
        "check": "connect", "status": expected == nil || expected == era.rawValue ? "pass" : "fail",
        "detail": "\(version) (\(era.rawValue))" + (expected.map { ", expected \($0)" } ?? ""),
    ])

    let battery = Battery(
        client: client, era: era, counters: counters, timeout: options.timeout,
        isHTTP: options.url != nil, watchedUpdates: options.watchedUpdates)
    switch options.profile {
    case "tool":
        await battery.runTool(options)
    case "advanced":
        await battery.runAdvanced()
    case "tasks":
        await battery.runTasks(options)
    case "apps":
        await battery.runApps()
    case "connect":
        await battery.check("tools-list") { "\(try await client.listTools().tools.count) tools" }
    case "session":
        await battery.check("session-before") {
            battery.text(try await battery.callTool("test_simple_text").content)
        }
        do {
            guard let pauseFile = options.pauseFile else { throw Failure("session needs --pause-file") }
            try await pause(at: pauseFile)
        } catch {
            emit(["check": "session-expired", "status": "fail", "detail": "\(error)"])
            return 1
        }
        // The server restarted: the session ID is unknown to it (HTTP 404).
        await battery.check("session-expired") {
            do {
                let result = try await withTimeout(10) { try await battery.callTool("test_simple_text") }
                return "recovered: \(battery.text(result.content))"
            } catch let failure as Failure {
                throw failure
            } catch {
                guard reportsLostSession(error) else { throw Failure("unexpected error: \(error)") }
                return "error: \(error)"
            }
        }
        await client.disconnect()
        await battery.check("session-reconnect") {
            let fresh = await makeClient(options, counters)
            let connection = try Connection(options)
            defer { connection.close() }
            _ = try await fresh.connect(transport: connection.transport)
            let result = try await fresh.callTool(name: "test_simple_text")
            await fresh.disconnect()
            return battery.text(result.content)
        }
        return 0
    default:
        await battery.runEverything()
    }
    await client.disconnect()
    return 0
}

exit(try await run())
