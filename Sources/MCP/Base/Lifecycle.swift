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

        public init(
            protocolVersion: String = Version.latest,
            capabilities: Client.Capabilities,
            clientInfo: Client.Info
        ) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.clientInfo = clientInfo
        }

        private enum CodingKeys: String, CodingKey {
            case protocolVersion, capabilities, clientInfo
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
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        let protocolVersion: String
        let capabilities: Server.Capabilities
        let serverInfo: Server.Info
        let instructions: String?
        var _meta: [String: Value]?
        var extraFields: [String: Value]?

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

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case protocolVersion, capabilities, serverInfo, instructions
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(capabilities, forKey: .capabilities)
            try container.encode(serverInfo, forKey: .serverInfo)
            try container.encodeIfPresent(instructions, forKey: .instructions)

            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            try encodeMeta(_meta, to: &dynamicContainer)
            try encodeExtraFields(extraFields, to: &dynamicContainer, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
            capabilities = try container.decode(Server.Capabilities.self, forKey: .capabilities)
            serverInfo = try container.decode(Server.Info.self, forKey: .serverInfo)
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)

            let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
            _meta = try decodeMeta(from: dynamicContainer)
            extraFields = try decodeExtraFields(from: dynamicContainer, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }
    }
}

/// After successful initialization, the client MUST send an initialized notification to indicate it is ready to begin normal operations.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/lifecycle/#initialization
public struct InitializedNotification: Notification {
    public static let name: String = "notifications/initialized"
}
