import Foundation

// MARK: - Task Result Handler

/// Handler for `tasks/result` that implements the message queue pattern.
///
/// This handler:
/// 1. Dequeues pending messages (elicitations, sampling) for the task
/// 2. Sends them to the client via the response stream
/// 3. Waits for responses and resolves them back to callers
/// 4. Blocks until task reaches terminal state
/// 5. Returns the final result
///
/// The handler also implements `ResponseRouter` to route incoming responses
/// back to waiting task handlers.
///
/// - Important: This is an experimental API that may change without notice.
public final class TaskResultHandler: Sendable, ResponseRouter {
    private let store: any TaskStore
    private let queue: any TaskMessageQueue

    /// Create a task result handler.
    ///
    /// - Parameters:
    ///   - store: The task store for reading task state
    ///   - queue: The message queue for pending messages
    public init(store: any TaskStore, queue: any TaskMessageQueue) {
        self.store = store
        self.queue = queue
    }

    /// Handle a `tasks/result` request.
    ///
    /// This implements the dequeue-send-wait loop:
    /// 1. Dequeue all pending messages
    /// 2. Send each via the provided send function with relatedRequestId
    /// 3. If task not terminal, wait for status change or new messages
    /// 4. Loop until task is terminal
    /// 5. Return final result with related-task metadata
    ///
    /// - Parameters:
    ///   - taskId: The task to get results for
    ///   - sendMessage: Closure to send queued messages to the client
    /// - Returns: The task result with related-task metadata
    /// - Throws: MCPError if task not found or processing fails
    public func handle(
        taskId: String,
        sendMessage: @Sendable (Data) async throws -> Void
    ) async throws -> GetTaskPayload.Result {
        while true {
            // Check task exists
            guard let task = await store.getTask(taskId: taskId) else {
                throw MCPError.invalidParams("Task not found: \(taskId)")
            }

            // Deliver all queued messages
            try await deliverQueuedMessages(taskId: taskId, sendMessage: sendMessage)

            // If task is terminal, return result
            if isTerminalStatus(task.status) {
                let result = await store.getResult(taskId: taskId)
                let relatedTaskMeta: [String: Value] = [
                    relatedTaskMetaKey: .object(["taskId": .string(taskId)])
                ]

                // Flatten result fields into extraFields
                return GetTaskPayload.Result(
                    fromResultValue: result,
                    _meta: relatedTaskMeta
                )
            }

            // Wait for task update (status change or new messages)
            try await waitForTaskUpdate(taskId: taskId)
        }
    }

    /// Deliver all queued messages for a task.
    ///
    /// - Parameters:
    ///   - taskId: The task identifier
    ///   - sendMessage: Closure to send messages to the client
    private func deliverQueuedMessages(
        taskId: String,
        sendMessage: @Sendable (Data) async throws -> Void
    ) async throws {
        while let message = await queue.dequeue(taskId: taskId) {
            // Send the message to the client
            try await sendMessage(message.data)
        }
    }

    /// Wait for a task update (status change or new message).
    ///
    /// - Parameter taskId: The task identifier
    private func waitForTaskUpdate(taskId: String) async throws {
        // We need to wait for either:
        // 1. Task status to change (via store.waitForUpdate)
        // 2. A new message to be queued (via queue.waitForMessage)
        //
        // For simplicity, we'll use the store's wait which is signaled
        // both on status changes and when messages are queued.
        try await store.waitForUpdate(taskId: taskId)
    }

    /// Route a response back to a waiting resolver.
    ///
    /// This is called when a response arrives for a queued request
    /// (e.g., elicitation or sampling response).
    ///
    /// - Parameters:
    ///   - requestId: The request ID of the original request
    ///   - response: The response value
    /// - Returns: True if the response was routed, false if no resolver found
    public func routeResponse(requestId: RequestId, response: Value) async -> Bool {
        guard let resolver = await queue.removeResolver(forRequestId: requestId) else {
            return false
        }
        await resolver.setResult(response)
        return true
    }

    /// Route an error back to a waiting resolver.
    ///
    /// - Parameters:
    ///   - requestId: The request ID of the original request
    ///   - error: The error
    /// - Returns: True if the error was routed, false if no resolver found
    public func routeError(requestId: RequestId, error: any Error) async -> Bool {
        guard let resolver = await queue.removeResolver(forRequestId: requestId) else {
            return false
        }
        await resolver.setError(error)
        return true
    }
}
