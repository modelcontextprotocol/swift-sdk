import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose resources to clients.
/// Resources allow servers to share data that provides context to language models,
/// such as files, database schemas, or application-specific information.
/// Each resource is uniquely identified by a URI.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/resources/
public struct Resource: Hashable, Codable, Sendable {
    /// The resource name
    public var name: String
    /// A human-readable resource title
    public var title: String?
    /// The resource URI
    public var uri: String
    /// The resource description
    public var description: String?
    /// The resource MIME type
    public var mimeType: String?
    /// The resource metadata
    public var metadata: [String: String]?
    /// Metadata fields for the resource (see spec for _meta usage)
    public var _meta: [String: Value]?

    public init(
        name: String,
        uri: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        metadata: [String: String]? = nil,
        _meta: [String: Value]? = nil
    ) {
        self.name = name
        self.title = title
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.metadata = metadata
        self._meta = _meta
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case uri
        case title
        case description
        case mimeType
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
        let metaContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        _meta = try decodeMeta(from: metaContainer)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        var metaContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        try encodeMeta(_meta, to: &metaContainer)
    }

    /// Content of a resource.
    public struct Content: Hashable, Codable, Sendable {
        /// The resource URI
        public let uri: String
        /// The resource MIME type
        public let mimeType: String?
        /// The resource text content
        public let text: String?
        /// The resource binary content
        public let blob: String?
        /// Metadata fields (see spec for _meta usage)
        public var _meta: [String: Value]?

        public static func text(
            _ content: String,
            uri: String,
            mimeType: String? = nil,
            _meta: [String: Value]? = nil
        ) -> Self {
            .init(uri: uri, mimeType: mimeType, text: content, _meta: _meta)
        }

        public static func binary(
            _ data: Data,
            uri: String,
            mimeType: String? = nil,
            _meta: [String: Value]? = nil
        ) -> Self {
            .init(
                uri: uri,
                mimeType: mimeType,
                blob: data.base64EncodedString(),
                _meta: _meta
            )
        }

        private init(
            uri: String,
            mimeType: String? = nil,
            text: String? = nil,
            _meta: [String: Value]? = nil
        ) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = text
            self.blob = nil
            self._meta = _meta
        }

        private init(
            uri: String,
            mimeType: String? = nil,
            blob: String,
            _meta: [String: Value]? = nil
        ) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = nil
            self.blob = blob
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey {
            case uri
            case mimeType
            case text
            case blob
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uri = try container.decode(String.self, forKey: .uri)
            mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            blob = try container.decodeIfPresent(String.self, forKey: .blob)
            let metaContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
            _meta = try decodeMeta(from: metaContainer)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(blob, forKey: .blob)

            // Encode _meta
            var metaContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            try encodeMeta(_meta, to: &metaContainer)
        }
    }

    /// A resource template.
    public struct Template: Hashable, Codable, Sendable {
        /// The URI template pattern
        public var uriTemplate: String
        /// The template name
        public var name: String
        /// A human-readable template title
        public var title: String?
        /// The template description
        public var description: String?
        /// The resource MIME type
        public var mimeType: String?

        public init(
            uriTemplate: String,
            name: String,
            title: String? = nil,
            description: String? = nil,
            mimeType: String? = nil
        ) {
            self.uriTemplate = uriTemplate
            self.name = name
            self.title = title
            self.description = description
            self.mimeType = mimeType
        }
    }

    // A resource annotation.
    public struct Annotations: Hashable, Codable, Sendable {
        /// The intended audience for this resource.
        public enum Audience: String, Hashable, Codable, Sendable {
            /// Content intended for end users.
            case user = "user"
            /// Content intended for AI assistants.
            case assistant = "assistant"
        }

        /// An array indicating the intended audience(s) for this resource. For example, `[.user, .assistant]` indicates content useful for both.
        public let audience: [Audience]
        /// A number from 0.0 to 1.0 indicating the importance of this resource. A value of 1 means “most important” (effectively required), while 0 means “least important”.
        public let priority: Double?
        /// An ISO 8601 formatted timestamp indicating when the resource was last modified (e.g., "2025-01-12T15:00:58Z").
        public let lastModified: String

        public init(
            audience: [Audience],
            priority: Double? = nil,
            lastModified: String
        ) {
            self.audience = audience
            self.priority = priority
            self.lastModified = lastModified
        }
    }
}

// MARK: -

/// To discover available resources, clients send a `resources/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/resources/#listing-resources
public enum ListResources: Method {
    public static let name: String = "resources/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?

        public init() {
            self.cursor = nil
        }

        public init(cursor: String) {
            self.cursor = cursor
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        let resources: [Resource]
        let nextCursor: String?
        var _meta: [String: Value]?
        var extraFields: [String: Value]?

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

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case resources, nextCursor
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(resources, forKey: .resources)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)

            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            try encodeMeta(_meta, to: &dynamicContainer)
            try encodeExtraFields(
                extraFields, to: &dynamicContainer,
                excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resources = try container.decode([Resource].self, forKey: .resources)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)

            let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
            _meta = try decodeMeta(from: dynamicContainer)
            extraFields = try decodeExtraFields(
                from: dynamicContainer, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }
    }
}

/// To retrieve resource contents, clients send a `resources/read` request:
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/resources/#reading-resources
public enum ReadResource: Method {
    public static let name: String = "resources/read"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String

        public init(uri: String) {
            self.uri = uri
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let contents: [Resource.Content]
        /// Optional metadata about this result
        public var _meta: [String: Value]?
        /// Extra fields for this result (index signature)
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

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case contents
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(contents, forKey: .contents)

            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            try encodeMeta(_meta, to: &dynamicContainer)
            try encodeExtraFields(
                extraFields, to: &dynamicContainer,
                excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contents = try container.decode([Resource.Content].self, forKey: .contents)

            let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
            _meta = try decodeMeta(from: dynamicContainer)
            extraFields = try decodeExtraFields(
                from: dynamicContainer, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }
    }
}

/// To discover available resource templates, clients send a `resources/templates/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/resources/#resource-templates
public enum ListResourceTemplates: Method {
    public static let name: String = "resources/templates/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?

        public init() {
            self.cursor = nil
        }

        public init(cursor: String) {
            self.cursor = cursor
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let templates: [Resource.Template]
        public let nextCursor: String?
        /// Optional metadata about this result
        public var _meta: [String: Value]?
        /// Extra fields for this result (index signature)
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

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case templates = "resourceTemplates"
            case nextCursor
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(templates, forKey: .templates)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)

            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            try encodeMeta(_meta, to: &dynamicContainer)
            try encodeExtraFields(
                extraFields, to: &dynamicContainer,
                excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            templates = try container.decode([Resource.Template].self, forKey: .templates)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)

            let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
            _meta = try decodeMeta(from: dynamicContainer)
            extraFields = try decodeExtraFields(
                from: dynamicContainer, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }
    }
}

/// When the list of available resources changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/resources/#list-changed-notification
public struct ResourceListChangedNotification: Notification {
    public static let name: String = "notifications/resources/list_changed"

    public typealias Parameters = Empty
}

/// Clients can subscribe to specific resources and receive notifications when they change.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/resources/#subscriptions
public enum ResourceSubscribe: Method {
    public static let name: String = "resources/subscribe"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
    }

    public typealias Result = Empty
}

/// When a resource changes, servers that declared the updated capability SHOULD send a notification to subscribed clients.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/resources/#subscriptions
public struct ResourceUpdatedNotification: Notification {
    public static let name: String = "notifications/resources/updated"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String

        public init(uri: String) {
            self.uri = uri
        }
    }
}
