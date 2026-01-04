import Logging

import struct Foundation.Data

// MARK: - Message Context Types

/// Information about the incoming HTTP request.
///
/// This is the Swift equivalent of TypeScript's `RequestInfo` interface, which
/// provides access to HTTP request headers for request handlers.
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { params, context in
///     if let requestInfo = context.requestInfo {
///         // Access custom headers
///         if let customHeader = requestInfo.headers["X-Custom-Header"] {
///             print("Custom header: \(customHeader)")
///         }
///     }
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public struct RequestInfo: Hashable, Sendable {
    /// The HTTP headers from the request.
    ///
    /// Header names are preserved as provided by the HTTP framework.
    /// Use case-insensitive comparison when looking up headers.
    public let headers: [String: String]

    public init(headers: [String: String]) {
        self.headers = headers
    }

    /// Get a header value (case-insensitive lookup).
    ///
    /// - Parameter name: The header name to look up
    /// - Returns: The header value, or nil if not found
    public func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        for (key, value) in headers {
            if key.lowercased() == lowercased {
                return value
            }
        }
        return nil
    }
}

/// Context information associated with a received message.
///
/// This is the Swift equivalent of TypeScript's `MessageExtraInfo`, which is passed
/// via `onmessage(message, extra)`. It carries per-message context like authentication
/// info and SSE stream management callbacks.
///
/// For simple transports (stdio, in-memory), context is typically `nil`.
/// For HTTP transports, context includes authentication info and SSE controls.
public struct MessageContext: Sendable {
    /// Authentication information for this message's request.
    ///
    /// Contains validated access token information when using HTTP transports
    /// with OAuth or other token-based authentication. Request handlers can
    /// access this via `context.authInfo`.
    public let authInfo: AuthInfo?

    /// Information about the incoming HTTP request.
    ///
    /// Contains HTTP headers from the original request. Only available for
    /// HTTP transports. Request handlers can access this via `context.requestInfo`.
    ///
    /// This matches TypeScript SDK's `extra.requestInfo` and allows handlers
    /// to inspect custom headers for authentication, client identification, etc.
    public let requestInfo: RequestInfo?

    /// Closes the SSE stream for this request, triggering client reconnection.
    ///
    /// Only available when using HTTPServerTransport with eventStore configured.
    /// Use this to implement polling behavior during long-running operations.
    public let closeSSEStream: (@Sendable () async -> Void)?

    /// Closes the standalone GET SSE stream, triggering client reconnection.
    ///
    /// Only available when using HTTPServerTransport with eventStore configured.
    public let closeStandaloneSSEStream: (@Sendable () async -> Void)?

    public init(
        authInfo: AuthInfo? = nil,
        requestInfo: RequestInfo? = nil,
        closeSSEStream: (@Sendable () async -> Void)? = nil,
        closeStandaloneSSEStream: (@Sendable () async -> Void)? = nil
    ) {
        self.authInfo = authInfo
        self.requestInfo = requestInfo
        self.closeSSEStream = closeSSEStream
        self.closeStandaloneSSEStream = closeStandaloneSSEStream
    }
}

/// A message received from a transport with optional context.
///
/// This is the Swift equivalent of TypeScript's `onmessage(message, extra)` pattern,
/// adapted for Swift's `AsyncThrowingStream` approach. Each message carries its own
/// context, eliminating race conditions that would occur if context were stored
/// as mutable state on the transport.
///
/// ## Example
///
/// ```swift
/// for try await message in transport.receive() {
///     let data = message.data
///     if let authInfo = message.context?.authInfo {
///         // Handle authenticated request
///     }
/// }
/// ```
public struct TransportMessage: Sendable {
    /// The raw message data (JSON-RPC message).
    public let data: Data

    /// Context associated with this message.
    ///
    /// Includes authentication info, SSE stream controls, and other per-message
    /// context. For simple transports, this is `nil`.
    public let context: MessageContext?

    public init(data: Data, context: MessageContext? = nil) {
        self.data = data
        self.context = context
    }
}

// MARK: - Transport Protocol

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

    /// Receives messages with optional context in an async sequence.
    ///
    /// Each message includes optional context (auth info, SSE closures, etc.)
    /// that was associated with it at receive time. This pattern matches
    /// TypeScript's `onmessage(message, extra)` callback approach.
    ///
    /// For simple transports, messages are yielded with `nil` context.
    /// For HTTP transports, context includes authentication info and SSE controls.
    func receive() -> AsyncThrowingStream<TransportMessage, Swift.Error>
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
