import Foundation

/// Experimental APIs for MCP servers.
///
/// Access via `server.experimental.tasks`:
/// ```swift
/// // Enable task support with in-memory storage
/// await server.experimental.tasks.enable()
///
/// // Or with custom configuration
/// let taskSupport = TaskSupport.inMemory()
/// await server.experimental.tasks.enable(taskSupport)
/// ```
///
/// - Warning: These APIs are experimental and may change without notice.
public struct ExperimentalServerFeatures: Sendable {
    private let server: Server

    init(server: Server) {
        self.server = server
    }

    /// Task-related experimental APIs.
    public var tasks: ExperimentalServerTasks {
        ExperimentalServerTasks(server: server)
    }
}

/// Experimental task APIs for MCP servers.
///
/// - Warning: These APIs are experimental and may change without notice.
public struct ExperimentalServerTasks: Sendable {
    private let server: Server

    init(server: Server) {
        self.server = server
    }

    /// Enable task support with default in-memory storage.
    ///
    /// This is a convenience method that enables task support using
    /// an in-memory task store and message queue. Suitable for
    /// development, testing, and single-process servers.
    ///
    /// For production distributed systems, use `enable(_:)` with
    /// custom `TaskSupport` configuration.
    ///
    /// This method:
    /// 1. Sets the tasks capability with full support (list, cancel, task-augmented tools/call)
    /// 2. Registers default handlers for `tasks/get`, `tasks/list`, `tasks/cancel`, and `tasks/result`
    ///
    /// - Returns: Self for chaining
    @discardableResult
    public func enable() async -> Server {
        await server.enableTaskSupport(.inMemory())
    }

    /// Enable task support with custom configuration.
    ///
    /// Use this method when you need custom task storage (e.g., database
    /// or distributed cache) or custom message queue implementations.
    ///
    /// This method:
    /// 1. Sets the tasks capability with full support (list, cancel, task-augmented tools/call)
    /// 2. Registers the TaskResultHandler as a response router for mid-task elicitation/sampling
    /// 3. Registers default handlers for `tasks/get`, `tasks/list`, `tasks/cancel`, and `tasks/result`
    ///
    /// - Parameter taskSupport: The task support configuration
    /// - Returns: Self for chaining
    @discardableResult
    public func enable(_ taskSupport: TaskSupport) async -> Server {
        await server.enableTaskSupport(taskSupport)
    }

    // MARK: - Client Task Polling (Server → Client)

    /// Get a task from the client.
    ///
    /// This sends a `tasks/get` request to the client to retrieve task status.
    /// Used when the server has initiated a task-augmented request (like elicitAsTask)
    /// and needs to check the client's task status.
    ///
    /// - Parameter taskId: The client-side task identifier
    /// - Returns: The task status from the client
    /// - Throws: MCPError if the client doesn't support tasks or the task is not found
    public func getClientTask(_ taskId: String) async throws -> GetTask.Result {
        try await server.getClientTask(taskId: taskId)
    }

    /// Get the result payload of a client task.
    ///
    /// This sends a `tasks/result` request to the client to retrieve the task result.
    /// For non-terminal tasks, this will block until the task completes.
    ///
    /// - Parameter taskId: The client-side task identifier
    /// - Returns: The task result payload
    /// - Throws: MCPError if the client doesn't support tasks or the task is not found
    public func getClientTaskResult(_ taskId: String) async throws -> GetTaskPayload.Result {
        try await server.getClientTaskResult(taskId: taskId)
    }

    /// Get the result payload of a client task, decoded as a specific type.
    ///
    /// This is a convenience method that retrieves the task result and decodes it
    /// as the expected result type.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Send a task-augmented elicitation to the client
    /// let createResult = try await server.experimental.tasks.elicitAsTask(...)
    ///
    /// // Get the result decoded as ElicitResult
    /// let result: ElicitResult = try await server.experimental.tasks.getClientTaskResult(
    ///     createResult.task.taskId,
    ///     as: ElicitResult.self
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - taskId: The client-side task identifier
    ///   - type: The type to decode the result as
    /// - Returns: The task result decoded as the specified type
    /// - Throws: MCPError or DecodingError if the result cannot be decoded
    public func getClientTaskResult<T: Decodable & Sendable>(
        _ taskId: String,
        as type: T.Type
    ) async throws -> T {
        try await server.getClientTaskResultAs(taskId: taskId, type: type)
    }

    /// Poll a client task until it reaches a terminal state.
    ///
    /// This method repeatedly polls the client for task status until the task
    /// reaches a terminal state (completed, failed, or cancelled).
    ///
    /// The polling interval is determined by the `pollInterval` returned by the client,
    /// defaulting to 500ms if not specified.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Start a task-augmented request
    /// let createResult = try await server.experimental.tasks.elicitAsTask(...)
    ///
    /// // Poll until complete
    /// for try await status in server.experimental.tasks.pollClientTask(createResult.task.taskId) {
    ///     print("Task status: \(status)")
    /// }
    ///
    /// // Get the final result
    /// let result = try await server.experimental.tasks.getClientTaskResult(
    ///     createResult.task.taskId,
    ///     as: ElicitResult.self
    /// )
    /// ```
    ///
    /// - Parameter taskId: The client-side task identifier
    /// - Returns: An async stream of task statuses, ending when terminal
    public func pollClientTask(_ taskId: String) -> AsyncThrowingStream<TaskStatus, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    while true {
                        let result = try await server.getClientTask(taskId: taskId)
                        continuation.yield(result.status)

                        if result.status.isTerminal {
                            continuation.finish()
                            return
                        }

                        // Wait for poll interval (default 500ms)
                        let intervalMs = result.pollInterval ?? 500
                        try await Task.sleep(for: .milliseconds(intervalMs))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Poll a client task until terminal, then return the final result.
    ///
    /// This is a convenience method that polls until the task completes and then
    /// retrieves and decodes the result.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Send a task-augmented elicitation and wait for result
    /// let createResult = try await server.experimental.tasks.elicitAsTask(...)
    /// let elicitResult: ElicitResult = try await server.experimental.tasks.pollClientTaskResult(
    ///     createResult.task.taskId,
    ///     as: ElicitResult.self
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - taskId: The client-side task identifier
    ///   - type: The type to decode the result as
    /// - Returns: The task result decoded as the specified type
    /// - Throws: MCPError or DecodingError if the result cannot be decoded
    public func pollClientTaskResult<T: Decodable & Sendable>(
        _ taskId: String,
        as type: T.Type
    ) async throws -> T {
        // Poll until terminal
        for try await _ in pollClientTask(taskId) {
            // Just consume the stream until terminal
        }

        // Get the final result
        return try await getClientTaskResult(taskId, as: type)
    }
}
