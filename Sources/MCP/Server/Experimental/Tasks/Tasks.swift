import Foundation

/// Tasks provide a way to track the progress of long-running operations.
/// This is an experimental feature in MCP protocol version 2025-11-25.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/

// MARK: - Task Metadata Keys

/// Metadata key for associating messages with a related task.
///
/// This constant is used in the `_meta` field of requests, responses, and notifications
/// to indicate they are related to a specific task.
///
/// ## Example
///
/// ```swift
/// let meta: [String: Value] = [
///     relatedTaskMetaKey: .object(["taskId": .string(taskId)])
/// ]
/// ```
public let relatedTaskMetaKey = "io.modelcontextprotocol/related-task"

/// Metadata key for providing an immediate response to the model while a task continues.
///
/// When a task is created, the server can include this in `_meta` to provide
/// immediate feedback to the model while the actual work continues in the background.
///
/// ## Example
///
/// ```swift
/// let meta: [String: Value] = [
///     modelImmediateResponseKey: .string("Starting to process your request...")
/// ]
/// ```
public let modelImmediateResponseKey = "io.modelcontextprotocol/model-immediate-response"

// MARK: - Task Status

/// The status of a task.
public enum TaskStatus: String, Hashable, Codable, Sendable {
    /// Task is actively being worked on
    case working
    /// Task requires user input to continue
    case inputRequired = "input_required"
    /// Task completed successfully
    case completed
    /// Task failed
    case failed
    /// Task was cancelled
    case cancelled

    /// Whether this status represents a terminal state.
    ///
    /// Terminal states are: completed, failed, cancelled.
    /// Once a task reaches a terminal state, no further status updates will occur.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .working, .inputRequired:
            return false
        }
    }
}

// MARK: - Task

/// Represents a running or completed task.
///
/// Note: This type represents the `Task` schema which does not include `_meta`.
/// When combined with `Result` or `NotificationParams` (via allOf), the `_meta`
/// field comes from those base types.
public struct MCPTask: Hashable, Sendable {
    /// Unique identifier for the task
    public var taskId: String
    /// Current status of the task
    public var status: TaskStatus
    /// Time in milliseconds to keep task results available after completion.
    /// If nil, the task has unlimited lifetime until manually cleaned up.
    /// Note: Per the MCP spec, this field is always present in the JSON (encoded as null when nil).
    public var ttl: Int?
    /// ISO 8601 timestamp when the task was created
    public var createdAt: String
    /// ISO 8601 timestamp when the task was last updated
    public var lastUpdatedAt: String
    /// Suggested polling interval in milliseconds for clients
    public var pollInterval: Int?
    /// Optional diagnostic message for failed tasks or other status information
    public var statusMessage: String?

    public init(
        taskId: String,
        status: TaskStatus,
        ttl: Int? = nil,
        createdAt: String,
        lastUpdatedAt: String,
        pollInterval: Int? = nil,
        statusMessage: String? = nil
    ) {
        self.taskId = taskId
        self.status = status
        self.ttl = ttl
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.pollInterval = pollInterval
        self.statusMessage = statusMessage
    }
}

extension MCPTask: Codable {
    enum CodingKeys: String, CodingKey {
        case taskId, status, ttl, createdAt, lastUpdatedAt, pollInterval, statusMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(String.self, forKey: .taskId)
        status = try container.decode(TaskStatus.self, forKey: .status)
        // ttl is required in the spec but can be null for unlimited
        ttl = try container.decode(Int?.self, forKey: .ttl)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastUpdatedAt = try container.decode(String.self, forKey: .lastUpdatedAt)
        pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollInterval)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(status, forKey: .status)
        // ttl is required in the spec - always encode it (as null when nil)
        try container.encode(ttl, forKey: .ttl)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encodeIfPresent(pollInterval, forKey: .pollInterval)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
    }
}

/// Metadata for task creation, passed via `_meta.task` in request parameters.
///
/// When a client sends a request that may become a long-running task, it can include
/// this metadata to configure task behavior.
///
/// ## Example
///
/// ```swift
/// // Include task metadata in a tool call
/// let params = CallTool.Parameters(
///     name: "long_running_operation",
///     arguments: ["input": .string("data")],
///     _meta: ["task": .object(["ttl": .int(3600000)])]  // Keep for 1 hour
/// )
/// ```
public struct TaskMetadata: Hashable, Codable, Sendable {
    /// Time-to-live in milliseconds for task results after completion.
    /// If nil, the task has unlimited lifetime until manually cleaned up.
    public var ttl: Int?

    public init(ttl: Int? = nil) {
        self.ttl = ttl
    }
}

/// Metadata indicating an operation is related to an existing task.
///
/// When a server sends notifications or requests during task execution,
/// it can include this metadata in `_meta.task` to associate them with
/// the originating task.
///
/// ## Example
///
/// ```swift
/// // Send progress notification for a task
/// let notification = ProgressNotification.Parameters(
///     progressToken: token,
///     progress: 50,
///     total: 100,
///     _meta: ["task": .object(["taskId": .string(taskId)])]
/// )
/// ```
public struct RelatedTaskMetadata: Hashable, Codable, Sendable {
    /// The ID of the task this operation is related to.
    public var taskId: String

    public init(taskId: String) {
        self.taskId = taskId
    }
}

// MARK: - Create Task Result

/// Result returned when a task-augmented request creates a task.
///
/// When a client sends a request with a `task` field in the parameters,
/// the server returns this result instead of the normal method result.
/// The client can then poll for the actual result using `tasks/result`.
///
/// ## Example
///
/// ```swift
/// // Client sends task-augmented tool call
/// let params = CallTool.Parameters(
///     name: "long_running_tool",
///     arguments: ["input": .string("data")],
///     task: TaskMetadata(ttl: 60000)
/// )
///
/// // Server returns CreateTaskResult instead of CallTool.Result
/// let createTaskResult = CreateTaskResult(
///     task: MCPTask(
///         taskId: "abc123",
///         status: .working,
///         ttl: 60000,
///         createdAt: ISO8601DateFormatter().string(from: Date()),
///         lastUpdatedAt: ISO8601DateFormatter().string(from: Date()),
///         pollInterval: 1000
///     )
/// )
/// ```
public struct CreateTaskResult: ResultWithExtraFields {
    public typealias ResultCodingKeys = CodingKeys

    /// The created task.
    public var task: MCPTask
    /// Reserved for clients and servers to attach additional metadata.
    /// May include `io.modelcontextprotocol/model-immediate-response` for feedback.
    public var _meta: [String: Value]?
    /// Additional fields not defined in the schema (for forward compatibility).
    public var extraFields: [String: Value]?

    public init(
        task: MCPTask,
        _meta: [String: Value]? = nil,
        extraFields: [String: Value]? = nil
    ) {
        self.task = task
        self._meta = _meta
        self.extraFields = extraFields
    }

    /// Convenience initializer with optional model immediate response.
    ///
    /// - Parameters:
    ///   - task: The created task
    ///   - modelImmediateResponse: Optional immediate feedback for the model
    public init(task: MCPTask, modelImmediateResponse: String?) {
        self.task = task
        if let response = modelImmediateResponse {
            self._meta = [modelImmediateResponseKey: .string(response)]
        } else {
            self._meta = nil
        }
        self.extraFields = nil
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case task, _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(MCPTask.self, forKey: .task)
        _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
        extraFields = try Self.decodeExtraFields(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task, forKey: .task)
        try container.encodeIfPresent(_meta, forKey: ._meta)
        try encodeExtraFields(to: encoder)
    }
}

// MARK: - Get Task

/// Request to get information about a specific task.
public enum GetTask: Method {
    public static let name = "tasks/get"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The ID of the task to retrieve
        public var taskId: String
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(taskId: String, _meta: RequestMeta? = nil) {
            self.taskId = taskId
            self._meta = _meta
        }
    }

    /// The response to a tasks/get request.
    ///
    /// This type flattens `Result` and `Task` fields per the spec's `allOf[Result, Task]`.
    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        // Task fields (flattened from MCPTask)
        /// Unique identifier for the task
        public var taskId: String
        /// Current status of the task
        public var status: TaskStatus
        /// Time in milliseconds to keep task results available after completion.
        public var ttl: Int?
        /// ISO 8601 timestamp when the task was created
        public var createdAt: String
        /// ISO 8601 timestamp when the task was last updated
        public var lastUpdatedAt: String
        /// Suggested polling interval in milliseconds for clients
        public var pollInterval: Int?
        /// Optional diagnostic message for failed tasks or other status information
        public var statusMessage: String?

        // Result fields
        /// Reserved for clients and servers to attach additional metadata
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            taskId: String,
            status: TaskStatus,
            ttl: Int? = nil,
            createdAt: String,
            lastUpdatedAt: String,
            pollInterval: Int? = nil,
            statusMessage: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.taskId = taskId
            self.status = status
            self.ttl = ttl
            self.createdAt = createdAt
            self.lastUpdatedAt = lastUpdatedAt
            self.pollInterval = pollInterval
            self.statusMessage = statusMessage
            self._meta = _meta
            self.extraFields = extraFields
        }

        /// Convenience initializer from MCPTask
        public init(task: MCPTask, _meta: [String: Value]? = nil, extraFields: [String: Value]? = nil) {
            self.taskId = task.taskId
            self.status = task.status
            self.ttl = task.ttl
            self.createdAt = task.createdAt
            self.lastUpdatedAt = task.lastUpdatedAt
            self.pollInterval = task.pollInterval
            self.statusMessage = task.statusMessage
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case taskId, status, ttl, createdAt, lastUpdatedAt, pollInterval, statusMessage, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            taskId = try container.decode(String.self, forKey: .taskId)
            status = try container.decode(TaskStatus.self, forKey: .status)
            ttl = try container.decodeIfPresent(Int.self, forKey: .ttl)
            createdAt = try container.decode(String.self, forKey: .createdAt)
            lastUpdatedAt = try container.decode(String.self, forKey: .lastUpdatedAt)
            pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollInterval)
            statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(taskId, forKey: .taskId)
            try container.encode(status, forKey: .status)
            // ttl is required in the spec - always encode it (as null when nil)
            try container.encode(ttl, forKey: .ttl)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
            try container.encodeIfPresent(pollInterval, forKey: .pollInterval)
            try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

// MARK: - Get Task Payload

/// Request to get the result payload of a completed task.
///
/// This method retrieves the actual result data for a completed task.
/// The result type depends on the original request that created the task
/// (e.g., a tool call result for a task created from `tools/call`).
///
/// - Note: This should only be called for tasks with status `.completed`.
///   For failed or cancelled tasks, check `MCPTask.statusMessage` instead.
public enum GetTaskPayload: Method {
    public static let name = "tasks/result"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The ID of the task to get results for
        public var taskId: String
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(taskId: String, _meta: RequestMeta? = nil) {
            self.taskId = taskId
            self._meta = _meta
        }
    }

    /// The result type for tasks/result.
    ///
    /// Per the MCP spec, this is a "loose" Result type where the actual result fields
    /// are flattened directly into the response (via `extraFields`), not wrapped
    /// in a separate field. For example, a tools/call task would have `content` and
    /// `isError` as top-level fields in the response.
    ///
    /// ## Example response for a completed tools/call task:
    /// ```json
    /// {
    ///   "_meta": {"io.modelcontextprotocol/related-task": {"taskId": "..."}},
    ///   "content": [{"type": "text", "text": "Result"}],
    ///   "isError": false
    /// }
    /// ```
    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        /// Reserved for clients and servers to attach additional metadata.
        /// Typically includes `io.modelcontextprotocol/related-task` with the task ID.
        public var _meta: [String: Value]?

        /// The actual result payload fields from the original request's result type.
        /// For a tools/call task, this would contain `content`, `isError`, etc.
        /// These fields are encoded/decoded as top-level fields in the JSON.
        public var extraFields: [String: Value]?

        public init(_meta: [String: Value]? = nil, extraFields: [String: Value]? = nil) {
            self._meta = _meta
            self.extraFields = extraFields
        }

        /// Convenience initializer from a Value representing the original result.
        ///
        /// This extracts the fields from the Value and stores them in extraFields.
        /// - Parameters:
        ///   - resultValue: The result as a Value (typically from task storage)
        ///   - _meta: Optional metadata
        public init(fromResultValue resultValue: Value?, _meta: [String: Value]? = nil) {
            self._meta = _meta
            if case .object(let fields) = resultValue {
                self.extraFields = fields
            } else {
                self.extraFields = nil
            }
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

// MARK: - List Tasks

/// Request to list all tasks.
public enum ListTasks: Method {
    public static let name = "tasks/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        /// Pagination cursor
        public var cursor: String?
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init() {
            self.cursor = nil
            self._meta = nil
        }

        public init(cursor: String? = nil, _meta: RequestMeta? = nil) {
            self.cursor = cursor
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        /// List of tasks
        public var tasks: [MCPTask]
        /// Next pagination cursor
        public var nextCursor: String?
        /// Reserved for clients and servers to attach additional metadata
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            tasks: [MCPTask],
            nextCursor: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.tasks = tasks
            self.nextCursor = nextCursor
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case tasks, nextCursor, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tasks = try container.decode([MCPTask].self, forKey: .tasks)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tasks, forKey: .tasks)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

// MARK: - Cancel Task

/// Request to cancel a running task.
public enum CancelTask: Method {
    public static let name = "tasks/cancel"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The ID of the task to cancel
        public var taskId: String
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(taskId: String, _meta: RequestMeta? = nil) {
            self.taskId = taskId
            self._meta = _meta
        }
    }

    /// The response to a tasks/cancel request.
    ///
    /// This type flattens `Result` and `Task` fields per the spec's `allOf[Result, Task]`.
    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        // Task fields (flattened from MCPTask)
        /// Unique identifier for the task
        public var taskId: String
        /// Current status of the task
        public var status: TaskStatus
        /// Time in milliseconds to keep task results available after completion.
        public var ttl: Int?
        /// ISO 8601 timestamp when the task was created
        public var createdAt: String
        /// ISO 8601 timestamp when the task was last updated
        public var lastUpdatedAt: String
        /// Suggested polling interval in milliseconds for clients
        public var pollInterval: Int?
        /// Optional diagnostic message for failed tasks or other status information
        public var statusMessage: String?

        // Result fields
        /// Reserved for clients and servers to attach additional metadata
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            taskId: String,
            status: TaskStatus,
            ttl: Int? = nil,
            createdAt: String,
            lastUpdatedAt: String,
            pollInterval: Int? = nil,
            statusMessage: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.taskId = taskId
            self.status = status
            self.ttl = ttl
            self.createdAt = createdAt
            self.lastUpdatedAt = lastUpdatedAt
            self.pollInterval = pollInterval
            self.statusMessage = statusMessage
            self._meta = _meta
            self.extraFields = extraFields
        }

        /// Convenience initializer from MCPTask
        public init(task: MCPTask, _meta: [String: Value]? = nil, extraFields: [String: Value]? = nil) {
            self.taskId = task.taskId
            self.status = task.status
            self.ttl = task.ttl
            self.createdAt = task.createdAt
            self.lastUpdatedAt = task.lastUpdatedAt
            self.pollInterval = task.pollInterval
            self.statusMessage = task.statusMessage
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case taskId, status, ttl, createdAt, lastUpdatedAt, pollInterval, statusMessage, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            taskId = try container.decode(String.self, forKey: .taskId)
            status = try container.decode(TaskStatus.self, forKey: .status)
            ttl = try container.decodeIfPresent(Int.self, forKey: .ttl)
            createdAt = try container.decode(String.self, forKey: .createdAt)
            lastUpdatedAt = try container.decode(String.self, forKey: .lastUpdatedAt)
            pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollInterval)
            statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(taskId, forKey: .taskId)
            try container.encode(status, forKey: .status)
            // ttl is required in the spec - always encode it (as null when nil)
            try container.encode(ttl, forKey: .ttl)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
            try container.encodeIfPresent(pollInterval, forKey: .pollInterval)
            try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

// MARK: - Task Status Notification

/// Notification sent when a task's status changes.
public struct TaskStatusNotification: Notification {
    public static let name = "notifications/tasks/status"

    /// Parameters for task status notification.
    ///
    /// This type flattens `NotificationParams` and `Task` fields per the spec's
    /// `allOf[NotificationParams, Task]`.
    public struct Parameters: Hashable, Sendable {
        // Task fields (flattened from MCPTask)
        /// Unique identifier for the task
        public var taskId: String
        /// Current status of the task
        public var status: TaskStatus
        /// Time in milliseconds to keep task results available after completion.
        public var ttl: Int?
        /// ISO 8601 timestamp when the task was created
        public var createdAt: String
        /// ISO 8601 timestamp when the task was last updated
        public var lastUpdatedAt: String
        /// Suggested polling interval in milliseconds for clients
        public var pollInterval: Int?
        /// Optional diagnostic message for failed tasks or other status information
        public var statusMessage: String?

        // NotificationParams fields
        /// Reserved for additional metadata.
        public var _meta: [String: Value]?

        public init(
            taskId: String,
            status: TaskStatus,
            ttl: Int? = nil,
            createdAt: String,
            lastUpdatedAt: String,
            pollInterval: Int? = nil,
            statusMessage: String? = nil,
            _meta: [String: Value]? = nil
        ) {
            self.taskId = taskId
            self.status = status
            self.ttl = ttl
            self.createdAt = createdAt
            self.lastUpdatedAt = lastUpdatedAt
            self.pollInterval = pollInterval
            self.statusMessage = statusMessage
            self._meta = _meta
        }

        /// Convenience initializer from MCPTask
        public init(task: MCPTask, _meta: [String: Value]? = nil) {
            self.taskId = task.taskId
            self.status = task.status
            self.ttl = task.ttl
            self.createdAt = task.createdAt
            self.lastUpdatedAt = task.lastUpdatedAt
            self.pollInterval = task.pollInterval
            self.statusMessage = task.statusMessage
            self._meta = _meta
        }

        enum CodingKeys: String, CodingKey {
            case taskId, status, ttl, createdAt, lastUpdatedAt, pollInterval, statusMessage, _meta
        }
    }
}

extension TaskStatusNotification.Parameters: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(String.self, forKey: .taskId)
        status = try container.decode(TaskStatus.self, forKey: .status)
        ttl = try container.decodeIfPresent(Int.self, forKey: .ttl)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastUpdatedAt = try container.decode(String.self, forKey: .lastUpdatedAt)
        pollInterval = try container.decodeIfPresent(Int.self, forKey: .pollInterval)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(status, forKey: .status)
        // ttl is required in the spec - always encode it (as null when nil)
        try container.encode(ttl, forKey: .ttl)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encodeIfPresent(pollInterval, forKey: .pollInterval)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

// MARK: - Server Capabilities

extension Server.Capabilities {
    /// Tasks capabilities for servers.
    ///
    /// Servers advertise these capabilities during initialization to indicate
    /// what task-related features they support.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let capabilities = Server.Capabilities(
    ///     tasks: .init(
    ///         list: .init(),
    ///         cancel: .init(),
    ///         requests: .init(tools: .init(call: .init()))
    ///     )
    /// )
    /// ```
    public struct Tasks: Hashable, Codable, Sendable {
        /// Capability marker for list operations.
        public struct List: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Capability marker for cancel operations.
        public struct Cancel: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Task-augmented request capabilities.
        public struct Requests: Hashable, Codable, Sendable {
            /// Tools request capabilities.
            public struct Tools: Hashable, Codable, Sendable {
                /// Capability marker for task-augmented tools/call.
                public struct Call: Hashable, Codable, Sendable {
                    public init() {}
                }

                /// Whether task-augmented tools/call is supported.
                public var call: Call?

                public init(call: Call? = nil) {
                    self.call = call
                }
            }

            /// Whether task-augmented tools requests are supported.
            public var tools: Tools?

            public init(tools: Tools? = nil) {
                self.tools = tools
            }
        }

        /// Whether the server supports tasks/list.
        public var list: List?
        /// Whether the server supports tasks/cancel.
        public var cancel: Cancel?
        /// Task-augmented request capabilities.
        public var requests: Requests?

        public init(
            list: List? = nil,
            cancel: Cancel? = nil,
            requests: Requests? = nil
        ) {
            self.list = list
            self.cancel = cancel
            self.requests = requests
        }

        /// Convenience initializer for full task support.
        ///
        /// Creates a capability declaration with list, cancel, and task-augmented tools/call.
        public static func full() -> Tasks {
            Tasks(
                list: List(),
                cancel: Cancel(),
                requests: Requests(tools: .init(call: .init()))
            )
        }
    }
}

// MARK: - Client Capabilities

extension Client.Capabilities {
    /// Tasks capabilities for clients.
    ///
    /// Clients advertise these capabilities during initialization to indicate
    /// what task-related features they support. This is for bidirectional task
    /// support where servers can initiate tasks on clients.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let capabilities = Client.Capabilities(
    ///     tasks: .init(
    ///         list: .init(),
    ///         cancel: .init(),
    ///         requests: .init(
    ///             sampling: .init(createMessage: .init()),
    ///             elicitation: .init(create: .init())
    ///         )
    ///     )
    /// )
    /// ```
    public struct Tasks: Hashable, Codable, Sendable {
        /// Capability marker for list operations.
        public struct List: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Capability marker for cancel operations.
        public struct Cancel: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Task-augmented request capabilities for client.
        public struct Requests: Hashable, Codable, Sendable {
            /// Sampling request capabilities.
            public struct Sampling: Hashable, Codable, Sendable {
                /// Capability marker for task-augmented sampling/createMessage.
                public struct CreateMessage: Hashable, Codable, Sendable {
                    public init() {}
                }

                /// Whether task-augmented sampling/createMessage is supported.
                public var createMessage: CreateMessage?

                public init(createMessage: CreateMessage? = nil) {
                    self.createMessage = createMessage
                }
            }

            /// Elicitation request capabilities.
            public struct Elicitation: Hashable, Codable, Sendable {
                /// Capability marker for task-augmented elicitation/create.
                public struct Create: Hashable, Codable, Sendable {
                    public init() {}
                }

                /// Whether task-augmented elicitation/create is supported.
                public var create: Create?

                public init(create: Create? = nil) {
                    self.create = create
                }
            }

            /// Whether task-augmented sampling requests are supported.
            public var sampling: Sampling?
            /// Whether task-augmented elicitation requests are supported.
            public var elicitation: Elicitation?

            public init(
                sampling: Sampling? = nil,
                elicitation: Elicitation? = nil
            ) {
                self.sampling = sampling
                self.elicitation = elicitation
            }
        }

        /// Whether the client supports tasks/list.
        public var list: List?
        /// Whether the client supports tasks/cancel.
        public var cancel: Cancel?
        /// Task-augmented request capabilities.
        public var requests: Requests?

        public init(
            list: List? = nil,
            cancel: Cancel? = nil,
            requests: Requests? = nil
        ) {
            self.list = list
            self.cancel = cancel
            self.requests = requests
        }

        /// Convenience initializer for full task support.
        ///
        /// Creates a capability declaration with list, cancel, and all task-augmented requests.
        public static func full() -> Tasks {
            Tasks(
                list: List(),
                cancel: Cancel(),
                requests: Requests(
                    sampling: .init(createMessage: .init()),
                    elicitation: .init(create: .init())
                )
            )
        }
    }
}

// MARK: - Capability Checking Helpers

/// Check if server capabilities include task-augmented tools/call support.
///
/// - Parameter caps: The server capabilities
/// - Returns: True if task-augmented tools/call is supported
public func hasTaskAugmentedToolsCall(_ caps: Server.Capabilities?) -> Bool {
    caps?.tasks?.requests?.tools?.call != nil
}

/// Check if client capabilities include task-augmented elicitation support.
///
/// - Parameter caps: The client capabilities
/// - Returns: True if task-augmented elicitation/create is supported
public func hasTaskAugmentedElicitation(_ caps: Client.Capabilities?) -> Bool {
    caps?.tasks?.requests?.elicitation?.create != nil
}

/// Check if client capabilities include task-augmented sampling support.
///
/// - Parameter caps: The client capabilities
/// - Returns: True if task-augmented sampling/createMessage is supported
public func hasTaskAugmentedSampling(_ caps: Client.Capabilities?) -> Bool {
    caps?.tasks?.requests?.sampling?.createMessage != nil
}

/// Require task-augmented elicitation support from client.
///
/// - Parameter caps: The client capabilities
/// - Throws: MCPError if client doesn't support task-augmented elicitation
public func requireTaskAugmentedElicitation(_ caps: Client.Capabilities?) throws {
    if !hasTaskAugmentedElicitation(caps) {
        throw MCPError.invalidRequest("Client does not support task-augmented elicitation")
    }
}

/// Require task-augmented sampling support from client.
///
/// - Parameter caps: The client capabilities
/// - Throws: MCPError if client doesn't support task-augmented sampling
public func requireTaskAugmentedSampling(_ caps: Client.Capabilities?) throws {
    if !hasTaskAugmentedSampling(caps) {
        throw MCPError.invalidRequest("Client does not support task-augmented sampling")
    }
}

/// Require task-augmented tools/call support from server.
///
/// - Parameter caps: The server capabilities
/// - Throws: MCPError if server doesn't support task-augmented tools/call
public func requireTaskAugmentedToolsCall(_ caps: Server.Capabilities?) throws {
    if !hasTaskAugmentedToolsCall(caps) {
        throw MCPError.invalidRequest("Server does not support task-augmented tools/call")
    }
}

