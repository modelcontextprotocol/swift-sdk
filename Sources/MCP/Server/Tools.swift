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
    ///
    /// No other case is added in 1.x: a kind from a later revision is ``unknown(type:_:)``.
    public enum Content: Hashable, Codable, Sendable {
        /// Text content
        case text(text: String, annotations: Resource.Annotations? = nil, _meta: Metadata? = nil)
        /// Image content
        case image(data: String, mimeType: String, annotations: Resource.Annotations? = nil, _meta: Metadata? = nil)
        /// Audio content
        case audio(data: String, mimeType: String, annotations: Resource.Annotations? = nil, _meta: Metadata? = nil)
        /// Embedded resource content (EmbeddedResource from spec)
        case resource(resource: Resource.Content, annotations: Resource.Annotations? = nil, _meta: Metadata? = nil)
        /// Resource link
        case resourceLink(
            uri: String, name: String, title: String? = nil, description: String? = nil,
            mimeType: String? = nil,
            annotations: Resource.Annotations? = nil
        )
        /// A block of a type the SDK does not know, from a later revision: its
        /// `type` and the whole block as received. It is encoded as received.
        case unknown(type: String, Value)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case image
            case resource
            case resource_link
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
                let annotations = try container.decodeIfPresent(Resource.Annotations.self, forKey: .annotations)
                let _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
                self = .text(text: text, annotations: annotations, _meta: _meta)
            case "image":
                let data = try container.decode(String.self, forKey: .data)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                let annotations = try container.decodeIfPresent(Resource.Annotations.self, forKey: .annotations)
                let _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
                self = .image(data: data, mimeType: mimeType, annotations: annotations, _meta: _meta)
            case "audio":
                let data = try container.decode(String.self, forKey: .data)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                let annotations = try container.decodeIfPresent(Resource.Annotations.self, forKey: .annotations)
                let _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
                self = .audio(data: data, mimeType: mimeType, annotations: annotations, _meta: _meta)
            case "resource":
                let resourceContent = try container.decode(Resource.Content.self, forKey: .resource)
                let annotations = try container.decodeIfPresent(Resource.Annotations.self, forKey: .annotations)
                let _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
                self = .resource(resource: resourceContent, annotations: annotations, _meta: _meta)
            case "resource_link":
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
                self = .unknown(type: type, try UnknownBlock.decode(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            if case .unknown(let type, let block) = self {
                try UnknownBlock.encode(block, kind: type, to: encoder)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .text(let text, let annotations, let _meta):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(_meta, forKey: ._meta)
            case .image(let data, let mimeType, let annotations, let _meta):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(_meta, forKey: ._meta)
            case .audio(let data, let mimeType, let annotations, let _meta):
                try container.encode("audio", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(_meta, forKey: ._meta)
            case .resource(let resourceContent, let annotations, let _meta):
                try container.encode("resource", forKey: .type)
                try container.encode(resourceContent, forKey: .resource)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(_meta, forKey: ._meta)
            case .resourceLink(
                let uri, let name, let title, let description, let mimeType, let annotations):
                try container.encode("resource_link", forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(title, forKey: .title)
                try container.encodeIfPresent(description, forKey: .description)
                try container.encodeIfPresent(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(annotations, forKey: .annotations)
            case .unknown:
                return
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
        try container.encodeIfPresent(description, forKey: .description)
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
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#listing-tools
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

    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        public let tools: [Tool]
        public let nextCursor: String?
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        public init(
            tools: [Tool],
            nextCursor: String? = nil,
            _meta: Metadata? = nil,
            ttlMs: Int? = nil,
            cacheScope: CacheScope? = nil
        ) {
            self.tools = tools
            self.nextCursor = nextCursor
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case tools, nextCursor, _meta, ttlMs, cacheScope
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tools, forKey: .tools)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
            try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tools = try container.decode([Tool].self, forKey: .tools)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
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

        /// The client's responses to the server's input requests, keyed as
        /// the requests were (2026-07-28, SEP-2322).
        public var inputResponses: [String: InputResponse]?

        /// The `requestState` of the previous round, echoed unchanged.
        public var requestState: String?

        public init(
            name: String,
            arguments: [String: Value]? = nil,
            meta: Metadata? = nil,
            inputResponses: [String: InputResponse]? = nil,
            requestState: String? = nil
        ) {
            self._meta = meta
            self.name = name
            self.arguments = arguments
            self.inputResponses = inputResponses
            self.requestState = requestState
        }

        private enum CodingKeys: String, CodingKey {
            case _meta
            case name
            case arguments
            case inputResponses
            case requestState
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            name = try container.decode(String.self, forKey: .name)
            arguments = try container.decodeIfPresent([String: Value].self, forKey: .arguments)
            inputResponses = try MRTR.decodeInputResponses(container, forKey: .inputResponses)
            requestState = try container.decodeIfPresent(String.self, forKey: .requestState)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(arguments, forKey: .arguments)
            try container.encodeIfPresent(inputResponses, forKey: .inputResponses)
            try container.encodeIfPresent(requestState, forKey: .requestState)
        }
    }

    /// The result of a tool call: its content, or, at 2026-07-28, a request
    /// for more input (see `inputRequired(_:requestState:_meta:)`).
    public struct Result: Hashable, Codable, Sendable {
        public let content: [Tool.Content]
        public let structuredContent: Value?
        public let isError: Bool?
        /// Optional metadata about this result
        public var _meta: Metadata?

        /// Requests the client must fulfill before the call can finish,
        /// keyed by names the server chooses (SEP-2322).
        public var inputRequests: [String: InputRequest]?

        /// Opaque state the client echoes on the next round. The server
        /// SDK seals it before it leaves the server.
        public var requestState: String?

        private var declaredResultType: ResultType?

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
            var result = Result(_meta: _meta)
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
            case content, structuredContent, isError, _meta
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
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(structuredContent, forKey: .structuredContent)
            try container.encodeIfPresent(isError, forKey: .isError)
            try container.encodeIfPresent(_meta, forKey: ._meta)
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
                content = []
                structuredContent = nil
                isError = nil
                return
            }
            content = try container.decode([Tool.Content].self, forKey: .content)
            structuredContent = try container.decodeIfPresent(
                Value.self, forKey: .structuredContent)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        }
    }
}

extension CallTool.Parameters: InputRespondingParameters {
    var stateBinding: (target: String, arguments: Value) { (name, .object(arguments ?? [:])) }

    func retrying(inputResponses: [String: InputResponse]?, requestState: String?) -> Self {
        var copy = self
        copy.inputResponses = inputResponses
        copy.requestState = requestState
        return copy
    }
}

extension CallTool.Result: InputRequiringResult {
    var hasContent: Bool { !content.isEmpty || structuredContent != nil || isError != nil }
}

/// When the list of available tools changes, servers that declared the listChanged capability SHOULD send a notification:
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-06-18/server/tools/#list-changed-notification
public struct ToolListChangedNotification: Notification {
    public static let name: String = "notifications/tools/list_changed"
}
