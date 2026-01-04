import Foundation

extension Client {
    // MARK: - Prompts

    /// Get a prompt by name.
    ///
    /// - Parameters:
    ///   - name: The name of the prompt to retrieve.
    ///   - arguments: Optional arguments to pass to the prompt.
    /// - Returns: The prompt result containing description and messages.
    public func getPrompt(name: String, arguments: [String: String]? = nil) async throws
        -> GetPrompt.Result
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        return try await send(request)
    }

    /// List available prompts from the server.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing prompts and optional next cursor.
    public func listPrompts(cursor: String? = nil) async throws -> ListPrompts.Result {
        try validateServerCapability(\.prompts, "Prompts")
        let request: Request<ListPrompts>
        if let cursor {
            request = ListPrompts.request(.init(cursor: cursor))
        } else {
            request = ListPrompts.request(.init())
        }
        return try await send(request)
    }

    // MARK: - Resources

    /// Read a resource by URI.
    ///
    /// - Parameter uri: The URI of the resource to read.
    /// - Returns: The read result containing resource contents.
    public func readResource(uri: String) async throws -> ReadResource.Result {
        try validateServerCapability(\.resources, "Resources")
        let request = ReadResource.request(.init(uri: uri))
        return try await send(request)
    }

    /// List available resources from the server.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing resources and optional next cursor.
    public func listResources(cursor: String? = nil) async throws -> ListResources.Result {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResources>
        if let cursor {
            request = ListResources.request(.init(cursor: cursor))
        } else {
            request = ListResources.request(.init())
        }
        return try await send(request)
    }

    /// Subscribe to updates for a resource.
    ///
    /// - Parameter uri: The URI of the resource to subscribe to.
    public func subscribeToResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    /// Unsubscribe from updates for a resource.
    ///
    /// - Parameter uri: The URI of the resource to unsubscribe from.
    public func unsubscribeFromResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceUnsubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    /// List available resource templates from the server.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing templates and optional next cursor.
    public func listResourceTemplates(cursor: String? = nil) async throws
        -> ListResourceTemplates.Result
    {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResourceTemplates>
        if let cursor {
            request = ListResourceTemplates.request(.init(cursor: cursor))
        } else {
            request = ListResourceTemplates.request(.init())
        }
        return try await send(request)
    }

    // MARK: - Tools

    /// List available tools from the server.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing tools and optional next cursor.
    public func listTools(cursor: String? = nil) async throws -> ListTools.Result {
        try validateServerCapability(\.tools, "Tools")
        let request: Request<ListTools>
        if let cursor {
            request = ListTools.request(.init(cursor: cursor))
        } else {
            request = ListTools.request(.init())
        }
        return try await send(request)
    }

    /// Call a tool by name.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Optional arguments to pass to the tool.
    /// - Returns: The tool call result containing content, structured content, and error flag.
    public func callTool(name: String, arguments: [String: Value]? = nil) async throws
        -> CallTool.Result
    {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments))
        // TODO: Add client-side output validation against the tool's outputSchema.
        // TypeScript and Python SDKs cache tool outputSchemas from listTools() and
        // validate structuredContent when receiving tool results.
        return try await send(request)
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
    /// - Returns: The completion result from the server.
    public func complete(
        ref: CompletionReference,
        argument: CompletionArgument,
        context: CompletionContext? = nil
    ) async throws -> Complete.Result {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(.init(ref: ref, argument: argument, context: context))
        return try await send(request)
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
