import Foundation

// MARK: - Response Router

/// Protocol for routing responses back to waiting task handlers.
///
/// When a task handler calls `elicit()` or `createMessage()`, it queues a request
/// and waits for a response. This protocol allows the response to be routed back
/// to the waiting handler's resolver when it arrives.
///
/// Implementations should check if they have a pending resolver for the given
/// request ID and, if so, deliver the response to that resolver.
///
/// ## Example
///
/// ```swift
/// // Register the router with the session
/// session.addResponseRouter(taskResultHandler)
///
/// // When a response arrives:
/// for router in responseRouters {
///     if router.routeResponse(requestId: responseId, response: responseData) {
///         // Response was handled by this router
///         return
///     }
/// }
/// // Fall through to normal response handling
/// ```
///
/// - Important: This is an experimental API that may change without notice.
public protocol ResponseRouter: Sendable {
    /// Route a response back to a waiting resolver.
    ///
    /// - Parameters:
    ///   - requestId: The request ID of the original request
    ///   - response: The response data
    /// - Returns: True if the response was routed (resolver found), false otherwise
    func routeResponse(requestId: RequestId, response: Value) async -> Bool

    /// Route an error back to a waiting resolver.
    ///
    /// - Parameters:
    ///   - requestId: The request ID of the original request
    ///   - error: The error
    /// - Returns: True if the error was routed (resolver found), false otherwise
    func routeError(requestId: RequestId, error: any Error) async -> Bool
}

// MARK: - Resolver

/// A resolver for passing results between async contexts.
///
/// This is used to route responses back to waiting task handlers.
/// When a task-augmented handler calls `elicit()` or `createMessage()`,
/// it creates a resolver and waits on it. When the response arrives
/// via `tasks/result`, the resolver is used to deliver the response.
///
/// ## Example
///
/// ```swift
/// // In task handler
/// let resolver = Resolver<ElicitResult>()
/// await queue.enqueueWithResolver(taskId: taskId, message: request, resolver: resolver)
/// let result = try await resolver.wait()
///
/// // In tasks/result handler
/// // ... route response back via resolver
/// await resolver.setResult(response)
/// ```
public actor Resolver<T: Sendable> {
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    public init() {}

    /// Set the result value and wake up waiters.
    public func setResult(_ value: T) {
        if result != nil {
            // Already completed, ignore
            return
        }
        result = .success(value)
        continuation?.resume(returning: value)
        continuation = nil
    }

    /// Set an exception and wake up waiters.
    public func setError(_ error: any Error) {
        if result != nil {
            // Already completed, ignore
            return
        }
        result = .failure(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }

    /// Wait for the result and return it, or throw the exception.
    public func wait() async throws -> T {
        // Check if already resolved
        if let result {
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        // Wait for result
        return try await withCheckedThrowingContinuation { cont in
            // Check again (race with setResult)
            if let result {
                switch result {
                case .success(let value):
                    cont.resume(returning: value)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            } else {
                continuation = cont
            }
        }
    }

    /// Return true if the resolver has been completed.
    public var isDone: Bool {
        result != nil
    }
}

// MARK: - Queued Message

/// Represents a message queued for side-channel delivery via tasks/result.
///
/// This is used during task execution to queue requests (like elicitation or sampling)
/// that need to be delivered to the client when it polls for task results.
public enum QueuedMessage: Sendable {
    /// A JSON-RPC request to be sent to the client
    case request(Data, timestamp: Date)
    /// A JSON-RPC notification to be sent to the client
    case notification(Data, timestamp: Date)
    /// A JSON-RPC response
    case response(Data, timestamp: Date)
    /// A JSON-RPC error response
    case error(Data, timestamp: Date)

    /// The timestamp when this message was queued.
    public var timestamp: Date {
        switch self {
        case .request(_, let ts), .notification(_, let ts),
             .response(_, let ts), .error(_, let ts):
            return ts
        }
    }

    /// The message data.
    public var data: Data {
        switch self {
        case .request(let d, _), .notification(let d, _),
             .response(let d, _), .error(let d, _):
            return d
        }
    }
}

/// A queued message with an associated resolver for response routing.
///
/// When a request is queued that expects a response (like elicitation),
/// this struct pairs the request with a resolver that will receive the response.
public struct QueuedRequestWithResolver: Sendable {
    /// The queued message.
    public let message: QueuedMessage
    /// The resolver to receive the response.
    public let resolver: Resolver<Value>
    /// The original request ID used for routing the response back.
    public let originalRequestId: RequestId

    public init(message: QueuedMessage, resolver: Resolver<Value>, originalRequestId: RequestId) {
        self.message = message
        self.resolver = resolver
        self.originalRequestId = originalRequestId
    }
}

/// Protocol for managing per-task FIFO message queues.
///
/// This allows pluggable queue implementations (in-memory, Redis, other distributed queues, etc.).
/// Each method accepts taskId to enable a single queue instance to manage messages for multiple tasks.
///
/// All methods are async to support external storage implementations.
///
/// - Important: This is an experimental API that may change without notice.
public protocol TaskMessageQueue: Sendable {
    /// Adds a message to the end of the queue for a specific task.
    ///
    /// - Parameters:
    ///   - taskId: The task identifier
    ///   - message: The message to enqueue
    ///   - maxSize: Optional maximum queue size. If specified and queue is full, throws an error.
    /// - Throws: Error if maxSize is specified and would be exceeded
    func enqueue(taskId: String, message: QueuedMessage, maxSize: Int?) async throws

    /// Adds a request message with a resolver for response routing.
    ///
    /// This is used for requests that expect a response (like elicitation or sampling).
    /// The resolver will be used to deliver the response when it arrives.
    ///
    /// - Parameters:
    ///   - taskId: The task identifier
    ///   - request: The request message with resolver
    ///   - maxSize: Optional maximum queue size
    /// - Throws: Error if maxSize is specified and would be exceeded
    func enqueueWithResolver(taskId: String, request: QueuedRequestWithResolver, maxSize: Int?) async throws

    /// Removes and returns the first message from the queue for a specific task.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The first message, or nil if the queue is empty
    func dequeue(taskId: String) async -> QueuedMessage?

    /// Removes and returns the first message with its resolver from the queue.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: The first message with resolver, or nil if empty
    func dequeueWithResolver(taskId: String) async -> QueuedRequestWithResolver?

    /// Removes and returns all messages from the queue for a specific task.
    ///
    /// Used when tasks are cancelled or failed to clean up pending messages.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: Array of all messages that were in the queue
    func dequeueAll(taskId: String) async -> [QueuedMessage]

    /// Check if the queue for a task is empty.
    ///
    /// - Parameter taskId: The task identifier
    /// - Returns: True if the queue is empty or doesn't exist
    func isEmpty(taskId: String) async -> Bool

    /// Wait for a message to become available for the specified task.
    ///
    /// This method blocks until a message is enqueued for the task.
    /// Used by `tasks/result` to implement long-polling behavior.
    ///
    /// - Parameter taskId: The task identifier
    /// - Throws: Error if waiting is interrupted
    func waitForMessage(taskId: String) async throws

    /// Notify waiters that a message is available for the specified task.
    ///
    /// This should be called after enqueueing a message.
    ///
    /// - Parameter taskId: The task identifier
    func notifyMessageAvailable(taskId: String) async

    /// Get the resolver for a pending request by its request ID.
    ///
    /// This is used to route responses back to the waiting handler.
    ///
    /// - Parameter requestId: The request ID to look up
    /// - Returns: The resolver if found, or nil
    func getResolver(forRequestId requestId: RequestId) async -> Resolver<Value>?

    /// Remove and return the resolver for a pending request.
    ///
    /// - Parameter requestId: The request ID to look up
    /// - Returns: The resolver if found, or nil
    func removeResolver(forRequestId requestId: RequestId) async -> Resolver<Value>?
}

/// An in-memory implementation of ``TaskMessageQueue`` for demonstration purposes.
///
/// This implementation stores messages in memory, organized by task ID.
/// Messages are stored in FIFO queues per task.
///
/// - Important: This is not suitable for production use in distributed systems.
///   For production, consider implementing TaskMessageQueue with Redis or other distributed queues.
public actor InMemoryTaskMessageQueue: TaskMessageQueue {
    /// Internal storage for a queued item that may have a resolver.
    private struct QueuedItem {
        let message: QueuedMessage
        let resolver: Resolver<Value>?
        let originalRequestId: RequestId?
    }

    /// Dictionary of message queues keyed by task ID.
    private var queues: [String: [QueuedItem]] = [:]

    /// Pending request resolvers keyed by request ID for response routing.
    private var pendingResolvers: [RequestId: Resolver<Value>] = [:]

    /// Waiters for message availability, keyed by task ID.
    private var messageWaiters: [String: [CheckedContinuation<Void, any Error>]] = [:]

    /// Create an in-memory task message queue.
    public init() {}

    public func enqueue(taskId: String, message: QueuedMessage, maxSize: Int?) async throws {
        var queue = queues[taskId, default: []]

        if let maxSize, queue.count >= maxSize {
            throw MCPError.internalError("Task message queue overflow: queue size (\(queue.count)) exceeds maximum (\(maxSize))")
        }

        queue.append(QueuedItem(message: message, resolver: nil, originalRequestId: nil))
        queues[taskId] = queue

        // Notify waiters that a message is available
        await notifyMessageAvailable(taskId: taskId)
    }

    public func enqueueWithResolver(taskId: String, request: QueuedRequestWithResolver, maxSize: Int?) async throws {
        var queue = queues[taskId, default: []]

        if let maxSize, queue.count >= maxSize {
            throw MCPError.internalError("Task message queue overflow: queue size (\(queue.count)) exceeds maximum (\(maxSize))")
        }

        let item = QueuedItem(
            message: request.message,
            resolver: request.resolver,
            originalRequestId: request.originalRequestId
        )
        queue.append(item)
        queues[taskId] = queue

        // Store the resolver for response routing
        pendingResolvers[request.originalRequestId] = request.resolver

        // Notify waiters that a message is available
        await notifyMessageAvailable(taskId: taskId)
    }

    public func dequeue(taskId: String) async -> QueuedMessage? {
        guard var queue = queues[taskId], !queue.isEmpty else {
            return nil
        }

        let item = queue.removeFirst()
        queues[taskId] = queue
        return item.message
    }

    public func dequeueWithResolver(taskId: String) async -> QueuedRequestWithResolver? {
        guard var queue = queues[taskId], !queue.isEmpty else {
            return nil
        }

        let item = queue.removeFirst()
        queues[taskId] = queue

        guard let resolver = item.resolver, let originalRequestId = item.originalRequestId else {
            // Re-queue the message if it doesn't have a resolver
            // and try the next one
            queues[taskId, default: []].insert(QueuedItem(message: item.message, resolver: nil, originalRequestId: nil), at: 0)
            return nil
        }

        return QueuedRequestWithResolver(
            message: item.message,
            resolver: resolver,
            originalRequestId: originalRequestId
        )
    }

    public func dequeueAll(taskId: String) async -> [QueuedMessage] {
        let items = queues.removeValue(forKey: taskId) ?? []
        return items.map(\.message)
    }

    public func isEmpty(taskId: String) async -> Bool {
        queues[taskId]?.isEmpty ?? true
    }

    public func waitForMessage(taskId: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            messageWaiters[taskId, default: []].append(continuation)
        }
    }

    public func notifyMessageAvailable(taskId: String) async {
        guard let waiters = messageWaiters.removeValue(forKey: taskId), !waiters.isEmpty else {
            return
        }
        for continuation in waiters {
            continuation.resume()
        }
    }

    public func getResolver(forRequestId requestId: RequestId) async -> Resolver<Value>? {
        pendingResolvers[requestId]
    }

    public func removeResolver(forRequestId requestId: RequestId) async -> Resolver<Value>? {
        pendingResolvers.removeValue(forKey: requestId)
    }

    /// Clear all queues (useful for testing or graceful shutdown).
    public func cleanUp() async {
        queues.removeAll()
        // Cancel all message waiters
        for (_, continuations) in messageWaiters {
            for continuation in continuations {
                continuation.resume(throwing: CancellationError())
            }
        }
        messageWaiters.removeAll()
        // Error out all pending resolvers
        for (_, resolver) in pendingResolvers {
            await resolver.setError(CancellationError())
        }
        pendingResolvers.removeAll()
    }
}
