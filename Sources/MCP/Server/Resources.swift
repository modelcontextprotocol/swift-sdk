import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose resources to clients.
/// Resources allow servers to share data that provides context to language models,
/// such as files, database schemas, or application-specific information.
/// Each resource is uniquely identified by a URI.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/server/resources/
public struct Resource: Hashable, Codable, Sendable {
    /// The resource name (intended for programmatic or logical use)
    public var name: String
    /// A human-readable title for the resource, intended for UI display.
    /// If not provided, the `name` should be used for display.
    public var title: String?
    /// The resource URI
    public var uri: String
    /// The resource description
    public var description: String?
    /// The resource MIME type
    public var mimeType: String?
    /// The size of the raw resource content, in bytes, if known.
    public var size: Int?
    /// Optional annotations for the client.
    public var annotations: Annotations?
    /// Reserved for clients and servers to attach additional metadata.
    public var _meta: [String: Value]?
    /// Optional icons representing this resource.
    public var icons: [Icon]?

    public init(
        name: String,
        title: String? = nil,
        uri: String,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        annotations: Annotations? = nil,
        _meta: [String: Value]? = nil,
        icons: [Icon]? = nil
    ) {
        self.name = name
        self.title = title
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
        self._meta = _meta
        self.icons = icons
    }

    /// Content of a resource.
    public struct Contents: Hashable, Codable, Sendable {
        /// The resource URI
        public let uri: String
        /// The resource MIME type
        public let mimeType: String?
        /// The resource text content
        public let text: String?
        /// The resource binary content
        public let blob: String?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?

        public static func text(_ content: String, uri: String, mimeType: String? = nil) -> Self {
            .init(uri: uri, mimeType: mimeType, text: content)
        }

        public static func binary(_ data: Data, uri: String, mimeType: String? = nil) -> Self {
            .init(uri: uri, mimeType: mimeType, blob: data.base64EncodedString())
        }

        private init(uri: String, mimeType: String? = nil, text: String? = nil) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = text
            self.blob = nil
            self._meta = nil
        }

        private init(uri: String, mimeType: String? = nil, blob: String) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = nil
            self.blob = blob
            self._meta = nil
        }
    }

    // TODO: Deprecate in a future version
    /// Backwards compatibility alias for `Contents`.
    public typealias Content = Contents

    /// A resource template that can generate multiple resources via URI pattern matching.
    ///
    /// Resource templates use [RFC 6570 URI Templates](https://datatracker.ietf.org/doc/html/rfc6570)
    /// to define patterns for dynamic resource URIs. Clients can use these templates to construct
    /// resource URIs by substituting template variables.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Define a template for user profiles
    /// let template = Resource.Template(
    ///     uriTemplate: "users://{userId}/profile",
    ///     name: "user_profile",
    ///     title: "User Profile",
    ///     description: "Profile information for a specific user",
    ///     mimeType: "application/json"
    /// )
    ///
    /// // Register with a server
    /// server.registerResources {
    ///     listTemplates: { _ in [template] },
    ///     read: { uri in
    ///         // Parse userId from URI and return profile data
    ///         let userId = parseUserId(from: uri)
    ///         return [.text(getProfile(userId), uri: uri)]
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: https://spec.modelcontextprotocol.io/specification/server/resources/#resource-templates
    public struct Template: Hashable, Codable, Sendable {
        /// The URI template pattern (RFC 6570 format, e.g., "file:///{path}").
        public var uriTemplate: String
        /// The template name (intended for programmatic or logical use).
        public var name: String
        /// A human-readable title for the template, intended for UI display.
        /// If not provided, the `name` should be used for display.
        public var title: String?
        /// A description of what resources this template provides.
        public var description: String?
        /// The MIME type of resources generated from this template.
        public var mimeType: String?
        /// Optional annotations for the client.
        public var annotations: Annotations?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Optional icons representing this resource template.
        public var icons: [Icon]?

        public init(
            uriTemplate: String,
            name: String,
            title: String? = nil,
            description: String? = nil,
            mimeType: String? = nil,
            annotations: Annotations? = nil,
            _meta: [String: Value]? = nil,
            icons: [Icon]? = nil
        ) {
            self.uriTemplate = uriTemplate
            self.name = name
            self.title = title
            self.description = description
            self.mimeType = mimeType
            self.annotations = annotations
            self._meta = _meta
            self.icons = icons
        }
    }
}

/// A resource link returned in tool results, referencing a resource that can be read.
///
/// Resource links differ from embedded resources in that they don't include
/// the actual content - they're references to resources that can be read later.
///
/// Note: Resource links returned by tools are not guaranteed to appear
/// in the results of `resources/list` requests.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/server/tools/#resource-links
public struct ResourceLink: Hashable, Codable, Sendable {
    /// The resource name (intended for programmatic or logical use)
    public var name: String
    /// A human-readable title for the resource, intended for UI display.
    public var title: String?
    /// The resource URI
    public var uri: String
    /// The resource description
    public var description: String?
    /// The resource MIME type
    public var mimeType: String?
    /// The size of the raw resource content, in bytes, if known.
    public var size: Int?
    /// Optional annotations for the client.
    public var annotations: Annotations?
    /// Optional icons representing this resource.
    public var icons: [Icon]?
    /// Reserved for clients and servers to attach additional metadata.
    public var _meta: [String: Value]?

    public init(
        name: String,
        title: String? = nil,
        uri: String,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        annotations: Annotations? = nil,
        icons: [Icon]? = nil,
        _meta: [String: Value]? = nil
    ) {
        self.name = name
        self.title = title
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
        self.icons = icons
        self._meta = _meta
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case title
        case uri
        case description
        case mimeType
        case size
        case annotations
        case icons
        case _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Verify type is "resource_link"
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        if let type, type != "resource_link" {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Expected type 'resource_link', got '\(type)'")
        }
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        uri = try container.decode(String.self, forKey: .uri)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
        icons = try container.decodeIfPresent([Icon].self, forKey: .icons)
        _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("resource_link", forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(icons, forKey: .icons)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

// MARK: -

/// To discover available resources, clients send a `resources/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#listing-resources
public enum ListResources: Method {
    public static let name: String = "resources/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init() {
            self.cursor = nil
            self._meta = nil
        }

        public init(cursor: String? = nil, _meta: RequestMeta? = nil) {
            self.cursor = cursor
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let resources: [Resource]
        public let nextCursor: String?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            resources: [Resource],
            nextCursor: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.resources = resources
            self.nextCursor = nextCursor
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case resources, nextCursor, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resources = try container.decode([Resource].self, forKey: .resources)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(resources, forKey: .resources)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// To retrieve resource contents, clients send a `resources/read` request:
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#reading-resources
public enum ReadResource: Method {
    public static let name: String = "resources/read"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(uri: String, _meta: RequestMeta? = nil) {
            self.uri = uri
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let contents: [Resource.Content]
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            contents: [Resource.Content],
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.contents = contents
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case contents, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contents = try container.decode([Resource.Content].self, forKey: .contents)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(contents, forKey: .contents)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// To discover available resource templates, clients send a `resources/templates/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#resource-templates
public enum ListResourceTemplates: Method {
    public static let name: String = "resources/templates/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init() {
            self.cursor = nil
            self._meta = nil
        }

        public init(cursor: String? = nil, _meta: RequestMeta? = nil) {
            self.cursor = cursor
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let templates: [Resource.Template]
        public let nextCursor: String?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            templates: [Resource.Template],
            nextCursor: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.templates = templates
            self.nextCursor = nextCursor
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case templates = "resourceTemplates"
            case nextCursor
            case _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            templates = try container.decode([Resource.Template].self, forKey: .templates)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(templates, forKey: .templates)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// When the list of available resources changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#list-changed-notification
public struct ResourceListChangedNotification: Notification {
    public static let name: String = "notifications/resources/list_changed"

    public typealias Parameters = NotificationParams
}

/// Clients can subscribe to specific resources and receive notifications when they change.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/server/resources/#subscriptions
public enum ResourceSubscribe: Method {
    public static let name: String = "resources/subscribe"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(uri: String, _meta: RequestMeta? = nil) {
            self.uri = uri
            self._meta = _meta
        }
    }

    public typealias Result = Empty
}

/// Clients can unsubscribe from resources to stop receiving update notifications.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/server/resources/#subscriptions
public enum ResourceUnsubscribe: Method {
    public static let name: String = "resources/unsubscribe"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(uri: String, _meta: RequestMeta? = nil) {
            self.uri = uri
            self._meta = _meta
        }
    }

    public typealias Result = Empty
}

/// When a resource changes, servers that declared the updated capability SHOULD send a notification to subscribed clients.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#subscriptions
public struct ResourceUpdatedNotification: Notification {
    public static let name: String = "notifications/resources/updated"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
        /// Reserved for additional metadata.
        public var _meta: [String: Value]?

        public init(uri: String, _meta: [String: Value]? = nil) {
            self.uri = uri
            self._meta = _meta
        }
    }
}
