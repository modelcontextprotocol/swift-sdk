/// HTTP header names used by the MCP protocol.
public enum HTTPHeader {
    // MARK: - MCP Protocol Headers

    /// Session identifier for Streamable HTTP transport.
    ///
    /// Servers may return this header during initialization. Clients must
    /// include it in all subsequent requests when present.
    public static let sessionId = "mcp-session-id"

    /// Protocol version indicating the MCP version in use.
    ///
    /// Required for protocol versions >= 2025-06-18. Clients should send
    /// the version negotiated during initialization.
    public static let protocolVersion = "mcp-protocol-version"

    // MARK: - Standard HTTP Headers

    /// Content type of the request or response body.
    public static let contentType = "content-type"

    /// Caching directives for the response.
    public static let cacheControl = "cache-control"

    /// Connection management options.
    public static let connection = "connection"

    /// Media types acceptable for the response.
    public static let accept = "accept"

    /// Last event ID for SSE stream resumability.
    public static let lastEventId = "last-event-id"

    /// Allowed HTTP methods for a resource (used in 405 responses).
    public static let allow = "allow"

    /// Host header for the request target.
    public static let host = "host"

    /// Origin header indicating where a request originated from.
    public static let origin = "origin"

    /// Authorization header for bearer tokens and other auth schemes.
    public static let authorization = "authorization"
}
