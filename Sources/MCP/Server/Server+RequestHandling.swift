import Foundation

extension Server {
    // MARK: - Request and Message Handling

    /// Internal context for routing responses to the correct transport.
    ///
    /// When handling requests, we capture the current connection at request time.
    /// This ensures that when the handler completes (which may be async), the response
    /// is sent to the correct client even if `self.connection` has changed in the meantime.
    ///
    /// This pattern is critical for HTTP transports where multiple clients can connect
    /// and the server's `connection` reference gets reassigned.
    struct RequestContext {
        /// The transport connection captured at request time
        let capturedConnection: (any Transport)?
        /// The ID of the request being handled
        let requestId: ID
        /// The session ID from the transport, if available.
        ///
        /// For HTTP transports with multiple concurrent clients, this identifies
        /// the specific session. Used for per-session features like log levels.
        let sessionId: String?
        /// The request metadata from `_meta` field, if present.
        ///
        /// Contains the progress token and any additional metadata.
        let meta: RequestMeta?
        /// Authentication information, if available.
        ///
        /// Set by HTTP transports when OAuth or other authentication is in use.
        let authInfo: AuthInfo?
        /// Information about the incoming HTTP request.
        ///
        /// Contains HTTP headers from the original request. Only available for
        /// HTTP transports. This matches TypeScript SDK's `extra.requestInfo`.
        let requestInfo: RequestInfo?
        /// Closure to close the SSE stream for this request.
        ///
        /// Only set by HTTP transports with SSE support.
        let closeSSEStream: (@Sendable () async -> Void)?
        /// Closure to close the standalone SSE stream.
        ///
        /// Only set by HTTP transports with SSE support.
        let closeStandaloneSSEStream: (@Sendable () async -> Void)?
    }
}
