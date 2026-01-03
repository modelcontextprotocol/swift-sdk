import Foundation

// MARK: - Task Mode Validation

/// Validates that a request is compatible with a tool's task execution mode.
///
/// Per MCP spec:
/// - `required`: Clients MUST invoke as task. Server returns error if not.
/// - `forbidden` (or nil): Clients MUST NOT invoke as task. Server returns error if they do.
/// - `optional`: Either is acceptable.
///
/// - Parameters:
///   - isTaskRequest: Whether the request includes task metadata
///   - taskSupport: The tool's task support setting (nil defaults to .forbidden)
/// - Throws: MCPError if the request is incompatible with the tool's task mode
public func validateTaskMode(
    isTaskRequest: Bool,
    taskSupport: Tool.Execution.TaskSupport?
) throws {
    let mode = taskSupport ?? .forbidden

    switch mode {
    case .required:
        if !isTaskRequest {
            throw MCPError.methodNotFound("This tool requires task-augmented invocation")
        }
    case .forbidden:
        if isTaskRequest {
            throw MCPError.methodNotFound("This tool does not support task-augmented invocation")
        }
    case .optional:
        // Both task and non-task requests are acceptable
        break
    }
}

/// Validates that a request is compatible with a tool's configuration.
///
/// - Parameters:
///   - isTaskRequest: Whether the request includes task metadata
///   - tool: The tool being invoked
/// - Throws: MCPError if the request is incompatible with the tool's configuration
public func validateTaskMode(isTaskRequest: Bool, for tool: Tool) throws {
    let taskSupport = tool.execution?.taskSupport
    try validateTaskMode(isTaskRequest: isTaskRequest, taskSupport: taskSupport)
}

/// Check if a client can invoke a tool with the given task mode.
///
/// - Parameters:
///   - clientSupportsTask: Whether the client supports task-augmented requests
///   - taskSupport: The tool's task support setting
/// - Returns: True if the client can use this tool
public func canUseToolWithTaskMode(
    clientSupportsTask: Bool,
    taskSupport: Tool.Execution.TaskSupport?
) -> Bool {
    let mode = taskSupport ?? .forbidden
    switch mode {
    case .required:
        return clientSupportsTask
    case .forbidden, .optional:
        return true
    }
}

// MARK: - Task Support Configuration

/// Configuration for experimental task support on the server.
///
/// TaskSupport encapsulates the task store and message queue infrastructure
/// needed for task-augmented requests. When enabled on a server, it provides
/// default handlers for task operations.
///
/// - Important: This is an experimental API that may change without notice.
///
/// ## Example
///
/// ```swift
/// let server = Server(name: "MyServer", version: "1.0")
///
/// // Enable task support with in-memory storage
/// let taskSupport = TaskSupport.inMemory()
/// server.enableTaskSupport(taskSupport)
/// ```
public final class TaskSupport: Sendable {
    /// The task store for persisting task state.
    public let store: any TaskStore

    /// The message queue for side-channel communication during task execution.
    public let queue: any TaskMessageQueue

    /// The result handler for processing tasks/result requests.
    public let resultHandler: TaskResultHandler

    /// Create task support with custom store and queue.
    ///
    /// - Parameters:
    ///   - store: The task store implementation
    ///   - queue: The message queue implementation
    public init(store: any TaskStore, queue: any TaskMessageQueue) {
        self.store = store
        self.queue = queue
        self.resultHandler = TaskResultHandler(store: store, queue: queue)
    }

    /// Create in-memory task support.
    ///
    /// Suitable for development, testing, and single-process servers.
    /// For distributed systems, provide custom store and queue implementations.
    ///
    /// - Returns: TaskSupport configured with in-memory store and queue
    public static func inMemory() -> TaskSupport {
        TaskSupport(
            store: InMemoryTaskStore(),
            queue: InMemoryTaskMessageQueue()
        )
    }

    /// Run a work function as a background task.
    ///
    /// This is the recommended way to handle task-augmented tool calls. It:
    /// 1. Creates a task in the store
    /// 2. Spawns the work function in a background task
    /// 3. Returns `CreateTaskResult` immediately
    ///
    /// The work function receives a `ServerTaskContext` with:
    /// - `updateStatus()` for progress updates
    /// - `complete(result:)` / `fail(error:)` for finishing the task
    /// - `isCancelled` to check for cancellation
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // In your tool handler:
    /// server.withRequestHandler(CallTool.self) { params, context in
    ///     guard let taskMetadata = params.task else {
    ///         // Handle non-task request
    ///         return CallTool.Result(content: [.text("Done")])
    ///     }
    ///
    ///     // Run as a task
    ///     let createTaskResult = try await taskSupport.runTask(
    ///         metadata: taskMetadata,
    ///         modelImmediateResponse: "Starting to process..."
    ///     ) { taskContext in
    ///         try await taskContext.updateStatus("Working...")
    ///         // Do work...
    ///         return CallTool.Result(content: [.text("Done!")])
    ///     }
    ///
    ///     // Return CreateTaskResult as the response
    ///     // Note: This requires the response type to be flexible
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - metadata: The task metadata from the request
    ///   - taskId: Optional specific task ID (generated if nil)
    ///   - modelImmediateResponse: Optional immediate feedback for the model
    ///   - clientCapabilities: Optional client capabilities for mid-task elicitation/sampling
    ///   - server: Optional server reference for task-augmented requests (elicitAsTask, createMessageAsTask)
    ///   - work: The async work function that receives the task context
    /// - Returns: CreateTaskResult to return to the client
    /// - Throws: Error if task creation fails
    public func runTask(
        metadata: TaskMetadata,
        taskId: String? = nil,
        modelImmediateResponse: String? = nil,
        clientCapabilities: Client.Capabilities? = nil,
        server: Server? = nil,
        work: @escaping @Sendable (ServerTaskContext) async throws -> CallTool.Result
    ) async throws -> CreateTaskResult {
        // Create the task
        let task = try await store.createTask(metadata: metadata, taskId: taskId)

        // Create the context
        let context = ServerTaskContext(
            task: task,
            store: store,
            queue: queue,
            clientCapabilities: clientCapabilities,
            server: server
        )

        // Spawn the work in a background task
        Task.detached { [store] in
            do {
                let result = try await work(context)
                // If the task isn't already in a terminal state, complete it
                if !isTerminalStatus(context.task.status) {
                    try await context.complete(toolResult: result)
                }
            } catch is CancellationError {
                // If cancelled, update status
                if !isTerminalStatus(context.task.status) {
                    _ = try? await store.updateTask(
                        taskId: context.taskId,
                        status: .cancelled,
                        statusMessage: "Cancelled"
                    )
                }
            } catch {
                // If the task isn't already in a terminal state, fail it
                if !isTerminalStatus(context.task.status) {
                    try? await context.fail(error: error)
                }
            }
        }

        // Return immediately
        return CreateTaskResult(task: task, modelImmediateResponse: modelImmediateResponse)
    }
}

// MARK: - Server Extension

extension Server {
    // Note: This method is internal. Access via server.experimental.enableTasks()
    @discardableResult
    func enableTaskSupport(_ taskSupport: TaskSupport) -> Self {
        // Set the tasks capability with full support
        capabilities.tasks = .full()

        // Register the result handler as a response router
        // This routes responses back to waiting task handlers (elicit/createMessage)
        addResponseRouter(taskSupport.resultHandler)

        // Register default task handlers
        registerDefaultTaskHandlers(taskSupport)

        return self
    }

    /// Register default handlers for task operations.
    private func registerDefaultTaskHandlers(_ taskSupport: TaskSupport) {
        // tasks/get - Get task status
        withRequestHandler(GetTask.self) { params, _ in
            guard let task = await taskSupport.store.getTask(taskId: params.taskId) else {
                throw MCPError.invalidParams("Task not found: \(params.taskId)")
            }
            return GetTask.Result(task: task)
        }

        // tasks/list - List all tasks
        withRequestHandler(ListTasks.self) { params, _ in
            let (tasks, nextCursor) = await taskSupport.store.listTasks(cursor: params.cursor)
            return ListTasks.Result(tasks: tasks, nextCursor: nextCursor)
        }

        // tasks/cancel - Cancel a running task
        withRequestHandler(CancelTask.self) { params, _ in
            guard let task = await taskSupport.store.getTask(taskId: params.taskId) else {
                throw MCPError.invalidParams("Task not found: \(params.taskId)")
            }

            // Can't cancel a task that's already in a terminal state
            // Per spec: return -32602 (Invalid params) for terminal status tasks
            if isTerminalStatus(task.status) {
                throw MCPError.invalidParams("Cannot cancel task in terminal status: \(task.status.rawValue)")
            }

            // Update task status to cancelled
            let updatedTask = try await taskSupport.store.updateTask(
                taskId: params.taskId,
                status: .cancelled,
                statusMessage: "Cancelled by client request"
            )

            // Clean up any queued messages for this task
            _ = await taskSupport.queue.dequeueAll(taskId: params.taskId)

            return CancelTask.Result(task: updatedTask)
        }

        // tasks/result - Get task result (with blocking until terminal)
        // Uses TaskResultHandler to deliver queued messages (elicitation/sampling)
        withRequestHandler(GetTaskPayload.self) { params, context in
            try await taskSupport.resultHandler.handle(
                taskId: params.taskId,
                sendMessage: context.sendData
            )
        }
    }
}
