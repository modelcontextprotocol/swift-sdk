import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

// Multi round-trip requests (SEP-2322).
//
// At protocol 2026-07-28 a server cannot send requests to the client. When
// `tools/call`, `prompts/get` or `resources/read` needs input, the server
// returns an input-required result that carries `inputRequests`; the client
// fulfills them and sends the request again with `inputResponses` and the
// echoed `requestState`.

/// A request that a server embeds in an input-required result.
///
/// The client fulfills it as it would fulfill the same request sent by the
/// server, and returns the outcome as an ``InputResponse`` under the same key.
public enum InputRequest: Hashable, Sendable {
    /// `elicitation/create`: ask the user for input.
    case elicitation(CreateElicitation.Parameters)
    /// `sampling/createMessage`: ask the client's model for a completion.
    case sampling(CreateSamplingMessage.Parameters)
    /// `roots/list`: ask for the client's roots.
    case listRoots

    /// The method of the request.
    public var method: String {
        switch self {
        case .elicitation: return CreateElicitation.name
        case .sampling: return CreateSamplingMessage.name
        case .listRoots: return ListRoots.name
        }
    }

    /// A form elicitation.
    public static func elicitation(
        message: String, requestedSchema: Elicitation.RequestSchema = .init()
    ) -> InputRequest {
        .elicitation(.form(.init(message: message, requestedSchema: requestedSchema)))
    }

    /// The capability the client must declare to receive this request.
    func isSupported(by capabilities: Client.Capabilities) -> Bool {
        switch self {
        case .elicitation(let params):
            guard let elicitation = capabilities.elicitation else { return false }
            if case .url = params { return elicitation.url != nil }
            return true
        case .sampling: return capabilities.sampling != nil
        case .listRoots: return capabilities.roots != nil
        }
    }

    /// Adds the capability this request needs to `capabilities`.
    func require(in capabilities: inout Client.Capabilities) {
        switch self {
        case .elicitation(let params):
            var elicitation = capabilities.elicitation ?? .init(form: nil)
            if case .url = params {
                elicitation.url = .init()
            } else {
                elicitation.form = .init()
            }
            capabilities.elicitation = elicitation
        case .sampling: capabilities.sampling = capabilities.sampling ?? .init()
        case .listRoots: capabilities.roots = capabilities.roots ?? .init()
        }
    }

    /// The `params` of the request.
    func params() throws -> Value {
        switch self {
        case .elicitation(let params): return try Value(params)
        case .sampling(let params): return try Value(params)
        case .listRoots: return [:]
        }
    }
}

extension InputRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decode(String.self, forKey: .method)
        switch method {
        case CreateElicitation.name:
            self = .elicitation(try container.decode(CreateElicitation.Parameters.self, forKey: .params))
        case CreateSamplingMessage.name:
            self = .sampling(try container.decode(CreateSamplingMessage.Parameters.self, forKey: .params))
        case ListRoots.name:
            self = .listRoots
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .method, in: container, debugDescription: "Unsupported input request method \(method)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        switch self {
        case .elicitation(let params): try container.encode(params, forKey: .params)
        case .sampling(let params): try container.encode(params, forKey: .params)
        case .listRoots: try container.encode(Empty(), forKey: .params)
        }
    }
}

/// The client's outcome for one ``InputRequest``.
///
/// On the wire it is the plain result of the request. Decoding tells the
/// kinds apart by shape: `roots` for roots, `action` for elicitation,
/// otherwise sampling.
public enum InputResponse: Hashable, Sendable {
    case elicitation(CreateElicitation.Result)
    case sampling(CreateSamplingMessage.Result)
    case roots(ListRoots.Result)

    /// The elicitation result, if this is one.
    public var elicitation: CreateElicitation.Result? {
        if case .elicitation(let result) = self { return result }
        return nil
    }

    /// The sampling result, if this is one.
    public var sampling: CreateSamplingMessage.Result? {
        if case .sampling(let result) = self { return result }
        return nil
    }

    /// The roots, if this is a roots result.
    public var roots: [Root]? {
        if case .roots(let result) = self { return result.roots }
        return nil
    }

    /// Decodes the result of a request of `method`.
    init(method: String, result: Value) throws {
        switch method {
        case CreateElicitation.name: self = .elicitation(try CreateElicitation.Result(decoding: result))
        case CreateSamplingMessage.name: self = .sampling(try CreateSamplingMessage.Result(decoding: result))
        case ListRoots.name: self = .roots(try ListRoots.Result(decoding: result))
        default: throw MCPError.invalidParams("Unsupported input request method \(method)")
        }
    }
}

extension InputResponse: Codable {
    public init(from decoder: Decoder) throws {
        let object = try [String: Value](from: decoder)
        if object["roots"] != nil {
            self = .roots(try ListRoots.Result(decoding: Value.object(object)))
        } else if object["action"] != nil {
            self = .elicitation(try CreateElicitation.Result(decoding: Value.object(object)))
        } else {
            self = .sampling(try CreateSamplingMessage.Result(decoding: Value.object(object)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .elicitation(let result): try result.encode(to: encoder)
        case .sampling(let result): try result.encode(to: encoder)
        case .roots(let result): try result.encode(to: encoder)
        }
    }
}

// MARK: - Carriers

/// The result of a request that may ask for input: `tools/call`,
/// `prompts/get` or `resources/read`.
protocol InputRequiringResult: Codable, Sendable {
    var inputRequests: [String: InputRequest]? { get }
    var requestState: String? { get set }
    var resultType: ResultType { get }
    /// Whether the result also carries its normal content.
    var hasContent: Bool { get }
}

extension InputRequiringResult {
    var isInputRequired: Bool { resultType == .inputRequired }
}

/// The parameters of a request that may be retried with input responses.
protocol InputRespondingParameters: Codable, Sendable {
    var inputResponses: [String: InputResponse]? { get }
    var requestState: String? { get }
    /// A copy that carries the responses and state for the next round.
    func retrying(inputResponses: [String: InputResponse]?, requestState: String?) -> Self
    /// What a sealed `requestState` is bound to: the tool or prompt name or
    /// resource URI, and the arguments.
    var stateBinding: (target: String, arguments: Value) { get }
}

enum MRTR {
    /// The methods whose results may ask for input.
    static let carriers: Set<String> = [CallTool.name, GetPrompt.name, ReadResource.name]

    /// The most rounds a request takes before the SDK gives up (client
    /// loop and server bridge alike).
    static let maxRounds = 10

    /// The client's first wait before retrying a result without input requests.
    static let stateOnlyInitialDelay: Duration = .milliseconds(50)
    static let stateOnlyMaximumDelay: Duration = .milliseconds(250)

    /// Decodes `inputResponses`, rejecting an explicit `null`.
    static func decodeInputResponses<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) throws -> [String: InputResponse]? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "inputResponses must be an object")
        }
        return try container.decode([String: InputResponse].self, forKey: key)
    }

    /// The resultType a decoded result declares, or the one its fields imply.
    static func resultType(declared: ResultType?, inputRequests: [String: InputRequest]?, requestState: String?)
        -> ResultType
    {
        if let declared { return declared }
        return inputRequests != nil || requestState != nil ? .inputRequired : .complete
    }

    /// The resultType to store for a decoded result: `nil` for `complete`, so
    /// that decoded and constructed complete results compare equal.
    static func declared(_ decoded: ResultType?) -> ResultType? {
        decoded == .complete ? nil : decoded
    }
}

extension Decodable {
    /// Decodes a value from its JSON `Value`.
    init(decoding value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}
