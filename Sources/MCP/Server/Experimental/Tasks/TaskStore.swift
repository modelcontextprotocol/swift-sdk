import Foundation

/// Protocol for storing and retrieving task state and results.
///
/// This abstraction allows pluggable task storage implementations
/// (in-memory, database, distributed cache, etc.).
///
/// All methods are async to support various backends.
///
/// - Important: This is an experimental API that may change without notice.
public protocol TaskStore: Sendable {
    /// Create a new task with the given metadata.
    ///
    /// - Parameters:
    ///   - metadata: Task metadata (TTL, etc.)
    ///   - taskId: Optional task ID. If nil, implementation should generate one.
    /// - Returns: The created Task with status `working`
    /// - Throws: Error if taskId already exists
    func createTask(metadata: TaskMetadata, taskId: String?) async throws -> MCPTask

    /// Get a task by ID.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The Task, or nil if not found
    func getTask(taskId: String) async -> MCPTask?

    /// Update a task's status and/or message.
    ///
    /// - Parameters:
    ///   - taskId: The task identifier
    ///   - status: New status (if changing)
    ///   - statusMessage: New status message (if changing)
    /// - Returns: The updated Task
    /// - Throws: Error if task not found or if attempting to transition from a terminal status
    func updateTask(taskId: String, status: TaskStatus?, statusMessage: String?) async throws -> MCPTask

    /// Store the result for a task.
    ///
    /// - Parameters:
    ///   - taskId: The task identifier
    ///   - result: The result to store
    /// - Throws: Error if task not found
    func storeResult(taskId: String, result: Value) async throws

    /// Get the stored result for a task.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The stored result, or nil if not available
    func getResult(taskId: String) async -> Value?

    /// List tasks with pagination.
    ///
    /// - Parameter cursor: Optional cursor for pagination
    /// - Returns: Tuple of (tasks, nextCursor). nextCursor is nil if no more pages.
    func listTasks(cursor: String?) async -> (tasks: [MCPTask], nextCursor: String?)

    /// Delete a task.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: True if deleted, false if not found
    func deleteTask(taskId: String) async -> Bool

    /// Wait for an update to the specified task.
    ///
    /// This method blocks until the task's status changes or a message becomes available.
    /// Used by `tasks/result` to implement long-polling behavior.
    ///
    /// - Parameter taskId: The task identifier
    /// - Throws: Error if waiting is interrupted
    func waitForUpdate(taskId: String) async throws

    /// Notify waiters that a task has been updated.
    ///
    /// This should be called after updating a task's status or queueing a message.
    ///
    /// - Parameter taskId: The task identifier
    func notifyUpdate(taskId: String) async
}

/// Checks if a task status represents a terminal state.
///
/// Terminal states are those where the task has finished and will not change.
///
/// - Parameter status: The task status to check
/// - Returns: True if the status is terminal (completed, failed, or cancelled)
public func isTerminalStatus(_ status: TaskStatus) -> Bool {
    switch status {
    case .completed, .failed, .cancelled:
        return true
    case .working, .inputRequired:
        return false
    }
}

/// An in-memory implementation of ``TaskStore`` for demonstration and testing purposes.
///
/// This implementation stores all tasks in memory and provides lazy cleanup
/// based on the TTL duration specified in the task metadata.
///
/// - Important: This is not suitable for production use as all data is lost on restart.
///   For production, consider implementing TaskStore with a database or distributed cache.
public actor InMemoryTaskStore: TaskStore {
    /// Internal storage for a task and its result.
    private struct StoredTask {
        var task: MCPTask
        var result: Value?
        /// Time when this task should be removed (nil = never)
        var expiresAt: Date?
    }

    /// Dictionary of stored tasks keyed by task ID.
    private var tasks: [String: StoredTask] = [:]

    /// Page size for listing tasks.
    private let pageSize: Int

    /// A waiter entry with unique ID for cancellation tracking.
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Waiters for task updates, keyed by task ID.
    /// Each waiter has a unique ID so it can be individually cancelled.
    private var waiters: [String: [Waiter]] = [:]

    /// Create an in-memory task store.
    ///
    /// - Parameter pageSize: The number of tasks to return per page in `listTasks`. Defaults to 10.
    public init(pageSize: Int = 10) {
        self.pageSize = pageSize
    }

    /// Calculate expiry date from TTL in milliseconds.
    private func calculateExpiry(ttl: Int?) -> Date? {
        guard let ttl else { return nil }
        return Date().addingTimeInterval(Double(ttl) / 1000.0)
    }

    /// Check if a stored task has expired.
    private func isExpired(_ stored: StoredTask) -> Bool {
        guard let expiresAt = stored.expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// Remove all expired tasks (called lazily during access operations).
    private func cleanUpExpired() {
        let expiredIds = tasks.filter { isExpired($0.value) }.map(\.key)
        for id in expiredIds {
            tasks.removeValue(forKey: id)
        }
    }

    /// Generate a unique task ID using UUID.
    private func generateTaskId() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Create an ISO 8601 timestamp for the current time.
    private func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    public func createTask(metadata: TaskMetadata, taskId: String?) async throws -> MCPTask {
        cleanUpExpired()

        let id = taskId ?? generateTaskId()

        guard tasks[id] == nil else {
            throw MCPError.invalidRequest("Task with ID \(id) already exists")
        }

        let now = currentTimestamp()
        let task = MCPTask(
            taskId: id,
            status: .working,
            ttl: metadata.ttl,
            createdAt: now,
            lastUpdatedAt: now,
            pollInterval: 1000  // Default 1 second poll interval
        )

        tasks[id] = StoredTask(
            task: task,
            result: nil,
            expiresAt: calculateExpiry(ttl: metadata.ttl)
        )

        return task
    }

    public func getTask(taskId: String) async -> MCPTask? {
        cleanUpExpired()
        return tasks[taskId]?.task
    }

    public func updateTask(taskId: String, status: TaskStatus?, statusMessage: String?) async throws -> MCPTask {
        guard var stored = tasks[taskId] else {
            throw MCPError.invalidParams("Task with ID \(taskId) not found")
        }

        // Per spec: Terminal states MUST NOT transition to any other status
        if let newStatus = status, newStatus != stored.task.status, isTerminalStatus(stored.task.status) {
            throw MCPError.invalidRequest("Cannot transition from terminal status '\(stored.task.status.rawValue)'")
        }

        if let newStatus = status {
            stored.task.status = newStatus
        }

        if let message = statusMessage {
            stored.task.statusMessage = message
        }

        stored.task.lastUpdatedAt = currentTimestamp()

        // If task is now terminal and has TTL, reset expiry timer
        if let newStatus = status, isTerminalStatus(newStatus), let ttl = stored.task.ttl {
            stored.expiresAt = calculateExpiry(ttl: ttl)
        }

        tasks[taskId] = stored

        // Notify waiters that the task has been updated
        await notifyUpdate(taskId: taskId)

        return stored.task
    }

    public func storeResult(taskId: String, result: Value) async throws {
        guard var stored = tasks[taskId] else {
            throw MCPError.invalidParams("Task with ID \(taskId) not found")
        }

        stored.result = result
        tasks[taskId] = stored

        // Notify waiters that the task has been updated
        await notifyUpdate(taskId: taskId)
    }

    public func getResult(taskId: String) async -> Value? {
        tasks[taskId]?.result
    }

    public func listTasks(cursor: String?) async -> (tasks: [MCPTask], nextCursor: String?) {
        cleanUpExpired()

        let allTaskIds = Array(tasks.keys).sorted()

        var startIndex = 0
        if let cursor {
            if let index = allTaskIds.firstIndex(of: cursor) {
                startIndex = index + 1
            }
        }

        let pageTaskIds = Array(allTaskIds.dropFirst(startIndex).prefix(pageSize))
        let pageTasks = pageTaskIds.compactMap { tasks[$0]?.task }

        let nextCursor: String? = if startIndex + pageSize < allTaskIds.count, let lastId = pageTaskIds.last {
            lastId
        } else {
            nil
        }

        return (tasks: pageTasks, nextCursor: nextCursor)
    }

    public func deleteTask(taskId: String) async -> Bool {
        tasks.removeValue(forKey: taskId) != nil
    }

    /// Clear all tasks (useful for testing or graceful shutdown).
    public func cleanUp() {
        tasks.removeAll()
        // Cancel all waiters
        for (_, taskWaiters) in waiters {
            for waiter in taskWaiters {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
        waiters.removeAll()
    }

    /// Get all tasks (useful for debugging).
    public func getAllTasks() -> [MCPTask] {
        cleanUpExpired()
        return tasks.values.map(\.task)
    }

    public func waitForUpdate(taskId: String) async throws {
        let waiterId = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters[taskId, default: []].append(Waiter(id: waiterId, continuation: continuation))
            }
        } onCancel: {
            // Schedule cancellation on the actor
            // Note: This runs synchronously when the Task is cancelled
            Task { [weak self] in
                await self?.cancelWaiter(taskId: taskId, waiterId: waiterId)
            }
        }
    }

    /// Cancel a specific waiter by ID.
    /// Called when the waiting Task is cancelled.
    private func cancelWaiter(taskId: String, waiterId: UUID) {
        guard var taskWaiters = waiters[taskId] else { return }

        if let index = taskWaiters.firstIndex(where: { $0.id == waiterId }) {
            let waiter = taskWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())

            if taskWaiters.isEmpty {
                waiters.removeValue(forKey: taskId)
            } else {
                waiters[taskId] = taskWaiters
            }
        }
    }

    public func notifyUpdate(taskId: String) async {
        guard let taskWaiters = waiters.removeValue(forKey: taskId), !taskWaiters.isEmpty else {
            return
        }
        for waiter in taskWaiters {
            waiter.continuation.resume()
        }
    }
}
