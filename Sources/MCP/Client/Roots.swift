import Foundation

/// The Model Context Protocol (MCP) provides a mechanism for clients to expose
/// filesystem boundaries to servers through roots. Roots allow servers to understand
/// the scope of filesystem access they can request, enabling safe and controlled
/// file operations.
///
/// Unlike Resources/Tools/Prompts, Roots use bidirectional communication:
/// - Servers send `roots/list` requests TO clients
/// - Clients respond with available roots
/// - Clients send `notifications/roots/list_changed` when roots change
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
public struct Root: Hashable, Codable, Sendable {
    /// The root URI (must use file:// scheme)
    public let uri: String
    /// Optional human-readable name for the root
    public let name: String?
    /// Optional metadata
    public var _meta: Metadata?

    public init(
        uri: String,
        name: String? = nil,
        _meta: Metadata? = nil
    ) {
        self.uri = uri
        self.name = name
        self._meta = _meta
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case name
        case _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

// MARK: -

/// To discover available roots, servers send a `roots/list` request to the client.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
public enum ListRoots: Method {
    public static let name: String = "roots/list"

    public typealias Parameters = Empty

    public struct Result: Hashable, Codable, Sendable {
        public let roots: [Root]
        /// Optional metadata about this result
        public var _meta: Metadata?

        public init(
            roots: [Root],
            _meta: Metadata? = nil
        ) {
            self.roots = roots
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case roots, _meta
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(roots, forKey: .roots)
            try container.encodeIfPresent(_meta, forKey: ._meta)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            roots = try container.decode([Root].self, forKey: .roots)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }
    }
}

/// When the list of roots changes, clients that declared the `roots` capability
/// SHOULD send this notification to inform servers.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
public struct RootsListChangedNotification: Notification {
    public static let name: String = "notifications/roots/list_changed"

    public typealias Parameters = Empty
}
