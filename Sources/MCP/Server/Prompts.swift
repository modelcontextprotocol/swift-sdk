import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose prompt templates to clients.
/// Prompts allow servers to provide structured messages and instructions
/// for interacting with language models.
/// Clients can discover available prompts, retrieve their contents,
/// and provide arguments to customize them.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/
public struct Prompt: Hashable, Codable, Sendable {
    /// The prompt name
    public let name: String
    /// The prompt description
    public let description: String?
    /// The prompt arguments
    public let arguments: [Argument]?

    public init(name: String, description: String? = nil, arguments: [Argument]? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }

    /// An argument for a prompt
    public struct Argument: Hashable, Codable, Sendable {
        /// The argument name
        public let name: String
        /// The argument description
        public let description: String?
        /// Whether the argument is required
        public let required: Bool?

        public init(name: String, description: String? = nil, required: Bool? = nil) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    /// A message in a prompt
    public struct Message: Hashable, Codable, Sendable {
        /// The message role
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

        public init(role: Role, content: Content) {
            self.role = role
            self.content = content
        }

        /// Content types for messages
        public enum Content: Hashable, Codable, Sendable {
            /// Text content
            case text(text: String)
            /// Image content
            case image(data: String, mimeType: String)
            /// Audio content
            case audio(data: String, mimeType: String)
            /// Embedded resource content
            case resource(uri: String, mimeType: String, text: String?, blob: String?)

            private enum CodingKeys: String, CodingKey {
                case type, text, data, mimeType, uri, blob
            }

            public func encode(to encoder: Encoder) throws {
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
                case .resource(let uri, let mimeType, let text, let blob):
                    try container.encode("resource", forKey: .type)
                    try container.encode(uri, forKey: .uri)
                    try container.encode(mimeType, forKey: .mimeType)
                    try container.encodeIfPresent(text, forKey: .text)
                    try container.encodeIfPresent(blob, forKey: .blob)
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
                    let uri = try container.decode(String.self, forKey: .uri)
                    let mimeType = try container.decode(String.self, forKey: .mimeType)
                    let text = try container.decodeIfPresent(String.self, forKey: .text)
                    let blob = try container.decodeIfPresent(String.self, forKey: .blob)
                    self = .resource(uri: uri, mimeType: mimeType, text: text, blob: blob)
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Unknown content type")
                }
            }
        }
    }

    /// Reference type for prompts
    public struct Reference: Hashable, Codable, Sendable {
        /// The prompt reference name
        public let name: String

        public init(name: String) {
            self.name = name
        }

        private enum CodingKeys: String, CodingKey {
            case type, name
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("ref/prompt", forKey: .type)
            try container.encode(name, forKey: .name)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.decode(String.self, forKey: .type)
            name = try container.decode(String.self, forKey: .name)
        }
    }
}

// MARK: -

/// To retrieve available prompts, clients send a `prompts/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#listing-prompts
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

    public struct Result: Hashable, Codable, Sendable {
        public let prompts: [Prompt]
        public let nextCursor: String?

        public init(prompts: [Prompt], nextCursor: String? = nil) {
            self.prompts = prompts
            self.nextCursor = nextCursor
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
        public let arguments: [String: Value]?

        public init(name: String, arguments: [String: Value]? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let description: String?
        public let messages: [Prompt.Message]

        public init(description: String?, messages: [Prompt.Message]) {
            self.description = description
            self.messages = messages
        }
    }
}

/// When the list of available prompts changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#list-changed-notification
public struct PromptListChangedNotification: Notification {
    public static let name: String = "notifications/prompts/list_changed"
}
