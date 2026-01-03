/// The initialization phase MUST be the first interaction between client and server.
/// During this phase, the client and server:
/// - Establish protocol version compatibility
/// - Exchange and negotiate capabilities
/// - Share implementation details
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/lifecycle/#initialization
public enum Initialize: Method {
    public static let name: String = "initialize"

    public struct Parameters: Hashable, Codable, Sendable {
        public let protocolVersion: String
        public let capabilities: Client.Capabilities
        public let clientInfo: Client.Info
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(
            protocolVersion: String = Version.latest,
            capabilities: Client.Capabilities,
            clientInfo: Client.Info,
            _meta: RequestMeta? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.clientInfo = clientInfo
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey {
            case protocolVersion, capabilities, clientInfo, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion =
                try container.decodeIfPresent(String.self, forKey: .protocolVersion)
                ?? Version.latest
            capabilities =
                try container.decodeIfPresent(Client.Capabilities.self, forKey: .capabilities)
                ?? .init()
            clientInfo =
                try container.decodeIfPresent(Client.Info.self, forKey: .clientInfo)
                ?? .init(name: "unknown", version: "0.0.0")
            _meta = try container.decodeIfPresent(RequestMeta.self, forKey: ._meta)
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let protocolVersion: String
        public let capabilities: Server.Capabilities
        public let serverInfo: Server.Info
        public let instructions: String?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            protocolVersion: String,
            capabilities: Server.Capabilities,
            serverInfo: Server.Info,
            instructions: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.serverInfo = serverInfo
            self.instructions = instructions
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case protocolVersion, capabilities, serverInfo, instructions, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
            capabilities = try container.decode(Server.Capabilities.self, forKey: .capabilities)
            serverInfo = try container.decode(Server.Info.self, forKey: .serverInfo)
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(capabilities, forKey: .capabilities)
            try container.encode(serverInfo, forKey: .serverInfo)
            try container.encodeIfPresent(instructions, forKey: .instructions)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// After successful initialization, the client MUST send an initialized notification to indicate it is ready to begin normal operations.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/lifecycle/#initialization
public struct InitializedNotification: Notification {
    public static let name: String = "notifications/initialized"

    public typealias Parameters = NotificationParams
}

/// Notification sent when an operation is cancelled.
///
/// This can be used by either client or server to indicate that an
/// ongoing operation should be terminated.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/
public struct CancelledNotification: Notification {
    public static let name: String = "notifications/cancelled"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The ID of the request to cancel.
        /// Optional in protocol version 2025-11-25 and later.
        public var requestId: RequestId?
        /// The reason for cancellation.
        public var reason: String?
        /// Reserved for additional metadata.
        public var _meta: [String: Value]?

        public init(requestId: RequestId? = nil, reason: String? = nil, _meta: [String: Value]? = nil) {
            self.requestId = requestId
            self.reason = reason
            self._meta = _meta
        }
    }
}
