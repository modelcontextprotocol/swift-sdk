import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose resources to clients.
/// Resources allow servers to share data that provides context to language models,
/// such as files, database schemas, or application-specific information.
/// Each resource is uniquely identified by a URI.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/
public struct Resource: Hashable, Codable, Sendable {
    /// The resource name
    public var name: String
    /// The resource URI
    public var uri: String
    /// The resource description
    public var description: String?
    /// The resource MIME type
    public var mimeType: String?
    /// The resource metadata
    public var metadata: [String: String]?
    /// General MCP fields such as `_meta`.
    public var general: GeneralFields

    public init(
        name: String,
        uri: String,
        description: String? = nil,
        mimeType: String? = nil,
        metadata: [String: String]? = nil,
        general: GeneralFields = .init()
    ) {
        self.name = name
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.metadata = metadata
        self.general = general
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case uri
        case description
        case mimeType
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        general = try GeneralFields.decode(
            from: dynamic,
            reservedKeyNames: Self.reservedGeneralFieldNames)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try general.encode(
            into: encoder,
            reservedKeyNames: Self.reservedGeneralFieldNames)
    }

    private static var reservedGeneralFieldNames: Set<String> {
        ["name", "uri", "description", "mimeType", "metadata"]
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
        /// General MCP fields such as `_meta`.
        public var general: GeneralFields

        public static func text(
            _ content: String,
            uri: String,
            mimeType: String? = nil,
            general: GeneralFields = .init()
        ) -> Self {
            .init(uri: uri, mimeType: mimeType, text: content, general: general)
        }

        public static func binary(
            _ data: Data,
            uri: String,
            mimeType: String? = nil,
            general: GeneralFields = .init()
        ) -> Self {
            .init(
                uri: uri,
                mimeType: mimeType,
                blob: data.base64EncodedString(),
                general: general
            )
        }

        private init(
            uri: String,
            mimeType: String? = nil,
            text: String? = nil,
            general: GeneralFields = .init()
        ) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = text
            self.blob = nil
            self.general = general
        }

        private init(
            uri: String,
            mimeType: String? = nil,
            blob: String,
            general: GeneralFields = .init()
        ) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = nil
            self.blob = blob
            self.general = general
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
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            general = try GeneralFields.decode(
                from: dynamic,
                reservedKeyNames: Self.reservedGeneralFieldNames)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(blob, forKey: .blob)
            try general.encode(
                into: encoder,
                reservedKeyNames: Self.reservedGeneralFieldNames)
        }

        private static var reservedGeneralFieldNames: Set<String> {
            ["uri", "mimeType", "text", "blob"]
        }
    }

    /// A resource template.
    public struct Template: Hashable, Codable, Sendable {
        /// The URI template pattern
        public var uriTemplate: String
        /// The template name
        public var name: String
        /// The template description
        public var description: String?
        /// The resource MIME type
        public var mimeType: String?

        public init(
            uriTemplate: String,
            name: String,
            description: String? = nil,
            mimeType: String? = nil
        ) {
            self.uriTemplate = uriTemplate
            self.name = name
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
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#listing-resources
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
        public let resources: [Resource]
        public let nextCursor: String?

        public init(resources: [Resource], nextCursor: String? = nil) {
            self.resources = resources
            self.nextCursor = nextCursor
        }
    }
}

/// To retrieve resource contents, clients send a `resources/read` request:
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#reading-resources
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

        public init(contents: [Resource.Content]) {
            self.contents = contents
        }
    }
}

/// To discover available resource templates, clients send a `resources/templates/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#resource-templates
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

        public init(templates: [Resource.Template], nextCursor: String? = nil) {
            self.templates = templates
            self.nextCursor = nextCursor
        }

        private enum CodingKeys: String, CodingKey {
            case templates = "resourceTemplates"
            case nextCursor
        }
    }
}

/// When the list of available resources changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#list-changed-notification
public struct ResourceListChangedNotification: Notification {
    public static let name: String = "notifications/resources/list_changed"

    public typealias Parameters = Empty
}

/// Clients can subscribe to specific resources and receive notifications when they change.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#subscriptions
public enum ResourceSubscribe: Method {
    public static let name: String = "resources/subscribe"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
    }

    public typealias Result = Empty
}

/// When a resource changes, servers that declared the updated capability SHOULD send a notification to subscribed clients.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/resources/#subscriptions
public struct ResourceUpdatedNotification: Notification {
    public static let name: String = "notifications/resources/updated"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String

        public init(uri: String) {
            self.uri = uri
        }
    }
}
