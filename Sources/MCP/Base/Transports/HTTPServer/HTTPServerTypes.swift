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
    /// Creates a UUID session ID generator.
    public init() {}

    /// Returns a new random UUID string.
    public func generateSessionID() -> String {
        UUID().uuidString
    }
}

// MARK: - HTTP Request

/// A framework-agnostic HTTP request representation.
///
/// This type decouples the transport from any specific HTTP framework.
/// The HTTP framework adapter converts its native request type into this before passing to the transport.
///
/// An adapter should pass the header field lines as received, with
/// ``init(method:headerFields:body:path:)``: the transports then see how many
/// times a header was sent, and refuse a repeated single-valued header such
/// as `MCP-Protocol-Version` or `Mcp-Name` (RFC 9110 §5.3).
public struct HTTPRequest: Sendable {
    /// The HTTP method (e.g., "GET", "POST", "DELETE").
    public let method: String

    /// HTTP headers as key-value pairs.
    ///
    /// Built with ``init(method:headerFields:body:path:)``, it has one key
    /// per field name, spelled as first received, and the values of
    /// repeated field lines joined with `", "` in order (RFC 9110 §5.3).
    /// Built from a dictionary, it is that dictionary: an adapter that
    /// joins repeated lines itself should join them the same way.
    public let headers: [String: String]

    /// The request body data, if any.
    public let body: Data?

    /// The request path (e.g., "/mcp", "/.well-known/oauth-protected-resource").
    /// Used by validators that need to match on specific paths.
    public let path: String?

    /// The header field lines as received, or `nil` when the request was
    /// built from a dictionary.
    private let fieldLines: [(name: String, value: String)]?

    /// Creates an HTTP request from a dictionary of headers.
    ///
    /// The transports cannot tell how many field lines a value came from;
    /// prefer ``init(method:headerFields:body:path:)`` in an adapter.
    public init(method: String, headers: [String: String] = [:], body: Data? = nil, path: String? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
        self.path = path
        self.fieldLines = nil
    }

    /// Creates an HTTP request from its header field lines, in the order
    /// received.
    ///
    /// Names are compared case-insensitively (RFC 9110 §5.1). ``headers``
    /// joins the values of repeated lines; ``headerValues(_:)`` returns
    /// each line's value. A SwiftNIO adapter passes `Array(head.headers)`.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, such as `"POST"`.
    ///   - headerFields: The header field lines, as `(name, value)` pairs.
    ///   - body: The request body, if any.
    ///   - path: The request path without the query, such as `"/mcp"`.
    public init(
        method: String, headerFields: [(name: String, value: String)], body: Data? = nil, path: String? = nil
    ) {
        var headers: [String: String] = [:]
        var keys: [String: String] = [:]
        for (name, value) in headerFields {
            let key = keys[name.lowercased(), default: name]
            keys[name.lowercased()] = key
            headers[key] = headers[key].map { "\($0), \(value)" } ?? value
        }
        self.method = method
        self.headers = headers
        self.body = body
        self.path = path
        self.fieldLines = headerFields
    }

    /// Case-insensitive header lookup.
    ///
    /// Keys that differ only in case are one field (RFC 9110 §5.1): their
    /// values are joined with `", "` in the order of their keys, so the
    /// result does not depend on the dictionary's order.
    public func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        let matches = headers.filter { $0.key.lowercased() == lowercased }
        guard matches.count > 1 else { return matches.first?.value }
        return matches.sorted { $0.key < $1.key }.map(\.value).joined(separator: ", ")
    }

    /// The value of each field line named `name`, compared
    /// case-insensitively, in the order received; empty when there is none.
    ///
    /// For a request built from a dictionary, the value of each key that
    /// matches, in the order of the keys: a value the adapter joined from
    /// several lines counts once.
    public func headerValues(_ name: String) -> [String] {
        let lowercased = name.lowercased()
        if let fieldLines {
            return fieldLines.filter { $0.name.lowercased() == lowercased }.map(\.value)
        }
        return headers.filter { $0.key.lowercased() == lowercased }.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Whether the single-valued header `name` was sent more than once:
    /// on several field lines, or, for a header whose values never contain
    /// a comma, as a comma-joined value.
    func isRepeated(_ name: String, valuesMayContainCommas: Bool = false) -> Bool {
        let values = headerValues(name)
        if values.count > 1 { return true }
        return !valuesMayContainCommas && values.first?.contains(",") == true
    }

    /// The `MCP-Protocol-Version` header when it names a revision served
    /// without a session (2026-07-28 and later, or an unknown version).
    ///
    /// Use it to route a request: a non-`nil` value belongs to
    /// ``StatelessHTTPServerTransport``; anything else to the session-based
    /// transport.
    public var statelessProtocolVersion: String? {
        guard let version = header(HTTPHeaderName.protocolVersion)?
            .trimmingCharacters(in: .whitespaces), !version.isEmpty,
            !Version.handshake.contains(version)
        else { return nil }
        return version
    }
}

/// HTTP status codes for JSON-RPC errors on stateless (2026-07-28) requests.
enum JSONRPCErrorStatus {
    /// -32601 maps to 404; invalid request, invalid params and the
    /// -32020/-32021/-32022 protocol errors map to 400; anything else to 200.
    static func statusCode(for code: Int) -> Int {
        switch code {
        case -32601: 404
        case -32600, -32602, -32020, -32021, -32022: 400
        default: 200
        }
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
///
/// Frozen: no case is added in 1.x (a new case would need changes in every server adapter, so it is a major release).
public enum HTTPResponse: Sendable {
    /// 202 Accepted, no body. Used for notifications and client responses.
    case accepted(headers: [String: String] = [:])

    /// 200 OK, no body. Used for DELETE confirmation.
    case ok(headers: [String: String] = [:])

    /// A data body (typically JSON), 200 OK unless `statusCode` says otherwise.
    case data(Data, statusCode: Int = 200, headers: [String: String] = [:])

    /// 200 OK with SSE streaming body.
    case stream(AsyncThrowingStream<Data, Swift.Error>, headers: [String: String] = [:])

    /// Error response with a JSON-RPC error body.
    /// The status code, headers, and body are derived automatically. `id` is
    /// the JSON-RPC id of the rejected request, or `nil` when it is unknown.
    case error(
        statusCode: Int, MCPError, id: ID? = nil, sessionID: String? = nil,
        extraHeaders: [String: String] = [:])

    // MARK: - Computed Properties

    /// The HTTP status code of the response.
    public var statusCode: Int {
        switch self {
        case .accepted: 202
        case .ok, .stream: 200
        case .data(_, let code, _): code
        case .error(let code, _, _, _, _): code
        }
    }

    /// The response headers.
    ///
    /// For `.error`, `Content-Type: application/json`, `MCP-Session-Id` when
    /// a session ID is set, and the extra headers.
    public var headers: [String: String] {
        switch self {
        case .accepted(let headers), .ok(let headers), .data(_, _, let headers), .stream(_, let headers):
            return headers
        case .error(_, _, _, let sessionID, let extraHeaders):
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
        case .data(let data, _, _):
            return data
        case .error(_, let error, let id, _, _):
            return try? JSONEncoder().encode(ErrorBody(id: id, error: error))
        }
    }

    /// Returns the response with `id` as the JSON-RPC id of an error body
    /// that has none. Other responses are returned unchanged.
    public func withRequestID(_ id: ID?) -> HTTPResponse {
        guard let id, case .error(let code, let error, nil, let sessionID, let extra) = self else {
            return self
        }
        return .error(statusCode: code, error, id: id, sessionID: sessionID, extraHeaders: extra)
    }

    private struct ErrorBody: Encodable {
        let id: ID?
        let error: MCPError

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("2.0", forKey: .jsonrpc)
            try container.encode(id, forKey: .id)
            try container.encode(error, forKey: .error)
        }

        private enum CodingKeys: String, CodingKey { case jsonrpc, id, error }
    }
}

// MARK: - HTTP Header Names

/// Standard header names used by the MCP Streamable HTTP transport.
public enum HTTPHeaderName {
    /// A DPoP proof (RFC 9449).
    public static let dpop = "DPoP"
    /// A server-provided DPoP nonce (RFC 9449 §8).
    public static let dpopNonce = "DPoP-Nonce"
    /// `MCP-Session-Id`: the session of a handshake-era request.
    public static let sessionID = "MCP-Session-Id"
    /// `MCP-Protocol-Version`: the protocol revision of a request.
    public static let protocolVersion = "MCP-Protocol-Version"
    /// `Last-Event-ID`: the last SSE event a client received, for resuming a stream.
    public static let lastEventID = "Last-Event-ID"
    /// `Accept`: the media types a client accepts.
    public static let accept = "Accept"
    /// `Content-Type`: the media type of a body.
    public static let contentType = "Content-Type"
    /// `Authorization`: the credentials of a request.
    public static let authorization = "Authorization"
    /// `WWW-Authenticate`: the authentication challenge of a 401 or 403 response.
    public static let wwwAuthenticate = "WWW-Authenticate"
    /// `Origin`: the origin a browser request comes from.
    public static let origin = "Origin"
    /// `Host`: the host and port a request is addressed to.
    public static let host = "Host"
    /// `Cache-Control`: caching directives; SSE responses send `no-cache, no-transform`.
    public static let cacheControl = "Cache-Control"
    /// `Connection`: connection options; SSE responses send `keep-alive`.
    public static let connection = "Connection"
    /// `Allow`: the methods an endpoint accepts, sent with 405 responses.
    public static let allow = "Allow"
    /// `ETag`: the entity tag of a response, for revalidation.
    public static let etag = "ETag"
    /// `If-None-Match`: the entity tags a client has; 304 when one still matches.
    public static let ifNoneMatch = "If-None-Match"
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

// MARK: - HTTP Context Providing

/// A transport that can surface the originating HTTP request for an in-flight JSON-RPC
/// request, keyed by its JSON-RPC id.
///
/// The server consults this during dispatch so that registered method handlers can
/// observe the HTTP request that triggered them (headers, auth, path, body) via
/// ``Server/currentHandlerContext``, without changing the `withMethodHandler` signature.
///
/// Only JSON-RPC *requests* (with an id) are addressable — notifications have no id and
/// are not correlated.
public protocol HTTPContextProviding: Sendable {
    /// Returns the HTTP request associated with the given JSON-RPC id, if the
    /// transport still has it on hand. Implementations must return `nil` once the
    /// corresponding response has been delivered or the session has terminated.
    func httpRequestContext(for id: ID) async -> HTTPRequest?
}

// MARK: - JSON-RPC Message Classification

/// Classifies a raw JSON-RPC message for routing purposes.
///
/// Used by transports to determine where to route outgoing messages:
/// - Responses are routed to the originating request's stream
/// - Notifications and server requests are routed to the standalone GET stream
package enum JSONRPCMessageKind: Decodable {
    case request(id: String, method: String)
    case notification(method: String)
    case response(id: String)
    /// A message with a string `method` that is neither a valid request
    /// nor a valid notification: its `id` is not a string or an integer, or
    /// its `jsonrpc` is not `"2.0"`. It must be answered with -32600, using
    /// `id` when it is a string or an integer and `null` otherwise.
    case invalid(method: String, id: ID?, reason: String)

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, result, error
    }

    /// Attempts to classify raw JSON-RPC data.
    /// Returns `nil` if the data cannot be parsed or classified.
    package init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = decoded
    }

    /// The error for data that could not be classified as a JSON-RPC message.
    static func classificationError(for data: Data) -> MCPError {
        // JSON-RPC 2.0 §5.1 reserves -32700 for invalid JSON. Scalars and arrays
        // are valid JSON, but are not single messages on the HTTP transport.
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .invalidRequest("Invalid JSON-RPC message")
        } catch {
            return .parseError("Invalid JSON-RPC message")
        }
    }

    /// Classifies a JSON-RPC object.
    ///
    /// A message with a string `method` is a request when it has an `id`
    /// member and a notification when it has none, whatever the type of
    /// the `id`: an `id` that is not a string or an integer makes it
    /// ``invalid(method:id:reason:)``, not a notification (JSON-RPC 2.0 §5).
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `ID` reads `null` as `""`.
        let isNull = (try? container.decodeNil(forKey: .id)) == true
        let id = isNull ? nil : try? container.decode(ID.self, forKey: .id)

        if let method = try? container.decode(String.self, forKey: .method) {
            if (try? container.decode(String.self, forKey: .jsonrpc)) != "2.0" {
                self = .invalid(method: method, id: id, reason: InvalidRequestReason.jsonrpc)
            } else if !container.contains(.id) {
                self = .notification(method: method)
            } else if let id {
                self = .request(id: id.description, method: method)
            } else {
                // A number too large to decode as a `Value` is `nil` here.
                let reason = InvalidRequestReason.id(try? container.decode(Value.self, forKey: .id))
                self = .invalid(method: method, id: nil, reason: reason)
            }
        } else if container.contains(.result) || container.contains(.error), let id {
            // JSON-RPC 2.0 §5 requires the version on responses too.
            guard (try? container.decode(String.self, forKey: .jsonrpc)) == "2.0" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .jsonrpc, in: container, debugDescription: InvalidRequestReason.jsonrpc)
            }
            self = .response(id: id.description)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath, debugDescription: "Not a JSON-RPC message"))
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

    /// A message's `id`, rendered as a string; `nil` when absent or not a
    /// string or an integer that fits `Int`.
    package static func extractID(from json: [String: Any]) -> String? {
        switch json["id"] {
        case let string as String:
            return string
        // A JSON boolean is an `NSNumber` too, and `true as? Int` is 1 on Darwin.
        case let number as NSNumber where !isBoolean(number):
            return (number as? Int).map(String.init)
        default:
            return nil
        }
    }

    /// Whether `number` came from a JSON `true` or `false`.
    static func isBoolean(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c"
    }

    /// The `requestId` of a `notifications/cancelled` message, rendered like
    /// a request's ID, or `nil` for any other message.
    static func cancelledRequestID(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["method"] as? String == CancelledNotification.name,
            let params = json["params"] as? [String: Any]
        else { return nil }
        return extractID(from: ["id": params["requestId"] as Any])
    }
}

/// Why a message with a `method` is not a valid request or notification,
/// for the message of the -32600 answer.
enum InvalidRequestReason {
    /// `jsonrpc` is missing or not `"2.0"`.
    static let jsonrpc = "jsonrpc must be \"2.0\""

    /// The problem with an `id` that is not a string or an integer, as
    /// decoded into a ``Value``; `nil` is a number too large to decode.
    static func id(_ value: Value?) -> String {
        switch value {
        case .null?: return null
        case .double(let double)?: return double.rounded() == double ? outOfRange : type
        case nil: return outOfRange
        default: return type
        }
    }

    private static let null = "id must not be null"
    private static let outOfRange = "id is out of range"
    private static let type = "id must be a string or an integer"
}
