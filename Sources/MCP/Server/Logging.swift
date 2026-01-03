/// Server logging capabilities.
///
/// Servers can send log messages to clients, and clients can control
/// the minimum log level they wish to receive.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/utilities/logging/

/// Log severity levels following RFC 5424 syslog conventions.
///
/// Levels are ordered by increasing severity:
/// debug < info < notice < warning < error < critical < alert < emergency
public enum LoggingLevel: String, Hashable, Codable, Sendable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
    case alert
    case emergency

    /// The severity index of this log level (0 = debug, 7 = emergency).
    public var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        case .critical: return 5
        case .alert: return 6
        case .emergency: return 7
        }
    }

    /// Returns true if this level is at least as severe as the given level.
    public func isAtLeast(_ level: LoggingLevel) -> Bool {
        self.severity >= level.severity
    }
}

/// Request from client to set the minimum log level for messages.
///
/// After receiving this request, servers should only send log messages
/// at the specified level or higher (more severe).
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/utilities/logging/
public enum SetLoggingLevel: Method {
    public static let name: String = "logging/setLevel"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The minimum log level to receive.
        public let level: LoggingLevel
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(level: LoggingLevel, _meta: RequestMeta? = nil) {
            self.level = level
            self._meta = _meta
        }
    }

    public typealias Result = Empty
}

/// Notification sent by servers to deliver log messages to clients.
///
/// Servers should respect the log level set by the client via `SetLoggingLevel`,
/// only sending messages at or above that severity.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/utilities/logging/
public struct LogMessageNotification: Notification {
    public static let name: String = "notifications/message"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The severity level of this log message.
        public let level: LoggingLevel

        /// An optional name identifying the logger source.
        public let logger: String?

        /// The log message data. Can be any JSON-serializable value.
        public let data: Value

        /// Reserved for additional metadata.
        public var _meta: [String: Value]?

        public init(
            level: LoggingLevel,
            logger: String? = nil,
            data: Value,
            _meta: [String: Value]? = nil
        ) {
            self.level = level
            self.logger = logger
            self.data = data
            self._meta = _meta
        }
    }
}
