import Foundation

// MARK: - Session ID Generator

/// Generates unique session identifiers for stateful HTTP server transports.
///
/// Conform to this protocol to provide custom session ID generation logic.
/// Session IDs **MUST** contain only visible ASCII characters (0x21–0x7E)
/// per the MCP specification.
///
/// A default implementation using UUID is provided via ``UUIDSessionIDGenerator``.
public protocol SessionIDGenerator: Sendable {
    /// Generates a new unique session identifier.
    func generateSessionID() -> String
}

/// Default session ID generator that produces UUID strings.
///
/// UUID strings consist of hexadecimal characters and hyphens,
/// which are all within the valid ASCII range (0x21–0x7E).
public struct UUIDSessionIDGenerator: SessionIDGenerator {
    public init() {}

    public func generateSessionID() -> String {
        UUID().uuidString
    }
}

// MARK: - HTTP Request

/// A framework-agnostic HTTP request representation.
///
/// This type decouples the transport from any specific HTTP framework.
/// The HTTP framework adapter converts its native request type into this before passing to the transport.
public struct HTTPRequest: Sendable {
    /// The HTTP method (e.g., "GET", "POST", "DELETE").
    public let method: String

    /// HTTP headers as key-value pairs.
    public let headers: [String: String]

    /// The request body data, if any.
    public let body: Data?

    public init(method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercased }?.value
    }
}

// MARK: - HTTP Response

/// A framework-agnostic HTTP response.
///
/// The HTTP framework adapter converts this into its native response type.
///
/// Use computed properties (`statusCode`, `headers`, `bodyData`) for generic access,
/// or switch on the enum for case-specific handling (e.g., streaming):
///
/// ```swift
/// let response = await transport.handleRequest(request)
/// switch response {
/// case .stream(let sseStream, _):
///     // Pipe the async stream to the HTTP response body
/// default:
///     // Use response.bodyData for the body
/// }
/// ```
public enum HTTPResponse: Sendable {
    /// 202 Accepted, no body. Used for notifications and client responses.
    case accepted(headers: [String: String] = [:])

    /// 200 OK, no body. Used for DELETE confirmation.
    case ok(headers: [String: String] = [:])

    /// 200 OK with data body (typically JSON).
    case data(Data, headers: [String: String] = [:])

    /// 200 OK with SSE streaming body.
    case stream(AsyncThrowingStream<Data, Swift.Error>, headers: [String: String] = [:])

    /// Error response with a JSON-RPC error body.
    /// The status code, headers, and body are derived automatically.
    case error(statusCode: Int, MCPError, sessionID: String? = nil, extraHeaders: [String: String] = [:])

    // MARK: - Computed Properties

    public var statusCode: Int {
        switch self {
        case .accepted: 202
        case .ok, .data, .stream: 200
        case .error(let code, _, _, _): code
        }
    }

    public var headers: [String: String] {
        switch self {
        case .accepted(let headers), .ok(let headers), .data(_, let headers), .stream(_, let headers):
            return headers
        case .error(_, _, let sessionID, let extraHeaders):
            var headers: [String: String] = [HTTPHeaderName.contentType: ContentType.json]
            if let sessionID { headers[HTTPHeaderName.sessionID] = sessionID }
            headers.merge(extraHeaders) { _, new in new }
            return headers
        }
    }

    /// The response body as data. `nil` for `.accepted`, `.ok`, and `.stream`.
    public var bodyData: Data? {
        switch self {
        case .accepted, .ok, .stream:
            return nil
        case .data(let data, _):
            return data
        case .error(_, let error, _, _):
            let errorBody: [String: Any] = [
                "jsonrpc": "2.0",
                "error": [
                    "code": error.code,
                    "message": error.errorDescription ?? "Unknown error",
                ],
                "id": NSNull(),
            ]
            return try? JSONSerialization.data(withJSONObject: errorBody)
        }
    }
}

// MARK: - HTTP Header Names

/// Standard header names used by the MCP Streamable HTTP transport.
public enum HTTPHeaderName {
    public static let sessionID = "MCP-Session-Id"
    public static let protocolVersion = "MCP-Protocol-Version"
    public static let lastEventID = "Last-Event-Id"
    public static let accept = "Accept"
    public static let contentType = "Content-Type"
    public static let origin = "Origin"
    public static let host = "Host"
    public static let cacheControl = "Cache-Control"
    public static let connection = "Connection"
    public static let allow = "Allow"
}

// MARK: - Content Types

enum ContentType {
    static let json = "application/json"
    static let sse = "text/event-stream"
}

// MARK: - SSE Event

/// A Server-Sent Event (SSE) data structure.
///
/// Formats according to the SSE specification:
/// https://html.spec.whatwg.org/multipage/server-sent-events.html
struct SSEEvent: Sendable {
    var id: String?
    var event: String?
    var data: String
    var retry: Int?

    /// Formats the event as SSE wire data.
    func formatted() -> Data {
        var result = ""
        if let id {
            result += "id: \(id)\n"
        }
        if let event {
            result += "event: \(event)\n"
        }
        if let retry {
            result += "retry: \(retry)\n"
        }
        result += "data: \(data)\n\n"
        return Data(result.utf8)
    }

    /// Creates a priming event with an empty data field.
    /// Per spec, this is sent immediately to prime the client for reconnection.
    static func priming(id: String, retry: Int? = nil) -> SSEEvent {
        SSEEvent(id: id, event: nil, data: "", retry: retry)
    }

    /// Creates a message event wrapping JSON-RPC data.
    static func message(data: Data, id: String? = nil) -> SSEEvent {
        SSEEvent(
            id: id,
            event: "message",
            data: String(decoding: data, as: UTF8.self)
        )
    }
}

// MARK: - JSON-RPC Message Classification

/// Classifies a raw JSON-RPC message for routing purposes.
///
/// Used by transports to determine where to route outgoing messages:
/// - Responses are routed to the originating request's stream
/// - Notifications and server requests are routed to the standalone GET stream
package enum JSONRPCMessageKind {
    case request(id: String, method: String)
    case notification(method: String)
    case response(id: String)

    /// Attempts to classify raw JSON-RPC data.
    /// Returns `nil` if the data cannot be parsed or classified.
    package init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let id = Self.extractID(from: json)

        if let method = json["method"] as? String {
            if let id {
                self = .request(id: id, method: method)
            } else {
                self = .notification(method: method)
            }
        } else if json["result"] != nil || json["error"] != nil {
            guard let id else { return nil }
            self = .response(id: id)
        } else {
            return nil
        }
    }

    /// Whether this message is a JSON-RPC response (success or error).
    var isResponse: Bool {
        if case .response = self { return true }
        return false
    }

    /// Whether this message is an `initialize` request.
    package var isInitializeRequest: Bool {
        if case .request(_, let method) = self {
            return method == "initialize"
        }
        return false
    }

    private static func extractID(from json: [String: Any]) -> String? {
        if let stringID = json["id"] as? String {
            return stringID
        } else if let intID = json["id"] as? Int {
            return String(intID)
        }
        return nil
    }
}
