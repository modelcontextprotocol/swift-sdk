import Foundation

/// The Model Context Protocol (MCP) provides a standardized way for servers to send
/// structured log messages to clients. Clients can control logging verbosity by setting
/// minimum log levels, with servers sending notifications containing severity levels,
/// optional logger names, and arbitrary JSON-serializable data.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
///
/// Frozen: no case is added in 1.x (the eight RFC 5424 severities).
///
/// > Important: Logging is deprecated by the specification (SEP-2577) and can be removed in the
///   first revision released on or after 2027-07-28. It works on every revision that has it. To
///   migrate, log to stderr (stdio) or use OpenTelemetry.
public enum LogLevel: String, Hashable, Codable, Sendable, CaseIterable {
    /// Detailed debugging information
    case debug
    /// General informational messages
    case info
    /// Normal but significant events
    case notice
    /// Warning conditions
    case warning
    /// Error conditions
    case error
    /// Critical conditions
    case critical
    /// Action must be taken immediately
    case alert
    /// System is unusable
    case emergency
}

// MARK: - Set Log Level

/// To configure the minimum log level, clients MAY send a `logging/setLevel` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
///
/// > Important: Logging is deprecated by the specification (SEP-2577) and can be removed in the
///   first revision released on or after 2027-07-28. It works on every revision that has it. To
///   migrate, log to stderr (stdio) or use OpenTelemetry.
public enum SetLoggingLevel: Method {
    public static let name = "logging/setLevel"

    /// The parameters of `logging/setLevel`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The minimum log level to set
        public let level: LogLevel

        /// Creates the parameters of a `logging/setLevel` request.
        public init(level: LogLevel) {
            self.level = level
        }
    }

    public typealias Result = Empty
}

// MARK: - Log Message Notification

/// Servers send log messages using `notifications/message` notifications.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
///
/// > Important: Logging is deprecated by the specification (SEP-2577) and can be removed in the
///   first revision released on or after 2027-07-28. It works on every revision that has it. To
///   migrate, log to stderr (stdio) or use OpenTelemetry.
public struct LogMessageNotification: Notification {
    public static let name = "notifications/message"

    /// The parameters of `notifications/message`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The severity level of the log message
        public let level: LogLevel
        /// Optional logger name to identify the source
        public let logger: String?
        /// Arbitrary JSON-serializable data for the log message
        public let data: Value

        /// Creates the parameters of a `notifications/message` notification.
        public init(
            level: LogLevel,
            logger: String? = nil,
            data: Value
        ) {
            self.level = level
            self.logger = logger
            self.data = data
        }
    }
}

extension LogLevel: Comparable {
    /// Severity order, from `debug` (lowest) to `emergency` (highest).
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
