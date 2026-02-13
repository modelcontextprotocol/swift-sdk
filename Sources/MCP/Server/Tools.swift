import Foundation

/// The Model Context Protocol (MCP) allows servers to expose tools
/// that can be invoked by language models.
/// Tools enable models to interact with external systems, such as
/// querying databases, calling APIs, or performing computations.
/// Each tool is uniquely identified by a name and includes metadata
/// describing its schema.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/
public struct Tool: Hashable, Codable, Sendable {
    /// The tool name
    public let name: String
    /// The human-readable name of the tool for display purposes.
    public let title: String?
    /// The tool description
    public let description: String?
    /// The tool input schema
    public let inputSchema: Value
    /// Optional set of sized icons that the client can display in a user interface
    public var icons: [Icon]?
    /// The tool output schema, defining expected output structure
    public let outputSchema: Value?
    /// Metadata fields for the tool (see spec for _meta usage)
    public var _meta: Metadata?

    /// Annotations that provide display-facing and operational information for a Tool.
    ///
    /// - Note: All properties in `ToolAnnotations` are **hints**.
    ///         They are not guaranteed to provide a faithful description of
    ///         tool behavior (including descriptive properties like `title`).
    ///
    ///         Clients should never make tool use decisions based on `ToolAnnotations`
    ///         received from untrusted servers.
    public struct Annotations: Hashable, Codable, Sendable, ExpressibleByNilLiteral {
        /// A human-readable title for the tool
        public var title: String?

        /// If true, the tool may perform destructive updates to its environment.
        /// If false, the tool performs only additive updates.
        /// (This property is meaningful only when `readOnlyHint == false`)
        ///
        /// When unspecified, the implicit default is `true`.
        public var destructiveHint: Bool?

        /// If true, calling the tool repeatedly with the same arguments
        /// will have no additional effect on its environment.
        /// (This property is meaningful only when `readOnlyHint == false`)
        ///
        /// When unspecified, the implicit default is `false`.
        public var idempotentHint: Bool?

        /// If true, this tool may interact with an "open world" of external
        /// entities. If false, the tool's domain of interaction is closed.
        /// For example, the world of a web search tool is open, whereas that
        /// of a memory tool is not.
        ///
        /// When unspecified, the implicit default is `true`.
        public var openWorldHint: Bool?

        /// If true, the tool does not modify its environment.
        ///
        /// When unspecified, the implicit default is `false`.
        public var readOnlyHint: Bool?

        /// Returns true if all properties are nil
        public var isEmpty: Bool {
            title == nil && readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil
                && openWorldHint == nil
        }

        public init(
            title: String? = nil,
            readOnlyHint: Bool? = nil,
            destructiveHint: Bool? = nil,
            idempotentHint: Bool? = nil,
            openWorldHint: Bool? = nil
        ) {
            self.title = title
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
            self.idempotentHint = idempotentHint
            self.openWorldHint = openWorldHint
        }

        /// Initialize an empty annotations object
        public init(nilLiteral: ()) {}
    }

    /// Annotations that provide display-facing and operational information
    public var annotations: Annotations

    /// Initialize a tool with a name, description, input schema, annotations, and optional icons
    public init(
        name: String,
        title: String? = nil,
        description: String?,
        inputSchema: Value,
        annotations: Annotations = nil,
        outputSchema: Value? = nil,
        icons: [Icon]? = nil,
        _meta: Metadata? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self._meta = _meta
        self.icons = icons
    }

    /// Content types that can be returned by a tool
    public enum Content: Hashable, Codable, Sendable {
        /// Text content
        case text(String)
        /// Image content
        case image(data: String, mimeType: String, metadata: Metadata?)
        /// Audio content
        case audio(data: String, mimeType: String)
        /// Embedded resource content (EmbeddedResource from spec)
        case resource(resource: Resource.Content, annotations: Resource.Annotations? = nil, _meta: Metadata? = nil)
        /// Resource link
        case resourceLink(
            uri: String, name: String, title: String? = nil, description: String? = nil,
            mimeType: String? = nil,
            annotations: Resource.Annotations? = nil
        )

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case image
            case resource
            case resourceLink
            case audio
            case uri
            case name
            case title
            case description
            case annotations
            case mimeType
            case data
            case _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case "image":
                let data = try container.decode(String.self, forKey: .data)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                let _meta = try container.decodeIfPresent(
                    Metadata.self, forKey: ._meta)
                self = .image(data: data, mimeType: mimeType, metadata: _meta)
            case "audio":
                let data = try container.decode(String.self, forKey: .data)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                self = .audio(data: data, mimeType: mimeType)
            case "resource":
                let resourceContent = try container.decode(Resource.Content.self, forKey: .resource)
                let annotations = try container.decodeIfPresent(Resource.Annotations.self, forKey: .annotations)
                let _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
                self = .resource(resource: resourceContent, annotations: annotations, _meta: _meta)
            case "resourceLink":
                let uri = try container.decode(String.self, forKey: .uri)
                let name = try container.decode(String.self, forKey: .name)
                let title = try container.decodeIfPresent(String.self, forKey: .title)
                let description = try container.decodeIfPresent(String.self, forKey: .description)
                let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
                let annotations = try container.decodeIfPresent(
                    Resource.Annotations.self, forKey: .annotations)
                self = .resourceLink(
                    uri: uri, name: name, title: title, description: description,
                    mimeType: mimeType, annotations: annotations)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "Unknown tool content type")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let data, let mimeType, let metadata):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(metadata, forKey: ._meta)
            case .audio(let data, let mimeType):
                try container.encode("audio", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
            case .resource(let resourceContent, let annotations, let _meta):
                try container.encode("resource", forKey: .type)
                try container.encode(resourceContent, forKey: .resource)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(_meta, forKey: ._meta)
            case .resourceLink(
                let uri, let name, let title, let description, let mimeType, let annotations):
                try container.encode("resourceLink", forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(title, forKey: .title)
                try container.encodeIfPresent(description, forKey: .description)
                try container.encodeIfPresent(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(annotations, forKey: .annotations)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
        case outputSchema
        case annotations
        case icons
        case _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode(Value.self, forKey: .inputSchema)
        outputSchema = try container.decodeIfPresent(Value.self, forKey: .outputSchema)
        annotations =
            try container.decodeIfPresent(Tool.Annotations.self, forKey: .annotations) ?? .init()
        icons = try container.decodeIfPresent([Icon].self, forKey: .icons)
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
        if !annotations.isEmpty {
            try container.encode(annotations, forKey: .annotations)
        }
        try container.encodeIfPresent(icons, forKey: .icons)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

// MARK: -

/// To discover available tools, clients send a `tools/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/tools/#listing-tools
public enum ListTools: Method {
    public static let name = "tools/list"

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
        public let tools: [Tool]
        public let nextCursor: String?
        public var _meta: Metadata?

        public init(
            tools: [Tool],
            nextCursor: String? = nil,
            _meta: Metadata? = nil
        ) {
            self.tools = tools
            self.nextCursor = nextCursor
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case tools, nextCursor, _meta
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tools, forKey: .tools)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tools = try container.decode([Tool].self, forKey: .tools)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }
    }
}

/// To call a tool, clients send a `tools/call` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#calling-tools
public enum CallTool: Method {
    public static let name = "tools/call"

    public struct Parameters: Hashable, Codable, Sendable {
        /// Optional request metadata including progress token.
        ///
        /// If `progressToken` is specified, the caller is requesting out-of-band
        /// progress notifications for this request.
        public let _meta: Metadata?

        /// The name of the tool to call.
        public let name: String

        /// Arguments to use for the tool call.
        public let arguments: [String: Value]?

        public init(name: String, arguments: [String: Value]? = nil, meta: Metadata? = nil) {
            self._meta = meta
            self.name = name
            self.arguments = arguments
        }

        private enum CodingKeys: String, CodingKey {
            case _meta
            case name
            case arguments
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            name = try container.decode(String.self, forKey: .name)
            arguments = try container.decodeIfPresent([String: Value].self, forKey: .arguments)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(arguments, forKey: .arguments)
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let content: [Tool.Content]
        public let structuredContent: Value?
        public let isError: Bool?
        /// Optional metadata about this result
        public var _meta: Metadata?

        public init(
            content: [Tool.Content] = [],
            structuredContent: Value? = nil,
            isError: Bool? = nil,
            _meta: Metadata? = nil
        ) {
            self.content = content
            self.structuredContent = structuredContent
            self.isError = isError
            self._meta = _meta
        }

        public init<Output: Codable>(
            content: [Tool.Content] = [],
            structuredContent: Output,
            isError: Bool? = nil,
            _meta: Metadata? = nil
        ) throws {
            let encoded = try Value(structuredContent)
            self.init(
                content: content,
                structuredContent: Optional.some(encoded),
                isError: isError,
                _meta: _meta
            )
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case content, structuredContent, isError, _meta
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(structuredContent, forKey: .structuredContent)
            try container.encodeIfPresent(isError, forKey: .isError)
            try container.encodeIfPresent(_meta, forKey: ._meta)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decode([Tool.Content].self, forKey: .content)
            structuredContent = try container.decodeIfPresent(
                Value.self, forKey: .structuredContent)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }
    }
}

/// When the list of available tools changes, servers that declared the listChanged capability SHOULD send a notification:
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/tools/#list-changed-notification
public struct ToolListChangedNotification: Notification {
    public static let name: String = "notifications/tools/list_changed"
}
