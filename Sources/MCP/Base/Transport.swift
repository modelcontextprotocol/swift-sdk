import Logging

import struct Foundation.Data

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends data
    func send(_ data: Data) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

/// Client transports that can abort an in-flight request's response stream.
///
/// ``Client/cancelRequest(_:reason:)`` uses this so a cancelled
/// `subscriptions/listen` (or any long-lived POST SSE) actually closes the
/// HTTP connection instead of only sending `notifications/cancelled`.
public protocol RequestStreamCancelling: Sendable {
    func cancelInFlightRequestStream(for id: ID) async
}
