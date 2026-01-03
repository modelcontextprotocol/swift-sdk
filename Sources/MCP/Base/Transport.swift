import Logging

import struct Foundation.Data

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// The session identifier for this transport connection.
    ///
    /// For HTTP transports supporting multiple concurrent clients, each client
    /// session has a unique identifier. This enables per-session features like
    /// independent log levels for each client.
    ///
    /// For simple transports (stdio, single-connection), this returns `nil`.
    var sessionId: String? { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends data
    func send(_ data: Data) async throws

    /// Sends data with an optional related request ID for response routing.
    ///
    /// For transports that support multiplexing (like HTTP), the `relatedRequestId`
    /// parameter enables routing responses back to the correct client connection.
    ///
    /// For simple transports (stdio, single-connection), this can be ignored.
    ///
    /// - Parameters:
    ///   - data: The data to send
    ///   - relatedRequestId: The ID of the request this message relates to (for response routing)
    func send(_ data: Data, relatedRequestId: RequestId?) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

// MARK: - Default Implementation

extension Transport {
    /// Default implementation returns `nil` for simple transports.
    ///
    /// HTTP transports override this to return their session identifier.
    public var sessionId: String? { nil }

    /// Default implementation that ignores the request ID.
    ///
    /// Simple transports (stdio, single-connection) don't need request ID routing,
    /// so they can use this default implementation that delegates to `send(_:)`.
    public func send(_ data: Data, relatedRequestId: RequestId?) async throws {
        try await send(data)
    }
}
