import Foundation
import Testing

@testable import MCP

// MARK: - Task Type Tests

@Suite("Task Type Tests")
struct TaskTypeTests {

    // MARK: - TaskStatus Tests

    @Test(
        "TaskStatus raw values match spec",
        arguments: [
            (TaskStatus.working, "working"),
            (TaskStatus.inputRequired, "input_required"),
            (TaskStatus.completed, "completed"),
            (TaskStatus.failed, "failed"),
            (TaskStatus.cancelled, "cancelled"),
        ]
    )
    func taskStatusRawValues(testCase: (status: TaskStatus, rawValue: String)) {
        #expect(testCase.status.rawValue == testCase.rawValue)
    }

    @Test(
        "TaskStatus.isTerminal returns correct values",
        arguments: [
            (TaskStatus.working, false),
            (TaskStatus.inputRequired, false),
            (TaskStatus.completed, true),
            (TaskStatus.failed, true),
            (TaskStatus.cancelled, true),
        ]
    )
    func taskStatusIsTerminal(testCase: (status: TaskStatus, isTerminal: Bool)) {
        #expect(testCase.status.isTerminal == testCase.isTerminal)
    }

    @Test("isTerminalStatus helper function matches TaskStatus.isTerminal")
    func isTerminalStatusHelperFunction() {
        #expect(isTerminalStatus(.working) == false)
        #expect(isTerminalStatus(.inputRequired) == false)
        #expect(isTerminalStatus(.completed) == true)
        #expect(isTerminalStatus(.failed) == true)
        #expect(isTerminalStatus(.cancelled) == true)
    }

    @Test("TaskStatus encodes and decodes correctly")
    func taskStatusEncodingDecoding() throws {
        let statuses: [TaskStatus] = [.working, .inputRequired, .completed, .failed, .cancelled]

        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(TaskStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    // MARK: - MCPTask Tests

    @Test("MCPTask encoding and decoding with all fields")
    func mcpTaskFullEncodingDecoding() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:05Z",
            pollInterval: 1000,
            statusMessage: "Processing..."
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(MCPTask.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .working)
        #expect(decoded.ttl == 60000)
        #expect(decoded.createdAt == "2024-01-15T10:30:00Z")
        #expect(decoded.lastUpdatedAt == "2024-01-15T10:30:05Z")
        #expect(decoded.pollInterval == 1000)
        #expect(decoded.statusMessage == "Processing...")
    }

    @Test("MCPTask with nil ttl encodes as null (per spec requirement)")
    func mcpTaskNilTtlEncodesAsNull() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:05Z"
        )

        let data = try JSONEncoder().encode(task)
        let jsonString = String(data: data, encoding: .utf8)!

        // Per MCP spec, ttl must always be present (encoded as null when nil)
        #expect(jsonString.contains("\"ttl\":null"))
    }

    @Test("MCPTask decodes ttl as null correctly")
    func mcpTaskDecodesNullTtl() throws {
        let jsonString = """
            {
                "taskId": "task-123",
                "status": "working",
                "ttl": null,
                "createdAt": "2024-01-15T10:30:00Z",
                "lastUpdatedAt": "2024-01-15T10:30:05Z"
            }
            """

        let data = jsonString.data(using: .utf8)!
        let task = try JSONDecoder().decode(MCPTask.self, from: data)

        #expect(task.ttl == nil)
    }

    @Test("MCPTask with optional fields omitted")
    func mcpTaskOptionalFieldsOmitted() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .completed,
            ttl: 30000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:10Z"
        )

        let data = try JSONEncoder().encode(task)
        let jsonString = String(data: data, encoding: .utf8)!

        // Optional fields should not be present
        #expect(!jsonString.contains("pollInterval"))
        #expect(!jsonString.contains("statusMessage"))
    }

    // MARK: - TaskMetadata Tests

    @Test("TaskMetadata encoding and decoding")
    func taskMetadataEncodingDecoding() throws {
        let metadata = TaskMetadata(ttl: 60000)

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TaskMetadata.self, from: data)

        #expect(decoded.ttl == 60000)
    }

    @Test("TaskMetadata with nil ttl")
    func taskMetadataNilTtl() throws {
        let metadata = TaskMetadata(ttl: nil)

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TaskMetadata.self, from: data)

        #expect(decoded.ttl == nil)
    }

    // MARK: - RelatedTaskMetadata Tests

    @Test("RelatedTaskMetadata encoding and decoding")
    func relatedTaskMetadataEncodingDecoding() throws {
        let metadata = RelatedTaskMetadata(taskId: "task-456")

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RelatedTaskMetadata.self, from: data)

        #expect(decoded.taskId == "task-456")
    }

    // MARK: - Metadata Key Tests

    @Test("relatedTaskMetaKey has correct value")
    func relatedTaskMetaKeyValue() {
        #expect(relatedTaskMetaKey == "io.modelcontextprotocol/related-task")
    }

    @Test("modelImmediateResponseKey has correct value")
    func modelImmediateResponseKeyValue() {
        #expect(modelImmediateResponseKey == "io.modelcontextprotocol/model-immediate-response")
    }
}

// MARK: - CreateTaskResult Tests

@Suite("CreateTaskResult Tests")
struct CreateTaskResultTests {

    @Test("CreateTaskResult encoding and decoding")
    func createTaskResultEncodingDecoding() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z",
            pollInterval: 1000
        )

        let result = CreateTaskResult(task: task)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateTaskResult.self, from: data)

        #expect(decoded.task.taskId == "task-123")
        #expect(decoded.task.status == .working)
        #expect(decoded.task.ttl == 60000)
        #expect(decoded.task.pollInterval == 1000)
    }

    @Test("CreateTaskResult with model immediate response")
    func createTaskResultWithModelImmediateResponse() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z"
        )

        let result = CreateTaskResult(task: task, modelImmediateResponse: "Starting task...")

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateTaskResult.self, from: data)

        #expect(decoded._meta?[modelImmediateResponseKey]?.stringValue == "Starting task...")
    }

    @Test("CreateTaskResult with _meta")
    func createTaskResultWithMeta() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z"
        )

        let meta: [String: Value] = [
            "custom": .string("value"),
            modelImmediateResponseKey: .string("Processing your request..."),
        ]

        let result = CreateTaskResult(task: task, _meta: meta)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateTaskResult.self, from: data)

        #expect(decoded._meta?["custom"]?.stringValue == "value")
        #expect(decoded._meta?[modelImmediateResponseKey]?.stringValue == "Processing your request...")
    }
}

// MARK: - GetTask Tests

@Suite("GetTask Method Tests")
struct GetTaskMethodTests {

    @Test("GetTask.name is correct")
    func getTaskMethodName() {
        #expect(GetTask.name == "tasks/get")
    }

    @Test("GetTask.Parameters encoding and decoding")
    func getTaskParametersEncodingDecoding() throws {
        let params = GetTask.Parameters(taskId: "task-123")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(GetTask.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
    }

    @Test("GetTask.Result encoding and decoding")
    func getTaskResultEncodingDecoding() throws {
        let result = GetTask.Result(
            taskId: "task-123",
            status: .completed,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:30Z",
            pollInterval: 1000,
            statusMessage: "Done"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(GetTask.Result.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .completed)
        #expect(decoded.ttl == 60000)
        #expect(decoded.pollInterval == 1000)
        #expect(decoded.statusMessage == "Done")
    }

    @Test("GetTask.Result from MCPTask")
    func getTaskResultFromMCPTask() throws {
        let task = MCPTask(
            taskId: "task-456",
            status: .failed,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:15Z",
            statusMessage: "Connection timeout"
        )

        let result = GetTask.Result(task: task)

        #expect(result.taskId == task.taskId)
        #expect(result.status == task.status)
        #expect(result.statusMessage == "Connection timeout")
    }

    @Test("GetTask.Result ttl encodes as null when nil")
    func getTaskResultTtlEncodesAsNull() throws {
        let result = GetTask.Result(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z"
        )

        let data = try JSONEncoder().encode(result)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("\"ttl\":null"))
    }
}

// MARK: - GetTaskPayload Tests

@Suite("GetTaskPayload Method Tests")
struct GetTaskPayloadMethodTests {

    @Test("GetTaskPayload.name is correct")
    func getTaskPayloadMethodName() {
        #expect(GetTaskPayload.name == "tasks/result")
    }

    @Test("GetTaskPayload.Parameters encoding and decoding")
    func getTaskPayloadParametersEncodingDecoding() throws {
        let params = GetTaskPayload.Parameters(taskId: "task-123")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(GetTaskPayload.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
    }

    @Test("GetTaskPayload.Result with extraFields (flattened result)")
    func getTaskPayloadResultWithExtraFields() throws {
        // Simulate a tools/call result flattened into extraFields
        let extraFields: [String: Value] = [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Hello, world!"),
                ])
            ]),
            "isError": .bool(false),
        ]

        let meta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string("task-123")])
        ]

        let result = GetTaskPayload.Result(_meta: meta, extraFields: extraFields)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(GetTaskPayload.Result.self, from: data)

        #expect(decoded._meta?[relatedTaskMetaKey] != nil)
        #expect(decoded.extraFields?["isError"]?.boolValue == false)
    }

    @Test("GetTaskPayload.Result fromResultValue convenience initializer")
    func getTaskPayloadResultFromResultValue() throws {
        let resultValue: Value = .object([
            "content": .array([.object(["type": .string("text"), "text": .string("Result")])]),
            "isError": .bool(false),
        ])

        let result = GetTaskPayload.Result(fromResultValue: resultValue)

        #expect(result.extraFields?["isError"]?.boolValue == false)
    }
}

// MARK: - ListTasks Tests

@Suite("ListTasks Method Tests")
struct ListTasksMethodTests {

    @Test("ListTasks.name is correct")
    func listTasksMethodName() {
        #expect(ListTasks.name == "tasks/list")
    }

    @Test("ListTasks.Parameters encoding and decoding with cursor")
    func listTasksParametersWithCursor() throws {
        let params = ListTasks.Parameters(cursor: "page-2-token")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(ListTasks.Parameters.self, from: data)

        #expect(decoded.cursor == "page-2-token")
    }

    @Test("ListTasks.Parameters empty initializer")
    func listTasksParametersEmpty() throws {
        let params = ListTasks.Parameters()

        #expect(params.cursor == nil)
        #expect(params._meta == nil)
    }

    @Test("ListTasks.Result encoding and decoding")
    func listTasksResultEncodingDecoding() throws {
        let tasks = [
            MCPTask(
                taskId: "task-1",
                status: .completed,
                ttl: nil,
                createdAt: "2024-01-15T10:00:00Z",
                lastUpdatedAt: "2024-01-15T10:05:00Z"
            ),
            MCPTask(
                taskId: "task-2",
                status: .working,
                ttl: 60000,
                createdAt: "2024-01-15T10:10:00Z",
                lastUpdatedAt: "2024-01-15T10:10:00Z"
            ),
        ]

        let result = ListTasks.Result(tasks: tasks, nextCursor: "page-2")

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ListTasks.Result.self, from: data)

        #expect(decoded.tasks.count == 2)
        #expect(decoded.tasks[0].taskId == "task-1")
        #expect(decoded.tasks[1].taskId == "task-2")
        #expect(decoded.nextCursor == "page-2")
    }

    @Test("ListTasks.Result without nextCursor indicates end of pagination")
    func listTasksResultWithoutNextCursor() throws {
        let result = ListTasks.Result(tasks: [], nextCursor: nil)

        let data = try JSONEncoder().encode(result)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(!jsonString.contains("nextCursor"))
    }
}

// MARK: - CancelTask Tests

@Suite("CancelTask Method Tests")
struct CancelTaskMethodTests {

    @Test("CancelTask.name is correct")
    func cancelTaskMethodName() {
        #expect(CancelTask.name == "tasks/cancel")
    }

    @Test("CancelTask.Parameters encoding and decoding")
    func cancelTaskParametersEncodingDecoding() throws {
        let params = CancelTask.Parameters(taskId: "task-123")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(CancelTask.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
    }

    @Test("CancelTask.Result encoding and decoding")
    func cancelTaskResultEncodingDecoding() throws {
        let result = CancelTask.Result(
            taskId: "task-123",
            status: .cancelled,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:45Z",
            statusMessage: "Cancelled by user"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CancelTask.Result.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .cancelled)
        #expect(decoded.statusMessage == "Cancelled by user")
    }

    @Test("CancelTask.Result from MCPTask")
    func cancelTaskResultFromMCPTask() throws {
        let task = MCPTask(
            taskId: "task-456",
            status: .cancelled,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:30Z"
        )

        let result = CancelTask.Result(task: task)

        #expect(result.taskId == task.taskId)
        #expect(result.status == .cancelled)
    }
}

// MARK: - TaskStatusNotification Tests

@Suite("TaskStatusNotification Tests")
struct TaskStatusNotificationTests {

    @Test("TaskStatusNotification.name is correct")
    func taskStatusNotificationName() {
        #expect(TaskStatusNotification.name == "notifications/tasks/status")
    }

    @Test("TaskStatusNotification.Parameters encoding and decoding")
    func taskStatusNotificationParametersEncodingDecoding() throws {
        let params = TaskStatusNotification.Parameters(
            taskId: "task-123",
            status: .inputRequired,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:10Z",
            pollInterval: 500,
            statusMessage: "Waiting for user input"
        )

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(TaskStatusNotification.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .inputRequired)
        #expect(decoded.ttl == 60000)
        #expect(decoded.pollInterval == 500)
        #expect(decoded.statusMessage == "Waiting for user input")
    }

    @Test("TaskStatusNotification.Parameters from MCPTask")
    func taskStatusNotificationFromMCPTask() {
        let task = MCPTask(
            taskId: "task-789",
            status: .completed,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:31:00Z"
        )

        let params = TaskStatusNotification.Parameters(task: task)

        #expect(params.taskId == task.taskId)
        #expect(params.status == task.status)
        #expect(params.createdAt == task.createdAt)
        #expect(params.lastUpdatedAt == task.lastUpdatedAt)
    }
}

// MARK: - Server Capabilities Tests

@Suite("Server Tasks Capabilities Tests")
struct ServerTasksCapabilitiesTests {

    @Test("Server.Capabilities.Tasks encoding and decoding")
    func serverTasksCapabilitiesEncodingDecoding() throws {
        let capabilities = Server.Capabilities.Tasks(
            list: .init(),
            cancel: .init(),
            requests: .init(tools: .init(call: .init()))
        )

        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(Server.Capabilities.Tasks.self, from: data)

        #expect(decoded.list != nil)
        #expect(decoded.cancel != nil)
        #expect(decoded.requests?.tools?.call != nil)
    }

    @Test("Server.Capabilities.Tasks.full() creates complete capability")
    func serverTasksCapabilitiesFull() throws {
        let capabilities = Server.Capabilities.Tasks.full()

        #expect(capabilities.list != nil)
        #expect(capabilities.cancel != nil)
        #expect(capabilities.requests?.tools?.call != nil)
    }

    @Test("hasTaskAugmentedToolsCall helper")
    func hasTaskAugmentedToolsCallHelper() {
        // No capabilities
        #expect(hasTaskAugmentedToolsCall(nil) == false)

        // Empty capabilities
        #expect(hasTaskAugmentedToolsCall(Server.Capabilities()) == false)

        // Tasks without requests
        let capsNoRequests = Server.Capabilities(tasks: .init(list: .init()))
        #expect(hasTaskAugmentedToolsCall(capsNoRequests) == false)

        // Full task support
        let capsFull = Server.Capabilities(tasks: .full())
        #expect(hasTaskAugmentedToolsCall(capsFull) == true)
    }

    @Test("requireTaskAugmentedToolsCall throws when not supported")
    func requireTaskAugmentedToolsCallThrows() throws {
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedToolsCall(nil)
        }

        #expect(throws: MCPError.self) {
            try requireTaskAugmentedToolsCall(Server.Capabilities())
        }

        // Should not throw with full support
        try requireTaskAugmentedToolsCall(Server.Capabilities(tasks: .full()))
    }
}

// MARK: - Client Capabilities Tests

@Suite("Client Tasks Capabilities Tests")
struct ClientTasksCapabilitiesTests {

    @Test("Client.Capabilities.Tasks encoding and decoding")
    func clientTasksCapabilitiesEncodingDecoding() throws {
        let capabilities = Client.Capabilities.Tasks(
            list: .init(),
            cancel: .init(),
            requests: .init(
                sampling: .init(createMessage: .init()),
                elicitation: .init(create: .init())
            )
        )

        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(Client.Capabilities.Tasks.self, from: data)

        #expect(decoded.list != nil)
        #expect(decoded.cancel != nil)
        #expect(decoded.requests?.sampling?.createMessage != nil)
        #expect(decoded.requests?.elicitation?.create != nil)
    }

    @Test("Client.Capabilities.Tasks.full() creates complete capability")
    func clientTasksCapabilitiesFull() throws {
        let capabilities = Client.Capabilities.Tasks.full()

        #expect(capabilities.list != nil)
        #expect(capabilities.cancel != nil)
        #expect(capabilities.requests?.sampling?.createMessage != nil)
        #expect(capabilities.requests?.elicitation?.create != nil)
    }

    @Test("hasTaskAugmentedElicitation helper")
    func hasTaskAugmentedElicitationHelper() {
        #expect(hasTaskAugmentedElicitation(nil) == false)
        #expect(hasTaskAugmentedElicitation(Client.Capabilities()) == false)

        let capsWithElicitation = Client.Capabilities(
            tasks: .init(requests: .init(elicitation: .init(create: .init())))
        )
        #expect(hasTaskAugmentedElicitation(capsWithElicitation) == true)
    }

    @Test("hasTaskAugmentedSampling helper")
    func hasTaskAugmentedSamplingHelper() {
        #expect(hasTaskAugmentedSampling(nil) == false)
        #expect(hasTaskAugmentedSampling(Client.Capabilities()) == false)

        let capsWithSampling = Client.Capabilities(
            tasks: .init(requests: .init(sampling: .init(createMessage: .init())))
        )
        #expect(hasTaskAugmentedSampling(capsWithSampling) == true)
    }

    @Test("requireTaskAugmentedElicitation throws when not supported")
    func requireTaskAugmentedElicitationThrows() throws {
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedElicitation(nil)
        }

        // Should not throw with support
        let caps = Client.Capabilities(tasks: .full())
        try requireTaskAugmentedElicitation(caps)
    }

    @Test("requireTaskAugmentedSampling throws when not supported")
    func requireTaskAugmentedSamplingThrows() throws {
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedSampling(nil)
        }

        // Should not throw with support
        let caps = Client.Capabilities(tasks: .full())
        try requireTaskAugmentedSampling(caps)
    }
}

// MARK: - InMemoryTaskStore Tests

@Suite("InMemoryTaskStore Tests")
struct InMemoryTaskStoreTests {

    @Test("createTask creates task with working status")
    func createTaskCreatesWorkingTask() async throws {
        let store = InMemoryTaskStore()
        let metadata = TaskMetadata(ttl: 60000)

        let task = try await store.createTask(metadata: metadata, taskId: nil)

        #expect(task.status == .working)
        #expect(task.ttl == 60000)
        #expect(!task.taskId.isEmpty)
    }

    @Test("createTask with custom taskId")
    func createTaskWithCustomId() async throws {
        let store = InMemoryTaskStore()
        let metadata = TaskMetadata(ttl: nil)

        let task = try await store.createTask(metadata: metadata, taskId: "custom-id-123")

        #expect(task.taskId == "custom-id-123")
    }

    @Test("createTask throws on duplicate taskId")
    func createTaskThrowsOnDuplicate() async throws {
        let store = InMemoryTaskStore()
        let metadata = TaskMetadata()

        _ = try await store.createTask(metadata: metadata, taskId: "task-1")

        await #expect(throws: MCPError.self) {
            _ = try await store.createTask(metadata: metadata, taskId: "task-1")
        }
    }

    @Test("getTask returns created task")
    func getTaskReturnsCreatedTask() async throws {
        let store = InMemoryTaskStore()
        let created = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123")

        let retrieved = await store.getTask(taskId: "task-123")

        #expect(retrieved?.taskId == created.taskId)
        #expect(retrieved?.status == created.status)
    }

    @Test("getTask returns nil for non-existent task")
    func getTaskReturnsNilForNonExistent() async {
        let store = InMemoryTaskStore()

        let result = await store.getTask(taskId: "non-existent")

        #expect(result == nil)
    }

    @Test("updateTask changes status")
    func updateTaskChangesStatus() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123")

        let updated = try await store.updateTask(taskId: "task-123", status: .completed, statusMessage: "Done")

        #expect(updated.status == .completed)
        #expect(updated.statusMessage == "Done")
    }

    @Test("updateTask throws when transitioning from terminal status")
    func updateTaskThrowsFromTerminalStatus() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123")

        // Complete the task
        _ = try await store.updateTask(taskId: "task-123", status: .completed, statusMessage: nil)

        // Try to update again - should throw
        await #expect(throws: MCPError.self) {
            _ = try await store.updateTask(taskId: "task-123", status: .working, statusMessage: nil)
        }
    }

    @Test("updateTask throws for non-existent task")
    func updateTaskThrowsForNonExistent() async {
        let store = InMemoryTaskStore()

        await #expect(throws: MCPError.self) {
            _ = try await store.updateTask(taskId: "non-existent", status: .completed, statusMessage: nil)
        }
    }

    @Test("storeResult and getResult work correctly")
    func storeAndGetResult() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123")

        let result: Value = .object(["data": .string("test result")])
        try await store.storeResult(taskId: "task-123", result: result)

        let retrieved = await store.getResult(taskId: "task-123")

        #expect(retrieved?.objectValue?["data"]?.stringValue == "test result")
    }

    @Test("getResult returns nil when no result stored")
    func getResultReturnsNilWhenNoResult() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123")

        let result = await store.getResult(taskId: "task-123")

        #expect(result == nil)
    }

    @Test("listTasks returns all tasks")
    func listTasksReturnsAllTasks() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1")
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-2")
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-3")

        let (tasks, _) = await store.listTasks(cursor: nil)

        #expect(tasks.count == 3)
    }

    @Test("listTasks pagination works correctly")
    func listTasksPagination() async throws {
        let store = InMemoryTaskStore(pageSize: 2)

        // Create 5 tasks
        for i in 1...5 {
            _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-\(i)")
        }

        // First page
        let (page1, cursor1) = await store.listTasks(cursor: nil)
        #expect(page1.count == 2)
        #expect(cursor1 != nil)

        // Second page
        let (page2, cursor2) = await store.listTasks(cursor: cursor1)
        #expect(page2.count == 2)
        #expect(cursor2 != nil)

        // Third page
        let (page3, cursor3) = await store.listTasks(cursor: cursor2)
        #expect(page3.count == 1)
        #expect(cursor3 == nil)
    }

    @Test("deleteTask removes task")
    func deleteTaskRemovesTask() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123")

        let deleted = await store.deleteTask(taskId: "task-123")
        #expect(deleted == true)

        let result = await store.getTask(taskId: "task-123")
        #expect(result == nil)
    }

    @Test("deleteTask returns false for non-existent task")
    func deleteTaskReturnsFalseForNonExistent() async {
        let store = InMemoryTaskStore()

        let deleted = await store.deleteTask(taskId: "non-existent")

        #expect(deleted == false)
    }

    @Test("waitForUpdate and notifyUpdate work together")
    func waitForUpdateAndNotifyUpdate() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123")

        // Start waiting in a separate task
        let waitTask = Task {
            try await store.waitForUpdate(taskId: "task-123")
            return true
        }

        // Give the wait a moment to start
        try await Task.sleep(for: .milliseconds(50))

        // Notify update
        await store.notifyUpdate(taskId: "task-123")

        // Wait should complete
        let result = try await waitTask.value
        #expect(result == true)
    }
}

// MARK: - InMemoryTaskMessageQueue Tests

@Suite("InMemoryTaskMessageQueue Tests")
struct InMemoryTaskMessageQueueTests {

    @Test("enqueue and dequeue work correctly")
    func enqueueAndDequeue() async throws {
        let queue = InMemoryTaskMessageQueue()

        let message = QueuedMessage.notification(
            try JSONEncoder().encode(["test": "data"]),
            timestamp: Date()
        )

        try await queue.enqueue(taskId: "task-123", message: message, maxSize: nil)

        let dequeued = await queue.dequeue(taskId: "task-123")
        #expect(dequeued != nil)

        // Queue should now be empty
        let empty = await queue.dequeue(taskId: "task-123")
        #expect(empty == nil)
    }

    @Test("enqueue respects maxSize")
    func enqueueRespectsMaxSize() async throws {
        let queue = InMemoryTaskMessageQueue()

        let message = QueuedMessage.notification(Data(), timestamp: Date())

        try await queue.enqueue(taskId: "task-123", message: message, maxSize: 1)

        // Second enqueue should fail
        await #expect(throws: MCPError.self) {
            try await queue.enqueue(taskId: "task-123", message: message, maxSize: 1)
        }
    }

    @Test("dequeueAll returns all messages")
    func dequeueAllReturnsAllMessages() async throws {
        let queue = InMemoryTaskMessageQueue()

        for i in 0..<3 {
            let message = QueuedMessage.notification(
                try JSONEncoder().encode(["index": i]),
                timestamp: Date()
            )
            try await queue.enqueue(taskId: "task-123", message: message, maxSize: nil)
        }

        let all = await queue.dequeueAll(taskId: "task-123")
        #expect(all.count == 3)

        // Queue should now be empty
        let empty = await queue.isEmpty(taskId: "task-123")
        #expect(empty == true)
    }

    @Test("isEmpty returns correct value")
    func isEmptyReturnsCorrectValue() async throws {
        let queue = InMemoryTaskMessageQueue()

        #expect(await queue.isEmpty(taskId: "task-123") == true)

        let message = QueuedMessage.notification(Data(), timestamp: Date())
        try await queue.enqueue(taskId: "task-123", message: message, maxSize: nil)

        #expect(await queue.isEmpty(taskId: "task-123") == false)

        _ = await queue.dequeue(taskId: "task-123")

        #expect(await queue.isEmpty(taskId: "task-123") == true)
    }

    @Test("enqueueWithResolver stores resolver")
    func enqueueWithResolverStoresResolver() async throws {
        let queue = InMemoryTaskMessageQueue()
        let resolver = Resolver<Value>()

        let message = QueuedMessage.request(Data(), timestamp: Date())
        let queuedRequest = QueuedRequestWithResolver(
            message: message,
            resolver: resolver,
            originalRequestId: .string("req-1")
        )

        try await queue.enqueueWithResolver(taskId: "task-123", request: queuedRequest, maxSize: nil)

        // Resolver should be retrievable
        let retrieved = await queue.getResolver(forRequestId: .string("req-1"))
        #expect(retrieved != nil)
    }

    @Test("removeResolver removes and returns resolver")
    func removeResolverRemovesAndReturns() async throws {
        let queue = InMemoryTaskMessageQueue()
        let resolver = Resolver<Value>()

        let message = QueuedMessage.request(Data(), timestamp: Date())
        let queuedRequest = QueuedRequestWithResolver(
            message: message,
            resolver: resolver,
            originalRequestId: .string("req-1")
        )

        try await queue.enqueueWithResolver(taskId: "task-123", request: queuedRequest, maxSize: nil)

        let removed = await queue.removeResolver(forRequestId: .string("req-1"))
        #expect(removed != nil)

        // Should no longer be retrievable
        let notFound = await queue.getResolver(forRequestId: .string("req-1"))
        #expect(notFound == nil)
    }
}

// MARK: - Resolver Tests

@Suite("Resolver Tests")
struct ResolverTests {

    @Test("setResult and wait work correctly")
    func setResultAndWait() async throws {
        let resolver = Resolver<Value>()

        // Set result in background
        Task {
            await resolver.setResult(.string("success"))
        }

        let result = try await resolver.wait()
        #expect(result.stringValue == "success")
    }

    @Test("setError and wait throws correctly")
    func setErrorAndWaitThrows() async throws {
        let resolver = Resolver<Value>()

        // Set error in background
        Task {
            await resolver.setError(MCPError.internalError("test error"))
        }

        await #expect(throws: MCPError.self) {
            _ = try await resolver.wait()
        }
    }

    @Test("isDone returns correct value")
    func isDoneReturnsCorrectValue() async {
        let resolver = Resolver<Value>()

        #expect(await resolver.isDone == false)

        await resolver.setResult(.string("done"))

        #expect(await resolver.isDone == true)
    }

    @Test("setResult is idempotent")
    func setResultIsIdempotent() async throws {
        let resolver = Resolver<Value>()

        await resolver.setResult(.string("first"))
        await resolver.setResult(.string("second"))  // Should be ignored

        let result = try await resolver.wait()
        #expect(result.stringValue == "first")
    }
}

// MARK: - QueuedMessage Tests

@Suite("QueuedMessage Tests")
struct QueuedMessageTests {

    @Test("QueuedMessage.request stores data and timestamp")
    func queuedMessageRequest() {
        let data = Data("test".utf8)
        let timestamp = Date()
        let message = QueuedMessage.request(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }

    @Test("QueuedMessage.notification stores data and timestamp")
    func queuedMessageNotification() {
        let data = Data("notification".utf8)
        let timestamp = Date()
        let message = QueuedMessage.notification(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }

    @Test("QueuedMessage.response stores data and timestamp")
    func queuedMessageResponse() {
        let data = Data("response".utf8)
        let timestamp = Date()
        let message = QueuedMessage.response(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }

    @Test("QueuedMessage.error stores data and timestamp")
    func queuedMessageError() {
        let data = Data("error".utf8)
        let timestamp = Date()
        let message = QueuedMessage.error(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }
}

// MARK: - JSON Round-Trip Tests

@Suite("Task JSON Round-Trip Tests")
struct TaskJSONRoundTripTests {

    @Test("Complete task workflow JSON encoding")
    func completeTaskWorkflowJSON() throws {
        // 1. Create task with metadata
        let createParams = CallTool.Parameters(
            name: "long_running_tool",
            arguments: ["input": .string("data")],
            task: TaskMetadata(ttl: 60000)
        )

        let createData = try JSONEncoder().encode(createParams)
        let decodedCreate = try JSONDecoder().decode(CallTool.Parameters.self, from: createData)
        #expect(decodedCreate.task?.ttl == 60000)

        // 2. Create task result
        let task = MCPTask(
            taskId: "task-abc123",
            status: .working,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z",
            pollInterval: 1000
        )
        let createResult = CreateTaskResult(task: task, modelImmediateResponse: "Starting...")

        let resultData = try JSONEncoder().encode(createResult)
        let decodedResult = try JSONDecoder().decode(CreateTaskResult.self, from: resultData)
        #expect(decodedResult.task.taskId == "task-abc123")
        #expect(decodedResult._meta?[modelImmediateResponseKey]?.stringValue == "Starting...")

        // 3. Task status notification
        let notification = TaskStatusNotification.Parameters(
            taskId: "task-abc123",
            status: .inputRequired,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:05Z",
            statusMessage: "Waiting for input"
        )

        let notificationData = try JSONEncoder().encode(notification)
        let decodedNotification = try JSONDecoder().decode(
            TaskStatusNotification.Parameters.self, from: notificationData)
        #expect(decodedNotification.status == .inputRequired)

        // 4. Get task result
        let payloadResult = GetTaskPayload.Result(
            _meta: [relatedTaskMetaKey: .object(["taskId": .string("task-abc123")])],
            extraFields: [
                "content": .array([.object(["type": .string("text"), "text": .string("Result")])]),
                "isError": .bool(false),
            ]
        )

        let payloadData = try JSONEncoder().encode(payloadResult)
        let decodedPayload = try JSONDecoder().decode(GetTaskPayload.Result.self, from: payloadData)
        #expect(decodedPayload.extraFields?["isError"]?.boolValue == false)
    }
}
