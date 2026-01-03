import Foundation

// MARK: - Task Stream Message

/// Messages yielded by streaming task operations.
///
/// Similar to TypeScript SDK's `ResponseMessage`, this enum represents the different
/// types of messages that can occur during task-augmented tool execution.
///
/// ## Example
///
/// ```swift
/// for try await message in await client.experimental.tasks.callToolStream(name: "myTool") {
///     switch message {
///     case .taskCreated(let task):
///         print("Task started: \(task.taskId)")
///     case .taskStatus(let task):
///         print("Status: \(task.status)")
///     case .result(let result):
///         print("Tool completed with \(result.content.count) content blocks")
///     case .error(let error):
///         print("Error: \(error.localizedDescription)")
///     }
/// }
/// ```
public enum TaskStreamMessage: Sendable {
    /// A task has been created. This is always the first message for task-augmented requests.
    case taskCreated(MCPTask)

    /// The task status has changed. Yielded when polling detects a status update.
    case taskStatus(MCPTask)

    /// The task completed successfully with a result.
    case result(CallTool.Result)

    /// The task or request encountered an error.
    case error(MCPError)
}

// MARK: - Experimental Client Features

/// Experimental APIs for MCP clients.
///
/// Access via `client.experimental.tasks`:
/// ```swift
/// // Call a tool as a task
/// let createResult = try await client.experimental.tasks.callToolAsTask(
///     name: "long_running_tool",
///     arguments: ["input": .string("data")]
/// )
///
/// // Get task status
/// let status = try await client.experimental.tasks.getTask(createResult.task.taskId)
///
/// // Get task result when complete
/// let result = try await client.experimental.tasks.getTaskResult(taskId)
///
/// // Poll for completion
/// for try await status in await client.experimental.tasks.pollTask(taskId) {
///     print("Status: \(status.status)")
/// }
/// ```
///
/// - Warning: These APIs are experimental and may change without notice.
public struct ExperimentalClientFeatures: Sendable {
    private let client: Client

    init(client: Client) {
        self.client = client
    }

    /// Task-related experimental APIs.
    public var tasks: ExperimentalClientTasks {
        ExperimentalClientTasks(client: client)
    }
}

/// Experimental task APIs for MCP clients.
///
/// - Warning: These APIs are experimental and may change without notice.
public struct ExperimentalClientTasks: Sendable {
    private let client: Client

    init(client: Client) {
        self.client = client
    }

    /// Get the current status of a task.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The task status information
    /// - Throws: MCPError if the server doesn't support tasks or if the task is not found
    public func getTask(_ taskId: String) async throws -> GetTask.Result {
        try await client.getTask(taskId: taskId)
    }

    /// List all tasks.
    ///
    /// - Parameter cursor: Optional pagination cursor
    /// - Returns: Tuple of (tasks, nextCursor). nextCursor is nil if no more pages.
    /// - Throws: MCPError if the server doesn't support tasks
    public func listTasks(cursor: String? = nil) async throws -> (tasks: [MCPTask], nextCursor: String?) {
        try await client.listTasks(cursor: cursor)
    }

    /// Cancel a running task.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The updated task status after cancellation
    /// - Throws: MCPError if the server doesn't support tasks or if the task is not found
    public func cancelTask(_ taskId: String) async throws -> CancelTask.Result {
        try await client.cancelTask(taskId: taskId)
    }

    /// Get the result payload of a completed task.
    ///
    /// The result type depends on the original request that created the task
    /// (e.g., a tool call result for a task created from `tools/call`).
    ///
    /// - Note: For non-terminal tasks, this will block until the task completes.
    ///   The server implements long-polling behavior.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The task result payload
    /// - Throws: MCPError if the server doesn't support tasks or if the task is not found
    public func getTaskResult(_ taskId: String) async throws -> GetTaskPayload.Result {
        try await client.getTaskResult(taskId: taskId)
    }

    /// Get the result payload of a completed task, decoded as a specific type.
    ///
    /// This is a convenience method that retrieves the task result and decodes it
    /// as the expected result type. Use this when you know the type of result
    /// the task will produce.
    ///
    /// - Note: For non-terminal tasks, this will block until the task completes.
    ///   The server implements long-polling behavior.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Start a task-augmented tool call
    /// let createResult = try await client.experimental.tasks.callToolAsTask(
    ///     name: "long_running_tool",
    ///     arguments: ["input": .string("data")]
    /// )
    ///
    /// // Get the result decoded as CallTool.Result
    /// let result: CallTool.Result = try await client.experimental.tasks.getTaskResult(
    ///     createResult.task.taskId,
    ///     as: CallTool.Result.self
    /// )
    /// print("Tool returned \(result.content.count) content blocks")
    /// ```
    ///
    /// - Parameters:
    ///   - taskId: The task identifier
    ///   - type: The type to decode the result as
    /// - Returns: The task result decoded as the specified type
    /// - Throws: MCPError if the server doesn't support tasks, if the task is not found,
    ///           or DecodingError if the result cannot be decoded as the specified type
    public func getTaskResult<T: Decodable & Sendable>(_ taskId: String, as type: T.Type) async throws -> T {
        try await client.getTaskResultAs(taskId: taskId, type: type)
    }

    /// Get the tool result of a completed task.
    ///
    /// This is a convenience method specifically for tasks created from `callToolAsTask()`.
    /// It retrieves and decodes the result as `CallTool.Result`.
    ///
    /// - Note: For non-terminal tasks, this will block until the task completes.
    ///   The server implements long-polling behavior.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let createResult = try await client.experimental.tasks.callToolAsTask(
    ///     name: "process_data",
    ///     arguments: ["input": .string("data")]
    /// )
    ///
    /// let toolResult = try await client.experimental.tasks.getToolResult(createResult.task.taskId)
    /// for content in toolResult.content {
    ///     // Process content blocks
    /// }
    /// ```
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The tool call result
    /// - Throws: MCPError if the server doesn't support tasks or if the task is not found
    public func getToolResult(_ taskId: String) async throws -> CallTool.Result {
        try await client.getTaskResultAs(taskId: taskId, type: CallTool.Result.self)
    }

    /// Call a tool as a task, returning immediately with a task reference.
    ///
    /// This is the recommended way to call tools that may take a long time to complete.
    /// Instead of waiting for the result, this method returns a `CreateTaskResult`
    /// containing the task ID. You can then poll for the result using `getTaskResult()`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Start the task
    /// let createResult = try await client.experimental.tasks.callToolAsTask(
    ///     name: "long_running_tool",
    ///     arguments: ["input": .string("data")],
    ///     ttl: 60000  // Keep results for 60 seconds
    /// )
    /// print("Task started: \(createResult.task.taskId)")
    ///
    /// // Poll for result
    /// let result = try await client.experimental.tasks.getTaskResult(createResult.task.taskId)
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call
    ///   - arguments: Optional arguments for the tool
    ///   - ttl: Optional time-to-live in milliseconds for the task result
    /// - Returns: The created task information
    /// - Throws: MCPError if the server doesn't support tasks or the request fails
    public func callToolAsTask(
        name: String,
        arguments: [String: Value]? = nil,
        ttl: Int? = nil
    ) async throws -> CreateTaskResult {
        try await client.callToolAsTask(name: name, arguments: arguments, ttl: ttl)
    }

    /// Poll a task until it reaches a terminal state.
    ///
    /// This method repeatedly polls the task status until it reaches a terminal
    /// state (completed, failed, or cancelled). It yields each status update as
    /// it occurs.
    ///
    /// The polling respects the server's suggested `pollInterval` if provided,
    /// otherwise defaults to 1 second.
    ///
    /// ## Example
    ///
    /// ```swift
    /// for try await status in await client.experimental.tasks.pollTask(taskId) {
    ///     print("Status: \(status.status)")
    ///     if status.status == .inputRequired {
    ///         // Handle user input request
    ///     }
    /// }
    /// // Task is now terminal - get the result
    /// let result = try await client.experimental.tasks.getTaskResult(taskId)
    /// ```
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: An async stream that yields task status updates until terminal
    /// - Throws: MCPError if polling fails
    public func pollTask(_ taskId: String) async -> AsyncThrowingStream<GetTask.Result, Error> {
        await client.pollTask(taskId: taskId)
    }

    /// Wait for a task to reach a terminal state.
    ///
    /// This is a convenience method that polls the task and returns only
    /// when it has completed, failed, or been cancelled.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The final task status
    /// - Throws: MCPError if polling fails
    public func pollUntilTerminal(_ taskId: String) async throws -> GetTask.Result {
        try await client.pollUntilTerminal(taskId: taskId)
    }

    /// Call a tool as a task and wait for the result.
    ///
    /// This is a convenience method that combines `callToolAsTask()` and
    /// `getTaskResult()`. It starts the task and waits for the result.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call
    ///   - arguments: Optional arguments for the tool
    ///   - ttl: Optional time-to-live in milliseconds for the task result
    /// - Returns: The tool result (same as `callTool()`)
    /// - Throws: MCPError if the request fails or the task fails
    public func callToolAsTaskAndWait(
        name: String,
        arguments: [String: Value]? = nil,
        ttl: Int? = nil
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        try await client.callToolAsTaskAndWait(name: name, arguments: arguments, ttl: ttl)
    }

    /// Call a tool as a task and stream status updates until completion.
    ///
    /// This method provides streaming access to tool execution, allowing you to
    /// observe intermediate task status updates for long-running tool calls.
    /// It combines `callToolAsTask()`, `pollTask()`, and `getTaskResult()` into
    /// a single stream that yields all events.
    ///
    /// The stream is guaranteed to end with either a `.result` or `.error` message.
    ///
    /// This is similar to TypeScript SDK's `callToolStream` method.
    ///
    /// ## Example
    ///
    /// ```swift
    /// for try await message in await client.experimental.tasks.callToolStream(name: "myTool") {
    ///     switch message {
    ///     case .taskCreated(let task):
    ///         print("Task started: \(task.taskId)")
    ///     case .taskStatus(let task):
    ///         print("Status: \(task.status), message: \(task.statusMessage ?? "none")")
    ///     case .result(let result):
    ///         print("Tool completed with \(result.content.count) content blocks")
    ///     case .error(let error):
    ///         print("Error: \(error.localizedDescription)")
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call
    ///   - arguments: Optional arguments for the tool
    ///   - ttl: Optional time-to-live in milliseconds for the task result
    /// - Returns: An async stream that yields `TaskStreamMessage` values
    public func callToolStream(
        name: String,
        arguments: [String: Value]? = nil,
        ttl: Int? = nil
    ) async -> AsyncThrowingStream<TaskStreamMessage, Error> {
        await client.callToolStream(name: name, arguments: arguments, ttl: ttl)
    }
}
