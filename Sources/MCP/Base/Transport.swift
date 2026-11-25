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

    /// Sends a request together with HTTP headers that belong to it.
    ///
    /// At 2026-07-28, ``Client`` mirrors the `tools/call` arguments that a
    /// tool's input schema marks with `x-mcp-header` into `Mcp-Param-<Name>`
    /// headers (SEP-2243), and passes them here; a server that serves that
    /// revision answers a call without them with -32020
    /// (``MCPError/headerMismatch(_:)``). The client calls this method only
    /// when there are headers to send.
    ///
    /// A Streamable HTTP transport must send `additionalHeaders` on the
    /// request's POST, as ``HTTPClientTransport`` does. A transport that is
    /// not HTTP has no headers to set and can keep the default
    /// implementation, which ignores them and calls ``send(_:)``. A
    /// transport that wraps another one should implement this method and
    /// forward the headers, so that they reach the HTTP transport.
    ///
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#custom-headers-from-tool-parameters
    func send(_ data: Data, additionalHeaders: [String: String]) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

extension Transport {
    public func send(_ data: Data, relatedRequestID: ID?) async throws {
        try await send(data)
    }

    /// Sends data, ignoring `additionalHeaders`.
    public func send(_ data: Data, additionalHeaders: [String: String]) async throws {
        try await send(data)
    }
}
