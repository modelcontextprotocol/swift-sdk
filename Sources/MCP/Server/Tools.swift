import Foundation

/// The Model Context Protocol (MCP) allows servers to expose tools
/// that can be invoked by language models.
/// Tools enable models to interact with external systems, such as
/// querying databases, calling APIs, or performing computations.
/// Each tool is uniquely identified by a name and includes metadata
/// describing its schema.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/tools/
public struct Tool: Hashable, Codable, Sendable {
    /// The tool name
    public let name: String
    /// The tool description
    public let description: String?
    /// The tool input schema
    public let inputSchema: Value

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

    /// Initialize a tool with a name, description, input schema, and annotations
    public init(
        name: String,
        description: String?,
        inputSchema: Value,
        annotations: Annotations = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    /// Content types that can be returned by a tool
    public enum Content: Hashable, Codable, Sendable {
        /// Text content
        case text(String)
        /// Image content
        case image(data: String, mimeType: String, metadata: [String: String]?)
        /// Audio content
        case audio(data: String, mimeType: String)
        /// Embedded resource content
        case resource(uri: String, mimeType: String, text: String?)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case image
            case resource
            case audio
            case uri
            case mimeType
            case data
            case metadata
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
                let metadata = try container.decodeIfPresent(
                    [String: String].self, forKey: .metadata)
                self = .image(data: data, mimeType: mimeType, metadata: metadata)
            case "audio":
                let data = try container.decode(String.self, forKey: .data)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                self = .audio(data: data, mimeType: mimeType)
            case "resource":
                let uri = try container.decode(String.self, forKey: .uri)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                let text = try container.decodeIfPresent(String.self, forKey: .text)
                self = .resource(uri: uri, mimeType: mimeType, text: text)
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
                try container.encodeIfPresent(metadata, forKey: .metadata)
            case .audio(let data, let mimeType):
                try container.encode("audio", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
            case .resource(let uri, let mimeType, let text):
                try container.encode("resource", forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(text, forKey: .text)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema
        case annotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        inputSchema = try container.decode(Value.self, forKey: .inputSchema)
        annotations =
            try container.decodeIfPresent(Tool.Annotations.self, forKey: .annotations) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        if !annotations.isEmpty {
            try container.encode(annotations, forKey: .annotations)
        }
    }
}

// MARK: -

/// To discover available tools, clients send a `tools/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/tools/#listing-tools
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

        public init(tools: [Tool], nextCursor: String? = nil) {
            self.tools = tools
            self.nextCursor = nextCursor
        }
    }
}

/// To call a tool, clients send a `tools/call` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/tools/#calling-tools
public enum CallTool: Method {
    public static let name = "tools/call"

    public struct Parameters: Hashable, Codable, Sendable {
        public let name: String
        public let arguments: [String: Value]?

        public init(name: String, arguments: [String: Value]? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let content: [Tool.Content]
        public let isError: Bool?

        public init(content: [Tool.Content], isError: Bool? = nil) {
            self.content = content
            self.isError = isError
        }
    }
}

/// When the list of available tools changes, servers that declared the listChanged capability SHOULD send a notification:
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/tools/#list-changed-notification
public struct ToolListChangedNotification: Notification {
    public static let name: String = "notifications/tools/list_changed"
}
