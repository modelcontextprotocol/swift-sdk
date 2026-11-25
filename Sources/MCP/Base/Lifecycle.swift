/// The initialization phase MUST be the first interaction between client and server.
/// During this phase, the client and server:
/// - Establish protocol version compatibility
/// - Exchange and negotiate capabilities
/// - Share implementation details
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/lifecycle/#initialization
public enum Initialize: Method {
    public static let name: String = "initialize"

    /// The parameters of `initialize`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The protocol revision the client requests.
        public let protocolVersion: String
        /// The capabilities the client supports.
        public let capabilities: Client.Capabilities
        /// The name and version of the client implementation.
        public let clientInfo: Client.Info

        /// Creates `initialize` parameters.
        ///
        /// `protocolVersion` defaults to ``Version/latestHandshake``.
        public init(
            protocolVersion: String = Version.latestHandshake,
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
                ?? Version.latestHandshake
            capabilities =
                try container.decodeIfPresent(Client.Capabilities.self, forKey: .capabilities)
                ?? .init()
            clientInfo =
                try container.decodeIfPresent(Client.Info.self, forKey: .clientInfo)
                ?? .init(name: "unknown", version: "0.0.0")
        }
    }

    /// The result of `initialize`.
    public struct Result: Hashable, Codable, Sendable {
        /// The protocol revision the server chose for the session.
        public let protocolVersion: String
        /// The capabilities the server supports.
        public let capabilities: Server.Capabilities
        /// The name and version of the server implementation.
        public let serverInfo: Server.Info
        /// How to use the server, for inclusion in a model prompt.
        public let instructions: String?
        /// Result metadata.
        public var _meta: Metadata?

        /// Creates an `initialize` result.
        public init(
            protocolVersion: String,
            capabilities: Server.Capabilities,
            serverInfo: Server.Info,
            instructions: String? = nil,
            _meta: Metadata? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.serverInfo = serverInfo
            self.instructions = instructions
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case protocolVersion, capabilities, serverInfo, instructions, _meta
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(capabilities, forKey: .capabilities)
            try container.encode(serverInfo, forKey: .serverInfo)
            try container.encodeIfPresent(instructions, forKey: .instructions)
            try container.encodeIfPresent(_meta, forKey: ._meta)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
            capabilities = try container.decode(Server.Capabilities.self, forKey: .capabilities)
            serverInfo = try container.decode(Server.Info.self, forKey: .serverInfo)
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }
    }
}

/// After successful initialization, the client MUST send an initialized notification to indicate it is ready to begin normal operations.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/lifecycle/#initialization
public struct InitializedNotification: Notification {
    public static let name: String = "notifications/initialized"
}
