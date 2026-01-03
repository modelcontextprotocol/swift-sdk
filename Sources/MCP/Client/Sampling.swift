import Foundation

/// Controls how the model uses tools during sampling.
///
/// This allows servers to influence whether the model should use tools in its response.
/// The client may ignore this preference if it doesn't support the requested mode.
public struct ToolChoice: Hashable, Codable, Sendable {
    /// How tools should be used during sampling.
    public enum Mode: String, Hashable, Codable, Sendable {
        /// Model decides whether to use tools (default).
        case auto
        /// Model MUST use at least one tool before completing.
        case required
        /// Model MUST NOT use any tools.
        case none
    }

    /// The tool choice mode. If nil, defaults to `.auto`.
    public var mode: Mode?

    public init(mode: Mode? = nil) {
        self.mode = mode
    }
}

/// Stop reason for sampling completion.
///
/// This is an open string type to allow for provider-specific stop reasons.
/// Standard values are: `endTurn`, `stopSequence`, `maxTokens`, `toolUse`.
public struct StopReason: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Natural end of turn
    public static let endTurn = StopReason(rawValue: "endTurn")
    /// Hit a stop sequence
    public static let stopSequence = StopReason(rawValue: "stopSequence")
    /// Reached maximum tokens
    public static let maxTokens = StopReason(rawValue: "maxTokens")
    /// Model decided to use a tool
    public static let toolUse = StopReason(rawValue: "toolUse")
}

/// Model preferences for sampling requests.
public struct ModelPreferences: Hashable, Codable, Sendable {
    /// A hint suggesting a model name or family.
    public struct Hint: Hashable, Codable, Sendable {
        public let name: String?
        public init(name: String? = nil) { self.name = name }
    }

    public let hints: [Hint]?
    public let costPriority: UnitInterval?
    public let speedPriority: UnitInterval?
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

// MARK: - Sampling Namespace

/// The Model Context Protocol (MCP) allows servers to request LLM completions
/// through the client, enabling sophisticated agentic behaviors while maintaining
/// security and privacy.
public enum Sampling {
    /// A message in the conversation history.
    public struct Message: Hashable, Codable, Sendable {
        public typealias Role = MCP.Role

        public let role: Role
        public let content: [ContentBlock]
        public var _meta: [String: Value]?

        public init(role: Role, content: ContentBlock, _meta: [String: Value]? = nil) {
            self.role = role
            self.content = [content]
            self._meta = _meta
        }

        public init(role: Role, content: [ContentBlock], _meta: [String: Value]? = nil) {
            self.role = role
            self.content = content
            self._meta = _meta
        }

        public static func user(_ content: ContentBlock) -> Message {
            Message(role: .user, content: content)
        }

        public static func user(_ content: [ContentBlock]) -> Message {
            Message(role: .user, content: content)
        }

        public static func assistant(_ content: ContentBlock) -> Message {
            Message(role: .assistant, content: content)
        }

        public static func assistant(_ content: [ContentBlock]) -> Message {
            Message(role: .assistant, content: content)
        }

        private enum CodingKeys: String, CodingKey {
            case role, content, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(Role.self, forKey: .role)

            // Content can be a single block or an array of blocks
            if var arrayContainer = try? container.nestedUnkeyedContainer(forKey: .content) {
                var blocks: [ContentBlock] = []
                while !arrayContainer.isAtEnd {
                    blocks.append(try arrayContainer.decode(ContentBlock.self))
                }
                content = blocks
            } else {
                content = [try container.decode(ContentBlock.self, forKey: .content)]
            }

            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)

            // Encode as single object if one block, array if multiple
            if content.count == 1, let block = content.first {
                try container.encode(block, forKey: .content)
            } else {
                try container.encode(content, forKey: .content)
            }

            try container.encodeIfPresent(_meta, forKey: ._meta)
        }

        /// Content block types for sampling messages.
        public enum ContentBlock: Hashable, Sendable {
            case text(String, annotations: Annotations?, _meta: [String: Value]?)
            case image(data: String, mimeType: String, annotations: Annotations?, _meta: [String: Value]?)
            case audio(data: String, mimeType: String, annotations: Annotations?, _meta: [String: Value]?)
            case toolUse(ToolUseContent)
            case toolResult(ToolResultContent)

            public static func text(_ text: String) -> ContentBlock {
                .text(text, annotations: nil, _meta: nil)
            }

            public static func image(data: String, mimeType: String) -> ContentBlock {
                .image(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
            }

            public static func audio(data: String, mimeType: String) -> ContentBlock {
                .audio(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
            }

            /// Whether this is a basic content type (text, image, or audio).
            public var isBasicContent: Bool {
                switch self {
                case .text, .image, .audio: return true
                case .toolUse, .toolResult: return false
                }
            }
        }
    }

    public typealias ModelPreferences = MCP.ModelPreferences

    public enum ContextInclusion: String, Hashable, Codable, Sendable {
        case none
        case thisServer
        case allServers
    }

    public typealias StopReason = MCP.StopReason
}

// MARK: - Tool Use Content

public struct ToolUseContent: Hashable, Codable, Sendable {
    public let type: String
    public var name: String
    public var id: String
    public var input: [String: Value]
    public var _meta: [String: Value]?

    public init(name: String, id: String, input: [String: Value], _meta: [String: Value]? = nil) {
        self.type = "tool_use"
        self.name = name
        self.id = id
        self.input = input
        self._meta = _meta
    }
}

public struct ToolResultContent: Hashable, Codable, Sendable {
    public let type: String
    public var toolUseId: String
    public var content: [Tool.Content]
    public var structuredContent: Value?
    public var isError: Bool?
    public var _meta: [String: Value]?

    public init(
        toolUseId: String,
        content: [Tool.Content] = [],
        structuredContent: Value? = nil,
        isError: Bool? = nil,
        _meta: [String: Value]? = nil
    ) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self._meta = _meta
    }
}

// MARK: - ContentBlock Codable

extension Sampling.Message.ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, annotations, _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(
                try container.decode(String.self, forKey: .text),
                annotations: try container.decodeIfPresent(Annotations.self, forKey: .annotations),
                _meta: try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            )
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType),
                annotations: try container.decodeIfPresent(Annotations.self, forKey: .annotations),
                _meta: try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            )
        case "audio":
            self = .audio(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType),
                annotations: try container.decodeIfPresent(Annotations.self, forKey: .annotations),
                _meta: try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            )
        case "tool_use":
            self = .toolUse(try ToolUseContent(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultContent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text, let annotations, let meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        case .image(let data, let mimeType, let annotations, let meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        case .audio(let data, let mimeType, let annotations, let meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        case .toolUse(let toolUse):
            try toolUse.encode(to: encoder)
        case .toolResult(let toolResult):
            try toolResult.encode(to: encoder)
        }
    }
}

extension Sampling.Message.ContentBlock: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value, annotations: nil, _meta: nil)
    }
}

extension Sampling.Message.ContentBlock: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .text(String(stringInterpolation: stringInterpolation), annotations: nil, _meta: nil)
    }
}

extension Sampling.Message {
    /// Type alias for backwards compatibility.
    @available(*, deprecated, renamed: "ContentBlock")
    public typealias Content = ContentBlock
}

// MARK: - Sampling Request Parameters (Shared Base)

/// Common parameters for sampling requests.
///
/// This struct contains all the shared fields between tool and non-tool sampling requests.
public struct SamplingParameters: Hashable, Codable, Sendable {
    public let messages: [Sampling.Message]
    public let modelPreferences: Sampling.ModelPreferences?
    public let systemPrompt: String?
    public let includeContext: Sampling.ContextInclusion?
    public let temperature: Double?
    public let maxTokens: Int
    public let stopSequences: [String]?
    public let metadata: [String: Value]?
    public var _meta: RequestMeta?
    public var task: TaskMetadata?

    public init(
        messages: [Sampling.Message],
        modelPreferences: Sampling.ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        maxTokens: Int,
        stopSequences: [String]? = nil,
        metadata: [String: Value]? = nil,
        _meta: RequestMeta? = nil,
        task: TaskMetadata? = nil
    ) {
        self.messages = messages
        self.modelPreferences = modelPreferences
        self.systemPrompt = systemPrompt
        self.includeContext = includeContext
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.metadata = metadata
        self._meta = _meta
        self.task = task
    }
}

// MARK: - CreateSamplingMessage (without tools)

/// Request sampling from a client without tool support.
///
/// The result will be a single content block (text, image, or audio).
/// For tool-enabled sampling, use `CreateSamplingMessageWithTools` instead.
public enum CreateSamplingMessage: Method {
    public static let name = "sampling/createMessage"

    /// Alias for shared parameters (no tools).
    public typealias Parameters = SamplingParameters

    /// Result for a sampling request without tools.
    /// Content is a single basic block (text, image, or audio).
    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let model: String
        public let stopReason: StopReason?
        public let role: Role
        /// Single content block (text, image, or audio - no tool use).
        public let content: Sampling.Message.ContentBlock
        public var _meta: [String: Value]?
        public var extraFields: [String: Value]?

        public init(
            model: String,
            stopReason: StopReason? = nil,
            role: Role,
            content: Sampling.Message.ContentBlock,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.model = model
            self.stopReason = stopReason
            self.role = role
            self.content = content
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case model, stopReason, role, content, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            stopReason = try container.decodeIfPresent(StopReason.self, forKey: .stopReason)
            role = try container.decode(Role.self, forKey: .role)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)

            // MCP spec allows content to be either a single block or an array.
            // Try to decode as array first, then fall back to single block.
            if var arrayContainer = try? container.nestedUnkeyedContainer(forKey: .content) {
                var blocks: [Sampling.Message.ContentBlock] = []
                while !arrayContainer.isAtEnd {
                    blocks.append(try arrayContainer.decode(Sampling.Message.ContentBlock.self))
                }
                guard let firstBlock = blocks.first else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .content, in: container,
                        debugDescription: "Content array is empty")
                }
                content = firstBlock
            } else {
                content = try container.decode(Sampling.Message.ContentBlock.self, forKey: .content)
            }

            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

// MARK: - CreateSamplingMessageWithTools

/// Request sampling from a client with tool support.
///
/// The result may contain tool use content, and content can be an array for parallel tool calls.
/// Requires `ClientCapabilities.sampling.tools` to be declared.
public enum CreateSamplingMessageWithTools: Method {
    public static let name = "sampling/createMessage"

    /// Parameters for a sampling request with tools.
    public struct Parameters: Hashable, Codable, Sendable {
        /// Base sampling parameters.
        public let base: SamplingParameters
        /// Tools that the model may use during generation.
        public let tools: [Tool]
        /// Controls how the model uses tools.
        public let toolChoice: ToolChoice?

        // Convenience accessors
        public var messages: [Sampling.Message] { base.messages }
        public var modelPreferences: Sampling.ModelPreferences? { base.modelPreferences }
        public var systemPrompt: String? { base.systemPrompt }
        public var includeContext: Sampling.ContextInclusion? { base.includeContext }
        public var temperature: Double? { base.temperature }
        public var maxTokens: Int { base.maxTokens }
        public var stopSequences: [String]? { base.stopSequences }
        public var metadata: [String: Value]? { base.metadata }
        public var _meta: RequestMeta? { base._meta }
        public var task: TaskMetadata? { base.task }

        public init(
            messages: [Sampling.Message],
            modelPreferences: Sampling.ModelPreferences? = nil,
            systemPrompt: String? = nil,
            includeContext: Sampling.ContextInclusion? = nil,
            temperature: Double? = nil,
            maxTokens: Int,
            stopSequences: [String]? = nil,
            metadata: [String: Value]? = nil,
            tools: [Tool],
            toolChoice: ToolChoice? = nil,
            _meta: RequestMeta? = nil,
            task: TaskMetadata? = nil
        ) {
            self.base = SamplingParameters(
                messages: messages,
                modelPreferences: modelPreferences,
                systemPrompt: systemPrompt,
                includeContext: includeContext,
                temperature: temperature,
                maxTokens: maxTokens,
                stopSequences: stopSequences,
                metadata: metadata,
                _meta: _meta,
                task: task
            )
            self.tools = tools
            self.toolChoice = toolChoice
        }

        // Custom coding to flatten the structure
        private enum CodingKeys: String, CodingKey {
            case messages, modelPreferences, systemPrompt, includeContext
            case temperature, maxTokens, stopSequences, metadata
            case tools, toolChoice, _meta, task
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            base = SamplingParameters(
                messages: try container.decode([Sampling.Message].self, forKey: .messages),
                modelPreferences: try container.decodeIfPresent(Sampling.ModelPreferences.self, forKey: .modelPreferences),
                systemPrompt: try container.decodeIfPresent(String.self, forKey: .systemPrompt),
                includeContext: try container.decodeIfPresent(Sampling.ContextInclusion.self, forKey: .includeContext),
                temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
                maxTokens: try container.decode(Int.self, forKey: .maxTokens),
                stopSequences: try container.decodeIfPresent([String].self, forKey: .stopSequences),
                metadata: try container.decodeIfPresent([String: Value].self, forKey: .metadata),
                _meta: try container.decodeIfPresent(RequestMeta.self, forKey: ._meta),
                task: try container.decodeIfPresent(TaskMetadata.self, forKey: .task)
            )
            tools = try container.decode([Tool].self, forKey: .tools)
            toolChoice = try container.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base.messages, forKey: .messages)
            try container.encodeIfPresent(base.modelPreferences, forKey: .modelPreferences)
            try container.encodeIfPresent(base.systemPrompt, forKey: .systemPrompt)
            try container.encodeIfPresent(base.includeContext, forKey: .includeContext)
            try container.encodeIfPresent(base.temperature, forKey: .temperature)
            try container.encode(base.maxTokens, forKey: .maxTokens)
            try container.encodeIfPresent(base.stopSequences, forKey: .stopSequences)
            try container.encodeIfPresent(base.metadata, forKey: .metadata)
            try container.encode(tools, forKey: .tools)
            try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
            try container.encodeIfPresent(base._meta, forKey: ._meta)
            try container.encodeIfPresent(base.task, forKey: .task)
        }
    }

    /// Result for a sampling request with tools.
    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let model: String
        public let stopReason: StopReason?
        public let role: Role
        public let content: [Sampling.Message.ContentBlock]
        public var _meta: [String: Value]?
        public var extraFields: [String: Value]?

        public init(
            model: String,
            stopReason: StopReason? = nil,
            role: Role,
            content: Sampling.Message.ContentBlock,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.model = model
            self.stopReason = stopReason
            self.role = role
            self.content = [content]
            self._meta = _meta
            self.extraFields = extraFields
        }

        public init(
            model: String,
            stopReason: StopReason? = nil,
            role: Role,
            content: [Sampling.Message.ContentBlock],
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.model = model
            self.stopReason = stopReason
            self.role = role
            self.content = content
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case model, stopReason, role, content, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            stopReason = try container.decodeIfPresent(StopReason.self, forKey: .stopReason)
            role = try container.decode(Role.self, forKey: .role)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)

            if var arrayContainer = try? container.nestedUnkeyedContainer(forKey: .content) {
                var blocks: [Sampling.Message.ContentBlock] = []
                while !arrayContainer.isAtEnd {
                    blocks.append(try arrayContainer.decode(Sampling.Message.ContentBlock.self))
                }
                content = blocks
            } else {
                content = [try container.decode(Sampling.Message.ContentBlock.self, forKey: .content)]
            }

            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
            try container.encode(role, forKey: .role)
            try container.encodeIfPresent(_meta, forKey: ._meta)

            if content.count == 1, let block = content.first {
                try container.encode(block, forKey: .content)
            } else {
                try container.encode(content, forKey: .content)
            }

            try encodeExtraFields(to: encoder)
        }
    }
}

// MARK: - Client-Side Sampling Handler

/// Parameters for client-side handling of sampling requests.
///
/// This extends the base parameters with optional tools for client-side flexibility.
public struct ClientSamplingParameters: Hashable, Codable, Sendable {
    public let base: SamplingParameters
    public let tools: [Tool]?
    public let toolChoice: ToolChoice?

    // Convenience accessors
    public var messages: [Sampling.Message] { base.messages }
    public var modelPreferences: Sampling.ModelPreferences? { base.modelPreferences }
    public var systemPrompt: String? { base.systemPrompt }
    public var includeContext: Sampling.ContextInclusion? { base.includeContext }
    public var temperature: Double? { base.temperature }
    public var maxTokens: Int { base.maxTokens }
    public var stopSequences: [String]? { base.stopSequences }
    public var metadata: [String: Value]? { base.metadata }
    public var _meta: RequestMeta? { base._meta }
    public var task: TaskMetadata? { base.task }

    /// Whether this request includes tool support.
    public var hasTools: Bool {
        tools != nil && !(tools?.isEmpty ?? true)
    }

    public init(
        messages: [Sampling.Message],
        modelPreferences: Sampling.ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        maxTokens: Int,
        stopSequences: [String]? = nil,
        metadata: [String: Value]? = nil,
        tools: [Tool]? = nil,
        toolChoice: ToolChoice? = nil,
        _meta: RequestMeta? = nil,
        task: TaskMetadata? = nil
    ) {
        self.base = SamplingParameters(
            messages: messages,
            modelPreferences: modelPreferences,
            systemPrompt: systemPrompt,
            includeContext: includeContext,
            temperature: temperature,
            maxTokens: maxTokens,
            stopSequences: stopSequences,
            metadata: metadata,
            _meta: _meta,
            task: task
        )
        self.tools = tools
        self.toolChoice = toolChoice
    }

    private enum CodingKeys: String, CodingKey {
        case messages, modelPreferences, systemPrompt, includeContext
        case temperature, maxTokens, stopSequences, metadata
        case tools, toolChoice, _meta, task
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = SamplingParameters(
            messages: try container.decode([Sampling.Message].self, forKey: .messages),
            modelPreferences: try container.decodeIfPresent(Sampling.ModelPreferences.self, forKey: .modelPreferences),
            systemPrompt: try container.decodeIfPresent(String.self, forKey: .systemPrompt),
            includeContext: try container.decodeIfPresent(Sampling.ContextInclusion.self, forKey: .includeContext),
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
            maxTokens: try container.decode(Int.self, forKey: .maxTokens),
            stopSequences: try container.decodeIfPresent([String].self, forKey: .stopSequences),
            metadata: try container.decodeIfPresent([String: Value].self, forKey: .metadata),
            _meta: try container.decodeIfPresent(RequestMeta.self, forKey: ._meta),
            task: try container.decodeIfPresent(TaskMetadata.self, forKey: .task)
        )
        tools = try container.decodeIfPresent([Tool].self, forKey: .tools)
        toolChoice = try container.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base.messages, forKey: .messages)
        try container.encodeIfPresent(base.modelPreferences, forKey: .modelPreferences)
        try container.encodeIfPresent(base.systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(base.includeContext, forKey: .includeContext)
        try container.encodeIfPresent(base.temperature, forKey: .temperature)
        try container.encode(base.maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(base.stopSequences, forKey: .stopSequences)
        try container.encodeIfPresent(base.metadata, forKey: .metadata)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encodeIfPresent(base._meta, forKey: ._meta)
        try container.encodeIfPresent(base.task, forKey: .task)
    }
}

/// Method type for client-side handling of sampling requests.
public enum ClientSamplingRequest: Method {
    public static let name = "sampling/createMessage"
    public typealias Parameters = ClientSamplingParameters
    /// Reuse the tools-capable result type.
    public typealias Result = CreateSamplingMessageWithTools.Result
}

// MARK: - Message Validation

extension Sampling.Message {
    /// Validates the structure of tool_use/tool_result messages.
    public static func validateToolUseResultMessages(_ messages: [Sampling.Message]) throws {
        guard !messages.isEmpty else { return }

        let lastContent = messages[messages.count - 1].content
        let hasToolResults = lastContent.contains { if case .toolResult = $0 { return true }; return false }

        let previousContent: [ContentBlock]? = messages.count >= 2 ? messages[messages.count - 2].content : nil
        let hasPreviousToolUse = previousContent?.contains { if case .toolUse = $0 { return true }; return false } ?? false

        if hasToolResults {
            let hasNonToolResult = lastContent.contains { if case .toolResult = $0 { return false }; return true }
            if hasNonToolResult {
                throw MCPError.invalidParams("The last message must contain only tool_result content if any is present")
            }

            guard previousContent != nil else {
                throw MCPError.invalidParams("tool_result requires a previous message containing tool_use")
            }

            if !hasPreviousToolUse {
                throw MCPError.invalidParams("tool_result blocks do not match any tool_use in the previous message")
            }
        }

        if hasPreviousToolUse, let previousContent {
            let toolUseIds = Set(previousContent.compactMap { if case .toolUse(let c) = $0 { return c.id }; return nil })
            let toolResultIds = Set(lastContent.compactMap { if case .toolResult(let c) = $0 { return c.toolUseId }; return nil })

            if toolUseIds != toolResultIds {
                throw MCPError.invalidParams("IDs of tool_result blocks and tool_use blocks from previous message do not match")
            }
        }
    }
}
