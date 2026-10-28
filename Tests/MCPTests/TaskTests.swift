import Foundation
import Testing

@testable import MCP

// Tasks (SEP-1686, SEP-2663): the wire forms of both generations, and the
// server at 2026-07-28.

private func encoded<T: Encodable>(_ value: T) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private let created = Date(timeIntervalSince1970: 1_790_000_000.25)

private func record(
    _ version: String = Version.v2026_07_28, status: TaskStatus = .working, ttlMs: Int? = 60_000
) -> TaskRecord {
    TaskRecord(
        id: "t1", owner: nil, protocolVersion: version, method: CallTool.name, status: status,
        createdAt: created, ttlMs: ttlMs, pollIntervalMs: 500)
}

@Suite("Task wire types")
struct TaskWireTests {
    @Test("A 2026-07-28 task uses ttlMs and pollIntervalMs; ttlMs is null without a limit")
    func v2Snapshot() throws {
        let snapshot = record().snapshot(detailed: true)
        let value = try encoded(snapshot)
        #expect(
            value
                == [
                    "taskId": "t1", "status": "working", "createdAt": "2026-09-21T14:13:20.250Z",
                    "lastUpdatedAt": "2026-09-21T14:13:20.250Z", "ttlMs": 60_000, "pollIntervalMs": 500,
                ])
        let unlimited = try encoded(record(ttlMs: nil).snapshot(detailed: true))
        #expect(unlimited.objectValue?["ttlMs"] == .null)
        #expect(unlimited.objectValue?["ttl"] == nil)
    }

    @Test("A 2025-11-25 task uses ttl and pollInterval and carries no outcome")
    func v1Snapshot() throws {
        var completed = record(Version.v2025_11_25, status: .completed, ttlMs: nil)
        completed.result = try encoded(CallTool.Result(content: [.text(text: "ok")]))
        let value = try encoded(completed.snapshot(detailed: true))
        #expect(
            value
                == [
                    "taskId": "t1", "status": "completed", "createdAt": "2026-09-21T14:13:20.250Z",
                    "lastUpdatedAt": "2026-09-21T14:13:20.250Z", "ttl": .null, "pollInterval": 500,
                ])
    }

    @Test("A tool error completes the task at 2026-07-28 and fails it at 2025-11-25")
    func toolErrorStatus() throws {
        for (version, status) in [(Version.v2026_07_28, TaskStatus.completed), (Version.v2025_11_25, .failed)] {
            var errored = record(version, status: .completed)
            errored.result = try encoded(CallTool.Result(content: [.text(text: "no")], isError: true))
            #expect(errored.snapshot(detailed: true).status == status)
        }
    }

    @Test("tasks/get inlines the outcome at 2026-07-28, with resultType")
    func detailedOutcome() throws {
        var completed = record(status: .completed)
        completed.result = try encoded(CallTool.Result(content: [.text(text: "ok")]))
        let result = try encoded(completed.snapshot(detailed: true)).objectValue?["result"]
        #expect(result == ["content": [["type": "text", "text": "ok"]], "resultType": "complete"])
        #expect(completed.snapshot(detailed: false).result == nil)

        var failed = record(status: .failed)
        failed.error = .internalError("boom")
        let error = try encoded(failed.snapshot(detailed: true)).objectValue?["error"]?.objectValue
        #expect(error?["code"] == -32603)
        #expect(try encoded(failed.snapshot(detailed: true)).objectValue?["result"] == nil)

        var waiting = record(status: .inputRequired)
        waiting.inputRequests = ["k": .elicitation(message: "Name?")]
        let requests = try encoded(waiting.snapshot(detailed: true)).objectValue?["inputRequests"]?.objectValue
        #expect(requests?["k"]?.objectValue?["method"] == "elicitation/create")
    }

    @Test("Decoding tells the generations apart and reads ttl leniently")
    func decodeGenerations() throws {
        let v1 = try decoded(
            TaskSnapshot.self,
            #"{"taskId":"a","status":"working","createdAt":"x","lastUpdatedAt":"x","ttl":1000.7,"pollInterval":200}"#)
        #expect(v1.generation == .v1)
        #expect(v1.ttlMs == 1000)
        #expect(v1.pollIntervalMs == 200)
        let v2 = try decoded(
            TaskSnapshot.self, #"{"taskId":"a","status":"some_new_status","createdAt":"x","ttlMs":null}"#)
        #expect(v2.generation == .v2)
        #expect(v2.ttlMs == nil)
        #expect(v2.status == "some_new_status")
        #expect(!v2.status.isTerminal)
        #expect(v2.lastUpdatedAt == "x")
    }

    @Test("The result that creates a task: flat at 2026-07-28, nested at 2025-11-25")
    func createTaskResult() throws {
        let v2 = CallTool.Result.creating(record().snapshot(detailed: false))
        let flat = try encoded(v2)
        #expect(flat.objectValue?["resultType"] == "task")
        #expect(flat.objectValue?["taskId"] == "t1")
        #expect(flat.objectValue?["ttlMs"] == 60_000)
        #expect(flat.objectValue?["task"] == nil)
        #expect(flat.objectValue?["content"] == nil)
        let decodedV2 = try JSONDecoder().decode(CallTool.Result.self, from: JSONEncoder().encode(v2))
        #expect(decodedV2.resultType == .task)
        #expect(decodedV2.task?.taskId == "t1")
        #expect(decodedV2.content.isEmpty)

        let v1 = CallTool.Result.creating(record(Version.v2025_11_25).snapshot(detailed: false))
        let nested = try encoded(v1)
        #expect(nested.objectValue?["resultType"] == nil)
        #expect(nested.objectValue?["task"]?.objectValue?["ttl"] == 60_000)
        #expect(nested.objectValue?["taskId"] == nil)
        let decodedV1 = try JSONDecoder().decode(CallTool.Result.self, from: JSONEncoder().encode(v1))
        #expect(decodedV1.task?.generation == .v1)
        #expect(decodedV1.resultType == .task)
    }

    @Test("A tool result with content and a task argument echo is not a task")
    func contentIsNotTask() throws {
        let result = try decoded(
            CallTool.Result.self, #"{"content":[{"type":"text","text":"hi"}],"task":{"taskId":"x"}}"#)
        #expect(result.task == nil)
        #expect(result.content.count == 1)
    }

    @Test("tasks/cancel: an empty acknowledgement at 2026-07-28, the task at 2025-11-25")
    func cancelResult() throws {
        #expect(try encoded(CancelTask.Result()) == [:])
        #expect(try decoded(CancelTask.Result.self, #"{"resultType":"complete"}"#).task == nil)
        let v1 = CancelTask.Result(task: record(Version.v2025_11_25, status: .cancelled).snapshot(detailed: false))
        let value = try encoded(v1)
        #expect(value.objectValue?["status"] == "cancelled")
        #expect(value.objectValue?["ttl"] == 60_000)
        #expect(try JSONDecoder().decode(CancelTask.Result.self, from: JSONEncoder().encode(v1)) == v1)
    }

    @Test("tasks/update reads responses of any shape and rejects null")
    func updateParameters() throws {
        let params = try decoded(
            UpdateTask.Parameters.self,
            #"{"taskId":"t","inputResponses":{"a":{"action":"accept","content":{"x":1}},"b":{"ignored":true}}}"#)
        #expect(params.inputResponses["a"]?.elicitation?.action == .accept)
        #expect(params.inputResponses["b"] == .unknown(["ignored": true]))
        #expect(throws: DecodingError.self) {
            try decoded(UpdateTask.Parameters.self, #"{"taskId":"t","inputResponses":null}"#)
        }
    }

    @Test("Tool.execution and CallTool's task member round-trip")
    func toolExecution() throws {
        let tool = Tool(
            name: "t", description: nil, inputSchema: [:], execution: .init(taskSupport: .required))
        let value = try encoded(tool)
        #expect(value.objectValue?["execution"] == ["taskSupport": "required"])
        #expect(try JSONDecoder().decode(Tool.self, from: JSONEncoder().encode(tool)) == tool)
        #expect(try decoded(Tool.self, #"{"name":"t","inputSchema":{},"execution":"bad"}"#).execution == nil)
        #expect(Tool(name: "u", description: nil, inputSchema: [:]).taskSupport == .forbidden)

        let params = CallTool.Parameters(name: "t", task: .init(ttl: 5000))
        #expect(try encoded(params).objectValue?["task"] == ["ttl": 5000])
        #expect(try decoded(CallTool.Parameters.self, #"{"name":"t","task":{"ttl":-4}}"#).task == TaskMetadata())
    }

    @Test("Profiles: tasks are core at 2025-11-25 and an extension at 2026-07-28")
    func profiles() {
        #expect(Version.profile(for: Version.v2025_06_18).taskGeneration == nil)
        #expect(Version.profile(for: Version.v2025_11_25).taskGeneration == .v1)
        #expect(Version.profile(for: Version.v2025_11_25).usesTaskAugmentation)
        #expect(Version.profile(for: Version.v2026_07_28).taskGeneration == .v2)
        #expect(Version.profile(for: Version.v2026_07_28).usesTasksExtension)
        #expect(!Version.profile(for: Version.v2026_07_28).usesTaskAugmentation)
    }

    @Test("Timestamps, identifiers and durations")
    func helpers() {
        #expect(TaskTimestamp.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(TaskTimestamp.date(from: "2026-09-21T14:13:20.250Z") == created)
        #expect(TaskTimestamp.date(from: "2026-09-21T14:13:20Z") != nil)
        #expect(TaskTimestamp.date(from: "yesterday") == nil)
        let ids = Set((0..<100).map { _ in TaskIdentifier.make() })
        #expect(ids.count == 100)
        #expect(ids.allSatisfy { $0.count == 22 && !$0.contains("+") && !$0.contains("/") && !$0.contains("=") })
        #expect(Duration.milliseconds(1500).wholeMilliseconds == 1500)
        #expect(Duration.microseconds(1).wholeMilliseconds == 1)
        #expect(Duration.zero.wholeMilliseconds == 0)
    }

    @Test("Mcp-Name carries the task id of tasks/get, tasks/update and tasks/cancel")
    func nameHeader() {
        for method in [GetTask.name, UpdateTask.name, CancelTask.name] {
            #expect(MCPRequestHeaders.nameValue(method: method, params: ["taskId": "abc"]) == "abc")
        }
        #expect(MCPRequestHeaders.nameValue(method: GetTaskPayload.name, params: ["taskId": "abc"]) == nil)
        #expect(MCPRequestHeaders.nameValue(method: GetTask.name, params: [:]) == nil)
    }

    @Test("related-task metadata")
    func relatedTask() {
        var meta = Metadata()
        meta.relatedTaskID = "t9"
        #expect(meta[MetaKey.relatedTask] == ["taskId": "t9"])
        #expect(meta.relatedTaskID == "t9")
    }
}

// MARK: - Server at 2026-07-28

private let tasksCapabilities: Value = ["elicitation": [:], "extensions": [ExtensionID.tasks: [:]]]

private func message(id: Int, method: String, params: [String: Value] = [:], capabilities: Value) -> String {
    var params = params
    var meta = params["_meta"]?.objectValue ?? [:]
    meta[MetaKey.protocolVersion] = .string(Version.v2026_07_28)
    meta[MetaKey.clientCapabilities] = capabilities
    params["_meta"] = .object(meta)
    let value: Value = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)]
    return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A server with the task tools of ``TaskServer``.
private func makeTaskServer(
    manager: TaskManager, cancelled: Flag = Flag(), ran: Counter = Counter(),
    versions: [String] = Version.stateless + Version.handshake
) async -> Server {
    let server = Server(
        name: "tasks", version: "1", capabilities: .init(tools: .init()),
        configuration: .init(protocolVersions: versions))
    await server.withTasks(manager)
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: TaskServer.tools) }
    await server.withMethodHandler(CallTool.self) { params in
        let seconds = params.arguments?["seconds"]?.intValue ?? 0
        switch params.name {
        case "sync":
            return .init(content: [.text(text: "sync")])
        case "ask":
            return try await Server.runAsTask { task in
                let answer = try await task.elicit(message: "Name?")
                return .init(content: [.text(text: answer.content?["name"]?.stringValue ?? "?")])
            }
        case "askTwice":
            return try await Server.runAsTask { task in
                let first = try await task.requestInput(["q": .elicitation(message: "One?")])
                let second = try await task.requestInput(["q": .elicitation(message: "Two?")])
                let names = [first["q"], second["q"]].map { $0?.elicitation?.content?["name"]?.stringValue ?? "?" }
                return .init(content: [.text(text: names.joined(separator: ","))])
            }
        case "toolError":
            return try await Server.runAsTask { _ in .init(content: [.text(text: "bad")], isError: true) }
        case "lateAnswer":
            let created = try await Server.runAsTask { _ in
                await ran.increment()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await cancelled.set()
                    throw error
                }
                return .init(content: [.text(text: "late")])
            }
            // Still answering when the client gives up.
            let deadline = ContinuousClock.now + .milliseconds(300)
            while ContinuousClock.now < deadline { await Task.yield() }
            return created
        case "giveUp":
            return try await Server.runAsTask { task in
                let ask = Task { try await task.requestInput(["q": .elicitation(message: "Anyone?")]) }
                try await Task.sleep(for: .milliseconds(150))
                ask.cancel()
                _ = await ask.result
                try await Task.sleep(for: .milliseconds(150))
                return .init(content: [.text(text: "gave up")])
            }
        case "progress":
            return try await Server.runAsTask { task in
                try await Task.sleep(for: .milliseconds(20))
                try await task.reportProgress(1, total: 2, message: "half")
                return .init(content: [.text(text: "done")])
            }
        case "protocolError":
            return try await Server.runAsTask { _ in throw MCPError.invalidParams("nope") }
        case "plainError":
            struct Plain: Error {}
            return try await Server.runAsTask { _ in throw Plain() }
        default:
            return try await Server.runAsTask(ttl: params.arguments?["ttlMs"]?.intValue.map { .milliseconds($0) }) {
                task in
                await ran.increment()
                do {
                    try await Task.sleep(for: .milliseconds(seconds * 1000))
                } catch {
                    await cancelled.set()
                    throw error
                }
                return .init(content: [.text(text: task.isTask ? "task" : "inline")])
            }
        }
    }
    return server
}

/// A server with task tools, driven by raw JSON-RPC.
private struct TaskServer {
    let wire: WireExchange
    let cancelled = Flag()
    let ran = Counter()
    private let ids = Counter()

    static let tools: [Tool] = [
        Tool(name: "sync", description: nil, inputSchema: [:]),
        Tool(name: "slow", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "must", description: nil, inputSchema: [:], execution: .init(taskSupport: .required)),
        Tool(name: "ask", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "askTwice", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "toolError", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "protocolError", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "plainError", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "forbidden", description: nil, inputSchema: [:], execution: .init(taskSupport: .forbidden)),
        Tool(name: "progress", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "giveUp", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
        Tool(name: "lateAnswer", description: nil, inputSchema: [:], execution: .init(taskSupport: .optional)),
    ]

    init(manager: TaskManager = TaskManager()) async throws {
        let server = await makeTaskServer(manager: manager, cancelled: cancelled, ran: ran)
        wire = WireExchange(server: server)
        try await wire.start()
    }

    /// Sends a request and returns its response.
    func request(
        _ method: String, _ params: [String: Value] = [:], capabilities: Value = tasksCapabilities
    ) async throws -> Value {
        await ids.increment()
        let id = await ids.value
        let replies = try await wire.send(message(id: id, method: method, params: params, capabilities: capabilities))
        return try #require(replies.first { $0.objectValue?["id"] == .int(id) })
    }

    func result(
        _ method: String, _ params: [String: Value] = [:], capabilities: Value = tasksCapabilities,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [String: Value] {
        let reply = try await request(method, params, capabilities: capabilities)
        return try #require(reply.objectValue?["result"]?.objectValue, "\(reply)", sourceLocation: sourceLocation)
    }

    func errorCode(_ method: String, _ params: [String: Value] = [:], capabilities: Value = tasksCapabilities)
        async throws -> Int?
    {
        try await request(method, params, capabilities: capabilities).objectValue?["error"]?.objectValue?["code"]?
            .intValue
    }

    func call(_ tool: String, _ arguments: [String: Value] = [:], capabilities: Value = tasksCapabilities)
        async throws -> [String: Value]
    {
        try await result(CallTool.name, ["name": .string(tool), "arguments": .object(arguments)], capabilities: capabilities)
    }

    func get(_ id: String) async throws -> [String: Value] {
        try await result(GetTask.name, ["taskId": .string(id)])
    }

    /// Polls `tasks/get` until the task's status is `status` or terminal.
    func wait(_ id: String, for status: String? = nil) async throws -> [String: Value] {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            let task = try await get(id)
            let current = task["status"]?.stringValue ?? ""
            if current == status || TaskStatus(rawValue: current).isTerminal || ContinuousClock.now > deadline {
                return task
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() async { await wire.stop() }
}

@Suite("Tasks at 2026-07-28")
struct StatelessTaskServerTests {
    @Test("server/discover declares the extension and not the 2025-11-25 slot")
    func discover() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let result = try await server.result(ServerDiscover.name)
        let capabilities = result["capabilities"]?.objectValue
        #expect(capabilities?["extensions"]?.objectValue?[ExtensionID.tasks] == [:])
        #expect(capabilities?["tasks"] == nil)
    }

    @Test("A task tool runs inline for a client that did not declare the extension")
    func undeclaredRunsInline() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let result = try await server.call("slow", capabilities: [:])
        #expect(result["resultType"] == "complete")
        #expect(result["taskId"] == nil)
        #expect(result["content"] == [["type": "text", "text": "inline"]])
    }

    @Test("A task: created flat, readable at once, completed with the result inlined")
    func lifecycle() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let created = try await server.call("slow")
        #expect(created["resultType"] == "task")
        let id = try #require(created["taskId"]?.stringValue)
        #expect(created["status"] == "working")
        #expect(created["ttlMs"]?.intValue == 3_600_000)
        #expect(created["pollIntervalMs"]?.intValue == 1000)
        for absent in ["task", "result", "error", "inputRequests", "requestState", "content", "ttl", "pollInterval"] {
            #expect(created[absent] == nil, "\(absent)")
        }

        let done = try await server.wait(id)
        #expect(done["status"] == "completed")
        #expect(done["resultType"] == "complete")
        let result = try #require(done["result"]?.objectValue)
        #expect(result["content"] == [["type": "text", "text": "task"]])
        #expect(result["resultType"] == "complete")
        #expect(result["_meta"]?.objectValue?[MetaKey.relatedTask] == nil)
        #expect(await server.ran.value == 1)
    }

    @Test("A sync tool never becomes a task, even with a legacy task hint")
    func syncTool() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let result = try await server.result(
            CallTool.name, ["name": "sync", "task": ["ttl": 60000, "pollInterval": 100]])
        #expect(result["resultType"] == "complete")
        #expect(result["content"] == [["type": "text", "text": "sync"]])
        let forbidden = try await server.call("forbidden")
        #expect(forbidden["resultType"] == "complete")
    }

    @Test("A required tool refuses an undeclared client with -32021 before its handler runs")
    func requiredTool() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let reply = try await server.request(CallTool.name, ["name": "must"], capabilities: [:])
        let error = try #require(reply.objectValue?["error"]?.objectValue)
        #expect(error["code"] == -32021)
        #expect(
            error["data"]?.objectValue?["requiredCapabilities"]?.objectValue?["extensions"]?.objectValue?[
                ExtensionID.tasks] == [:])
        #expect(await server.ran.value == 0)
        let created = try await server.call("must")
        #expect(created["resultType"] == "task")
    }

    @Test("Task methods need the extension: -32021 before the task is looked up")
    func gatedMethods() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        for (method, params) in [
            (GetTask.name, ["taskId": "nope"]), (UpdateTask.name, ["taskId": "nope", "inputResponses": [:]]),
            (CancelTask.name, ["taskId": "nope"]),
        ] as [(String, [String: Value])] {
            #expect(try await server.errorCode(method, params, capabilities: [:]) == -32021, "\(method)")
            #expect(try await server.errorCode(method, params) == -32602, "\(method)")
        }
    }

    @Test("tasks/result and tasks/list do not exist at 2026-07-28")
    func removedMethods() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        #expect(try await server.errorCode(GetTaskPayload.name, ["taskId": "x"]) == -32601)
        #expect(try await server.errorCode(ListTasks.name) == -32601)
    }

    @Test("tools/list omits execution at 2026-07-28")
    func listStripsExecution() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let tools = try await server.result(ListTools.name)["tools"]?.arrayValue ?? []
        #expect(tools.count == TaskServer.tools.count)
        #expect(tools.allSatisfy { $0.objectValue?["execution"] == nil })
    }

    @Test("Cancel acknowledges, cancels the work, and acknowledges again once terminal")
    func cancel() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.call("slow", ["seconds": 30])["taskId"]?.stringValue)
        let ack = try await server.result(CancelTask.name, ["taskId": .string(id)])
        #expect(ack["resultType"] == "complete")
        #expect(Set(ack.keys).isSubset(of: ["resultType", "_meta"]))
        #expect(try await server.get(id)["status"] == "cancelled")
        let deadline = ContinuousClock.now + .seconds(2)
        while await !server.cancelled.isSet, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await server.cancelled.isSet)
        let again = try await server.result(CancelTask.name, ["taskId": .string(id)])
        #expect(again["resultType"] == "complete")
        #expect(try await server.get(id)["status"] == "cancelled")
    }

    @Test("Outcomes: a tool error completes, a protocol error fails, other errors fail with -32603")
    func outcomes() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let toolError = try await server.wait(try #require(try await server.call("toolError")["taskId"]?.stringValue))
        #expect(toolError["status"] == "completed")
        #expect(toolError["result"]?.objectValue?["isError"] == true)

        let protocolError = try await server.wait(
            try #require(try await server.call("protocolError")["taskId"]?.stringValue))
        #expect(protocolError["status"] == "failed")
        #expect(protocolError["error"]?.objectValue?["code"] == -32602)
        #expect(protocolError["result"] == nil)

        let plain = try await server.wait(try #require(try await server.call("plainError")["taskId"]?.stringValue))
        #expect(plain["status"] == "failed")
        #expect(plain["error"]?.objectValue?["code"] == -32603)
    }

    @Test("Input: reported on tasks/get, answered with tasks/update, then resumed")
    func input() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.call("ask")["taskId"]?.stringValue)
        let waiting = try await server.wait(id, for: "input_required")
        #expect(waiting["status"] == "input_required")
        let requests = try #require(waiting["inputRequests"]?.objectValue)
        let key = try #require(requests.keys.first)
        #expect(requests[key]?.objectValue?["method"] == "elicitation/create")

        // Unknown keys are ignored; a response of the wrong kind is refused.
        let ignored = try await server.result(
            UpdateTask.name, ["taskId": .string(id), "inputResponses": ["other": ["ignored": true]]])
        #expect(ignored["resultType"] == "complete")
        #expect(try await server.get(id)["status"] == "input_required")
        #expect(
            try await server.errorCode(
                UpdateTask.name, ["taskId": .string(id), "inputResponses": [key: ["roots": []]]]) == -32602)

        let ack = try await server.result(
            UpdateTask.name,
            ["taskId": .string(id), "inputResponses": [key: ["action": "accept", "content": ["name": "Ada"]]]])
        #expect(ack["resultType"] == "complete")
        #expect(ack["status"] == nil)
        let done = try await server.wait(id)
        #expect(done["status"] == "completed")
        #expect(done["result"]?.objectValue?["content"] == [["type": "text", "text": "Ada"]])
    }

    @Test("Input keys stay unique for the life of the task")
    func inputKeys() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.call("askTwice")["taskId"]?.stringValue)
        var keys: [String] = []
        for name in ["A", "B"] {
            var waiting = try await server.wait(id, for: "input_required")
            // The status changes before the second request is recorded.
            while waiting["inputRequests"]?.objectValue?.keys.first.map({ !keys.contains($0) }) != true {
                try await Task.sleep(for: .milliseconds(5))
                waiting = try await server.get(id)
            }
            let key = try #require(waiting["inputRequests"]?.objectValue?.keys.first)
            keys.append(key)
            _ = try await server.result(
                UpdateTask.name,
                ["taskId": .string(id), "inputResponses": [key: ["action": "accept", "content": ["name": .string(name)]]]])
        }
        #expect(keys == ["q", "q#2"])
        let done = try await server.wait(id)
        #expect(done["result"]?.objectValue?["content"] == [["type": "text", "text": "A,B"]])
    }

    @Test("Input the client cannot answer fails the task with -32021")
    func inputWithoutCapability() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let capabilities: Value = ["extensions": [ExtensionID.tasks: [:]]]
        let id = try #require(try await server.call("ask", capabilities: capabilities)["taskId"]?.stringValue)
        let done = try await server.wait(id)
        #expect(done["status"] == "failed")
        #expect(done["error"]?.objectValue?["code"] == -32021)
    }

    @Test("Run inline, work cannot ask for input at 2026-07-28")
    func inlineInput() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let reply = try await server.request(
            CallTool.name, ["name": "ask"], capabilities: ["elicitation": [:]])
        #expect(reply.objectValue?["error"]?.objectValue?["code"] == -32021)
    }

    @Test("A task lives for its ttlMs and is gone after it")
    func expiry() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let created = try await server.call("slow", ["ttlMs": 100])
        let id = try #require(created["taskId"]?.stringValue)
        #expect(created["ttlMs"] == 100)
        #expect(try await server.get(id)["taskId"] == .string(id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await server.errorCode(GetTask.name, ["taskId": .string(id)]) == -32602)
    }

    @Test("A call cancelled after it created its task cancels the task, and gets no answer")
    func cancelledCreation() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let call = message(id: 77, method: CallTool.name, params: ["name": "lateAnswer"], capabilities: tasksCapabilities)
        try await server.wire.send(call, expecting: 0)
        let deadline = ContinuousClock.now + .seconds(2)
        while await server.ran.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await server.wire.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":77}}"#, expecting: 0)
        while await !server.cancelled.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await server.cancelled.isSet)
        try await Task.sleep(for: .milliseconds(400))
        let answer = try await sentMessage(server.wire, timeout: .milliseconds(50)) { $0.objectValue?["id"] == 77 }
        #expect(answer == nil)
    }

    @Test("Input the work stops waiting for is withdrawn from the task")
    func withdrawnInput() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.call("giveUp")["taskId"]?.stringValue)
        let waiting = try await server.wait(id, for: "input_required")
        #expect(waiting["inputRequests"]?.objectValue?.keys.sorted() == ["q"])
        var later = try await server.get(id)
        let deadline = ContinuousClock.now + .seconds(2)
        while later["status"] == "input_required", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            later = try await server.get(id)
        }
        #expect(later["status"] != "input_required")
        #expect(later["inputRequests"] == nil)
        let done = try await server.wait(id)
        #expect(done["result"]?.objectValue?["content"] == [["type": "text", "text": "gave up"]])
    }

    @Test("Work handed to another system: complete(_:with:) finishes the task and ends the work")
    func externalCompletion() async throws {
        let manager = TaskManager()
        let ended = Flag()
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withTasks(manager)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "job", description: nil, inputSchema: [:], execution: .init(taskSupport: .required))])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            try await Server.runAsTask { task in
                do {
                    return try await task.untilFinished()
                } catch {
                    await ended.set()
                    throw error
                }
            }
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }
        let created = try await wire.send(
            message(id: 1, method: CallTool.name, params: ["name": "job"], capabilities: tasksCapabilities))
        let id = try #require(created.first?.objectValue?["result"]?.objectValue?["taskId"]?.stringValue)
        try await manager.complete(id, with: .init(content: [.text(text: "from the job")]))
        let got = try await wire.send(
            message(id: 2, method: GetTask.name, params: ["taskId": .string(id)], capabilities: tasksCapabilities))
        let task = try #require(got.first?.objectValue?["result"]?.objectValue)
        #expect(task["status"] == "completed")
        #expect(task["result"]?.objectValue?["content"] == [["type": "text", "text": "from the job"]])
        let deadline = ContinuousClock.now + .seconds(2)
        while await !ended.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await ended.isSet)
        try await manager.fail(id, with: .internalError("late"))
        #expect(try await manager.record(id: id)?.status == .completed)
    }

    @Test("A failed task says why in its status message")
    func failureMessage() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let done = try await server.wait(try #require(try await server.call("protocolError")["taskId"]?.stringValue))
        #expect(done["statusMessage"]?.stringValue?.contains("nope") == true)
    }

    @Test("Without a principal hook only the overall limit applies")
    func noPrincipalLimit() async throws {
        let manager = TaskManager(configuration: .init(maxActiveTasks: 3, maxActiveTasksPerPrincipal: 1))
        let server = try await TaskServer(manager: manager)
        defer { Task { await server.stop() } }
        for _ in 0..<3 {
            #expect(try await server.call("slow", ["seconds": 30])["resultType"] == "task")
        }
        #expect(try await server.call("slow")["content"] == [["type": "text", "text": "inline"]])

        let bound = TaskManager(configuration: .init(maxActiveTasksPerPrincipal: 1)) { _ in "one" }
        let other = try await TaskServer(manager: bound)
        defer { Task { await other.stop() } }
        #expect(try await other.call("slow", ["seconds": 30])["resultType"] == "task")
        #expect(try await other.call("slow")["content"] == [["type": "text", "text": "inline"]])
    }

    @Test("The maximum TTL shortens a longer one")
    func maximumTTL() async throws {
        let server = try await TaskServer(manager: TaskManager(configuration: .init(maximumTTL: .seconds(2))))
        defer { Task { await server.stop() } }
        #expect(try await server.call("slow")["ttlMs"] == 2000)
    }

    @Test("At the task limit an optional tool runs inline and a required one fails")
    func capacity() async throws {
        let manager = TaskManager(configuration: .init(maxActiveTasks: 1))
        let server = try await TaskServer(manager: manager)
        defer { Task { await server.stop() } }
        let first = try await server.call("slow", ["seconds": 30])
        #expect(first["resultType"] == "task")
        #expect(try await server.call("slow")["content"] == [["type": "text", "text": "inline"]])
        #expect(try await server.errorCode(CallTool.name, ["name": "must"]) == -32603)
        _ = try await server.result(CancelTask.name, ["taskId": try #require(first["taskId"])])
        #expect(try await server.call("slow")["resultType"] == "task")
    }

    @Test("With a principal, another caller cannot see the task")
    func principal() async throws {
        let manager = TaskManager { context in context.clientInfo?.name }
        let server = try await TaskServer(manager: manager)
        defer { Task { await server.stop() } }
        func meta(_ name: String) -> [String: Value] {
            ["_meta": [MetaKey.clientInfo: ["name": .string(name), "version": "1"]]]
        }
        var params = meta("alice")
        params["name"] = "slow"
        let id = try #require(try await server.result(CallTool.name, params)["taskId"])
        var get = meta("alice")
        get["taskId"] = id
        #expect(try await server.result(GetTask.name, get)["taskId"] == id)
        get = meta("mallory")
        get["taskId"] = id
        #expect(try await server.errorCode(GetTask.name, get) == -32602)
        #expect(try await server.errorCode(CancelTask.name, get) == -32602)
        #expect(try await manager.record(id: try #require(id.stringValue))?.owner == "alice")
    }

    @Test("A handler-registered task method is not replaced by withTasks")
    func applicationHandlerWins() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(GetTask.self) { params in
            TaskSnapshot(taskId: params.taskId, status: .completed, createdAt: "c", lastUpdatedAt: "c")
        }
        await server.withTasks()
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }
        let reply = try await wire.send(
            message(id: 1, method: GetTask.name, params: ["taskId": "mine"], capabilities: tasksCapabilities))
        #expect(reply.first?.objectValue?["result"]?.objectValue?["status"] == "completed")
    }

    @Test("A server without withTasks answers task methods with -32601")
    func withoutTasks() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }
        let reply = try await wire.send(
            message(id: 1, method: GetTask.name, params: ["taskId": "x"], capabilities: tasksCapabilities))
        #expect(reply.first?.objectValue?["error"]?.objectValue?["code"] == -32601)
        let discover = try await wire.send(message(id: 2, method: ServerDiscover.name, capabilities: [:]))
        #expect(
            discover.first?.objectValue?["result"]?.objectValue?["capabilities"]?.objectValue?["extensions"] == nil)
    }

    @Test("An input-required round may end in a task")
    func roundTripThenTask() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withTasks()
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "t", description: nil, inputSchema: [:], execution: .init(taskSupport: .required))])
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard let name = params.inputResponses?["n"]?.elicitation?.content?["name"]?.stringValue else {
                return .inputRequired(["n": .elicitation(message: "Name?")])
            }
            return try await Server.runAsTask { _ in .init(content: [.text(text: "Hello, \(name)")]) }
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }
        let first = try await wire.send(message(id: 1, method: CallTool.name, params: ["name": "t"], capabilities: tasksCapabilities))
        let round = try #require(first.first?.objectValue?["result"]?.objectValue)
        #expect(round["resultType"] == "input_required")
        #expect(round["taskId"] == nil)
        let second = try await wire.send(
            message(
                id: 2, method: CallTool.name,
                params: ["name": "t", "inputResponses": ["n": ["action": "accept", "content": ["name": "Bo"]]]],
                capabilities: tasksCapabilities))
        let task = try #require(second.first?.objectValue?["result"]?.objectValue)
        #expect(task["resultType"] == "task")
        #expect(task["requestState"] == nil)
    }
}

@Suite("Tasks over HTTP at 2026-07-28")
struct StatelessHTTPTaskTests {
    private func request(_ body: String, name: String?) -> HTTPRequest {
        var headers = [
            "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": Version.v2026_07_28,
        ]
        if let method = (try? JSONDecoder().decode(Value.self, from: Data(body.utf8)))?.objectValue?["method"]?.stringValue {
            headers[MCPRequestHeaders.method] = method
        }
        if let name { headers[MCPRequestHeaders.name] = name }
        return HTTPRequest(method: "POST", headers: headers, body: Data(body.utf8), path: "/mcp")
    }

    @Test("Mcp-Name must carry the task id")
    func nameHeader() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withTasks()
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }
        let body = message(id: 1, method: GetTask.name, params: ["taskId": "abc"], capabilities: tasksCapabilities)

        let matching = await transport.handleRequest(request(body, name: "abc"))
        #expect(matching.statusCode == 400)
        let unknown = try JSONDecoder().decode(Value.self, from: #require(matching.bodyData))
        #expect(unknown.objectValue?["error"]?.objectValue?["code"] == -32602)

        for name in ["other", nil] as [String?] {
            let response = await transport.handleRequest(request(body, name: name))
            let value = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
            #expect(response.statusCode == 400)
            #expect(value.objectValue?["error"]?.objectValue?["code"] == -32020, "\(name ?? "missing")")
        }
    }
}

// MARK: - Client at 2026-07-28

private actor Answers {
    private(set) var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}

/// A connected client and server of the task tools.
private func connectTaskClient(
    manager: TaskManager = TaskManager(configuration: .init(pollInterval: .milliseconds(10))),
    tasks: Client.Configuration.Tasks? = .init(minimumPollInterval: .milliseconds(5)),
    cancelled: Flag = Flag(),
    elicit: (@Sendable (String) async throws -> CreateElicitation.Result)? = nil
) async throws -> (Client, Server) {
    let server = await makeTaskServer(manager: manager, cancelled: cancelled)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(
        name: "c", version: "1",
        capabilities: .init(elicitation: elicit == nil ? nil : .init()),
        configuration: .init(protocolMode: .stateless(Version.v2026_07_28), tasks: tasks))
    if let elicit {
        await client.withElicitationHandler { params in
            guard case .form(let form) = params else { return .init(action: .decline) }
            return try await elicit(form.message)
        }
    }
    try await client.connect(transport: clientTransport)
    return (client, server)
}

private func text(_ result: CallTool.Result) -> String? {
    if case .text(let text, _, _)? = result.content.first { return text }
    return nil
}

@Suite("Client tasks at 2026-07-28")
struct ClientTaskTests {
    @Test("With tasks configured, callTool declares the extension and drives the task")
    func drivesTask() async throws {
        let (client, server) = try await connectTaskClient()
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(text(try await client.callTool(name: "slow")) == "task")
        #expect(text(try await client.callTool(name: "sync")) == "sync")
    }

    @Test("Without tasks configured, the server runs the work inline")
    func inlineWithoutConfiguration() async throws {
        let (client, server) = try await connectTaskClient(tasks: nil)
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(text(try await client.callTool(name: "slow")) == "inline")
        await #expect(throws: MCPError.self) { try await client.callTool(name: "must") }
    }

    @Test("Input requests are answered with the client's handlers")
    func answersInput() async throws {
        let answers = Answers()
        let (client, server) = try await connectTaskClient { message in
            await answers.record(message)
            let name = message == "Two?" ? "B" : message == "One?" ? "A" : "Ada"
            return .init(action: .accept, content: ["name": .string(name)])
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(text(try await client.callTool(name: "ask")) == "Ada")
        #expect(text(try await client.callTool(name: "askTwice")) == "A,B")
        #expect(await answers.messages == ["Name?", "One?", "Two?"])
    }

    @Test("Outcomes: a tool error is returned, a protocol error is thrown")
    func outcomes() async throws {
        let (client, server) = try await connectTaskClient()
        defer { Task { await client.disconnect(); await server.stop() } }
        let toolError = try await client.callTool(name: "toolError")
        #expect(toolError.isError == true)
        #expect(text(toolError) == "bad")
        do {
            _ = try await client.callTool(name: "protocolError")
            Issue.record("Expected an error")
        } catch let error as MCPError {
            #expect(error.code == -32602)
        }
    }

    @Test("A task cancelled on the server throws TaskCancelledError")
    func cancelledOnServer() async throws {
        let manager = TaskManager(configuration: .init(pollInterval: .milliseconds(10)))
        let (client, server) = try await connectTaskClient(manager: manager)
        defer { Task { await client.disconnect(); await server.stop() } }
        let created = try await client.startToolCall(name: "slow", arguments: ["seconds": 30]).value
        let task = try #require(created.task)
        #expect(created.resultType == .task)
        let handle = client.task(task)
        #expect(try await handle.snapshot().status == .working)
        try await manager.cancel(task.taskId)
        await #expect(throws: TaskCancelledError(taskID: task.taskId, statusMessage: "The task was cancelled")) {
            try await handle.result()
        }
    }

    @Test("A throwing input handler cancels the task")
    func handlerFailureCancels() async throws {
        struct Refused: Error {}
        let manager = TaskManager(configuration: .init(pollInterval: .milliseconds(10)))
        let (client, server) = try await connectTaskClient(manager: manager) { _ in throw Refused() }
        defer { Task { await client.disconnect(); await server.stop() } }
        let created = try await client.startToolCall(name: "ask").value
        let id = try #require(created.task?.taskId)
        await #expect(throws: (any Error).self) { try await client.task(id: id).result() }
        let deadline = ContinuousClock.now + .seconds(2)
        while try await manager.record(id: id)?.status != .cancelled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await manager.record(id: id)?.status == .cancelled)
    }

    @Test("Cancelling the caller cancels the task on the server")
    func callerCancellation() async throws {
        let cancelled = Flag()
        let (client, server) = try await connectTaskClient(cancelled: cancelled)
        defer { Task { await client.disconnect(); await server.stop() } }
        let call = Task { try await client.callTool(name: "slow", arguments: ["seconds": 30]) }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()
        _ = await call.result
        let deadline = ContinuousClock.now + .seconds(2)
        while await !cancelled.isSet, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cancelled.isSet)
    }

    @Test("cancelTask acknowledges at 2026-07-28 and the task reads as cancelled")
    func cancelTask() async throws {
        let (client, server) = try await connectTaskClient()
        defer { Task { await client.disconnect(); await server.stop() } }
        let created = try await client.startToolCall(name: "slow", arguments: ["seconds": 30]).value
        let id = try #require(created.task?.taskId)
        #expect(try await client.cancelTask(id) == nil)
        #expect(try await client.getTask(id).status == .cancelled)
        await #expect(throws: MCPError.self) { try await client.getTask("unknown") }
    }

    @Test("Poll intervals are kept within the configured bounds")
    func pollBounds() throws {
        let options = Client.Configuration.Tasks(
            minimumPollInterval: .milliseconds(100), maximumPollInterval: .seconds(2),
            defaultPollInterval: .milliseconds(700))
        #expect(options.pollInterval(suggested: 5) == .milliseconds(100))
        #expect(options.pollInterval(suggested: 60_000) == .seconds(2))
        #expect(options.pollInterval(suggested: nil) == .milliseconds(700))
        #expect(options.pollInterval(suggested: 250) == .milliseconds(250))

        let configuration = Client.Configuration(tasks: options)
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(Client.Configuration.self, from: data) == configuration)
        let old = try JSONDecoder().decode(Client.Configuration.self, from: Data(#"{"strict":false}"#.utf8))
        #expect(old.tasks == nil)
        let partial = try JSONDecoder().decode(Client.Configuration.Tasks.self, from: Data("{}".utf8))
        #expect(partial == .init())
    }
}

// MARK: - Server at 2025-11-25

private func handshakeMessage(id: Int, method: String, params: [String: Value] = [:]) -> String {
    let value: Value = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)]
    return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

/// A task server driven by raw JSON-RPC over an `initialize` session.
private struct HandshakeTaskServer {
    let wire: WireExchange
    let cancelled = Flag()
    let initializeResult: [String: Value]
    private let ids = Counter()

    init(
        manager: TaskManager = TaskManager(
            configuration: .init(pollInterval: .milliseconds(10), sendsStatusNotifications: false)),
        version: String = Version.v2025_11_25, capabilities: Value = ["elicitation": [:]]
    ) async throws {
        let server = await makeTaskServer(manager: manager, cancelled: cancelled)
        wire = WireExchange(server: server)
        try await wire.start()
        let reply = try await wire.send(
            handshakeMessage(
                id: 0, method: Initialize.name,
                params: [
                    "protocolVersion": .string(version), "capabilities": capabilities,
                    "clientInfo": ["name": "c", "version": "1"],
                ]))
        initializeResult = reply.first?.objectValue?["result"]?.objectValue ?? [:]
        try await wire.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, expecting: 0)
    }

    func nextID() async -> Int {
        await ids.increment()
        return await ids.value
    }

    /// Sends a request and returns every message up to its response.
    func exchange(_ method: String, _ params: [String: Value] = [:], expecting count: Int = 1) async throws
        -> (id: Int, messages: [Value])
    {
        let id = await nextID()
        return (id, try await wire.send(handshakeMessage(id: id, method: method, params: params), expecting: count))
    }

    /// Sends a request and returns its response, skipping notifications.
    func request(_ method: String, _ params: [String: Value] = [:]) async throws -> Value {
        let (id, messages) = try await exchange(method, params)
        if let reply = messages.first(where: { $0.objectValue?["id"] == .int(id) }) { return reply }
        let reply = try await sentMessage(wire) { $0.objectValue?["id"] == .int(id) && $0.objectValue?["method"] == nil }
        return try #require(reply)
    }

    func result(_ method: String, _ params: [String: Value] = [:]) async throws -> [String: Value] {
        let reply = try await request(method, params)
        return try #require(reply.objectValue?["result"]?.objectValue, "\(reply)")
    }

    func errorCode(_ method: String, _ params: [String: Value] = [:]) async throws -> Int? {
        try await request(method, params).objectValue?["error"]?.objectValue?["code"]?.intValue
    }

    /// Calls a tool with `task`, and returns the task.
    func create(_ tool: String, _ arguments: [String: Value] = [:], ttl: Int? = nil) async throws -> [String: Value] {
        var task: [String: Value] = [:]
        if let ttl { task["ttl"] = .int(ttl) }
        let result = try await self.result(
            CallTool.name, ["name": .string(tool), "arguments": .object(arguments), "task": .object(task)])
        return try #require(result["task"]?.objectValue, "\(result)")
    }

    func wait(_ id: Value, for status: String? = nil) async throws -> [String: Value] {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            let task = try await result(GetTask.name, ["taskId": id])
            let current = task["status"]?.stringValue ?? ""
            if current == status || TaskStatus(rawValue: current).isTerminal || ContinuousClock.now > deadline {
                return task
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() async { await wire.stop() }
}

@Suite("Tasks at 2025-11-25")
struct HandshakeTaskServerTests {
    @Test("initialize declares the tasks capability; list only with a principal")
    func capabilities() async throws {
        let plain = try await HandshakeTaskServer()
        defer { Task { await plain.stop() } }
        let tasks = plain.initializeResult["capabilities"]?.objectValue?["tasks"]
        #expect(tasks == ["cancel": [:], "requests": ["tools": ["call": [:]]]])
        #expect(plain.initializeResult["capabilities"]?.objectValue?["extensions"] == nil)

        let bound = try await HandshakeTaskServer(manager: TaskManager { _ in "me" })
        defer { Task { await bound.stop() } }
        #expect(bound.initializeResult["capabilities"]?.objectValue?["tasks"]?.objectValue?["list"] == [:])

        let old = try await HandshakeTaskServer(version: Version.v2025_06_18)
        defer { Task { await old.stop() } }
        #expect(old.initializeResult["capabilities"]?.objectValue?["tasks"] == nil)
        let tools = try await old.result(ListTools.name)["tools"]?.arrayValue ?? []
        #expect(tools.allSatisfy { $0.objectValue?["execution"] == nil })
    }

    @Test("tools/list carries execution at 2025-11-25")
    func listKeepsExecution() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let tools = try await server.result(ListTools.name)["tools"]?.arrayValue ?? []
        let slow = tools.first { $0.objectValue?["name"] == "slow" }
        #expect(slow?.objectValue?["execution"] == ["taskSupport": "optional"])
    }

    @Test("An augmented call creates a nested task; tasks/result returns the result with related-task")
    func lifecycle() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let task = try await server.create("slow", ttl: 60_000)
        #expect(task["status"] == "working")
        #expect(task["ttl"] == 60_000)
        #expect(task["pollInterval"] == 10)
        #expect(task["ttlMs"] == nil)
        let id = try #require(task["taskId"])

        let polled = try await server.result(GetTask.name, ["taskId": id])
        #expect(polled["taskId"] == id)
        #expect(polled["ttl"] == 60_000)
        #expect(polled["resultType"] == nil)

        let result = try await server.result(GetTaskPayload.name, ["taskId": id])
        #expect(result["content"] == [["type": "text", "text": "task"]])
        #expect(result["_meta"]?.objectValue?[MetaKey.relatedTask] == ["taskId": id])
        #expect(try await server.result(GetTask.name, ["taskId": id])["status"] == "completed")
    }

    @Test("Augmentation must match the tool: -32601 otherwise")
    func toolLevelNegotiation() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        for tool in ["sync", "forbidden"] {
            #expect(try await server.errorCode(CallTool.name, ["name": .string(tool), "task": [:]]) == -32601)
        }
        #expect(try await server.errorCode(CallTool.name, ["name": "must"]) == -32601)
        let inline = try await server.result(CallTool.name, ["name": "slow"])
        #expect(inline["content"] == [["type": "text", "text": "inline"]])
        #expect(inline["task"] == nil)
    }

    @Test("A tool error fails the task; tasks/result returns the tool's result")
    func toolError() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("toolError")["taskId"])
        let result = try await server.result(GetTaskPayload.name, ["taskId": id])
        #expect(result["isError"] == true)
        #expect(try await server.result(GetTask.name, ["taskId": id])["status"] == "failed")
    }

    @Test("A protocol error: tasks/result returns the same JSON-RPC error")
    func protocolError() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("protocolError")["taskId"])
        #expect(try await server.errorCode(GetTaskPayload.name, ["taskId": id]) == -32602)
        #expect(try await server.wait(id)["status"] == "failed")
    }

    @Test("Cancel returns the cancelled task; a terminal task cannot be cancelled")
    func cancel() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("slow", ["seconds": 30])["taskId"])
        let cancelled = try await server.result(CancelTask.name, ["taskId": id])
        #expect(cancelled["status"] == "cancelled")
        #expect(cancelled["taskId"] == id)
        #expect(try await server.errorCode(CancelTask.name, ["taskId": id]) == -32602)
        #expect(try await server.errorCode(GetTaskPayload.name, ["taskId": id]) == -32603)
        #expect(try await server.errorCode(CancelTask.name, ["taskId": "nope"]) == -32602)
    }

    @Test("Input is sent on the tasks/result stream with related-task")
    func input() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("ask")["taskId"])
        #expect(try await server.wait(id, for: "input_required")["status"] == "input_required")

        let (resultID, messages) = try await server.exchange(GetTaskPayload.name, ["taskId": id])
        let elicitation = try #require(messages.first?.objectValue)
        #expect(elicitation["method"] == "elicitation/create")
        let params = try #require(elicitation["params"]?.objectValue)
        #expect(params["_meta"]?.objectValue?[MetaKey.relatedTask] == ["taskId": id])
        let requestID = try #require(elicitation["id"])

        let response: Value = [
            "jsonrpc": "2.0", "id": requestID, "result": ["action": "accept", "content": ["name": "Ada"]],
        ]
        let replies = try await server.wire.send(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
        let final = try #require(replies.first { $0.objectValue?["id"] == .int(resultID) }?.objectValue?["result"])
        #expect(final.objectValue?["content"] == [["type": "text", "text": "Ada"]])
        #expect(final.objectValue?["_meta"]?.objectValue?[MetaKey.relatedTask] == ["taskId": id])
    }

    @Test("Cancelling a task withdraws the input requests tasks/result sent, and tasks/result ends")
    func cancelWhileDelivering() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("ask")["taskId"])
        _ = try await server.wait(id, for: "input_required")
        let (resultID, messages) = try await server.exchange(GetTaskPayload.name, ["taskId": id])
        let requestID = try #require(messages.first?.objectValue?["id"])
        #expect(try await server.result(CancelTask.name, ["taskId": id])["status"] == "cancelled")
        let reply = try await sentMessage(server.wire) { $0.objectValue?["id"] == .int(resultID) }
        #expect(reply?.objectValue?["error"]?.objectValue?["code"] == -32603)
        let withdrawn = try await sentMessage(server.wire) {
            $0.objectValue?["method"] == "notifications/cancelled"
                && $0.objectValue?["params"]?.objectValue?["requestId"] == requestID
        }
        #expect(withdrawn != nil)
    }

    @Test("A client error answering input fails the task")
    func inputFailure() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("ask")["taskId"])
        _ = try await server.wait(id, for: "input_required")
        let (resultID, messages) = try await server.exchange(GetTaskPayload.name, ["taskId": id])
        let requestID = try #require(messages.first?.objectValue?["id"])
        let failure: Value = ["jsonrpc": "2.0", "id": requestID, "error": ["code": -32600, "message": "no"]]
        let replies = try await server.wire.send(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self))
        let reply = try #require(replies.first { $0.objectValue?["id"] == .int(resultID) })
        #expect(reply.objectValue?["error"]?.objectValue?["code"] == -32603)
        #expect(try await server.result(GetTask.name, ["taskId": id])["status"] == "failed")
    }

    @Test("tasks/list needs a principal, pages by cursor and shows only the caller's tasks")
    func list() async throws {
        let plain = try await HandshakeTaskServer()
        defer { Task { await plain.stop() } }
        #expect(try await plain.errorCode(ListTasks.name) == -32601)

        let server = try await HandshakeTaskServer(manager: TaskManager { context in context.clientInfo?.name })
        defer { Task { await server.stop() } }
        let first = try #require(try await server.create("slow")["taskId"])
        let second = try #require(try await server.create("slow")["taskId"])
        let listed = try await server.result(ListTasks.name)
        #expect(listed["tasks"]?.arrayValue?.compactMap { $0.objectValue?["taskId"] } == [first, second])
        #expect(listed["nextCursor"] == nil)
        #expect(try await server.errorCode(ListTasks.name, ["cursor": "bogus"]) == -32602)
    }

    @Test("tasks/update does not exist at 2025-11-25; a v1 task is not visible at 2026-07-28")
    func generations() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        #expect(try await server.errorCode(UpdateTask.name, ["taskId": "x", "inputResponses": [:]]) == -32601)
        let id = try #require(try await server.create("slow", ["seconds": 30])["taskId"])
        let stateless = try await server.wire.send(
            message(id: 900, method: GetTask.name, params: ["taskId": id], capabilities: tasksCapabilities))
        #expect(stateless.first?.objectValue?["error"]?.objectValue?["code"] == -32602)
    }

    @Test("Run inline on a handshake connection, work asks for input with server requests")
    func inlineBridge() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let (callID, messages) = try await server.exchange(CallTool.name, ["name": "ask"])
        let elicitation = try #require(messages.first?.objectValue)
        #expect(elicitation["method"] == "elicitation/create")
        #expect(elicitation["params"]?.objectValue?["_meta"]?.objectValue?[MetaKey.relatedTask] == nil)
        let response: Value = [
            "jsonrpc": "2.0", "id": try #require(elicitation["id"]),
            "result": ["action": "accept", "content": ["name": "Inline"]],
        ]
        let replies = try await server.wire.send(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
        let result = replies.first { $0.objectValue?["id"] == .int(callID) }?.objectValue?["result"]
        #expect(result?.objectValue?["content"] == [["type": "text", "text": "Inline"]])
    }

    @Test("Before 2025-11-25 a task hint is ignored and the work runs inline")
    func olderRevision() async throws {
        let server = try await HandshakeTaskServer(version: Version.v2025_06_18)
        defer { Task { await server.stop() } }
        let result = try await server.result(CallTool.name, ["name": "must", "task": [:]])
        #expect(result["content"] == [["type": "text", "text": "inline"]])
        #expect(try await server.errorCode(GetTask.name, ["taskId": "x"]) == -32601)
    }
}

// MARK: - Client at 2025-11-25

private func connectHandshakeClient(
    manager: TaskManager = TaskManager(configuration: .init(pollInterval: .milliseconds(10))),
    tasks: Client.Configuration.Tasks? = .init(minimumPollInterval: .milliseconds(5)),
    elicit: (@Sendable (String) async throws -> CreateElicitation.Result)? = nil
) async throws -> (Client, Server) {
    let server = await makeTaskServer(manager: manager)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(
        name: "c", version: "1",
        capabilities: .init(elicitation: elicit == nil ? nil : .init()),
        configuration: .init(protocolMode: .handshake, tasks: tasks))
    if let elicit {
        await client.withElicitationHandler { params in
            guard case .form(let form) = params else { return .init(action: .decline) }
            return try await elicit(form.message)
        }
    }
    try await client.connect(transport: clientTransport)
    _ = try await client.listTools()
    return (client, server)
}

@Suite("Client tasks at 2025-11-25")
struct HandshakeClientTaskTests {
    @Test("A required tool is called as a task; an optional one inline, by default")
    func whenRequired() async throws {
        let (client, server) = try await connectHandshakeClient()
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(await client.serverCapabilities?.tasks?.requests?.tools?.call != nil)
        #expect(text(try await client.callTool(name: "must")) == "task")
        #expect(text(try await client.callTool(name: "slow")) == "inline")
    }

    @Test("whenSupported calls optional tools as tasks; never calls none")
    func policies() async throws {
        let (client, server) = try await connectHandshakeClient(
            tasks: .init(minimumPollInterval: .milliseconds(5), augmentation: .whenSupported))
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(text(try await client.callTool(name: "slow")) == "task")
        #expect(text(try await client.callTool(name: "sync")) == "sync")

        let (never, other) = try await connectHandshakeClient(tasks: .init(augmentation: .never))
        defer { Task { await never.disconnect(); await other.stop() } }
        await #expect(throws: MCPError.methodNotFound("The tool runs only as a task")) {
            try await never.callTool(name: "must")
        }
    }

    @Test("Input arrives through tasks/result and the client's handlers")
    func input() async throws {
        let (client, server) = try await connectHandshakeClient(
            tasks: .init(minimumPollInterval: .milliseconds(5), augmentation: .whenSupported)
        ) { _ in .init(action: .accept, content: ["name": "Ada"]) }
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(text(try await client.callTool(name: "ask")) == "Ada")
    }

    @Test("Outcomes: a failed task's tool error is returned, a protocol error thrown")
    func outcomes() async throws {
        let (client, server) = try await connectHandshakeClient(
            tasks: .init(minimumPollInterval: .milliseconds(5), augmentation: .whenSupported))
        defer { Task { await client.disconnect(); await server.stop() } }
        let toolError = try await client.callTool(name: "toolError")
        #expect(toolError.isError == true)
        await #expect(throws: MCPError.self) { try await client.callTool(name: "protocolError") }
    }

    @Test("Low level: create, read, cancel, list")
    func lowLevel() async throws {
        let manager = TaskManager(configuration: .init(pollInterval: .milliseconds(10))) { _ in "me" }
        let (client, server) = try await connectHandshakeClient(
            manager: manager, tasks: .init(minimumPollInterval: .milliseconds(5), augmentation: .whenSupported))
        defer { Task { await client.disconnect(); await server.stop() } }
        let created = try await client.startToolCall(name: "slow", arguments: ["seconds": 30]).value
        let task = try #require(created.task)
        #expect(task.generation == .v1)
        #expect(try await client.getTask(task.taskId).status == .working)
        #expect(try await client.listTasks().tasks.map(\.taskId) == [task.taskId])
        let cancelled = try await client.cancelTask(task.taskId)
        #expect(cancelled?.status == .cancelled)
        await #expect(throws: TaskCancelledError.self) { try await client.task(task).result() }
    }

    @Test("A task cancelled while tasks/result waits throws TaskCancelledError")
    func cancelledDuringResult() async throws {
        let manager = TaskManager(configuration: .init(pollInterval: .milliseconds(10)))
        let (client, server) = try await connectHandshakeClient(
            manager: manager, tasks: .init(minimumPollInterval: .milliseconds(5), augmentation: .whenSupported)
        ) { _ in
            try await Task.sleep(for: .seconds(30))
            return .init(action: .decline)
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        let created = try await client.startToolCall(name: "ask").value
        let task = try #require(created.task)
        let drive = Task { try await client.task(task).result() }
        var status = try await client.getTask(task.taskId).status
        let deadline = ContinuousClock.now + .seconds(2)
        while status != .inputRequired, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            status = try await client.getTask(task.taskId).status
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        try await manager.cancel(task.taskId)
        await #expect(throws: TaskCancelledError.self) { try await drive.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("A tool the client has not listed is called without a task")
    func unlisted() async throws {
        let server = await makeTaskServer(manager: TaskManager())
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(
            name: "c", version: "1", configuration: .init(protocolMode: .handshake, tasks: .init()))
        try await client.connect(transport: clientTransport)
        defer { Task { await client.disconnect(); await server.stop() } }
        await #expect(throws: MCPError.self) { try await client.callTool(name: "must") }
    }
}

// MARK: - Every revision

@Suite("Tasks at every revision")
struct TaskRevisionMatrixTests {
    @Test(
        "A task tool runs inline before 2025-11-25 and as a task from it on",
        arguments: [Version.v2024_11_05, Version.v2025_03_26, Version.v2025_06_18, Version.v2025_11_25, Version.v2026_07_28])
    func revision(version: String) async throws {
        let server = await makeTaskServer(
            manager: TaskManager(configuration: .init(pollInterval: .milliseconds(10))), versions: [version])
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let stateless = Version.stateless.contains(version)
        let client = Client(
            name: "c", version: "1",
            configuration: .init(
                protocolMode: stateless ? .stateless(version) : .handshake,
                tasks: .init(minimumPollInterval: .milliseconds(5), augmentation: .whenSupported)))
        try await client.connect(transport: clientTransport)
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(await client.negotiatedProtocolVersion == version)
        let tools = try await client.listTools().tools
        let profile = Version.profile(for: version)
        let expected = profile.taskGeneration == nil ? "inline" : "task"
        #expect(text(try await client.callTool(name: "slow")) == expected)
        #expect(text(try await client.callTool(name: "must")) == expected)
        #expect(tools.contains { $0.execution != nil } == (profile.taskGeneration == .v1))
        let declared = await client.serverCapabilities
        #expect((declared?.tasks != nil) == (profile.taskGeneration == .v1))
        #expect((declared?.extensions?[ExtensionID.tasks] != nil) == (profile.taskGeneration == .v2))
    }
}

// MARK: - Notifications

/// Waits until the server sent a message that satisfies `match`.
private func sentMessage(
    _ wire: WireExchange, timeout: Duration = .seconds(2), where match: (Value) -> Bool
) async throws -> Value? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        for data in await wire.transport.sentData {
            if let value = try? JSONDecoder().decode(Value.self, from: data), match(value) { return value }
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    return nil
}

@Suite("Task notifications")
struct TaskNotificationTests {
    @Test("2025-11-25: the server sends notifications/tasks/status on status changes, without related-task")
    func statusNotifications() async throws {
        let server = try await HandshakeTaskServer(
            manager: TaskManager(configuration: .init(pollInterval: .milliseconds(10))))
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("slow")["taskId"])
        let note = try await sentMessage(server.wire) {
            $0.objectValue?["method"] == "notifications/tasks/status"
                && $0.objectValue?["params"]?.objectValue?["status"] == "completed"
        }
        let params = try #require(note?.objectValue?["params"]?.objectValue)
        #expect(params["taskId"] == id)
        #expect(params["ttl"] != nil)
        #expect(params["_meta"]?.objectValue?[MetaKey.relatedTask] == nil)
    }

    @Test("2025-11-25: status notifications can be turned off")
    func statusNotificationsOff() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.create("slow")["taskId"])
        #expect(try await server.wait(id)["status"] == "completed")
        let note = try await sentMessage(server.wire, timeout: .milliseconds(100)) {
            $0.objectValue?["method"] == "notifications/tasks/status"
        }
        #expect(note == nil)
    }

    @Test("2025-11-25: progress uses the call's token for the task's lifetime")
    func progress() async throws {
        let server = try await HandshakeTaskServer()
        defer { Task { await server.stop() } }
        let result = try await server.result(
            CallTool.name, ["name": "progress", "task": [:], "_meta": ["progressToken": "p1"]])
        #expect(result["task"] != nil)
        let note = try await sentMessage(server.wire) { $0.objectValue?["method"] == "notifications/progress" }
        #expect(note?.objectValue?["params"]?.objectValue?["progressToken"] == "p1")
        #expect(note?.objectValue?["params"]?.objectValue?["message"] == "half")
    }

    @Test("2026-07-28: a task reports no progress")
    func noProgressAtV2() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let created = try await server.result(CallTool.name, ["name": "progress", "_meta": ["progressToken": "p2"]])
        let id = try #require(created["taskId"]?.stringValue)
        #expect(try await server.wait(id)["status"] == "completed")
        let note = try await sentMessage(server.wire, timeout: .milliseconds(100)) {
            $0.objectValue?["method"] == "notifications/progress"
        }
        #expect(note == nil)
    }

    @Test("2026-07-28: listen streams name tasks; the acknowledgement keeps the caller's")
    func listenTaskIDs() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        let id = try #require(try await server.call("slow", ["seconds": 30])["taskId"])
        let listen = try await server.wire.send(
            message(
                id: 500, method: SubscriptionsListen.name,
                params: ["notifications": ["taskIds": [id, "nope", id]]], capabilities: tasksCapabilities))
        let ack = try #require(listen.first?.objectValue)
        #expect(ack["method"] == "notifications/subscriptions/acknowledged")
        #expect(ack["params"]?.objectValue?["notifications"]?.objectValue?["taskIds"] == [id])

        _ = try await server.result(CancelTask.name, ["taskId": id])
        let note = try await sentMessage(server.wire) {
            $0.objectValue?["method"] == "notifications/tasks"
                && $0.objectValue?["params"]?.objectValue?["status"] == "cancelled"
        }
        let params = try #require(note?.objectValue?["params"]?.objectValue)
        #expect(params["taskId"] == id)
        #expect(params["ttlMs"] != nil)
        #expect(params["_meta"]?.objectValue?[MetaKey.subscriptionID] == 500)
    }

    @Test("2026-07-28: naming tasks on a listen stream needs the extension")
    func listenNeedsExtension() async throws {
        let server = try await TaskServer()
        defer { Task { await server.stop() } }
        #expect(
            try await server.errorCode(
                SubscriptionsListen.name, ["notifications": ["taskIds": ["x"]]], capabilities: [:]) == -32021)
    }

    @Test("A status notification wakes the client before the poll interval")
    func clientWakesEarly() async throws {
        let manager = TaskManager(configuration: .init(pollInterval: .seconds(10)))
        let (client, server) = try await connectHandshakeClient(
            manager: manager, tasks: .init(augmentation: .whenSupported))
        defer { Task { await client.disconnect(); await server.stop() } }
        let start = ContinuousClock.now
        #expect(text(try await client.callTool(name: "slow")) == "task")
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

// MARK: - Late answers

@Suite("Late task answers")
struct LateTaskAnswerTests {
    @Test("A tools/call cancelled before its answer arrives: a task in the late answer is cancelled")
    func clientCancelsOrphan() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await serverTransport.connect()
        let seen = Answers()
        // A hand-driven peer: answers discovery, holds the tools/call until the
        // client cancels it, then answers it with a task.
        let peer = Task {
            var call: Value?
            for try await data in await serverTransport.receive() {
                let message = try JSONDecoder().decode(Value.self, from: data)
                let object = message.objectValue ?? [:]
                let method = object["method"]?.stringValue ?? ""
                await seen.record(method)
                switch method {
                case ServerDiscover.name:
                    let reply: Value = [
                        "jsonrpc": "2.0", "id": object["id"] ?? .null,
                        "result": [
                            "resultType": "complete", "supportedVersions": ["2026-07-28"],
                            "capabilities": ["tools": [:], "extensions": [ExtensionID.tasks: [:]]],
                            "_meta": [MetaKey.serverInfo: ["name": "peer", "version": "1"]],
                        ],
                    ]
                    try await serverTransport.send(JSONEncoder().encode(reply))
                case CallTool.name:
                    call = message
                case CancelledNotification.name:
                    let reply: Value = [
                        "jsonrpc": "2.0", "id": call?.objectValue?["id"] ?? .null,
                        "result": [
                            "resultType": "task", "taskId": "orphan", "status": "working",
                            "createdAt": "2026-01-01T00:00:00Z", "lastUpdatedAt": "2026-01-01T00:00:00Z", "ttlMs": 60000,
                        ],
                    ]
                    try await serverTransport.send(JSONEncoder().encode(reply))
                case CancelTask.name:
                    let reply: Value = ["jsonrpc": "2.0", "id": object["id"] ?? .null, "result": ["resultType": "complete"]]
                    try await serverTransport.send(JSONEncoder().encode(reply))
                default:
                    break
                }
            }
        }
        defer { peer.cancel() }
        let client = Client(
            name: "c", version: "1", configuration: .init(protocolMode: .stateless(Version.v2026_07_28), tasks: .init()))
        try await client.connect(transport: clientTransport)
        defer { Task { await client.disconnect() } }

        let call = Task { try await client.callTool(name: "anything") }
        let deadline = ContinuousClock.now + .seconds(2)
        while await !seen.messages.contains(CallTool.name), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        call.cancel()
        _ = await call.result
        while await !seen.messages.contains(CancelTask.name), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await seen.messages.contains(CancelTask.name))
    }
}
