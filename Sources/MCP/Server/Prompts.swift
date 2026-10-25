import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose prompt templates to clients.
/// Prompts allow servers to provide structured messages and instructions
/// for interacting with language models.
/// Clients can discover available prompts, retrieve their contents,
/// and provide arguments to customize them.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/prompts/
public struct Prompt: Hashable, Codable, Sendable {
    /// The prompt name
    public let name: String
    /// A human-readable prompt title
    public let title: String?
    /// The prompt description
    public let description: String?
    /// The prompt arguments
    public let arguments: [Argument]?
    /// Optional set of sized icons that the client can display in a user interface
    public var icons: [Icon]?
    /// Optional metadata about this prompt
    public var _meta: Metadata?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [Argument]? = nil,
        icons: [Icon]? = nil,
        meta: Metadata? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.icons = icons
        self._meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, description, arguments, icons, _meta
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(icons, forKey: .icons)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        arguments = try container.decodeIfPresent([Argument].self, forKey: .arguments)
        icons = try container.decodeIfPresent([Icon].self, forKey: .icons)
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
    }

    /// An argument for a prompt
    public struct Argument: Hashable, Codable, Sendable {
        /// The argument name
        public let name: String
        /// A human-readable argument title
        public let title: String?
        /// The argument description
        public let description: String?
        /// Whether the argument is required
        public let required: Bool?

        public init(
            name: String,
            title: String? = nil,
            description: String? = nil,
            required: Bool? = nil
        ) {
            self.name = name
            self.title = title
            self.description = description
            self.required = required
        }
    }

    /// A message in a prompt
    public struct Message: Hashable, Codable, Sendable {
        /// The message role
        ///
        /// Frozen: no case is added in 1.x (every revision has `user` and `assistant` only).
        public enum Role: String, Hashable, Codable, Sendable {
            /// A user message
            case user
            /// An assistant message
            case assistant
        }

        /// The message role
        public let role: Role
        /// The message content
        public let content: Content

        /// Creates a message with the specified role and content
        @available(
            *, deprecated, message: "Use static factory methods .user(_:) or .assistant(_:) instead"
        )
        public init(role: Role, content: Content) {
            self.role = role
            self.content = content
        }

        /// Private initializer for convenience methods to avoid deprecation warnings
        private init(_role role: Role, _content content: Content) {
            self.role = role
            self.content = content
        }

        /// Creates a user message with the specified content
        public static func user(_ content: Content) -> Message {
            return Message(_role: .user, _content: content)
        }

        /// Creates an assistant message with the specified content
        public static func assistant(_ content: Content) -> Message {
            return Message(_role: .assistant, _content: content)
        }

        /// Content types for messages
        ///
        /// No other case is added in 1.x: a kind from a later revision is ``unknown(type:_:)``.
        public enum Content: Hashable, Sendable {
            /// Text content
            case text(text: String)
            /// Image content
            case image(data: String, mimeType: String)
            /// Audio content
            case audio(data: String, mimeType: String)
            /// Embedded resource content (EmbeddedResource from spec)
            case resource(resource: Resource.Content, annotations: Resource.Annotations? = nil, _meta: Metadata? = nil)
            /// Resource link
            case resourceLink(uri: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil, annotations: Resource.Annotations? = nil)
            /// A block of a type the SDK does not know, from a later revision: its
            /// `type` and the whole block as received. It is encoded as received.
            case unknown(type: String, Value)
        }
    }

    /// Reference type for prompts
    public struct Reference: Hashable, Codable, Sendable {
        /// The prompt reference name
        public let name: String
        /// A human-readable prompt title
        public let title: String?

        public init(name: String, title: String? = nil) {
            self.name = name
            self.title = title
        }

        private enum CodingKeys: String, CodingKey {
            case type, name, title
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("ref/prompt", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(title, forKey: .title)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.decode(String.self, forKey: .type)
            name = try container.decode(String.self, forKey: .name)
            title = try container.decodeIfPresent(String.self, forKey: .title)
        }
    }
}

// MARK: - Codable

extension Prompt.Message.Content: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, resource, annotations, _meta
        case uri, name, title, description
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(let type, let block) = self {
            try UnknownBlock.encode(block, kind: type, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .audio(let data, let mimeType):
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .resource(let resourceContent, let annotations, let _meta):
            try container.encode("resource", forKey: .type)
            try container.encode(resourceContent, forKey: .resource)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(_meta, forKey: ._meta)
        case .resourceLink(let uri, let name, let title, let description, let mimeType, let annotations):
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text: text)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        case "audio":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .audio(data: data, mimeType: mimeType)
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
            let annotations = try container.decodeIfPresent(Resource.Annotations.self, forKey: .annotations)
            self = .resourceLink(uri: uri, name: name, title: title, description: description, mimeType: mimeType, annotations: annotations)
        default:
            self = .unknown(type: type, try UnknownBlock.decode(from: decoder))
        }
    }
}

// MARK: - ExpressibleByStringLiteral

extension Prompt.Message.Content: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(text: value)
    }
}

// MARK: - ExpressibleByStringInterpolation

extension Prompt.Message.Content: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .text(text: String(stringInterpolation: stringInterpolation))
    }
}

// MARK: -

/// To retrieve available prompts, clients send a `prompts/list` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/prompts/#listing-prompts
public enum ListPrompts: Method {
    public static let name: String = "prompts/list"

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
        public let prompts: [Prompt]
        public let nextCursor: String?
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        public init(
            prompts: [Prompt],
            nextCursor: String? = nil,
            _meta: Metadata? = nil,
            ttlMs: Int? = nil,
            cacheScope: CacheScope? = nil
        ) {
            self.prompts = prompts
            self.nextCursor = nextCursor
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case prompts, nextCursor, _meta, ttlMs, cacheScope
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(prompts, forKey: .prompts)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
            try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompts = try container.decode([Prompt].self, forKey: .prompts)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
        }
    }
}

/// To retrieve a specific prompt, clients send a `prompts/get` request.
/// Arguments may be auto-completed through the completion API.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/prompts/#getting-a-prompt
public enum GetPrompt: Method {
    public static let name: String = "prompts/get"

    public struct Parameters: Hashable, Codable, Sendable {
        public let name: String
        public let arguments: [String: String]?

        /// The client's responses to the server's input requests, keyed as
        /// the requests were (2026-07-28, SEP-2322).
        public var inputResponses: [String: InputResponse]?

        /// The `requestState` of the previous round, echoed unchanged.
        public var requestState: String?

        public init(
            name: String,
            arguments: [String: String]? = nil,
            inputResponses: [String: InputResponse]? = nil,
            requestState: String? = nil
        ) {
            self.name = name
            self.arguments = arguments
            self.inputResponses = inputResponses
            self.requestState = requestState
        }

        private enum CodingKeys: String, CodingKey {
            case name, arguments, inputResponses, requestState
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments)
            inputResponses = try MRTR.decodeInputResponses(container, forKey: .inputResponses)
            requestState = try container.decodeIfPresent(String.self, forKey: .requestState)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(arguments, forKey: .arguments)
            try container.encodeIfPresent(inputResponses, forKey: .inputResponses)
            try container.encodeIfPresent(requestState, forKey: .requestState)
        }
    }

    /// The prompt, or, at 2026-07-28, a request for more input (see
    /// `inputRequired(_:requestState:_meta:)`).
    public struct Result: Hashable, Codable, Sendable {
        public let description: String?
        public let messages: [Prompt.Message]
        /// Optional metadata about this result
        public var _meta: Metadata?

        /// Requests the client must fulfill before the prompt can be
        /// returned, keyed by names the server chooses (SEP-2322).
        public var inputRequests: [String: InputRequest]?

        /// Opaque state the client echoes on the next round. The server
        /// SDK seals it before it leaves the server.
        public var requestState: String?

        private var declaredResultType: ResultType?

        public init(
            description: String? = nil,
            messages: [Prompt.Message],
            _meta: Metadata? = nil
        ) {
            self.description = description
            self.messages = messages
            self._meta = _meta
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
            var result = Result(messages: [], _meta: _meta)
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
            case description, messages, _meta
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
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(messages, forKey: .messages)
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
                description = nil
                messages = []
                return
            }
            description = try container.decodeIfPresent(String.self, forKey: .description)
            messages = try container.decode([Prompt.Message].self, forKey: .messages)
        }
    }
}

extension GetPrompt.Parameters: InputRespondingParameters {
    var stateBinding: (target: String, arguments: Value) {
        (name, .object((arguments ?? [:]).mapValues(Value.string)))
    }

    func retrying(inputResponses: [String: InputResponse]?, requestState: String?) -> Self {
        var copy = self
        copy.inputResponses = inputResponses
        copy.requestState = requestState
        return copy
    }
}

extension GetPrompt.Result: InputRequiringResult {
    var hasContent: Bool { !messages.isEmpty || description != nil }
}

/// When the list of available prompts changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/prompts/#list-changed-notification
public struct PromptListChangedNotification: Notification {
    public static let name: String = "notifications/prompts/list_changed"
}
