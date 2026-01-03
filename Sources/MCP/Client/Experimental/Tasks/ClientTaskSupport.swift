import Foundation

// MARK: - Client Task Handlers

/// Container for client-side task handlers.
///
/// This allows clients to handle task requests from servers (bidirectional task support).
/// When a server initiates a task on the client, these handlers process the requests.
///
/// - Important: This is an experimental API that may change without notice.
///
/// ## Example
///
/// ```swift
/// let handlers = ExperimentalClientTaskHandlers(
///     getTask: { taskId in
///         // Return task status
///         return GetTask.Result(task: myTask)
///     },
///     listTasks: { cursor in
///         // Return list of tasks
///         return ListTasks.Result(tasks: myTasks)
///     }
/// )
///
/// let client = Client(name: "MyClient", version: "1.0")
/// client.enableTaskHandlers(handlers)
/// ```
public struct ExperimentalClientTaskHandlers: Sendable {
    /// Handler for `tasks/get` requests from the server.
    public typealias GetTaskHandler = @Sendable (String) async throws -> GetTask.Result

    /// Handler for `tasks/list` requests from the server.
    public typealias ListTasksHandler = @Sendable (String?) async throws -> ListTasks.Result

    /// Handler for `tasks/cancel` requests from the server.
    public typealias CancelTaskHandler = @Sendable (String) async throws -> CancelTask.Result

    /// Handler for `tasks/result` requests from the server.
    public typealias GetTaskPayloadHandler = @Sendable (String) async throws -> GetTaskPayload.Result

    /// Handler for task-augmented sampling requests from the server.
    ///
    /// This is called when the server sends a `sampling/createMessage` request with a `task` field,
    /// indicating the client should run the sampling as a background task.
    public typealias TaskAugmentedSamplingHandler = @Sendable (CreateSamplingMessage.Parameters, TaskMetadata) async throws -> CreateTaskResult

    /// Handler for task-augmented elicitation requests from the server.
    ///
    /// This is called when the server sends an `elicitation/create` request with a `task` field,
    /// indicating the client should run the elicitation as a background task.
    public typealias TaskAugmentedElicitationHandler = @Sendable (Elicit.Parameters, TaskMetadata) async throws -> CreateTaskResult

    /// Handler for `tasks/get` requests.
    public var getTask: GetTaskHandler?

    /// Handler for `tasks/list` requests.
    public var listTasks: ListTasksHandler?

    /// Handler for `tasks/cancel` requests.
    public var cancelTask: CancelTaskHandler?

    /// Handler for `tasks/result` requests.
    public var getTaskPayload: GetTaskPayloadHandler?

    /// Handler for task-augmented sampling requests.
    public var taskAugmentedSampling: TaskAugmentedSamplingHandler?

    /// Handler for task-augmented elicitation requests.
    public var taskAugmentedElicitation: TaskAugmentedElicitationHandler?

    /// Create empty task handlers.
    public init() {}

    /// Create task handlers with specific implementations.
    public init(
        getTask: GetTaskHandler? = nil,
        listTasks: ListTasksHandler? = nil,
        cancelTask: CancelTaskHandler? = nil,
        getTaskPayload: GetTaskPayloadHandler? = nil,
        taskAugmentedSampling: TaskAugmentedSamplingHandler? = nil,
        taskAugmentedElicitation: TaskAugmentedElicitationHandler? = nil
    ) {
        self.getTask = getTask
        self.listTasks = listTasks
        self.cancelTask = cancelTask
        self.getTaskPayload = getTaskPayload
        self.taskAugmentedSampling = taskAugmentedSampling
        self.taskAugmentedElicitation = taskAugmentedElicitation
    }

    /// Build the client tasks capability based on which handlers are implemented.
    ///
    /// - Returns: The capability declaration, or nil if no handlers are set
    public func buildCapability() -> Client.Capabilities.Tasks? {
        // Check if any handlers are set
        let hasTaskHandlers = getTask != nil || listTasks != nil || cancelTask != nil || getTaskPayload != nil
        let hasAugmentedHandlers = taskAugmentedSampling != nil || taskAugmentedElicitation != nil

        guard hasTaskHandlers || hasAugmentedHandlers else {
            return nil
        }

        var requests: Client.Capabilities.Tasks.Requests?
        if hasAugmentedHandlers {
            requests = .init(
                sampling: taskAugmentedSampling != nil ? .init(createMessage: .init()) : nil,
                elicitation: taskAugmentedElicitation != nil ? .init(create: .init()) : nil
            )
        }

        return .init(
            list: listTasks != nil ? .init() : nil,
            cancel: cancelTask != nil ? .init() : nil,
            requests: requests
        )
    }
}

// MARK: - Client Task Support

/// Configuration for client-side task support.
///
/// This enables clients to run tasks initiated by servers (bidirectional task support).
/// The client can optionally provide its own task store and message queue for
/// tracking and managing tasks.
///
/// - Important: This is an experimental API that may change without notice.
public final class ClientTaskSupport: Sendable {
    /// The task store for persisting task state.
    public let store: any TaskStore

    /// The message queue for side-channel communication.
    public let queue: any TaskMessageQueue

    /// The task handlers.
    public let handlers: ExperimentalClientTaskHandlers

    /// Create client task support with custom store and queue.
    ///
    /// - Parameters:
    ///   - store: The task store implementation
    ///   - queue: The message queue implementation
    ///   - handlers: The task handlers
    public init(
        store: any TaskStore,
        queue: any TaskMessageQueue,
        handlers: ExperimentalClientTaskHandlers
    ) {
        self.store = store
        self.queue = queue
        self.handlers = handlers
    }

    /// Create in-memory client task support.
    ///
    /// - Parameter handlers: The task handlers
    /// - Returns: ClientTaskSupport configured with in-memory store and queue
    public static func inMemory(handlers: ExperimentalClientTaskHandlers = .init()) -> ClientTaskSupport {
        ClientTaskSupport(
            store: InMemoryTaskStore(),
            queue: InMemoryTaskMessageQueue(),
            handlers: handlers
        )
    }
}

// MARK: - Client Extension

extension Client {
    /// Enable task handlers on this client.
    ///
    /// This registers handlers for task requests from the server, enabling
    /// bidirectional task support where the server can initiate tasks on the client.
    ///
    /// This method also integrates task-augmented sampling and elicitation handlers
    /// that are called when the server sends requests with a `task` field, expecting
    /// `CreateTaskResult` instead of the normal result.
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// - Parameter taskSupport: The client task support configuration
    /// - Returns: Self for chaining
    @discardableResult
    public func enableTaskHandlers(_ taskSupport: ClientTaskSupport) -> Self {
        let handlers = taskSupport.handlers

        // Update capabilities based on handlers
        if let tasksCap = handlers.buildCapability() {
            capabilities.tasks = tasksCap
        }

        // Register handlers for task requests from server
        if let getTaskHandler = handlers.getTask {
            withRequestHandler(GetTask.self) { params, _ in
                try await getTaskHandler(params.taskId)
            }
        }

        if let listTasksHandler = handlers.listTasks {
            withRequestHandler(ListTasks.self) { params, _ in
                try await listTasksHandler(params.cursor)
            }
        }

        if let cancelTaskHandler = handlers.cancelTask {
            withRequestHandler(CancelTask.self) { params, _ in
                try await cancelTaskHandler(params.taskId)
            }
        }

        if let getTaskPayloadHandler = handlers.getTaskPayload {
            withRequestHandler(GetTaskPayload.self) { params, _ in
                try await getTaskPayloadHandler(params.taskId)
            }
        }

        // Register task-augmented sampling/elicitation handlers
        // These are stored separately and checked at dispatch time (Python SDK pattern)
        // This ensures handlers can be registered in any order without losing task-awareness
        if let taskAugmentedSampling = handlers.taskAugmentedSampling {
            _setTaskAugmentedSamplingHandler(taskAugmentedSampling)
        }

        if let taskAugmentedElicitation = handlers.taskAugmentedElicitation {
            _setTaskAugmentedElicitationHandler(taskAugmentedElicitation)
        }

        return self
    }
}
