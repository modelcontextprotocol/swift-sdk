import Foundation

/// Reserved `_meta` keys for MCP 2026-07-28 per-request protocol fields.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/index#meta
public enum ProtocolMetaKey {
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    public static let subscriptionId = "io.modelcontextprotocol/subscriptionId"
    public static let logLevel = "io.modelcontextprotocol/logLevel"
}

/// Result discriminant for modern protocol responses.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/index#result-responses
public enum ResultType: String, Hashable, Codable, Sendable {
    case complete
    case inputRequired = "input_required"
}

/// Helpers for reading modern request `_meta` from type-erased JSON-RPC params.
public enum ModernRequestMeta {
    /// Extracts the protocol version from `params._meta`, if present.
    public static func protocolVersion(from params: Value) -> String? {
        metaObject(from: params)?[ProtocolMetaKey.protocolVersion]?.stringValue
    }

    /// Extracts the nested `_meta` object from request params.
    public static func metaObject(from params: Value) -> [String: Value]? {
        guard case .object(let root) = params,
            case .object(let meta) = root["_meta"]
        else { return nil }
        return meta
    }

    /// Whether the request params declare a modern protocol version.
    public static func isModernRequest(params: Value) -> Bool {
        guard let version = protocolVersion(from: params) else { return false }
        return Version.isModern(version)
    }

    /// Per-request client capabilities from `_meta` (empty object allowed).
    public static func clientCapabilities(from params: Value) -> Value? {
        metaObject(from: params)?[ProtocolMetaKey.clientCapabilities]
    }

    /// Modern requests MUST carry `io.modelcontextprotocol/clientCapabilities` as an object.
    public static func hasRequiredClientCapabilities(params: Value) -> Bool {
        guard let caps = clientCapabilities(from: params),
            case .object = caps
        else { return false }
        return true
    }
}

/// A modern `input_required` result (MRTR).
///
/// At least one of `inputRequests` or `requestState` must be present.
///
/// - Important: This type models the wire schema for MRTR. End-to-end emission
///   from typed `withMethodHandler` results and client-side recovery before
///   typed decode are not wired yet; do not build application flows on it until
///   that path lands.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr
public struct InputRequiredResult: Hashable, Codable, Sendable {
    public let resultType: ResultType
    public var inputRequests: [String: Value]?
    public var requestState: String?
    public var _meta: Metadata?

    /// Creates an `input_required` result with input requests (and optional state).
    public init(
        inputRequests: [String: Value],
        requestState: String? = nil,
        _meta: Metadata? = nil
    ) {
        self.resultType = .inputRequired
        self.inputRequests = inputRequests
        self.requestState = requestState
        self._meta = _meta
    }

    /// Creates an `input_required` result from opaque request state only.
    public init(requestState: String, _meta: Metadata? = nil) {
        self.resultType = .inputRequired
        self.inputRequests = nil
        self.requestState = requestState
        self._meta = _meta
    }

    private enum CodingKeys: String, CodingKey {
        case resultType, inputRequests, requestState, _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultType = try container.decode(ResultType.self, forKey: .resultType)
        inputRequests = try container.decodeIfPresent([String: Value].self, forKey: .inputRequests)
        requestState = try container.decodeIfPresent(String.self, forKey: .requestState)
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        guard inputRequests != nil || requestState != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .inputRequests,
                in: container,
                debugDescription:
                    "input_required results require inputRequests and/or requestState"
            )
        }
        guard resultType == .inputRequired else {
            throw DecodingError.dataCorruptedError(
                forKey: .resultType,
                in: container,
                debugDescription: "InputRequiredResult requires resultType input_required"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard inputRequests != nil || requestState != nil else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription:
                        "input_required results require inputRequests and/or requestState"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resultType, forKey: .resultType)
        try container.encodeIfPresent(inputRequests, forKey: .inputRequests)
        try container.encodeIfPresent(requestState, forKey: .requestState)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

extension Value {
    /// Ensures a modern success result object carries `resultType: "complete"`
    /// and optional server identity metadata.
    public func ensuringModernCompleteResult(
        serverInfo: [String: Value]? = nil
    ) -> Value {
        guard case .object(var object) = self else {
            // Non-object success payloads cannot carry `resultType` without inventing
            // a non-schema wrapper key. Leave them unchanged; modern Method.Result
            // values are expected to be objects.
            return self
        }

        if object["resultType"] == nil {
            object["resultType"] = .string(ResultType.complete.rawValue)
        }

        if let serverInfo {
            var meta: [String: Value] = [:]
            if case .object(let existing) = object["_meta"] {
                meta = existing
            }
            if meta[ProtocolMetaKey.serverInfo] == nil {
                meta[ProtocolMetaKey.serverInfo] = .object(serverInfo)
            }
            object["_meta"] = .object(meta)
        }

        return .object(object)
    }
}
