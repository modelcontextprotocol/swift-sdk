import Foundation

// MARK: - Pure Task Context

/// A pure task context without server dependencies.
///
/// This context provides basic task management capabilities that work without
/// a server session, making it suitable for distributed workers or background
/// processing. For server-integrated task handling with elicitation and sampling,
/// use `ServerTaskContext` instead.
///
/// Unlike `ServerTaskContext`, this context:
/// - Does not require client capabilities
/// - Does not support mid-task elicitation or sampling
/// - Can be used in distributed/worker processes with just a TaskStore
///
/// - Important: This is an experimental API that may change without notice.
///
/// ## Example (Distributed Worker)
///
/// ```swift
/// func workerProcess(taskId: String) async {
///     let store = RedisTaskStore(url: redisUrl)
///     let context = try await TaskContext.load(taskId: taskId, from: store)
///
///     do {
///         await context.updateStatus("Processing...")
///         let result = try await doWork()
///         try await context.complete(result: result)
///     } catch {
///         try await context.fail(error: error)
///     }
/// }
/// ```
public actor TaskContext {
    /// The task this context is for.
    public private(set) var task: MCPTask

    /// The task store for persistence.
    private let store: any TaskStore

    /// Whether cancellation has been requested.
    private var _isCancelled = false

    /// Check if cancellation has been requested.
    public var isCancelled: Bool { _isCancelled }

    /// The task ID.
    public var taskId: String { task.taskId }

    /// Create a task context.
    ///
    /// - Parameters:
    ///   - task: The task to manage
    ///   - store: The task store for persistence
    public init(task: MCPTask, store: any TaskStore) {
        self.task = task
        self.store = store
    }

    /// Load a task context from the store.
    ///
    /// This is the recommended way to create a context in distributed workers.
    ///
    /// - Parameters:
    ///   - taskId: The task identifier
    ///   - store: The task store
    /// - Returns: A TaskContext for the loaded task
    /// - Throws: Error if the task is not found
    public static func load(taskId: String, from store: any TaskStore) async throws -> TaskContext {
        guard let task = await store.getTask(taskId: taskId) else {
            throw MCPError.invalidParams("Task not found: \(taskId)")
        }
        return TaskContext(task: task, store: store)
    }

    /// Request cancellation of the task.
    ///
    /// This sets the `isCancelled` flag but doesn't immediately stop execution.
    /// Task handlers should check this flag periodically and exit gracefully.
    public func requestCancellation() {
        _isCancelled = true
    }

    /// Update the task status with a message.
    ///
    /// This updates the task to `.working` status with the provided message.
    /// Use this to report progress during long-running operations.
    ///
    /// - Parameter message: A human-readable status message
    /// - Throws: Error if the task cannot be updated
    public func updateStatus(_ message: String) async throws {
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .working,
            statusMessage: message
        )
        task = updatedTask
    }

    /// Mark the task as requiring input.
    ///
    /// This updates the task to `.inputRequired` status, signaling that
    /// the task is waiting for user input.
    ///
    /// - Note: For mid-task elicitation, use `ServerTaskContext` instead.
    ///
    /// - Parameter message: Optional message describing what input is needed
    /// - Throws: Error if the task cannot be updated
    public func setInputRequired(_ message: String? = nil) async throws {
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .inputRequired,
            statusMessage: message
        )
        task = updatedTask
    }

    /// Complete the task successfully with a result.
    ///
    /// This stores the result and transitions the task to `.completed` status.
    ///
    /// - Parameter result: The result value to store
    /// - Throws: Error if the task cannot be completed
    public func complete(result: Value) async throws {
        try await store.storeResult(taskId: taskId, result: result)
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .completed,
            statusMessage: nil
        )
        task = updatedTask
    }

    /// Complete the task successfully with a CallTool.Result.
    ///
    /// This is a convenience method that encodes the result and stores it.
    ///
    /// - Parameter result: The tool result
    /// - Throws: Error if encoding fails or the task cannot be completed
    public func complete(toolResult: CallTool.Result) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(toolResult)
        let decoder = JSONDecoder()
        let value = try decoder.decode(Value.self, from: data)
        try await complete(result: value)
    }

    /// Fail the task with an error message.
    ///
    /// This transitions the task to `.failed` status with the error message.
    ///
    /// - Parameter error: A human-readable error message
    /// - Throws: Error if the task cannot be updated
    public func fail(error: String) async throws {
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .failed,
            statusMessage: error
        )
        task = updatedTask
    }

    /// Fail the task with an Error.
    ///
    /// - Parameter error: The error that caused the failure
    /// - Throws: Error if the task cannot be updated
    public func fail(error: any Error) async throws {
        try await fail(error: error.localizedDescription)
    }

    /// Cancel the task.
    ///
    /// This transitions the task to `.cancelled` status.
    ///
    /// - Parameter message: Optional message describing why the task was cancelled
    /// - Throws: Error if the task cannot be updated
    public func cancel(message: String? = nil) async throws {
        _isCancelled = true
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .cancelled,
            statusMessage: message ?? "Cancelled"
        )
        task = updatedTask
    }
}

// MARK: - Task Execution Helper

/// Execute work within a task context, automatically handling failures.
///
/// This is similar to Python SDK's `task_execution` context manager.
/// If an unhandled exception occurs, the task is automatically marked as failed
/// and the error is suppressed (since the failure is captured in task state).
///
/// This is useful for distributed workers that don't have a server session.
///
/// - Important: This is an experimental API that may change without notice.
///
/// ## Example (Distributed Worker)
///
/// ```swift
/// let store = RedisTaskStore(url: redisUrl)
/// try await withTaskExecution(taskId: taskId, store: store) { context in
///     await context.updateStatus("Working...")
///     let result = try await doWork()
///     try await context.complete(result: result)
/// }
/// // If doWork() throws, task is automatically marked as failed
/// ```
///
/// - Parameters:
///   - taskId: The task identifier to execute
///   - store: The task store (must be accessible by the worker)
///   - work: The async work function that receives the task context
/// - Throws: Error only if the task cannot be loaded (not for work failures)
public func withTaskExecution(
    taskId: String,
    store: any TaskStore,
    work: @escaping @Sendable (TaskContext) async throws -> Void
) async throws {
    let context = try await TaskContext.load(taskId: taskId, from: store)

    do {
        try await work(context)
    } catch is CancellationError {
        // Task was cancelled externally
        if !isTerminalStatus(await context.task.status) {
            try? await context.cancel(message: "Cancelled")
        }
    } catch {
        // Auto-fail the task if an exception occurs and task isn't already terminal
        if !isTerminalStatus(await context.task.status) {
            try? await context.fail(error: error)
        }
        // Don't re-raise - the failure is recorded in task state
    }
}

// MARK: - Task Helper Functions

/// Generate a unique task ID.
///
/// This is a helper for TaskStore implementations.
///
/// - Returns: A unique task identifier
public func generateTaskId() -> String {
    UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
}

/// Create a Task object with initial state.
///
/// This is a helper for TaskStore implementations.
///
/// - Parameters:
///   - metadata: Task metadata (TTL, etc.)
///   - taskId: Optional task ID (generated if nil)
///   - pollInterval: Suggested polling interval in milliseconds (default: 500)
/// - Returns: A new Task in "working" status
public func createTaskState(
    metadata: TaskMetadata,
    taskId: String? = nil,
    pollInterval: Int = 500
) -> MCPTask {
    let id = taskId ?? generateTaskId()
    let now = ISO8601DateFormatter().string(from: Date())
    return MCPTask(
        taskId: id,
        status: .working,
        ttl: metadata.ttl,
        createdAt: now,
        lastUpdatedAt: now,
        pollInterval: pollInterval
    )
}
