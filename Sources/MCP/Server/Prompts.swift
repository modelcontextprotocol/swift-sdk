import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose prompt templates to clients.
/// Prompts allow servers to provide structured messages and instructions
/// for interacting with language models.
/// Clients can discover available prompts, retrieve their contents,
/// and provide arguments to customize them.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/server/prompts/
public struct Prompt: Hashable, Codable, Sendable {
    /// The prompt name (intended for programmatic or logical use)
    public let name: String
    /// A human-readable title for the prompt, intended for UI display.
    /// If not provided, the `name` should be used for display.
    public let title: String?
    /// The prompt description
    public let description: String?
    /// The prompt arguments
    public let arguments: [Argument]?
    /// Reserved for clients and servers to attach additional metadata.
    public var _meta: [String: Value]?
    /// Optional icons representing this prompt.
    public var icons: [Icon]?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [Argument]? = nil,
        _meta: [String: Value]? = nil,
        icons: [Icon]? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self._meta = _meta
        self.icons = icons
    }

    /// An argument for a prompt
    public struct Argument: Hashable, Codable, Sendable {
        /// The argument name (intended for programmatic or logical use)
        public let name: String
        /// A human-readable title for the argument, intended for UI display.
        /// If not provided, the `name` should be used for display.
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
        // TODO: Deprecate in a future version
        /// Backwards compatibility alias for top-level `Role`.
        public typealias Role = MCP.Role

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

        // TODO: Consider consolidating with Tool.Content into a shared ContentBlock type
        // in a future breaking change release. The spec uses a single ContentBlock type.
        /// Content types for messages.
        ///
        /// Matches the MCP spec (2025-11-25) ContentBlock union:
        /// - TextContent, ImageContent, AudioContent, ResourceLink, EmbeddedResource
        public enum Content: Hashable, Sendable {
            /// Text content
            case text(text: String, annotations: Annotations?, _meta: [String: Value]?)
            /// Image content
            case image(data: String, mimeType: String, annotations: Annotations?, _meta: [String: Value]?)
            /// Audio content
            case audio(data: String, mimeType: String, annotations: Annotations?, _meta: [String: Value]?)
            /// Embedded resource content (includes actual content)
            case resource(resource: Resource.Content, annotations: Annotations?, _meta: [String: Value]?)
            /// Resource link (reference to a resource that can be read)
            case resourceLink(ResourceLink)

            // MARK: - Convenience initializers (backwards compatibility)

            /// Creates text content
            public static func text(_ text: String) -> Content {
                .text(text: text, annotations: nil, _meta: nil)
            }

            /// Creates image content
            public static func image(data: String, mimeType: String) -> Content {
                .image(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
            }

            /// Creates audio content
            public static func audio(data: String, mimeType: String) -> Content {
                .audio(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
            }

            /// Creates embedded resource content with text
            public static func resource(uri: String, mimeType: String? = nil, text: String) -> Content {
                .resource(resource: .text(text, uri: uri, mimeType: mimeType), annotations: nil, _meta: nil)
            }

            /// Creates embedded resource content with binary data
            public static func resource(uri: String, mimeType: String? = nil, blob: Data) -> Content {
                .resource(resource: .binary(blob, uri: uri, mimeType: mimeType), annotations: nil, _meta: nil)
            }
        }
    }

    /// Reference type for prompts
    public struct Reference: Hashable, Codable, Sendable {
        /// The prompt reference name
        public let name: String
        /// A human-readable title for the prompt, intended for UI display.
        /// If not provided, the `name` should be used for display.
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text, let annotations, let meta):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        case .image(let data, let mimeType, let annotations, let meta):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        case .audio(let data, let mimeType, let annotations, let meta):
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        case .resource(let resourceContent, let annotations, let meta):
            try container.encode("resource", forKey: .type)
            try container.encode(resourceContent, forKey: .resource)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        case .resourceLink(let link):
            try link.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
            let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            self = .text(text: text, annotations: annotations, _meta: meta)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
            let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            self = .image(data: data, mimeType: mimeType, annotations: annotations, _meta: meta)
        case "audio":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
            let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            self = .audio(data: data, mimeType: mimeType, annotations: annotations, _meta: meta)
        case "resource":
            let resourceContent = try container.decode(Resource.Content.self, forKey: .resource)
            let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
            let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            self = .resource(resource: resourceContent, annotations: annotations, _meta: meta)
        case "resource_link":
            let link = try ResourceLink(from: decoder)
            self = .resourceLink(link)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type")
        }
    }
}

// MARK: - ExpressibleByStringLiteral

extension Prompt.Message.Content: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(text: value, annotations: nil, _meta: nil)
    }
}

// MARK: - ExpressibleByStringInterpolation

extension Prompt.Message.Content: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .text(text: String(stringInterpolation: stringInterpolation), annotations: nil, _meta: nil)
    }
}

// MARK: -

/// To retrieve available prompts, clients send a `prompts/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#listing-prompts
public enum ListPrompts: Method {
    public static let name: String = "prompts/list"

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

        public let prompts: [Prompt]
        public let nextCursor: String?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            prompts: [Prompt],
            nextCursor: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.prompts = prompts
            self.nextCursor = nextCursor
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case prompts, nextCursor, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompts = try container.decode([Prompt].self, forKey: .prompts)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(prompts, forKey: .prompts)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// To retrieve a specific prompt, clients send a `prompts/get` request.
/// Arguments may be auto-completed through the completion API.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#getting-a-prompt
public enum GetPrompt: Method {
    public static let name: String = "prompts/get"

    public struct Parameters: Hashable, Codable, Sendable {
        public let name: String
        /// Arguments to use for templating the prompt.
        /// Per the MCP spec, argument values must be strings.
        public let arguments: [String: String]?
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(name: String, arguments: [String: String]? = nil, _meta: RequestMeta? = nil) {
            self.name = name
            self.arguments = arguments
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let description: String?
        public let messages: [Prompt.Message]
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            description: String?,
            messages: [Prompt.Message],
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.description = description
            self.messages = messages
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case description, messages, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            messages = try container.decode([Prompt.Message].self, forKey: .messages)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// When the list of available prompts changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#list-changed-notification
public struct PromptListChangedNotification: Notification {
    public static let name: String = "notifications/prompts/list_changed"

    public typealias Parameters = NotificationParams
}
