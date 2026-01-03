import Foundation

// Types extracted from HTTPServerTransport.swift
// - Options
// - SecuritySettings
// - EventStore protocol
// - HTTPRequest
// - HTTPResponse

/// Configuration options for HTTPServerTransport
public struct HTTPServerTransportOptions: Sendable {
    /// Function that generates a session ID for the transport.
    /// The session ID SHOULD be globally unique and cryptographically secure
    /// (e.g., a securely generated UUID, a JWT, or a cryptographic hash).
    ///
    /// If not provided, session management is disabled (stateless mode).
    public var sessionIdGenerator: (@Sendable () -> String)?

    /// Called when the server initializes a new session.
    /// This is called when the server receives an initialize request and generates a session ID.
    /// Useful for tracking multiple MCP sessions.
    public var onSessionInitialized: (@Sendable (String) async -> Void)?

    /// Called when the server closes a session (DELETE request).
    /// Useful for cleaning up resources associated with the session.
    public var onSessionClosed: (@Sendable (String) async -> Void)?

    /// If true, the server will return JSON responses instead of starting an SSE stream.
    /// This can be useful for simple request/response scenarios without streaming.
    /// Default is false (SSE streams are preferred).
    public var enableJsonResponse: Bool

    /// Event store for resumability support.
    /// If provided, resumability will be enabled, allowing clients to reconnect and resume messages.
    public var eventStore: EventStore?

    /// Retry interval in milliseconds to suggest to clients in SSE retry field.
    /// When set, the server will send a retry field in SSE priming events to control
    /// client reconnection timing for polling behavior.
    public var retryInterval: Int?

    /// Security settings for DNS rebinding protection.
    ///
    /// When nil, no security validation is performed.
    /// Use `TransportSecuritySettings.forLocalhost(port:)` for localhost-bound servers.
    ///
    /// See `TransportSecuritySettings` documentation for details on DNS rebinding attacks
    /// and the rationale for protection.
    public var security: TransportSecuritySettings?

    public init(
        sessionIdGenerator: (@Sendable () -> String)? = nil,
        onSessionInitialized: (@Sendable (String) async -> Void)? = nil,
        onSessionClosed: (@Sendable (String) async -> Void)? = nil,
        enableJsonResponse: Bool = false,
        eventStore: EventStore? = nil,
        retryInterval: Int? = nil,
        security: TransportSecuritySettings? = nil
    ) {
        self.sessionIdGenerator = sessionIdGenerator
        self.onSessionInitialized = onSessionInitialized
        self.onSessionClosed = onSessionClosed
        self.enableJsonResponse = enableJsonResponse
        self.eventStore = eventStore
        self.retryInterval = retryInterval
        self.security = security
    }
}

/// Security settings for DNS rebinding protection.
///
/// DNS rebinding is an attack where a malicious website can bypass same-origin policy
/// by manipulating DNS responses, potentially allowing browser-based attackers to
/// interact with local MCP servers. This is particularly dangerous for servers
/// bound to localhost.
///
/// ## How Protection Works
///
/// When enabled, the transport validates:
/// 1. **Host header**: Must match an allowed host pattern (prevents DNS rebinding)
/// 2. **Origin header**: If present (browser requests), must match an allowed origin
///
/// ## Usage
///
/// ```swift
/// // Auto-enabled for localhost (recommended)
/// let settings = TransportSecuritySettings.forLocalhost(port: 8080)
///
/// // Or manually configure
/// let settings = TransportSecuritySettings(
///     enableDnsRebindingProtection: true,
///     allowedHosts: ["myserver.local:8080"],
///     allowedOrigins: ["http://myserver.local:8080"]
/// )
/// ```
public struct TransportSecuritySettings: Sendable {
    /// Whether to validate Host and Origin headers for DNS rebinding protection.
    public var enableDnsRebindingProtection: Bool

    /// Allowed Host header values. Supports wildcard port patterns like "127.0.0.1:*".
    /// When protection is enabled, requests with Host headers not matching any pattern are rejected.
    public var allowedHosts: [String]

    /// Allowed Origin header values. Supports wildcard port patterns like "http://localhost:*".
    /// When protection is enabled and an Origin header is present, it must match one of these patterns.
    /// Requests without an Origin header are allowed (non-browser clients).
    public var allowedOrigins: [String]

    public init(
        enableDnsRebindingProtection: Bool = false,
        allowedHosts: [String] = [],
        allowedOrigins: [String] = []
    ) {
        self.enableDnsRebindingProtection = enableDnsRebindingProtection
        self.allowedHosts = allowedHosts
        self.allowedOrigins = allowedOrigins
    }

    /// Creates security settings for a localhost-bound server.
    ///
    /// - Parameter port: The port number (use "*" pattern if port varies)
    /// - Returns: Security settings with protection enabled for all localhost variants
    public static func forLocalhost(port: Int? = nil) -> TransportSecuritySettings {
        let portPattern = port.map { String($0) } ?? "*"
        return TransportSecuritySettings(
            enableDnsRebindingProtection: true,
            allowedHosts: [
                "127.0.0.1:\(portPattern)",
                "localhost:\(portPattern)",
                "[::1]:\(portPattern)",
            ],
            allowedOrigins: [
                "http://127.0.0.1:\(portPattern)",
                "http://localhost:\(portPattern)",
                "http://[::1]:\(portPattern)",
            ]
        )
    }

    /// Creates security settings appropriate for the given bind address.
    ///
    /// Auto-enables DNS rebinding protection for localhost addresses,
    /// returns nil for other addresses (no protection needed for remote bindings).
    ///
    /// - Parameters:
    ///   - host: The host address the server is binding to
    ///   - port: The port number
    /// - Returns: Security settings if protection should be enabled, nil otherwise
    public static func forBindAddress(host: String, port: Int) -> TransportSecuritySettings? {
        let localhostAddresses = ["127.0.0.1", "localhost", "::1"]
        if localhostAddresses.contains(host) {
            return forLocalhost(port: port)
        }
        return nil
    }
}

/// Protocol for storing and replaying SSE events for resumability support.
///
/// Implementations should store events durably and support replaying them
/// when clients reconnect with a Last-Event-ID header.
///
/// ## Priming Events
///
/// Priming events are stored with empty `Data()` as the message. These events
/// establish the initial event ID for a stream but should **not** be replayed
/// as regular messages. During replay, implementations should skip events with
/// empty message data and only replay actual JSON-RPC messages.
public protocol EventStore: Sendable {
    /// Stores an event and returns its unique ID.
    ///
    /// - Parameters:
    ///   - streamId: The stream this event belongs to
    ///   - message: The JSON-RPC message data. Empty `Data()` indicates a priming event
    ///              which should be skipped during replay.
    /// - Returns: A unique event ID for this event
    func storeEvent(streamId: String, message: Data) async throws -> String

    /// Gets the stream ID associated with an event ID.
    /// - Parameter eventId: The event ID to look up
    /// - Returns: The stream ID, or nil if not found
    func streamIdForEventId(_ eventId: String) async -> String?

    /// Replays events after the given event ID.
    ///
    /// Implementations should skip priming events (empty message data) during replay.
    /// Only actual JSON-RPC messages should be sent to the callback.
    ///
    /// - Parameters:
    ///   - lastEventId: The last event ID the client received
    ///   - send: Callback to send each replayed event (eventId, message)
    /// - Returns: The stream ID for continued event delivery
    func replayEventsAfter(
        _ lastEventId: String,
        send: @escaping @Sendable (String, Data) async throws -> Void
    ) async throws -> String
}

/// HTTP response returned by `HTTPServerTransport.handleRequest(_:)`.
///
/// This struct represents the result of processing an MCP request. It can contain either:
/// - A simple JSON response with `body` data (for non-streaming responses)
/// - An SSE stream for streaming responses (for long-running operations or server-initiated messages)
///
/// ## Usage with HTTP Frameworks
///
/// When integrating with an HTTP framework like Vapor or Hummingbird, convert this response
/// to the framework's native response type:
///
/// ```swift
/// // Vapor example
/// func handleMCP(req: Request) async throws -> Response {
///     let httpRequest = HTTPRequest(
///         method: req.method.rawValue,
///         headers: Dictionary(req.headers.map { ($0.name, $0.value) }) { _, last in last },
///         body: req.body.data
///     )
///     let response = await transport.handleRequest(httpRequest)
///
///     if let stream = response.stream {
///         // Return SSE response
///         return Response(status: .init(statusCode: response.statusCode), body: .init(asyncSequence: stream))
///     } else {
///         // Return JSON response
///         return Response(status: .init(statusCode: response.statusCode), body: .init(data: response.body ?? Data()))
///     }
/// }
/// ```
public struct HTTPResponse: Sendable {
    /// The HTTP status code for the response (e.g., 200, 400, 404).
    public let statusCode: Int
    /// HTTP headers to include in the response (e.g., Content-Type, Mcp-Session-Id).
    public let headers: [String: String]
    /// Response body data for non-streaming responses. Nil for SSE streaming responses.
    public let body: Data?
    /// SSE stream for streaming responses. Nil for simple JSON responses.
    /// When present, the caller should stream this data to the client as Server-Sent Events.
    public let stream: AsyncThrowingStream<Data, Swift.Error>?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data? = nil,
        stream: AsyncThrowingStream<Data, Swift.Error>? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.stream = stream
    }
}

/// HTTP request abstraction for framework-agnostic handling.
///
/// This struct provides a common interface for HTTP requests that can be populated from
/// any HTTP server framework (Vapor, Hummingbird, SwiftNIO, etc.). The
/// `HTTPServerTransport` uses this abstraction to process MCP requests
/// without being coupled to a specific framework.
///
/// ## Usage
///
/// Convert your framework's request type to `HTTPRequest` before passing to the transport:
///
/// ```swift
/// // Vapor example
/// let httpRequest = HTTPRequest(
///     method: req.method.rawValue,
///     headers: Dictionary(req.headers.map { ($0.name, $0.value) }) { _, last in last },
///     body: req.body.data
/// )
///
/// // Hummingbird example
/// let httpRequest = HTTPRequest(
///     method: String(describing: request.method),
///     headers: Dictionary(request.headers.map { ($0.name.rawName, $0.value) }) { _, last in last },
///     body: request.body.buffer?.getData(at: 0, length: request.body.buffer?.readableBytes ?? 0)
/// )
/// ```
public struct HTTPRequest: Sendable {
    /// The HTTP method (e.g., "GET", "POST", "DELETE").
    public let method: String
    /// Request headers as a case-sensitive dictionary.
    /// Use the `header(_:)` method for case-insensitive header lookup.
    public let headers: [String: String]
    /// The request body data, if present.
    public let body: Data?

    public init(method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// Get a header value (case-insensitive)
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
