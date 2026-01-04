import Foundation

extension Client {
    // MARK: - Prompts

    public func getPrompt(name: String, arguments: [String: String]? = nil) async throws
    -> (description: String?, messages: [Prompt.Message])
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
        return (description: result.description, messages: result.messages)
    }

    public func listPrompts(cursor: String? = nil) async throws
    -> (prompts: [Prompt], nextCursor: String?)
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request: Request<ListPrompts>
        if let cursor = cursor {
            request = ListPrompts.request(.init(cursor: cursor))
        } else {
            request = ListPrompts.request(.init())
        }
        let result = try await send(request)
        return (prompts: result.prompts, nextCursor: result.nextCursor)
    }

    // MARK: - Resources

    public func readResource(uri: String) async throws -> [Resource.Content] {
        try validateServerCapability(\.resources, "Resources")
        let request = ReadResource.request(.init(uri: uri))
        let result = try await send(request)
        return result.contents
    }

    public func listResources(cursor: String? = nil) async throws -> (
        resources: [Resource], nextCursor: String?
    ) {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResources>
        if let cursor = cursor {
            request = ListResources.request(.init(cursor: cursor))
        } else {
            request = ListResources.request(.init())
        }
        let result = try await send(request)
        return (resources: result.resources, nextCursor: result.nextCursor)
    }

    public func subscribeToResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    public func unsubscribeFromResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceUnsubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    public func listResourceTemplates(cursor: String? = nil) async throws -> (
        templates: [Resource.Template], nextCursor: String?
    ) {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResourceTemplates>
        if let cursor = cursor {
            request = ListResourceTemplates.request(.init(cursor: cursor))
        } else {
            request = ListResourceTemplates.request(.init())
        }
        let result = try await send(request)
        return (templates: result.templates, nextCursor: result.nextCursor)
    }

    // MARK: - Tools

    public func listTools(cursor: String? = nil) async throws -> (
        tools: [Tool], nextCursor: String?
    ) {
        try validateServerCapability(\.tools, "Tools")
        let request: Request<ListTools>
        if let cursor = cursor {
            request = ListTools.request(.init(cursor: cursor))
        } else {
            request = ListTools.request(.init())
        }
        let result = try await send(request)
        return (tools: result.tools, nextCursor: result.nextCursor)
    }

    public func callTool(name: String, arguments: [String: Value]? = nil) async throws -> (
        content: [Tool.Content], structuredContent: Value?, isError: Bool?
    ) {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
        // TODO: Add client-side output validation against the tool's outputSchema.
        // TypeScript and Python SDKs cache tool outputSchemas from listTools() and
        // validate structuredContent when receiving tool results.
        return (content: result.content, structuredContent: result.structuredContent, isError: result.isError)
    }

    // MARK: - Completions

    /// Request completion suggestions from the server.
    ///
    /// Completions provide autocomplete suggestions for prompt arguments or resource
    /// template URI parameters.
    ///
    /// - Parameters:
    ///   - ref: A reference to the prompt or resource template to get completions for.
    ///   - argument: The argument being completed, including its name and partial value.
    ///   - context: Optional additional context with previously-resolved argument values.
    /// - Returns: The completion suggestions from the server.
    public func complete(
        ref: CompletionReference,
        argument: CompletionArgument,
        context: CompletionContext? = nil
    ) async throws -> CompletionSuggestions {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(.init(ref: ref, argument: argument, context: context))
        let result = try await send(request)
        return result.completion
    }

    // MARK: - Logging

    /// Set the minimum log level for messages from the server.
    ///
    /// After calling this method, the server should only send log messages
    /// at the specified level or higher (more severe).
    ///
    /// - Parameter level: The minimum log level to receive.
    public func setLoggingLevel(_ level: LoggingLevel) async throws {
        try validateServerCapability(\.logging, "Logging")
        let request = SetLoggingLevel.request(.init(level: level))
        _ = try await send(request)
    }
}
