import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let jsonrpc = "2.0"

public protocol NotRequired {
    init()
}

public struct Empty: NotRequired, Hashable, Codable, Sendable {
    public init() {}
}

/// Base notification parameters with optional metadata.
///
/// Used by notifications that have no additional parameters beyond `_meta`.
public struct NotificationParams: NotRequired, Hashable, Codable, Sendable {
    /// Reserved for additional metadata.
    public var _meta: [String: Value]?

    public init() {
        self._meta = nil
    }

    public init(_meta: [String: Value]?) {
        self._meta = _meta
    }
}

extension Value: NotRequired {
    public init() {
        self = .null
    }
}

// MARK: -

/// A method that can be used to send requests and receive responses.
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
    public static func request(id: RequestId = .random) -> Request<Self> {
        Request(id: id, method: name, params: Empty())
    }
}

extension Method where Parameters: NotRequired {
    /// Create a request with default parameters.
    public static func request(id: RequestId = .random) -> Request<Self> {
        Request(id: id, method: name, params: Parameters())
    }
}

extension Method where Result == Empty {
    public static func response(id: RequestId) -> Response<Self> {
        Response(id: id, result: Empty())
    }
}

extension Method {
    /// Create a request with the given parameters.
    public static func request(id: RequestId = .random, _ parameters: Self.Parameters) -> Request<Self> {
        Request(id: id, method: name, params: parameters)
    }

    /// Create a response with the given result.
    public static func response(id: RequestId, result: Self.Result) -> Response<Self> {
        Response(id: id, result: result)
    }

    /// Create a response with the given error.
    public static func response(id: RequestId, error: MCPError) -> Response<Self> {
        Response(id: id, error: error)
    }
}

// MARK: -

/// A request message.
public struct Request<M: Method>: Hashable, Identifiable, Codable, Sendable {
    /// The request ID.
    public let id: RequestId
    /// The method name.
    public let method: String
    /// The request parameters.
    public let params: M.Parameters

    init(id: RequestId = .random, method: String, params: M.Parameters) {
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }
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

        let data = try encoder.encode(request)
        self = try decoder.decode(AnyRequest.self, from: data)
    }
}

/// A box for request handlers that can be type-erased
class RequestHandlerBox: @unchecked Sendable {
    func callAsFunction(_ request: AnyRequest, context: Server.RequestHandlerContext) async throws -> AnyResponse {
        fatalError("Must override")
    }
}

/// A typed request handler that can be used to handle requests of a specific type
final class TypedRequestHandler<M: Method>: RequestHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (Request<M>, Server.RequestHandlerContext) async throws -> Response<M>

    init(_ handler: @escaping @Sendable (Request<M>, Server.RequestHandlerContext) async throws -> Response<M>) {
        self._handle = handler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest, context: Server.RequestHandlerContext) async throws -> AnyResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Create a concrete request from the type-erased one
        let data = try encoder.encode(request)
        let request = try decoder.decode(Request<M>.self, from: data)

        // Handle with concrete type
        let response = try await _handle(request, context)

        // Convert result to AnyMethod response
        switch response.result {
        case .success(let result):
            let resultData = try encoder.encode(result)
            let resultValue = try decoder.decode(Value.self, from: resultData)
            return Response(id: response.id, result: resultValue)
        case .failure(let error):
            return Response(id: response.id, error: error)
        }
    }
}

// MARK: -

/// A response message.
public struct Response<M: Method>: Hashable, Identifiable, Codable, Sendable {
    /// The response ID.
    public let id: RequestId
    /// The response result.
    public let result: Swift.Result<M.Result, MCPError>

    public init(id: RequestId, result: M.Result) {
        self.id = id
        self.result = .success(result)
    }

    public init(id: RequestId, error: MCPError) {
        self.id = id
        self.result = .failure(error)
    }

    private enum CodingKeys: String, CodingKey {
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
        // Instead of re-encoding/decoding which might double-wrap the error,
        // directly transfer the properties
        self.id = response.id
        switch response.result {
        case .success(let result):
            // For success, we still need to convert the result to a Value
            let data = try JSONEncoder().encode(result)
            let resultValue = try JSONDecoder().decode(Value.self, from: data)
            self.result = .success(resultValue)
        case .failure(let error):
            // Keep the original error without re-encoding/decoding
            self.result = .failure(error)
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

/// Protocol for type-erased notification messages.
///
/// This protocol allows sending notification messages with parameters through
/// a type-erased interface. `Message<N>` conforms to this protocol.
public protocol NotificationMessageProtocol: Sendable, Encodable {
    /// The notification method name.
    var method: String { get }
}

/// A message that can be used to send notifications.
public struct Message<N: Notification>: NotificationMessageProtocol, Hashable, Codable, Sendable {
    /// The method name.
    public let method: String
    /// The notification parameters.
    public let params: N.Parameters

    public init(method: String, params: N.Parameters) {
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        if N.Parameters.self != Empty.self {
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

extension Notification where Parameters == NotificationParams {
    /// Create a message with default parameters (no metadata).
    public static func message() -> Message<Self> {
        Message(method: name, params: NotificationParams())
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

// MARK: - Client Request Handlers

/// A box for client request handlers that can be type-erased
class ClientRequestHandlerBox: @unchecked Sendable {
    func callAsFunction(_ request: AnyRequest, context: Client.RequestHandlerContext) async throws -> AnyResponse {
        fatalError("Must override")
    }
}

/// A typed client request handler that can be used to handle requests of a specific type
final class TypedClientRequestHandler<M: Method>: ClientRequestHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (M.Parameters, Client.RequestHandlerContext) async throws -> M.Result

    init(_ handler: @escaping @Sendable (M.Parameters, Client.RequestHandlerContext) async throws -> M.Result) {
        self._handle = handler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest, context: Client.RequestHandlerContext) async throws -> AnyResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Create a concrete request from the type-erased one
        let data = try encoder.encode(request)
        let typedRequest = try decoder.decode(Request<M>.self, from: data)

        // Handle with concrete type
        do {
            let result = try await _handle(typedRequest.params, context)

            // Convert result to AnyMethod response
            let resultData = try encoder.encode(result)
            let resultValue = try decoder.decode(Value.self, from: resultData)
            return Response(id: typedRequest.id, result: resultValue)
        } catch let error as MCPError {
            return Response(id: typedRequest.id, error: error)
        } catch {
            return Response(id: typedRequest.id, error: MCPError.internalError(error.localizedDescription))
        }
    }
}
