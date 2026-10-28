import Foundation

// Tasks: long-running requests the client polls instead of waiting on.
//
// Two generations share one model:
// - v1 (SEP-1686) is part of protocol 2025-11-25. The client augments a
//   `tools/call` with `task`, polls `tasks/get`, reads the outcome with
//   `tasks/result`, and the server sends its own requests for input.
// - v2 (SEP-2663) is the `io.modelcontextprotocol/tasks` extension at
//   2026-07-28. The server decides whether to create a task, `tasks/get`
//   inlines the outcome, and input travels as `inputRequests` answered with
//   `tasks/update`.
// A task created at one generation is only read through that generation.

/// Identifiers of protocol extensions (SEP-2133), the keys of
/// `capabilities.extensions`.
public enum ExtensionID {
    /// The tasks extension (SEP-2663).
    public static let tasks = "io.modelcontextprotocol/tasks"
}

/// The wire generation of a task.
enum TaskGeneration: Hashable, Sendable {
    /// SEP-1686, protocol 2025-11-25.
    case v1
    /// SEP-2663, protocol 2026-07-28 and later.
    case v2
}

/// The state of a task.
///
/// Open to values this SDK does not know, so a peer's new status does not
/// fail the task.
public struct TaskStatus: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The request is being processed.
    public static let working: TaskStatus = "working"
    /// The server needs input from the client before it can go on.
    public static let inputRequired: TaskStatus = "input_required"
    /// The request finished; the task holds its result.
    public static let completed: TaskStatus = "completed"
    /// The request failed with a protocol error. At 2025-11-25 a tool that
    /// reports an error (`isError`) also fails its task.
    public static let failed: TaskStatus = "failed"
    /// The task was cancelled before it finished.
    public static let cancelled: TaskStatus = "cancelled"

    /// Whether the task can no longer change: completed, failed or cancelled.
    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

/// Whether a tool runs as a task (`Tool.Execution.taskSupport`).
///
/// Open to values this SDK does not know; an unknown value is treated as
/// ``forbidden``.
public struct TaskSupport: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The tool never runs as a task. The default.
    public static let forbidden: TaskSupport = "forbidden"
    /// The tool may run as a task.
    public static let optional: TaskSupport = "optional"
    /// The tool runs only as a task: a client that cannot use tasks is
    /// refused.
    public static let required: TaskSupport = "required"
}

/// The `task` member of a request the client augments to run as a task
/// (protocol 2025-11-25).
public struct TaskMetadata: Hashable, Codable, Sendable {
    /// How long the client wants the server to keep the task, in
    /// milliseconds. The server may keep it for less.
    public var ttl: Int?

    /// Creates the `task` member of a request.
    public init(ttl: Int? = nil) {
        self.ttl = ttl
    }

    private enum CodingKeys: String, CodingKey {
        case ttl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ttl = container.decodeTTL(forKey: .ttl)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(ttl, forKey: .ttl)
    }
}

/// A task as the server reports it: the result that creates it, the result
/// of `tasks/get`, and the parameters of task status notifications.
///
/// The SDK encodes it in the form of the task's protocol version: at
/// 2025-11-25 `ttl` and `pollInterval` and no outcome; at 2026-07-28
/// `ttlMs` and `pollIntervalMs`, and from `tasks/get` the outcome:
/// ``inputRequests`` while the task waits for input, ``result`` once it
/// completed and ``error`` once it failed. Decoding accepts both forms.
public struct TaskSnapshot: Hashable, Sendable {
    /// The task's identifier, chosen by the server.
    public var taskId: String
    /// The task's state.
    public var status: TaskStatus
    /// A human-readable description of the state.
    public var statusMessage: String?
    /// When the task was created, as an ISO 8601 timestamp.
    public var createdAt: String
    /// When the task last changed, as an ISO 8601 timestamp.
    public var lastUpdatedAt: String
    /// How long the server keeps the task after it was created, in
    /// milliseconds; `nil` when it does not say.
    public var ttlMs: Int?
    /// How long the client should wait between polls, in milliseconds.
    public var pollIntervalMs: Int?
    /// The requests the client must fulfill, keyed by names the server
    /// chooses (2026-07-28, while the status is ``TaskStatus/inputRequired``).
    public var inputRequests: [String: InputRequest]?
    /// The result of the request (2026-07-28, once the task completed): for
    /// a tool call, a `CallTool.Result`, see ``callToolResult``.
    public var result: Value?
    /// The error the request failed with (2026-07-28, once the task failed).
    public var error: MCPError?
    /// Metadata.
    public var _meta: Metadata?

    /// The form the task is encoded in.
    var generation: TaskGeneration

    /// Creates a task in its 2026-07-28 form.
    public init(
        taskId: String,
        status: TaskStatus,
        statusMessage: String? = nil,
        createdAt: String,
        lastUpdatedAt: String,
        ttlMs: Int? = nil,
        pollIntervalMs: Int? = nil,
        inputRequests: [String: InputRequest]? = nil,
        result: Value? = nil,
        error: MCPError? = nil,
        _meta: Metadata? = nil
    ) {
        self.taskId = taskId
        self.status = status
        self.statusMessage = statusMessage
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.ttlMs = ttlMs
        self.pollIntervalMs = pollIntervalMs
        self.inputRequests = inputRequests
        self.result = result
        self.error = error
        self._meta = _meta
        self.generation = .v2
    }

    /// ``result`` as a tool call result; `nil` when absent or of another shape.
    public var callToolResult: CallTool.Result? {
        guard let result else { return nil }
        return try? CallTool.Result(decoding: result)
    }

    /// ``createdAt`` as a date; `nil` when it is not an ISO 8601 timestamp.
    public var createdDate: Date? { TaskTimestamp.date(from: createdAt) }

    /// ``lastUpdatedAt`` as a date; `nil` when it is not an ISO 8601 timestamp.
    public var lastUpdatedDate: Date? { TaskTimestamp.date(from: lastUpdatedAt) }

    /// The same task in the form of `generation`, without the members that
    /// form does not have.
    func shaped(as generation: TaskGeneration) -> TaskSnapshot {
        var copy = self
        copy.generation = generation
        if generation == .v1 {
            copy.inputRequests = nil
            copy.result = nil
            copy.error = nil
        }
        return copy
    }

    /// The task without its outcome, as the result that creates it.
    var withoutOutcome: TaskSnapshot {
        var copy = self
        copy.inputRequests = nil
        copy.result = nil
        copy.error = nil
        return copy
    }
}

extension TaskSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case taskId, status, statusMessage, createdAt, lastUpdatedAt
        case ttl, ttlMs, pollInterval, pollIntervalMs
        case inputRequests, result, error, _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(String.self, forKey: .taskId)
        status = try container.decode(TaskStatus.self, forKey: .status)
        statusMessage = try? container.decodeIfPresent(String.self, forKey: .statusMessage)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        lastUpdatedAt = try container.decodeIfPresent(String.self, forKey: .lastUpdatedAt) ?? createdAt
        let isV1 =
            !container.contains(.ttlMs) && !container.contains(.pollIntervalMs)
            && (container.contains(.ttl) || container.contains(.pollInterval))
        generation = isV1 ? .v1 : .v2
        ttlMs = isV1 ? container.decodeTTL(forKey: .ttl) : container.decodeTTL(forKey: .ttlMs)
        pollIntervalMs =
            isV1 ? container.decodeTTL(forKey: .pollInterval) : container.decodeTTL(forKey: .pollIntervalMs)
        inputRequests = try container.decodeIfPresent([String: InputRequest].self, forKey: .inputRequests)
        result = try container.decodeIfPresent(Value.self, forKey: .result)
        error = try container.decodeIfPresent(MCPError.self, forKey: .error)
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
        switch generation {
        case .v1:
            // `ttl` is required, `null` for an unlimited lifetime.
            if let ttlMs { try container.encode(ttlMs, forKey: .ttl) } else { try container.encodeNil(forKey: .ttl) }
            try container.encodeIfPresent(pollIntervalMs, forKey: .pollInterval)
        case .v2:
            if let ttlMs { try container.encode(ttlMs, forKey: .ttlMs) } else { try container.encodeNil(forKey: .ttlMs) }
            try container.encodeIfPresent(pollIntervalMs, forKey: .pollIntervalMs)
            try container.encodeIfPresent(inputRequests, forKey: .inputRequests)
            try container.encodeIfPresent(result, forKey: .result)
            try container.encodeIfPresent(error, forKey: .error)
        }
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

// MARK: - Methods

/// Reads the state of a task: `tasks/get`.
///
/// At 2026-07-28 the result also carries the task's outcome or the input it
/// waits for.
public enum GetTask: Method {
    public static let name = "tasks/get"

    /// The parameters of `tasks/get`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The task to read.
        public let taskId: String
        /// Request metadata.
        public var _meta: Metadata?

        /// Creates the parameters of a `tasks/get` request.
        public init(taskId: String, _meta: Metadata? = nil) {
            self.taskId = taskId
            self._meta = _meta
        }
    }

    public typealias Result = TaskSnapshot
}

/// Answers the input requests of a task: `tasks/update` (2026-07-28).
///
/// The result is an empty acknowledgement; the task's new state is read with
/// ``GetTask``. Responses under keys the task does not wait for are ignored.
public enum UpdateTask: Method {
    public static let name = "tasks/update"

    /// The parameters of `tasks/update`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The task to answer.
        public let taskId: String
        /// The responses, keyed as the task's `inputRequests` were. Any
        /// subset of the outstanding requests may be answered.
        public let inputResponses: [String: InputResponse]
        /// Request metadata.
        public var _meta: Metadata?

        /// Creates the parameters of a `tasks/update` request.
        public init(taskId: String, inputResponses: [String: InputResponse], _meta: Metadata? = nil) {
            self.taskId = taskId
            self.inputResponses = inputResponses
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey {
            case taskId, inputResponses, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            taskId = try container.decode(String.self, forKey: .taskId)
            inputResponses = try MRTR.decodeInputResponses(container, forKey: .inputResponses) ?? [:]
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }
    }
}

/// Asks the server to cancel a task: `tasks/cancel`.
///
/// At 2025-11-25 the result is the cancelled task, and a task that already
/// finished cannot be cancelled (-32602). At 2026-07-28 the result is an
/// empty acknowledgement, for a finished task too; the new state is read
/// with ``GetTask``.
public enum CancelTask: Method {
    public static let name = "tasks/cancel"

    /// The parameters of `tasks/cancel`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The task to cancel.
        public let taskId: String
        /// Request metadata.
        public var _meta: Metadata?

        /// Creates the parameters of a `tasks/cancel` request.
        public init(taskId: String, _meta: Metadata? = nil) {
            self.taskId = taskId
            self._meta = _meta
        }
    }

    /// The result of `tasks/cancel`.
    public struct Result: Hashable, Codable, Sendable {
        /// The cancelled task (2025-11-25); `nil` for the acknowledgement of
        /// 2026-07-28.
        public var task: TaskSnapshot?

        /// Creates the result of a `tasks/cancel` request.
        public init(task: TaskSnapshot? = nil) {
            self.task = task
        }

        private enum CodingKeys: String, CodingKey {
            case taskId
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            task = container.contains(.taskId) ? try TaskSnapshot(from: decoder) : nil
        }

        public func encode(to encoder: Encoder) throws {
            if let task {
                try task.encode(to: encoder)
            } else {
                _ = encoder.container(keyedBy: CodingKeys.self)
            }
        }
    }
}

/// Waits for a task to finish and returns the result of its request:
/// `tasks/result` (2025-11-25).
///
/// The server sends the task's input requests on the stream of this request.
/// The result is that of the original request, for a tool call a
/// `CallTool.Result`, with `_meta["io.modelcontextprotocol/related-task"]`.
public enum GetTaskPayload: Method {
    public static let name = "tasks/result"

    /// The parameters of `tasks/result`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The task whose result to return.
        public let taskId: String
        /// Request metadata.
        public var _meta: Metadata?

        /// Creates the parameters of a `tasks/result` request.
        public init(taskId: String, _meta: Metadata? = nil) {
            self.taskId = taskId
            self._meta = _meta
        }
    }

    public typealias Result = Value
}

/// Lists the caller's tasks: `tasks/list` (2025-11-25).
public enum ListTasks: Method {
    public static let name = "tasks/list"

    /// The parameters of `tasks/list`.
    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        /// The cursor from the `nextCursor` of a previous result, or `nil` for the first page.
        public let cursor: String?

        /// Creates the parameters of a request for the first page.
        public init() {
            self.cursor = nil
        }

        /// Creates the parameters of a request for the page at `cursor`.
        public init(cursor: String) {
            self.cursor = cursor
        }
    }

    /// The result of `tasks/list`.
    public struct Result: Hashable, Codable, Sendable {
        /// The tasks on this page.
        public let tasks: [TaskSnapshot]
        /// The cursor of the next page, or `nil` on the last page.
        public let nextCursor: String?
        /// Result metadata.
        public var _meta: Metadata?

        /// Creates the result of a `tasks/list` request.
        public init(tasks: [TaskSnapshot], nextCursor: String? = nil, _meta: Metadata? = nil) {
            self.tasks = tasks
            self.nextCursor = nextCursor
            self._meta = _meta
        }
    }
}

/// Sent by the server when a task changes: `notifications/tasks/status`
/// (2025-11-25). The client may use it instead of polling.
public struct TaskStatusNotification: Notification {
    public static let name = "notifications/tasks/status"
    public typealias Parameters = TaskSnapshot
}

/// Sent on a `subscriptions/listen` stream that names the task when it
/// changes: `notifications/tasks` (2026-07-28). Carries the task as
/// `tasks/get` returns it.
public struct TaskUpdatedNotification: Notification {
    public static let name = "notifications/tasks"
    public typealias Parameters = TaskSnapshot
}

/// The methods of the task surface.
enum TaskMethods {
    /// The methods of tasks at 2026-07-28, served only to clients that
    /// declare the extension.
    static let v2: Set<String> = [GetTask.name, UpdateTask.name, CancelTask.name]
    /// The methods of tasks at 2025-11-25.
    static let v1: Set<String> = [GetTask.name, GetTaskPayload.name, CancelTask.name, ListTasks.name]
}

extension Client.Capabilities {
    /// Whether the capabilities declare the tasks extension (SEP-2663).
    var declaresTasksExtension: Bool {
        extensions?[ExtensionID.tasks] != nil
    }
}

// MARK: - Helpers

/// ISO 8601 timestamps of tasks: UTC with milliseconds.
enum TaskTimestamp {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `date` as `YYYY-MM-DDTHH:MM:SS.sssZ`.
    static func string(from date: Date) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(components.year, 4))-\(pad(components.month, 2))-\(pad(components.day, 2))"
            + "T\(pad(components.hour, 2)):\(pad(components.minute, 2)):\(pad(components.second, 2))"
            + ".\(pad((components.nanosecond ?? 0) / 1_000_000, 3))Z"
    }

    /// Parses an ISO 8601 timestamp with or without fractional seconds.
    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Task identifiers: 128 random bits, base64url without padding.
enum TaskIdentifier {
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Duration {
    /// The duration in whole milliseconds, rounded down; at least 1 for a
    /// positive duration.
    var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        let total = seconds * 1000 + attoseconds / 1_000_000_000_000_000
        if total == 0, seconds > 0 || attoseconds > 0 { return 1 }
        return Int(clamping: total)
    }
}
