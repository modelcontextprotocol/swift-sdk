/// Clients at protocol 2026-07-28 and later send `server/discover` to learn the
/// protocol versions, capabilities and instructions of a server. It replaces
/// the `initialize` handshake and creates no session.
public enum ServerDiscover: Method {
    public static let name = "server/discover"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public init() {}
    }

    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        /// The protocol versions the server serves, newest first.
        public let supportedVersions: [String]
        /// The capabilities the server honors.
        public let capabilities: Server.Capabilities
        /// How to use the server, for inclusion in a model prompt.
        public let instructions: String?
        /// Result metadata; carries `io.modelcontextprotocol/serverInfo`.
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        public init(
            supportedVersions: [String],
            capabilities: Server.Capabilities,
            instructions: String? = nil,
            _meta: Metadata? = nil,
            ttlMs: Int? = nil,
            cacheScope: CacheScope? = nil
        ) {
            self.supportedVersions = supportedVersions
            self.capabilities = capabilities
            self.instructions = instructions
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        private enum CodingKeys: String, CodingKey {
            case supportedVersions, capabilities, instructions, _meta, ttlMs, cacheScope
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            supportedVersions = try container.decode([String].self, forKey: .supportedVersions)
            capabilities = try container.decode(Server.Capabilities.self, forKey: .capabilities)
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
        }

        /// The server that produced the result, from `_meta`.
        public var serverInfo: Server.Info? { _meta?.serverInfo }
    }
}
