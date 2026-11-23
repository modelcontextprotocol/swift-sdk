/// `server/discover` — modern protocol advertisement (MCP 2026-07-28).
///
/// Clients MAY call this to learn supported versions and capabilities. Version
/// negotiation can also happen inline via per-request `_meta`.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
public enum Discover: Method {
    public static let name = "server/discover"

    /// Cache scope for discover responses.
    public enum CacheScope: String, Hashable, Codable, Sendable {
        case `public`
        case `private`
    }

    public struct Parameters: Hashable, Codable, Sendable, NotRequired {
        public var _meta: Metadata

        /// Default `_meta` carries the modern protocol version.
        /// Client capabilities are filled by ``Client`` per-request injection when omitted.
        public static var defaultMeta: Metadata {
            Metadata(
                additionalFields: [
                    ProtocolMetaKey.protocolVersion: .string(Version.latest),
                ]
            )
        }

        public init(_meta: Metadata = Self.defaultMeta) {
            self._meta = _meta
        }

        public init() {
            self._meta = Self.defaultMeta
        }

        private enum CodingKeys: String, CodingKey {
            case _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta) ?? Self.defaultMeta
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public var resultType: ResultType
        public var supportedVersions: [String]
        public var capabilities: Server.Capabilities
        public var cacheScope: CacheScope
        public var ttlMs: Int
        public var instructions: String?
        public var _meta: Metadata?

        public init(
            supportedVersions: [String],
            capabilities: Server.Capabilities,
            cacheScope: CacheScope = .private,
            ttlMs: Int = 0,
            instructions: String? = nil,
            _meta: Metadata? = nil
        ) {
            self.resultType = .complete
            self.supportedVersions = supportedVersions
            self.capabilities = capabilities
            self.cacheScope = cacheScope
            self.ttlMs = ttlMs
            self.instructions = instructions
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey {
            case resultType, supportedVersions, capabilities, cacheScope, ttlMs, instructions, _meta
        }
    }
}
