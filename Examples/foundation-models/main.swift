// FoundationModelsExample: one set of FoundationModels tools (`add_task`,
// `complete_task`, `list_tasks`) that both:
//
//   1. runs locally inside an on-device FoundationModels `LanguageModelSession`
//      to perform checklist actions, and
//   2. exports over an MCP `Server` (`MCP.Tool(_:)` + `tool.call(_:)`) so any
//      MCP client — such as OpenCode, Claude Desktop, or `MCP.Client` — can
//      discover and call the exact same tools against the same JSON store.
//
// Modes:
//
//   # End-to-end walkthrough (local LanguageModelSession + in-process MCP client):
//   swift run FoundationModelsExample
//
//   # Run a custom natural-language prompt locally with FoundationModels:
//   swift run FoundationModelsExample \
//     --store /tmp/checklist.json \
//     --prompt "Add a high-priority task to review the MCP tools PR, then list open tasks."
//
//   # Run as a stdio MCP server so OpenCode or another MCP host can call the same tools:
//   swift build --target FoundationModelsExample
//   $(swift build --show-bin-path)/FoundationModelsExample --mcp --store /tmp/checklist.json
//
// Example `opencode.json` configuration to connect OpenCode to this server:
//
//   {
//     "$schema": "https://opencode.ai/config.json",
//     "mcp": {
//       "checklist": {
//         "type": "local",
//         "command": [
//           "/absolute/path/to/.build/debug/FoundationModelsExample",
//           "--mcp",
//           "--store",
//           "/tmp/checklist.json"
//         ]
//       }
//     }
//   }

import Foundation
import MCP

#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
    import FoundationModels

    // MARK: - Generable domain models

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    @Generable(description: "Priority of a checklist task")
    enum TaskPriority: String, Codable, Sendable {
        case low
        case medium
        case high
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    @Generable(description: "A single task in the checklist")
    struct ChecklistTask: Codable, Sendable {
        var id: Int
        var title: String
        var priority: TaskPriority
        var notes: String?
        var isCompleted: Bool
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    @Generable(description: "Summary of tasks in the checklist")
    struct ChecklistReport: Codable, Sendable {
        var tasks: [ChecklistTask]
        var openCount: Int
        var completedCount: Int
    }

    enum ChecklistError: LocalizedError {
        case emptyTitle
        case invalidID(Int)
        case taskNotFound(Int)

        var errorDescription: String? {
            switch self {
            case .emptyTitle:
                return "Task title must not be empty."
            case .invalidID(let id):
                return "Task ID must be at least 1 (got \(id))."
            case .taskNotFound(let id):
                return "No task with ID \(id) exists."
            }
        }
    }

    // MARK: - Persistent store shared between local sessions and MCP clients

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    actor ChecklistStore {
        private let fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func add(title: String, priority: TaskPriority, notes: String?) throws -> ChecklistTask {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ChecklistError.emptyTitle }
            var tasks = try load()
            let nextID = (tasks.map(\.id).max() ?? 0) + 1
            let created = ChecklistTask(
                id: nextID,
                title: trimmed,
                priority: priority,
                notes: notes,
                isCompleted: false)
            tasks.append(created)
            try save(tasks)
            return created
        }

        func complete(id: Int) throws -> ChecklistTask {
            guard id >= 1 else { throw ChecklistError.invalidID(id) }
            var tasks = try load()
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                throw ChecklistError.taskNotFound(id)
            }
            tasks[index].isCompleted = true
            try save(tasks)
            return tasks[index]
        }

        func list(includeCompleted: Bool) throws -> ChecklistReport {
            let all = try load()
            let completedCount = all.filter(\.isCompleted).count
            let openCount = all.count - completedCount
            let visible = includeCompleted ? all : all.filter { !$0.isCompleted }
            return ChecklistReport(
                tasks: visible,
                openCount: openCount,
                completedCount: completedCount)
        }

        private func load() throws -> [ChecklistTask] {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return []
            }
            return try JSONDecoder().decode([ChecklistTask].self, from: Data(contentsOf: fileURL))
        }

        private func save(_ tasks: [ChecklistTask]) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Shared FoundationModels.Tool definitions

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    struct AddTaskTool: FoundationModels.Tool {
        let name = "add_task"
        let description = "Creates a new task in the checklist and returns it."
        let store: ChecklistStore

        @Generable
        struct Arguments {
            @Guide(description: "Short action-oriented task title")
            var title: String
            @Guide(description: "Priority level: low, medium, or high")
            var priority: TaskPriority
            @Guide(description: "Optional context or notes")
            var notes: String?
        }

        func call(arguments: Arguments) async throws -> ChecklistTask {
            try await store.add(
                title: arguments.title,
                priority: arguments.priority,
                notes: arguments.notes)
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    struct CompleteTaskTool: FoundationModels.Tool {
        let name = "complete_task"
        let description = "Marks an existing checklist task as completed by its numeric ID."
        let store: ChecklistStore

        @Generable
        struct Arguments {
            @Guide(description: "Numeric ID of the task to complete", .minimum(1))
            var id: Int
        }

        func call(arguments: Arguments) async throws -> ChecklistTask {
            try await store.complete(id: arguments.id)
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    struct ListTasksTool: FoundationModels.Tool {
        let name = "list_tasks"
        let description = "Lists tasks in the checklist and counts of open and completed items."
        let store: ChecklistStore

        @Generable
        struct Arguments {
            @Guide(description: "Pass false to show only open tasks, or true to include completed tasks")
            var includeCompleted: Bool?
        }

        func call(arguments: Arguments) async throws -> ChecklistReport {
            try await store.list(includeCompleted: arguments.includeCompleted ?? true)
        }
    }

    // MARK: - Toolset wired to both LanguageModelSession and MCP.Server

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    struct ChecklistToolset: Sendable {
        let addTask: AddTaskTool
        let completeTask: CompleteTaskTool
        let listTasks: ListTasksTool

        init(store: ChecklistStore) {
            self.addTask = AddTaskTool(store: store)
            self.completeTask = CompleteTaskTool(store: store)
            self.listTasks = ListTasksTool(store: store)
        }

        /// Tools passed directly to a local FoundationModels `LanguageModelSession`.
        var localTools: [any FoundationModels.Tool] {
            [addTask, completeTask, listTasks]
        }

        /// Builds an MCP `Server` that exports the exact same tools to external clients
        /// such as OpenCode, Claude Desktop, or `MCP.Client`.
        func makeMCPServer() async throws -> Server {
            let definitions = [
                try MCP.Tool(
                    addTask,
                    annotations: .init(
                        title: "Add Task",
                        readOnlyHint: false,
                        destructiveHint: false,
                        idempotentHint: false,
                        openWorldHint: false)),
                try MCP.Tool(
                    completeTask,
                    annotations: .init(
                        title: "Complete Task",
                        readOnlyHint: false,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false)),
                try MCP.Tool(
                    listTasks,
                    annotations: .init(
                        title: "List Tasks",
                        readOnlyHint: true,
                        openWorldHint: false)),
            ]

            let server = Server(
                name: "checklist-foundation-models",
                version: "1.0.0",
                capabilities: .init(tools: .init()))

            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: definitions)
            }

            let addTask = self.addTask
            let completeTask = self.completeTask
            let listTasks = self.listTasks
            await server.withMethodHandler(CallTool.self) { params in
                switch params.name {
                case addTask.name:
                    return try await addTask.call(params)
                case completeTask.name:
                    return try await completeTask.call(params)
                case listTasks.name:
                    return try await listTasks.call(params)
                default:
                    throw MCPError.invalidParams("Unknown tool: \(params.name)")
                }
            }

            return server
        }

        /// Runs a prompt locally with Apple's on-device `SystemLanguageModel` and prints
        /// both the tool calls from the transcript and the assistant's response.
        func runLocalPrompt(_ prompt: String) async throws {
            let session = LanguageModelSession(
                tools: localTools,
                instructions: """
                    You manage the user's checklist using the provided tools.
                    Always call the tools to add, complete, or inspect tasks rather than guessing.
                    """)
            let response = try await session.respond(to: prompt)
            for entry in session.transcript {
                if case .toolCalls(let calls) = entry {
                    for call in calls {
                        print("  [FoundationModels tool call] \(call.toolName)(\(call.arguments.jsonString))")
                    }
                }
            }
            print("  [FoundationModels response] \(response.content)")
        }
    }

    // MARK: - CLI entrypoints

    struct Options {
        enum Mode {
            case walkthrough
            case prompt(String)
            case mcpStdio
        }

        var mode: Mode = .walkthrough
        var storeURL: URL?
    }

    func parseOptions() -> Options {
        var options = Options()
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--mcp":
                options.mode = .mcpStdio
            case "--prompt":
                if let text = iterator.next() {
                    options.mode = .prompt(text)
                }
            case "--store":
                if let path = iterator.next() {
                    options.storeURL = URL(fileURLWithPath: path)
                }
            default:
                break
            }
        }
        return options
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    func runWalkthrough(toolset: ChecklistToolset, storeURL: URL) async throws {
        print("Store: \(storeURL.path)\n")

        print("1. Local FoundationModels execution (same Tool structs):")
        if SystemLanguageModel.default.availability == .available {
            try await toolset.runLocalPrompt(
                "Add a high-priority task 'Ship FoundationModels MCP bridge' and a medium-priority task 'Write release notes'.")
        } else {
            print("  SystemLanguageModel unavailable (\(SystemLanguageModel.default.availability)); invoking tools directly:")
            let first = try await toolset.addTask.call(
                arguments: .init(
                    title: "Ship FoundationModels MCP bridge",
                    priority: .high,
                    notes: "Local tool call"))
            let second = try await toolset.addTask.call(
                arguments: .init(title: "Write release notes", priority: .medium, notes: nil))
            print("  Added #\(first.id) (\(first.title)) and #\(second.id) (\(second.title)).")
        }

        print("\n2. Exported over MCP Server and called by an MCP Client (such as OpenCode):")
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = try await toolset.makeMCPServer()
        try await server.start(transport: serverTransport)

        let client = Client(name: "opencode-example-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let exported = try await client.listTools().tools
        print("  Exported MCP tools: \(exported.map(\.name).joined(separator: ", "))")

        // External MCP client marks task #1 completed and adds another task.
        _ = try await client.callTool(name: "complete_task", arguments: ["id": 1])
        _ = try await client.callTool(
            name: "add_task",
            arguments: [
                "title": "Test server from OpenCode",
                "priority": "low",
                "notes": "Added via MCP tools/call",
            ])

        let report = try await client.callTool(name: "list_tasks", arguments: ["includeCompleted": true])
        if let structured = report.structuredContent {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = String(decoding: try encoder.encode(structured), as: UTF8.self)
            print("  Checklist state via MCP structuredContent:\n\(json)")
        }

        // Client-side bridge (#169): wrap the MCP server's tools back for a LanguageModelSession.
        let bridgedTools = try await client.languageModelTools { tool, arguments in
            if tool.annotations.readOnlyHint == true {
                return true
            }
            print("  [Host approval] Approving \(tool.name)(\(arguments))")
            return true
        }
        print("\n3. Client-side bridge: wrapped \(bridgedTools.count) remote MCP tools as FoundationModels.Tool.")
        if let remoteList = bridgedTools.first(where: { $0.name == "list_tasks" }) {
            let openOnly = try await remoteList.call(
                arguments: GeneratedContent(json: #"{"includeCompleted": false}"#))
            print("  Open tasks via Client.LanguageModelTool: \(openOnly)")
        }

        await client.disconnect()
        await server.stop()
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    func main() async throws {
        let options = parseOptions()
        // The walkthrough completes task #1 and adds demo tasks, so it always uses a fresh
        // temporary store and never touches the one passed with --store.
        let isTemporaryStore: Bool = {
            if case .walkthrough = options.mode { return true }
            return false
        }()
        if isTemporaryStore, options.storeURL != nil {
            FileHandle.standardError.write(
                Data("The walkthrough ignores --store and uses a temporary store.\n".utf8))
        }
        let storeURL =
            isTemporaryStore
            ? FileManager.default.temporaryDirectory.appendingPathComponent(
                "mcp-checklist-\(UUID().uuidString).json")
            : options.storeURL
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("mcp-checklist.json")
        defer {
            if isTemporaryStore {
                try? FileManager.default.removeItem(at: storeURL)
            }
        }

        let store = ChecklistStore(fileURL: storeURL)
        let toolset = ChecklistToolset(store: store)

        switch options.mode {
        case .mcpStdio:
            #if os(macOS)
                let server = try await toolset.makeMCPServer()
                try await server.start(transport: StdioTransport())
                await server.waitUntilCompleted()
            #else
                FileHandle.standardError.write(
                    Data("Stdio MCP server mode requires macOS.\n".utf8))
                exit(1)
            #endif
        case .prompt(let prompt):
            guard SystemLanguageModel.default.availability == .available else {
                FileHandle.standardError.write(
                    Data("SystemLanguageModel is not available on this device.\n".utf8))
                exit(1)
            }
            try await toolset.runLocalPrompt(prompt)
        case .walkthrough:
            try await runWalkthrough(toolset: toolset, storeURL: storeURL)
        }
    }

    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        try await main()
    } else {
        // stderr and a failing exit, so an MCP host reading stdout as JSON-RPC sees a clean failure.
        FileHandle.standardError.write(
            Data("FoundationModelsExample requires macOS 26, iOS 26, or visionOS 26.\n".utf8))
        exit(1)
    }
#else
    FileHandle.standardError.write(
        Data("FoundationModelsExample requires the FoundationModels framework.\n".utf8))
    exit(1)
#endif
