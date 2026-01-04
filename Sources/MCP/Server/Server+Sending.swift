import Foundation

extension Server {
    // MARK: - Sending

    /// Send a response to a request
    public func send<M: Method>(_ response: Response<M>) async throws {
        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let responseData = try encoder.encode(response)
        try await connection.send(responseData)
    }

    /// Send a notification to connected clients
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a log message notification to connected clients.
    ///
    /// This method can be called outside of request handlers to send log messages
    /// asynchronously. The message will only be sent if:
    /// - The server has declared the `logging` capability
    /// - The message's level is at or above the minimum level set by the session
    ///
    /// If the logging capability is not declared, this method silently returns without
    /// sending (matching TypeScript SDK behavior).
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: An optional name for the logger producing the message
    ///   - data: The log message data (can be a string or structured data)
    ///   - sessionId: Optional session ID for per-session log level filtering.
    ///     If `nil`, the log level for the nil-session (default) is used.
    public func sendLogMessage(
        level: LoggingLevel,
        logger: String? = nil,
        data: Value,
        sessionId: String? = nil
    ) async throws {
        // Check if logging capability is declared (matching TypeScript SDK behavior)
        guard capabilities.logging != nil else { return }

        // Check if this message should be sent based on the session's log level
        guard shouldSendLogMessage(at: level, forSession: sessionId) else { return }

        try await notify(LogMessageNotification.message(.init(
            level: level,
            logger: logger,
            data: data
        )))
    }
}
