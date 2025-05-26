import Foundation

/// The Model Context Protocol (MCP) allows servers to request LLM completions
/// through the client, enabling sophisticated agentic behaviors while maintaining
/// security and privacy.
///
/// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/sampling#how-sampling-works
public enum Sampling {
    /// A message in the conversation history.
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

        /// Content types for sampling messages
        public enum Content: Hashable, Sendable {
            /// Text content
            case text(String)
            /// Image content
            case image(data: String, mimeType: String)
        }
    }

    /// Model preferences for sampling requests
    public struct ModelPreferences: Hashable, Codable, Sendable {
        /// Model hints for selection
        public struct Hint: Hashable, Codable, Sendable {
            /// Suggested model name/family
            public let name: String?

            public init(name: String? = nil) {
                self.name = name
            }
        }

        /// Array of model name suggestions that clients can use to select an appropriate model
        public let hints: [Hint]?
        /// Importance of minimizing costs (0-1 normalized)
        public let costPriority: UnitInterval?
        /// Importance of low latency response (0-1 normalized)
        public let speedPriority: UnitInterval?
        /// Importance of advanced model capabilities (0-1 normalized)
        public let intelligencePriority: UnitInterval?

        public init(
            hints: [Hint]? = nil,
            costPriority: UnitInterval? = nil,
            speedPriority: UnitInterval? = nil,
            intelligencePriority: UnitInterval? = nil
        ) {
            self.hints = hints
            self.costPriority = costPriority
            self.speedPriority = speedPriority
            self.intelligencePriority = intelligencePriority
        }
    }

    /// Context inclusion options for sampling requests
    public enum ContextInclusion: String, Hashable, Codable, Sendable {
        /// No additional context
        case none
        /// Include context from the requesting server
        case thisServer
        /// Include context from all connected MCP servers
        case allServers
    }

    /// Stop reason for sampling completion
    public enum StopReason: String, Hashable, Codable, Sendable {
        /// Natural end of turn
        case endTurn
        /// Hit a stop sequence
        case stopSequence
        /// Reached maximum tokens
        case maxTokens
    }
}

// MARK: - Codable

extension Sampling.Message.Content: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType
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
            self = .image(data: data, mimeType: mimeType)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown sampling message content type")
        }
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
        }
    }
}

// MARK: - ExpressibleByStringLiteral

extension Sampling.Message.Content: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

// MARK: - ExpressibleByStringInterpolation

extension Sampling.Message.Content: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .text(String(stringInterpolation: stringInterpolation))
    }
}

// MARK: -

/// To request sampling from a client, servers send a `sampling/createMessage` request.
/// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/sampling#how-sampling-works
public enum CreateSamplingMessage: Method {
    public static let name = "sampling/createMessage"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The conversation history to send to the LLM
        public let messages: [Sampling.Message]
        /// Model selection preferences
        public let modelPreferences: Sampling.ModelPreferences?
        /// Optional system prompt
        public let systemPrompt: String?
        /// What MCP context to include
        public let includeContext: Sampling.ContextInclusion?
        /// Controls randomness (0.0 to 1.0)
        public let temperature: Double?
        /// Maximum tokens to generate
        public let maxTokens: Int
        /// Array of sequences that stop generation
        public let stopSequences: [String]?
        /// Additional provider-specific parameters
        public let metadata: [String: Value]?

        public init(
            messages: [Sampling.Message],
            modelPreferences: Sampling.ModelPreferences? = nil,
            systemPrompt: String? = nil,
            includeContext: Sampling.ContextInclusion? = nil,
            temperature: Double? = nil,
            maxTokens: Int,
            stopSequences: [String]? = nil,
            metadata: [String: Value]? = nil
        ) {
            self.messages = messages
            self.modelPreferences = modelPreferences
            self.systemPrompt = systemPrompt
            self.includeContext = includeContext
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.stopSequences = stopSequences
            self.metadata = metadata
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        /// Name of the model used
        public let model: String
        /// Why sampling stopped
        public let stopReason: Sampling.StopReason?
        /// The role of the completion
        public let role: Sampling.Message.Role
        /// The completion content
        public let content: Sampling.Message.Content

        public init(
            model: String,
            stopReason: Sampling.StopReason? = nil,
            role: Sampling.Message.Role,
            content: Sampling.Message.Content
        ) {
            self.model = model
            self.stopReason = stopReason
            self.role = role
            self.content = content
        }
    }
}
