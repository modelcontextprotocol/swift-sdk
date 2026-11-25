import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose resources to clients.
/// Resources allow servers to share data that provides context to language models,
/// such as files, database schemas, or application-specific information.
/// Each resource is uniquely identified by a URI.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/resources/
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
    /// Raw content size in bytes
    public var size: Int?
    /// Annotations for this resource
    public var annotations: Resource.Annotations?
    /// Optional set of sized icons that the client can display in a user interface
    public var icons: [Icon]?
    /// Metadata fields for the resource (see spec for _meta usage)
    public var _meta: Metadata?

    public init(
        name: String,
        uri: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        annotations: Resource.Annotations? = nil,
        icons: [Icon]? = nil,
        _meta: Metadata? = nil
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
        case name
        case uri
        case title
        case description
        case mimeType
        case size
        case annotations
        case icons
        case _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        annotations = try container.decodeIfPresent(Resource.Annotations.self, forKey: .annotations)
        icons = try container.decodeIfPresent([Icon].self, forKey: .icons)
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(icons, forKey: .icons)
        try container.encodeIfPresent(_meta, forKey: ._meta)
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
        public var _meta: Metadata?

        public static func text(
            _ content: String,
            uri: String,
            mimeType: String? = nil,
            _meta: Metadata? = nil
        ) -> Self {
            .init(uri: uri, mimeType: mimeType, text: content, _meta: _meta)
        }

        public static func binary(
            _ data: Data,
            uri: String,
            mimeType: String? = nil,
            _meta: Metadata? = nil
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
            _meta: Metadata? = nil
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
            _meta: Metadata? = nil
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
            case _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uri = try container.decode(String.self, forKey: .uri)
            mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            blob = try container.decodeIfPresent(String.self, forKey: .blob)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(blob, forKey: .blob)
            try container.encodeIfPresent(_meta, forKey: ._meta)
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
        /// Annotations for this template
        public var annotations: Resource.Annotations?
        /// Optional set of sized icons that the client can display in a user interface
        public var icons: [Icon]?
        /// Metadata fields for the template (see spec for _meta usage)
        public var _meta: Metadata?

        public init(
            uriTemplate: String,
            name: String,
            title: String? = nil,
            description: String? = nil,
            mimeType: String? = nil,
            annotations: Resource.Annotations? = nil,
            icons: [Icon]? = nil,
            _meta: Metadata? = nil
        ) {
            self.uriTemplate = uriTemplate
            self.name = name
            self.title = title
            self.description = description
            self.mimeType = mimeType
            self.annotations = annotations
            self.icons = icons
            self._meta = _meta
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
        public let audience: [Audience]?
        /// A number from 0.0 to 1.0 indicating the importance of this resource. A value of 1 means "most important" (effectively required), while 0 means "least important".
        public let priority: Double?
        /// An ISO 8601 formatted timestamp indicating when the resource was last modified (e.g., "2025-01-12T15:00:58Z").
        public let lastModified: String?

        public init(
            audience: [Audience]? = nil,
            priority: Double? = nil,
            lastModified: String? = nil
        ) {
            self.audience = audience
            self.priority = priority
            self.lastModified = lastModified
        }
    }
}

// MARK: -

/// To discover available resources, clients send a `resources/list` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/resources/#listing-resources
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

    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        public let resources: [Resource]
        public let nextCursor: String?
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        public init(
            resources: [Resource],
            nextCursor: String? = nil,
            _meta: Metadata? = nil,
            ttlMs: Int? = nil,
            cacheScope: CacheScope? = nil
        ) {
            self.resources = resources
            self.nextCursor = nextCursor
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case resources, nextCursor, _meta, ttlMs, cacheScope
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(resources, forKey: .resources)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
            try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resources = try container.decode([Resource].self, forKey: .resources)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
        }
    }
}

/// To retrieve resource contents, clients send a `resources/read` request:
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/resources/#reading-resources
public enum ReadResource: Method {
    public static let name: String = "resources/read"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String

        /// The client's responses to the server's input requests, keyed as
        /// the requests were (2026-07-28, SEP-2322).
        public var inputResponses: [String: InputResponse]?

        /// The `requestState` of the previous round, echoed unchanged.
        public var requestState: String?

        public init(
            uri: String,
            inputResponses: [String: InputResponse]? = nil,
            requestState: String? = nil
        ) {
            self.uri = uri
            self.inputResponses = inputResponses
            self.requestState = requestState
        }

        private enum CodingKeys: String, CodingKey {
            case uri, inputResponses, requestState
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uri = try container.decode(String.self, forKey: .uri)
            inputResponses = try MRTR.decodeInputResponses(container, forKey: .inputResponses)
            requestState = try container.decodeIfPresent(String.self, forKey: .requestState)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(inputResponses, forKey: .inputResponses)
            try container.encodeIfPresent(requestState, forKey: .requestState)
        }
    }

    /// The resource contents, or, at 2026-07-28, a request for more input
    /// (see `inputRequired(_:requestState:_meta:)`).
    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        public let contents: [Resource.Content]
        /// Optional metadata about this result
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        /// Requests the client must fulfill before the resource can be
        /// read, keyed by names the server chooses (SEP-2322).
        public var inputRequests: [String: InputRequest]?

        /// Opaque state the client echoes on the next round. The server
        /// SDK seals it before it leaves the server.
        public var requestState: String?

        private var declaredResultType: ResultType?

        public init(
            contents: [Resource.Content],
            _meta: Metadata? = nil,
            ttlMs: Int? = nil,
            cacheScope: CacheScope? = nil
        ) {
            self.contents = contents
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        /// A result that asks the client for input and a retry (SEP-2322).
        ///
        /// Give at least one of `requests` and `requestState`. For clients
        /// before 2026-07-28 the server sends the requests itself and calls
        /// the handler again with the responses.
        public static func inputRequired(
            _ requests: [String: InputRequest]? = nil,
            requestState: String? = nil,
            _meta: Metadata? = nil
        ) -> Result {
            var result = Result(contents: [], _meta: _meta)
            result.inputRequests = requests
            result.requestState = requestState
            result.declaredResultType = .inputRequired
            return result
        }

        /// ``ResultType/inputRequired`` when the server asks for input.
        public var resultType: ResultType {
            MRTR.resultType(
                declared: declaredResultType, inputRequests: inputRequests, requestState: requestState)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case contents, _meta, ttlMs, cacheScope
            case resultType, inputRequests, requestState
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if resultType == .inputRequired {
                try container.encode(resultType, forKey: .resultType)
                try container.encodeIfPresent(inputRequests, forKey: .inputRequests)
                try container.encodeIfPresent(requestState, forKey: .requestState)
                try container.encodeIfPresent(_meta, forKey: ._meta)
                return
            }
            try container.encode(contents, forKey: .contents)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
            try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            declaredResultType = MRTR.declared(
                try container.decodeIfPresent(ResultType.self, forKey: .resultType))
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            if declaredResultType == .inputRequired {
                inputRequests = try container.decodeIfPresent(
                    [String: InputRequest].self, forKey: .inputRequests)
                requestState = try container.decodeIfPresent(String.self, forKey: .requestState)
                contents = []
                return
            }
            contents = try container.decode([Resource.Content].self, forKey: .contents)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
        }
    }
}

extension ReadResource.Parameters: InputRespondingParameters {
    var stateBinding: (target: String, arguments: Value) { (uri, .object([:])) }

    func retrying(inputResponses: [String: InputResponse]?, requestState: String?) -> Self {
        var copy = self
        copy.inputResponses = inputResponses
        copy.requestState = requestState
        return copy
    }
}

extension ReadResource.Result: InputRequiringResult {
    var hasContent: Bool { !contents.isEmpty || ttlMs != nil || cacheScope != nil }
}

/// To discover available resource templates, clients send a `resources/templates/list` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/resources/#resource-templates
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

    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        public let templates: [Resource.Template]
        public let nextCursor: String?
        /// Optional metadata about this result
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        public init(
            templates: [Resource.Template],
            nextCursor: String? = nil,
            _meta: Metadata? = nil,
            ttlMs: Int? = nil,
            cacheScope: CacheScope? = nil
        ) {
            self.templates = templates
            self.nextCursor = nextCursor
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case templates = "resourceTemplates"
            case nextCursor
            case _meta, ttlMs, cacheScope
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(templates, forKey: .templates)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
            try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            templates = try container.decode([Resource.Template].self, forKey: .templates)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
        }
    }
}

/// When the list of available resources changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/resources/#list-changed-notification
public struct ResourceListChangedNotification: Notification {
    public static let name: String = "notifications/resources/list_changed"

    public typealias Parameters = Empty
}

/// Clients can subscribe to specific resources and receive notifications when they change.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/resources/#subscriptions
public enum ResourceSubscribe: Method {
    public static let name: String = "resources/subscribe"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
    }

    public typealias Result = Empty
}

/// Sent from the client to request cancellation of resources/updated notifications from the server. This should follow a previous resources/subscribe request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/schema#unsubscriberequest
public enum ResourceUnsubscribe: Method {
    public static let name: String = "resources/unsubscribe"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String
    }

    public typealias Result = Empty
}

/// When a resource changes, servers that declared the updated capability SHOULD send a notification to subscribed clients.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/resources/#subscriptions
public struct ResourceUpdatedNotification: Notification {
    public static let name: String = "notifications/resources/updated"

    public struct Parameters: Hashable, Codable, Sendable {
        public let uri: String

        public init(uri: String) {
            self.uri = uri
        }
    }
}
