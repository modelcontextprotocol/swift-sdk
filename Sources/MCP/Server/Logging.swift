import Foundation

/// The Model Context Protocol (MCP) provides a standardized way for servers to send
/// structured log messages to clients. Clients can control logging verbosity by setting
/// minimum log levels, with servers sending notifications containing severity levels,
/// optional logger names, and arbitrary JSON-serializable data.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
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
public enum SetLoggingLevel: Method {
    public static let name = "logging/setLevel"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The minimum log level to set
        public let level: LogLevel

        public init(level: LogLevel) {
            self.level = level
        }
    }

    public typealias Result = Empty
}

// MARK: - Log Message Notification

/// Servers send log messages using `notifications/message` notifications.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
public struct LogMessageNotification: Notification {
    public static let name = "notifications/message"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The severity level of the log message
        public let level: LogLevel
        /// Optional logger name to identify the source
        public let logger: String?
        /// Arbitrary JSON-serializable data for the log message
        public let data: Value

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
