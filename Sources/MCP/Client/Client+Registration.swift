import Foundation

extension Client {
    // MARK: - Handler Registration

    /// Register a handler for a notification
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self {
        notificationHandlers[N.name, default: []].append(TypedNotificationHandler(handler))
        return self
    }

    /// Send a notification to the server
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a progress notification to the server.
    ///
    /// This is a convenience method for sending progress notifications from the client
    /// to the server. This enables bidirectional progress reporting where clients can
    /// inform servers about their own progress (e.g., during client-side processing).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Client reports its own progress to the server
    /// try await client.sendProgressNotification(
    ///     token: .string("client-task-123"),
    ///     progress: 50.0,
    ///     total: 100.0,
    ///     message: "Processing client-side data..."
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - token: The progress token to associate with this notification
    ///   - progress: The current progress value (should increase monotonically)
    ///   - total: The total progress value, if known
    ///   - message: An optional human-readable message describing current progress
    public func sendProgressNotification(
        token: ProgressToken,
        progress: Double,
        total: Double? = nil,
        message: String? = nil
    ) async throws {
        try await notify(ProgressNotification.message(.init(
            progressToken: token,
            progress: progress,
            total: total,
            message: message
        )))
    }

    /// Send a notification that the list of available roots has changed.
    ///
    /// Servers that receive this notification should request an updated
    /// list of roots via the roots/list request.
    ///
    /// - Throws: `MCPError.invalidRequest` if the client has not declared
    ///   the `roots.listChanged` capability.
    public func sendRootsChanged() async throws {
        guard capabilities.roots?.listChanged == true else {
            throw MCPError.invalidRequest(
                "Client does not support roots.listChanged capability")
        }
        try await notify(RootsListChangedNotification.message(.init()))
    }

    /// Register a handler for server→client requests.
    ///
    /// This enables bidirectional communication where the server can send requests
    /// to the client (e.g., sampling, roots, elicitation).
    ///
    /// - Parameters:
    ///   - type: The method type to handle
    ///   - handler: The handler function that receives parameters and returns a result
    /// - Returns: Self for chaining
    @discardableResult
    public func withRequestHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        requestHandlers[M.name] = TypedClientRequestHandler<M>(handler)
        return self
    }

    /// Register a handler for `roots/list` requests from the server.
    ///
    /// When the server requests the list of roots, this handler will be called
    /// to provide the available filesystem directories.
    ///
    /// - Important: The client must have declared `roots` capability during initialization.
    ///
    /// - Parameter handler: A closure that returns the list of available roots.
    /// - Returns: Self for chaining.
    /// - Precondition: `capabilities.roots` must be non-nil.
    @discardableResult
    public func withRootsHandler(
        _ handler: @escaping @Sendable () async throws -> [Root]
    ) -> Self {
        precondition(
            capabilities.roots != nil,
            "Cannot register roots handler: Client does not have roots capability"
        )
        return withRequestHandler(ListRoots.self) { _ in
            ListRoots.Result(roots: try await handler())
        }
    }

    /// Register a handler for `sampling/createMessage` requests from the server.
    ///
    /// When the server requests a sampling completion, this handler will be called
    /// to generate the LLM response.
    ///
    /// The handler receives parameters that may or may not include tools. Check `params.hasTools`
    /// to determine if tool use is enabled for this request.
    ///
    /// - Important: The client must have declared `sampling` capability during initialization.
    ///
    /// ## Example
    ///
    /// ```swift
    /// client.withSamplingHandler { params in
    ///     // Call your LLM with the messages
    ///     let response = try await llm.complete(
    ///         messages: params.messages,
    ///         tools: params.tools,  // May be nil
    ///         maxTokens: params.maxTokens
    ///     )
    ///
    ///     return ClientSamplingRequest.Result(
    ///         model: "gpt-4",
    ///         stopReason: .endTurn,
    ///         role: .assistant,
    ///         content: .text(response.text)
    ///     )
    /// }
    /// ```
    ///
    /// - Parameter handler: A closure that receives sampling parameters and returns the result.
    /// - Returns: Self for chaining.
    /// - Precondition: `capabilities.sampling` must be non-nil.
    @discardableResult
    public func withSamplingHandler(
        _ handler: @escaping @Sendable (ClientSamplingRequest.Parameters) async throws -> ClientSamplingRequest.Result
    ) -> Self {
        precondition(
            capabilities.sampling != nil,
            "Cannot register sampling handler: Client does not have sampling capability"
        )
        return withRequestHandler(ClientSamplingRequest.self, handler: handler)
    }

    /// Register a handler for `elicitation/create` requests from the server.
    ///
    /// When the server requests user input via elicitation, this handler will be called
    /// to collect the input and return the result.
    ///
    /// - Important: The client must have declared `elicitation` capability during initialization.
    ///
    /// - Parameter handler: A closure that receives elicitation parameters and returns the result.
    /// - Returns: Self for chaining.
    /// - Precondition: `capabilities.elicitation` must be non-nil.
    @discardableResult
    public func withElicitationHandler(
        _ handler: @escaping @Sendable (Elicit.Parameters) async throws -> Elicit.Result
    ) -> Self {
        precondition(
            capabilities.elicitation != nil,
            "Cannot register elicitation handler: Client does not have elicitation capability"
        )
        return withRequestHandler(Elicit.self, handler: handler)
    }

    /// Internal method to set a request handler box directly.
    ///
    /// This is used by task-augmented handlers that need to return different result types
    /// based on whether the request has a `task` field.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setRequestHandler(method: String, handler: ClientRequestHandlerBox) {
        requestHandlers[method] = handler
    }

    /// Internal method to get an existing request handler box.
    ///
    /// This is used to retrieve the existing handler before wrapping it with
    /// a task-aware handler that preserves the normal handler as a fallback.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _getRequestHandler(method: String) -> ClientRequestHandlerBox? {
        requestHandlers[method]
    }

    /// Internal method to set the task-augmented sampling handler.
    ///
    /// This handler is called when the server sends a `sampling/createMessage` request
    /// with a `task` field. The handler should return `CreateTaskResult` instead of
    /// the normal sampling result.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setTaskAugmentedSamplingHandler(
        _ handler: @escaping ExperimentalClientTaskHandlers.TaskAugmentedSamplingHandler
    ) {
        taskAugmentedSamplingHandler = handler
    }

    /// Internal method to set the task-augmented elicitation handler.
    ///
    /// This handler is called when the server sends an `elicitation/create` request
    /// with a `task` field. The handler should return `CreateTaskResult` instead of
    /// the normal elicitation result.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setTaskAugmentedElicitationHandler(
        _ handler: @escaping ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler
    ) {
        taskAugmentedElicitationHandler = handler
    }
}
