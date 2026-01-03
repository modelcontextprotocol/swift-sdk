/// Roots represent filesystem directories that the client has access to.
///
/// Servers can request the list of roots from clients to understand
/// the scope of files they can work with.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/client/roots/

/// A root directory that the client has access to.
///
/// Roots allow clients to inform servers about which parts of the
/// filesystem are available for operations.
public struct Root: Hashable, Codable, Sendable {
    /// The prefix required for all root URIs.
    public static let requiredURIPrefix = "file://"

    /// The URI of the root. Must be a `file://` URI.
    public let uri: String

    /// An optional human-readable name for the root.
    public let name: String?

    /// Reserved for additional metadata.
    public var _meta: [String: Value]?

    /// Creates a new root with the specified URI.
    ///
    /// - Parameters:
    ///   - uri: The URI of the root. Must start with `file://`.
    ///   - name: An optional human-readable name for the root.
    ///   - _meta: Optional metadata for the root.
    /// - Precondition: `uri` must start with `file://`.
    public init(
        uri: String,
        name: String? = nil,
        _meta: [String: Value]? = nil
    ) {
        precondition(
            uri.hasPrefix(Self.requiredURIPrefix),
            "Root URI must start with '\(Self.requiredURIPrefix)', got: \(uri)"
        )
        self.uri = uri
        self.name = name
        self._meta = _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uri = try container.decode(String.self, forKey: .uri)
        guard uri.hasPrefix(Self.requiredURIPrefix) else {
            throw DecodingError.dataCorruptedError(
                forKey: .uri,
                in: container,
                debugDescription: "Root URI must start with '\(Self.requiredURIPrefix)', got: \(uri)"
            )
        }
        self.uri = uri
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self._meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
    }

    private enum CodingKeys: String, CodingKey {
        case uri, name, _meta
    }
}

/// Request from server to client to list available filesystem roots.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/client/roots/
public enum ListRoots: Method {
    public static let name: String = "roots/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init() {
            self._meta = nil
        }

        public init(_meta: RequestMeta?) {
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        /// The list of available roots.
        public let roots: [Root]
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            roots: [Root],
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.roots = roots
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case roots, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            roots = try container.decode([Root].self, forKey: .roots)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(roots, forKey: .roots)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// Notification sent by clients when the list of available roots changes.
///
/// Servers that receive this notification should request an updated
/// list of roots via `ListRoots`.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/client/roots/
public struct RootsListChangedNotification: Notification {
    public static let name: String = "notifications/roots/list_changed"

    public typealias Parameters = NotificationParams
}
