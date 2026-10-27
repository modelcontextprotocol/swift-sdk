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

    /// Sends data that belongs to an in-flight request.
    ///
    /// `relatedRequestID` is the id of the incoming request whose handler
    /// produced the message (a progress or log notification, or a
    /// server-to-client request). Transports with per-request streams deliver
    /// the message on that request's stream. The default implementation
    /// ignores the id and calls ``send(_:)``.
    func send(_ data: Data, relatedRequestID: ID?) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

extension Transport {
    public func send(_ data: Data, relatedRequestID: ID?) async throws {
        try await send(data)
    }
}
