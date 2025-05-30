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

    public init(
        name: String,
        uri: String,
        description: String? = nil,
        mimeType: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.name = name
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.metadata = metadata
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
        }

        private init(uri: String, mimeType: String? = nil, blob: String) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = nil
            self.blob = blob
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
