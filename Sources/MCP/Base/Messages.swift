import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let jsonrpc = "2.0"

/// A parameters type whose `params` member may be absent on the wire.
///
/// A message that omits `params` decodes with the value of ``init()``.
public protocol NotRequired {
    init()
}

/// Parameters or a result with no members.
public struct Empty: NotRequired, Hashable, Codable, Sendable {
    /// Creates an empty value.
    public init() {}
}

extension Value: NotRequired {
    /// Creates ``Value/null``.
    public init() {
        self = .null
    }
}

// MARK: -

/// A method that can be used to send requests and receive responses.
///
/// `Parameters` must encode as a JSON object. When the request carries
/// `_meta`, the parameters are re-encoded through ``Value`` to merge it, so
/// their numbers must fit `Int` or `Double`.
public protocol Method: Sendable {
    /// The parameters of the method.
    associatedtype Parameters: Codable, Hashable, Sendable = Empty
    /// The result of the method.
    associatedtype Result: Codable, Hashable, Sendable = Empty
    /// The name of the method.
    static var name: String { get }
}

/// Type-erased method for request/response handling
struct AnyMethod: Method, Sendable {
    static var name: String { "" }
    typealias Parameters = Value
    typealias Result = Value
}

extension Method where Parameters == Empty {
    /// Create a request for a method that takes no parameters.
    public static func request(
        id: ID = .random,
        _meta: Metadata? = nil
    ) -> Request<Self> {
        Request(id: id, method: name, params: Empty(), _meta: _meta)
    }
}

extension Method where Result == Empty {
    /// Create an empty success response for a method that returns no result.
    public static func response(id: ID) -> Response<Self> {
        Response(id: id, result: Empty())
    }
}

extension Method {
    /// Create a request with the given parameters.
    public static func request(
        id: ID = .random,
        _ parameters: Self.Parameters,
        _meta: Metadata? = nil
    ) -> Request<Self> {
        Request(id: id, method: name, params: parameters, _meta: _meta)
    }

    /// Create a response with the given result.
    public static func response(
        id: ID,
        result: Self.Result
    ) -> Response<Self> {
        Response(id: id, result: result)
    }

    /// Create a response with the given error.
    public static func response(
        id: ID,
        error: MCPError
    ) -> Response<Self> {
        Response(id: id, error: error)
    }
}

// MARK: -

/// A request message.
public struct Request<M: Method>: Hashable, Identifiable, Codable, Sendable {
    /// The request ID.
    public let id: ID
    /// The method name.
    public let method: String
    /// The request parameters.
    public let params: M.Parameters
    /// Request-level metadata, sent as `params._meta`.
    ///
    /// Merged with any `_meta` the parameters encode themselves; on a key
    /// conflict the parameters win. Decoding fills it from `params._meta`,
    /// so a decoded request whose parameters model `_meta` holds the same
    /// keys twice: equality with a request built without `_meta` fails, and
    /// a key is removed from the wire only by clearing it in both.
    ///
    /// When it is set, the parameters are re-encoded through ``Value``, so
    /// an integer beyond `Int` or a decimal beyond `Double` loses precision.
    public var _meta: Metadata?

    init(
        id: ID = .random,
        method: String,
        params: M.Parameters,
        _meta: Metadata? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self._meta = _meta
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case jsonrpc, id, method, params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        if let meta = _meta, !meta.fields.isEmpty {
            try container.encode(try mergingMeta(meta, into: params), forKey: .params)
        } else {
            try container.encode(params, forKey: .params)
        }
    }
}

/// Decodes only `_meta` from a parameters object.
private struct MetaProbe: Decodable {
    let _meta: Metadata?
}

/// Encodes `params` as a JSON object with `meta` merged into its `_meta`;
/// keys already present in the encoded `_meta` win.
private func mergingMeta<P: Codable>(_ meta: Metadata, into params: P) throws -> Value {
    var object: [String: Value]
    // Through `Value`, but strings stay strings: a `data:` URL argument is
    // sent as given.
    switch try Value.preservingStrings(params) {
    case .object(let fields): object = fields
    case .null: object = [:]
    default:
        throw EncodingError.invalidValue(
            params,
            EncodingError.Context(
                codingPath: [], debugDescription: "Parameters with _meta must encode as an object"))
    }
    var merged = meta.fields
    if case .object(let own) = object["_meta"] {
        merged.merge(own) { _, own in own }
    }
    object["_meta"] = .object(merged)
    return .object(object)
}

extension Request {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        guard version == jsonrpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version")
        }
        id = try container.decode(ID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        _meta = (try? container.decodeIfPresent(MetaProbe.self, forKey: .params))??._meta

        if M.Parameters.self is NotRequired.Type {
            // For NotRequired parameters, use decodeIfPresent or init()
            params =
                (try container.decodeIfPresent(M.Parameters.self, forKey: .params)
                    ?? (M.Parameters.self as! NotRequired.Type).init() as! M.Parameters)
        } else if let value = try? container.decode(M.Parameters.self, forKey: .params) {
            // If params exists and can be decoded, use it
            params = value
        } else if !container.contains(.params)
            || (try? container.decodeNil(forKey: .params)) == true
        {
            // If params is missing or explicitly null, use Empty for Empty parameters
            // or throw for non-Empty parameters
            if M.Parameters.self == Empty.self {
                params = Empty() as! M.Parameters
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Missing required params field"))
            }
        } else {
            // Decode again to report where the parameters are wrong.
            _ = try container.decode(M.Parameters.self, forKey: .params)
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid params field"))
        }
    }
}

/// A type-erased request for request/response handling
typealias AnyRequest = Request<AnyMethod>

extension AnyRequest {
    init<T: Method>(_ request: Request<T>) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        decoder.userInfo[.valuePreservesStrings] = true

        let data = try encoder.encode(request)
        self = try decoder.decode(AnyRequest.self, from: data)
    }
}

/// A box for request handlers that can be type-erased
class RequestHandlerBox: @unchecked Sendable {
    func callAsFunction(_ request: AnyRequest) async throws -> AnyResponse {
        fatalError("Must override")
    }
}

/// A typed request handler that can be used to handle requests of a specific type
final class TypedRequestHandler<M: Method>: RequestHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (Request<M>) async throws -> Response<M>

    /// Where decoding failed, without Swift type names or debug text: the
    /// peer sees the path of the member and the kind of problem only.
    static func problem(in error: any Error) -> String {
        guard let error = error as? DecodingError else { return "" }
        func path(_ codingPath: [any CodingKey], _ last: (any CodingKey)? = nil) -> String {
            let keys = (codingPath + (last.map { [$0] } ?? []))
                .map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "params" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return ": missing \(path(context.codingPath, key))"
        case .valueNotFound(_, let context):
            return ": missing value at \(path(context.codingPath))"
        case .typeMismatch(_, let context):
            return ": wrong type at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            return ": invalid value at \(path(context.codingPath))"
        @unknown default:
            return ""
        }
    }

    init(_ handler: @escaping @Sendable (Request<M>) async throws -> Response<M>) {
        self._handle = handler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest) async throws -> AnyResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Create a concrete request from the type-erased one; here `data:`
        // URL strings in `Value` fields become `.data`.
        let data = try encoder.encode(request)
        let request: Request<M>
        do {
            request = try decoder.decode(Request<M>.self, from: data)
        } catch {
            throw MCPError.invalidParams("Invalid params for \(M.name)\(Self.problem(in: error))")
        }

        // Handle with concrete type
        let response = try await _handle(request)

        // Convert result to AnyMethod response
        switch response.result {
        case .success(let result):
            // Strings as written: the result is sent as the handler made it.
            return Response(id: response.id, result: try Value.preservingStrings(result))
        case .failure(let error):
            return Response(id: response.id, error: error)
        }
    }
}

// MARK: -

/// A response message.
public struct Response<M: Method>: Hashable, Identifiable, Codable, Sendable {
    /// The response ID.
    public let id: ID
    /// The response result.
    public let result: Swift.Result<M.Result, MCPError>

    /// Creates a response with a result or an error.
    public init(
        id: ID,
        result: Swift.Result<M.Result, MCPError>
    ) {
        self.id = id
        self.result = result
    }

    /// Creates a success response.
    public init(
        id: ID,
        result: M.Result
    ) {
        self.init(id: id, result: .success(result))
    }

    /// Creates an error response.
    public init(
        id: ID,
        error: MCPError
    ) {
        self.init(id: id, result: .failure(error))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case jsonrpc, id, result, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)

        switch result {
        case .success(let result):
            try container.encode(result, forKey: .result)
        case .failure(let error):
            try container.encode(error, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        guard version == jsonrpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version")
        }
        id = try container.decode(ID.self, forKey: .id)
        if let result = try? container.decode(M.Result.self, forKey: .result) {
            self.result = .success(result)
        } else if let error = try? container.decode(MCPError.self, forKey: .error) {
            self.result = .failure(error)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid response"))
        }
    }
}

/// A type-erased response for request/response handling
typealias AnyResponse = Response<AnyMethod>

extension AnyResponse {
    init<T: Method>(_ response: Response<T>) throws {
        switch response.result {
        case .success(let result):
            self = Response<AnyMethod>(
                id: response.id,
                result: .success(try Value.preservingStrings(result))
            )
        case .failure(let error):
            self = Response<AnyMethod>(
                id: response.id,
                result: .failure(error)
            )
        }
    }
}

// MARK: -

/// A notification message.
public protocol Notification: Hashable, Codable, Sendable {
    /// The parameters of the notification.
    associatedtype Parameters: Hashable, Codable, Sendable = Empty
    /// The name of the notification.
    static var name: String { get }
}

/// A type-erased notification for message handling
struct AnyNotification: Notification, Sendable {
    static var name: String { "" }
    typealias Parameters = Value
}

extension AnyNotification {
    init(_ notification: some Notification) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)
        self = try decoder.decode(AnyNotification.self, from: data)
    }
}

/// A message that can be used to send notifications.
public struct Message<N: Notification>: Hashable, Codable, Sendable {
    /// The method name.
    public let method: String
    /// The notification parameters.
    public let params: N.Parameters
    /// Notification-level metadata, sent as `params._meta`.
    ///
    /// Merged with any `_meta` the parameters encode themselves; on a key
    /// conflict the parameters win. Decoding fills it from `params._meta`,
    /// so a decoded notification whose parameters model `_meta` holds the
    /// same keys twice: equality with a message built without `_meta` fails,
    /// and a key is removed from the wire only by clearing it in both.
    ///
    /// When it is set, the parameters are re-encoded through ``Value``, so
    /// an integer beyond `Int` or a decimal beyond `Double` loses precision.
    public var _meta: Metadata?

    /// Creates a notification message.
    public init(method: String, params: N.Parameters, _meta: Metadata? = nil) {
        self.method = method
        self.params = params
        self._meta = _meta
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        if let meta = _meta, !meta.fields.isEmpty {
            try container.encode(try mergingMeta(meta, into: params), forKey: .params)
        } else if N.Parameters.self != Empty.self {
            try container.encode(params, forKey: .params)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        guard version == jsonrpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version")
        }
        method = try container.decode(String.self, forKey: .method)
        _meta = (try? container.decodeIfPresent(MetaProbe.self, forKey: .params))??._meta

        if N.Parameters.self is NotRequired.Type {
            // For NotRequired parameters, use decodeIfPresent or init()
            params =
                (try container.decodeIfPresent(N.Parameters.self, forKey: .params)
                    ?? (N.Parameters.self as! NotRequired.Type).init() as! N.Parameters)
        } else if let value = try? container.decode(N.Parameters.self, forKey: .params) {
            // If params exists and can be decoded, use it
            params = value
        } else if !container.contains(.params)
            || (try? container.decodeNil(forKey: .params)) == true
        {
            // If params is missing or explicitly null, use Empty for Empty parameters
            // or throw for non-Empty parameters
            if N.Parameters.self == Empty.self {
                params = Empty() as! N.Parameters
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Missing required params field"))
            }
        } else {
            // Decode again to report where the parameters are wrong.
            _ = try container.decode(N.Parameters.self, forKey: .params)
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid params field"))
        }
    }
}

/// A type-erased message for message handling
typealias AnyMessage = Message<AnyNotification>

extension Notification where Parameters == Empty {
    /// Create a message with empty parameters.
    public static func message() -> Message<Self> {
        Message(method: name, params: Empty())
    }
}

extension Notification {
    /// Create a message with the given parameters.
    public static func message(_ parameters: Parameters) -> Message<Self> {
        Message(method: name, params: parameters)
    }
}

/// A box for notification handlers that can be type-erased
class NotificationHandlerBox: @unchecked Sendable {
    func callAsFunction(_ notification: Message<AnyNotification>) async throws {}
}

/// A typed notification handler that can be used to handle notifications of a specific type
final class TypedNotificationHandler<N: Notification>: NotificationHandlerBox,
    @unchecked Sendable
{
    private let _handle: @Sendable (Message<N>) async throws -> Void

    init(_ handler: @escaping @Sendable (Message<N>) async throws -> Void) {
        self._handle = handler
        super.init()
    }

    override func callAsFunction(_ notification: Message<AnyNotification>) async throws {
        // Create a concrete notification from the type-erased one
        let data = try JSONEncoder().encode(notification)
        let typedNotification = try JSONDecoder().decode(Message<N>.self, from: data)

        try await _handle(typedNotification)
    }
}
