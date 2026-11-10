import Foundation

/// Shares one asynchronous initialization result across concurrent callers.
package actor AsyncInitialization<Value: Sendable> {
    private var cachedValue: Value?
    private var activeTask: (id: UUID, task: Task<Value, Error>)?

    package init() {}

    package func value(
        create: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let cachedValue { return cachedValue }
        let active: (id: UUID, task: Task<Value, Error>)
        if let activeTask {
            active = activeTask
        } else {
            let id = UUID()
            let task = Task { try await create() }
            active = (id, task)
            activeTask = active
        }
        do {
            let result = try await active.task.value
            cachedValue = result
            if activeTask?.id == active.id { activeTask = nil }
            return result
        } catch {
            if activeTask?.id == active.id { activeTask = nil }
            throw error
        }
    }

    package func existingValue() async -> Value? {
        if let cachedValue { return cachedValue }
        guard let activeTask else { return nil }
        guard let result = try? await activeTask.task.value else { return nil }
        cachedValue = result
        return result
    }
}
import CoreFoundation

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

    /// The request path (e.g., "/mcp", "/.well-known/oauth-protected-resource").
    /// Used by validators that need to match on specific paths.
    public let path: String?

    /// An optional stable caller identity supplied by the hosting adapter.
    /// Sessionless transports can use it to scope client messages such as
    /// cancellation when Authorization or Cookie headers are unavailable. An
    /// adapter may opt into `MCP-Client-Identity`, which SDK clients populate
    /// with a random per-transport capability that remains stable across
    /// connections; treat that value as a bearer capability and do not replace
    /// it with an unauthenticated, low-entropy client identifier.
    public let clientIdentity: String?

    public init(
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        path: String? = nil,
        clientIdentity: String? = nil
    ) {
        self.method = method
        self.headers = headers
        self.body = body
        self.path = path
        self.clientIdentity = clientIdentity
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercased }?.value
    }

    package var toolSchemaCacheKey: String {
        if let clientIdentity, !clientIdentity.isEmpty { return "client:\(clientIdentity)" }
        if let explicitIdentity = header(HTTPHeaderName.clientIdentity), !explicitIdentity.isEmpty {
            return "client:\(explicitIdentity)"
        }
        if let authorization = header(HTTPHeaderName.authorization) { return "authorization:\(authorization)" }
        if let cookie = header("Cookie") { return "cookie:\(cookie)" }
        if let sessionID = header(HTTPHeaderName.sessionID) { return "session:\(sessionID)" }
        return "anonymous"
    }

    package var startsToolListAtFirstPage: Bool {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            json["method"] as? String == ListTools.name
        else { return false }
        return (json["params"] as? [String: Any])?["cursor"] == nil
    }

    /// Selects an identity for sessionless request scoping. Explicit MCP client
    /// identities take precedence; authenticated requests without one defer to
    /// their credentials instead of a connection-local fallback.
    package static func stableClientIdentity(
        headers: [String: String],
        connectionIdentity: String
    ) -> String? {
        func value(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        if let identity = value(HTTPHeaderName.clientIdentity), !identity.isEmpty {
            return identity
        }
        if value(HTTPHeaderName.authorization) != nil || value("Cookie") != nil {
            return nil
        }
        return connectionIdentity
    }
}

/// Allows the typed MCP server to provide current tool schemas when an HTTP
/// caller invokes a tool before its first `tools/list` request.
package protocol HTTPToolSchemaProviderInstalling: Sendable {
    func setToolSchemaProvider(
        _ provider: (@Sendable (HTTPRequest) async -> Data?)?
    ) async
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

    /// JSON body with an explicit non-200 status, used for JSON-RPC HTTP errors.
    case httpData(statusCode: Int, Data, headers: [String: String] = [:])

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
        case .httpData(let statusCode, _, _): statusCode
        case .error(let code, _, _, _): code
        }
    }

    public var headers: [String: String] {
        switch self {
        case .accepted(let headers), .ok(let headers), .data(_, let headers), .stream(_, let headers), .httpData(_, _, let headers):
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
        case .data(let data, _), .httpData(_, let data, _):
            return data
        case .error(_, let error, _, _):
            // Encode via MCPError's Codable so `data` (e.g. -32022 requested/supported) is preserved.
            struct Envelope: Encodable {
                let jsonrpc = "2.0"
                let error: MCPError
                let id: Value? = nil

                enum CodingKeys: String, CodingKey { case jsonrpc, error, id }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(jsonrpc, forKey: .jsonrpc)
                    try container.encode(error, forKey: .error)
                    try container.encodeNil(forKey: .id)
                }
            }
            return try? JSONEncoder().encode(Envelope(error: error))
        }
    }
}

// MARK: - HTTP Header Names

/// Standard MCP Streamable HTTP and SDK extension header names.
public enum HTTPHeaderName {
    public static let sessionID = "MCP-Session-Id"
    /// Stable per-transport capability used to associate requests across connections.
    public static let clientIdentity = "MCP-Client-Identity"
    public static let protocolVersion = "MCP-Protocol-Version"
    public static let mcpMethod = "Mcp-Method"
    public static let mcpName = "Mcp-Name"
    public static let lastEventID = "Last-Event-ID"
    public static let accept = "Accept"
    public static let contentType = "Content-Type"
    public static let authorization = "Authorization"
    public static let wwwAuthenticate = "WWW-Authenticate"
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

    /// Closes the per-request SSE (or equivalent) stream for `id` without sending
    /// a JSON-RPC response.
    ///
    /// Used when a modern request is cancelled (`notifications/cancelled` or
    /// `CancellationError`) so the client is not left with an open stream that
    /// still receives fan-out notifications. Idempotent when the stream is
    /// already gone.
    func closeRequestStream(for id: ID) async
}

extension HTTPContextProviding {
    /// Default behavior for context providers without a separately managed
    /// per-request response stream. Stream-capable transports can override it.
    public func closeRequestStream(for id: ID) async {}
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

        let id = Self.extractID(from: json)?.transportKey

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

    package var isDiscoverRequest: Bool {
        if case .request(_, let method) = self {
            return method == "server/discover"
        }
        return false
    }

    package var isSubscriptionsListenRequest: Bool {
        if case .request(_, let method) = self {
            return method == SubscriptionsListen.name
        }
        return false
    }

    /// Shared modern-profile classifier for HTTP transports and Server.
    ///
    /// A message is modern when it is `server/discover` / `subscriptions/listen`,
    /// or when body `_meta` (requests) / header (responses & notifications)
    /// carries a modern protocol version.
    package static func isModernProfile(
        kind: JSONRPCMessageKind,
        body: Data,
        headerProtocolVersion: String?
    ) -> Bool {
        if kind.isDiscoverRequest || kind.isSubscriptionsListenRequest {
            return true
        }
        let bodyVersion = protocolVersion(inBody: body)
        if let bodyVersion, Version.isModern(bodyVersion) {
            return true
        }
        let isRequest: Bool = {
            if case .request = kind { return true }
            return false
        }()
        if !isRequest, let headerProtocolVersion, Version.isModern(headerProtocolVersion) {
            return true
        }
        return false
    }

    /// Method name for request messages; nil otherwise.
    package var methodName: String? {
        switch self {
        case .request(_, let method), .notification(let method):
            return method
        case .response:
            return nil
        }
    }

    private static func extractID(from json: [String: Any]) -> ID? {
        if let stringID = json["id"] as? String {
            return .string(stringID)
        } else if let intID = json["id"] as? Int {
            return .number(intID)
        }
        if let number = json["id"] as? NSNumber {
            // Avoid treating Bool as Int (Bool is an NSNumber subclass).
            let typeID = CFGetTypeID(number as CFTypeRef)
            if typeID != CFBooleanGetTypeID() {
                return .number(number.intValue)
            }
        }
        return nil
    }

    /// Type-preserving JSON-RPC id key from a raw body, if present.
    package static func routingIDKey(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return extractID(from: json)?.transportKey
    }

    /// Protocol version from params._meta, if present in the raw body.
    package static func protocolVersion(inBody data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let params = json["params"] as? [String: Any],
            let meta = params["_meta"] as? [String: Any],
            let version = meta[ProtocolMetaKey.protocolVersion] as? String
        else { return nil }
        return version
    }

    /// Preserves the JSON kind of a progress token while extracting it from a request or notification.
    package static func progressToken(inBody data: Data) -> ProgressToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let params = json["params"] as? [String: Any]
        else { return nil }
        if let token = params["progressToken"], let parsed = progressToken(token) { return parsed }
        guard let meta = params["_meta"] as? [String: Any],
            let token = meta["progressToken"]
        else { return nil }
        return progressToken(token)
    }

    private static func progressToken(_ value: Any) -> ProgressToken? {
        if let string = value as? String { return .string(string) }
        guard let number = value as? NSNumber,
            CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID()
        else { return nil }
        return .integer(number.intValue)
    }

    /// Preserves JSON-RPC id type (string vs number) from a raw request body.
    package static func jsonRPCID(inBody data: Data) -> ID? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return extractID(from: json)
    }

    /// Extracts the subscription correlation id from a notification's params._meta.
    package static func subscriptionID(inBody data: Data) -> ID? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let params = json["params"] as? [String: Any],
            let meta = params["_meta"] as? [String: Any]
        else { return nil }

        if let stringID = meta[ProtocolMetaKey.subscriptionId] as? String {
            return .string(stringID)
        }
        if let intID = meta[ProtocolMetaKey.subscriptionId] as? Int {
            return .number(intID)
        }
        if let number = meta[ProtocolMetaKey.subscriptionId] as? NSNumber {
            let typeID = CFGetTypeID(number as CFTypeRef)
            if typeID != CFBooleanGetTypeID() {
                return .number(number.intValue)
            }
        }
        return nil
    }

    /// Adds the originating listen request id to a notification's params._meta.
    package static func taggingSubscriptionNotification(
        _ data: Data,
        subscriptionID: ID
    ) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        var params = json["params"] as? [String: Any] ?? [:]
        var meta = params["_meta"] as? [String: Any] ?? [:]
        switch subscriptionID {
        case .string(let value): meta[ProtocolMetaKey.subscriptionId] = value
        case .number(let value): meta[ProtocolMetaKey.subscriptionId] = value
        }
        params["_meta"] = meta
        json["params"] = params
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }
}
