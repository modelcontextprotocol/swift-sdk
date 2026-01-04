import Foundation

extension Server {
    // MARK: - Server to Client Requests

    /// Send a request to the client and wait for a response.
    ///
    /// This enables bidirectional communication where the server can request
    /// information from the client (e.g., roots, sampling, elicitation).
    ///
    /// - Parameter request: The request to send
    /// - Returns: The result from the client
    public func sendRequest<M: Method>(_ request: Request<M>) async throws -> M.Result {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<M.Result, Swift.Error>.makeStream()

        // Clean up pending request if cancelled
        let requestId = request.id
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cleanUpPendingRequest(id: requestId) }
        }

        // Register the pending request
        pendingRequests[request.id] = AnyServerPendingRequest(continuation: continuation)

        // Send the request
        do {
            try await connection.send(requestData)
        } catch {
            pendingRequests.removeValue(forKey: request.id)
            continuation.finish(throwing: error)
            throw error
        }

        // Wait for response
        for try await result in stream {
            return result
        }

        throw MCPError.internalError("No response received from client")
    }

    func cleanUpPendingRequest(id: RequestId) {
        pendingRequests.removeValue(forKey: id)
    }

    // MARK: - In-Flight Request Tracking (Protocol-Level Cancellation)

    /// Track an in-flight request handler Task.
    func trackInFlightRequest(_ requestId: RequestId, task: Task<Void, Never>) {
        inFlightHandlerTasks[requestId] = task
    }

    /// Remove an in-flight request handler Task.
    func removeInFlightRequest(_ requestId: RequestId) {
        inFlightHandlerTasks.removeValue(forKey: requestId)
    }

    /// Cancel an in-flight request handler Task.
    ///
    /// Called when a CancelledNotification is received for a specific requestId.
    /// Per MCP spec, if the request is unknown or already completed, this is a no-op.
    func cancelInFlightRequest(_ requestId: RequestId, reason: String?) async {
        if let task = inFlightHandlerTasks[requestId] {
            task.cancel()
            await logger?.debug(
                "Cancelled in-flight request",
                metadata: [
                    "id": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ]
            )
        }
        // Per spec: MAY ignore if request is unknown - no error needed
    }

    /// Generate a unique request ID for server→client requests.
    func generateRequestId() -> RequestId {
        let id = nextRequestId
        nextRequestId += 1
        return .number(id)
    }

    /// Request the list of roots from the client.
    ///
    /// Roots represent filesystem directories that the client has access to.
    /// Servers can use this to understand the scope of files they can work with.
    ///
    /// - Throws: MCPError if the client doesn't support roots or if the request fails.
    /// - Returns: The list of roots from the client.
    public func listRoots() async throws -> [Root] {
        // Check that client supports roots
        guard clientCapabilities?.roots != nil else {
            throw MCPError.invalidRequest("Client does not support roots capability")
        }

        let request: Request<ListRoots> = ListRoots.request(id: generateRequestId())
        let result = try await sendRequest(request)
        return result.roots
    }

    /// Request a sampling completion from the client (without tools).
    ///
    /// This enables servers to request LLM completions through the client,
    /// allowing sophisticated agentic behaviors while maintaining security.
    ///
    /// The result will be a single content block (text, image, or audio).
    /// For tool-enabled sampling, use `createMessageWithTools(_:)` instead.
    ///
    /// - Parameter params: The sampling parameters including messages, model preferences, etc.
    /// - Throws: MCPError if the client doesn't support sampling or if the request fails.
    /// - Returns: The sampling result from the client containing a single content block.
    public func createMessage(_ params: CreateSamplingMessage.Parameters) async throws -> CreateSamplingMessage.Result {
        // Check that client supports sampling
        guard clientCapabilities?.sampling != nil else {
            throw MCPError.invalidRequest("Client does not support sampling capability")
        }

        let request: Request<CreateSamplingMessage> = CreateSamplingMessage.request(id: generateRequestId(), params)
        return try await sendRequest(request)
    }

    /// Request a sampling completion from the client with tool support.
    ///
    /// This enables servers to request LLM completions that may involve tool use.
    /// The result may contain tool use content, and content can be an array for parallel tool calls.
    ///
    /// - Parameter params: The sampling parameters including messages, tools, and model preferences.
    /// - Throws: MCPError if the client doesn't support sampling or tool capabilities.
    /// - Returns: The sampling result from the client, which may include tool use content.
    public func createMessageWithTools(_ params: CreateSamplingMessageWithTools.Parameters) async throws -> CreateSamplingMessageWithTools.Result {
        // Check that client supports sampling
        guard clientCapabilities?.sampling != nil else {
            throw MCPError.invalidRequest("Client does not support sampling capability")
        }

        // Check tools capability
        guard clientCapabilities?.sampling?.tools != nil else {
            throw MCPError.invalidRequest("Client does not support sampling tools capability")
        }

        // Validate tool_use/tool_result message structure per MCP specification
        try Sampling.Message.validateToolUseResultMessages(params.messages)

        let request: Request<CreateSamplingMessageWithTools> = CreateSamplingMessageWithTools.request(id: generateRequestId(), params)
        return try await sendRequest(request)
    }

    /// Request user input via elicitation from the client.
    ///
    /// Elicitation allows servers to request structured input from users through
    /// the client, either via forms or external URLs (e.g., OAuth flows).
    ///
    /// - Parameter params: The elicitation parameters.
    /// - Throws: MCPError if the client doesn't support elicitation or if the request fails.
    /// - Returns: The elicitation result from the client.
    public func elicit(_ params: Elicit.Parameters) async throws -> Elicit.Result {
        // Check that client supports elicitation
        guard clientCapabilities?.elicitation != nil else {
            throw MCPError.invalidRequest("Client does not support elicitation capability")
        }

        // Check mode-specific capabilities
        switch params {
            case .form:
                guard clientCapabilities?.elicitation?.form != nil else {
                    throw MCPError.invalidRequest("Client does not support form elicitation")
                }
            case .url:
                guard clientCapabilities?.elicitation?.url != nil else {
                    throw MCPError.invalidRequest("Client does not support URL elicitation")
                }
        }

        let request: Request<Elicit> = Elicit.request(id: generateRequestId(), params)
        let result = try await sendRequest(request)

        // TODO: Add elicitation response validation against the requestedSchema.
        // TypeScript SDK uses JSON Schema validators (AJV, CfWorker) to validate
        // elicitation responses against the requestedSchema. Python SDK uses Pydantic.
        // The ideal solution is to use the same JSON Schema validator for both
        // elicitation and tool validation, for spec compliance and consistency.

        return result
    }

    func checkInitialized() throws {
        guard isInitialized else {
            throw MCPError.invalidRequest("Server is not initialized")
        }
    }

    // MARK: - Client Task Polling (Server → Client)

    /// Get a task from the client.
    ///
    /// Internal method used by experimental server task features.
    func getClientTask(taskId: String) async throws -> GetTask.Result {
        guard clientCapabilities?.tasks != nil else {
            throw MCPError.invalidRequest("Client does not support tasks capability")
        }

        let request = GetTask.request(.init(taskId: taskId))
        return try await sendRequest(request)
    }

    /// Get the result payload of a client task.
    ///
    /// Internal method used by experimental server task features.
    func getClientTaskResult(taskId: String) async throws -> GetTaskPayload.Result {
        guard clientCapabilities?.tasks != nil else {
            throw MCPError.invalidRequest("Client does not support tasks capability")
        }

        let request = GetTaskPayload.request(.init(taskId: taskId))
        return try await sendRequest(request)
    }

    /// Get the task result decoded as a specific type.
    ///
    /// Internal method used by experimental server task features.
    func getClientTaskResultAs<T: Decodable & Sendable>(taskId: String, type: T.Type) async throws -> T {
        let result = try await getClientTaskResult(taskId: taskId)

        // The result's extraFields contain the actual result payload
        guard let extraFields = result.extraFields else {
            throw MCPError.invalidParams("Task result has no payload")
        }

        // Convert extraFields to the target type
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let jsonData = try encoder.encode(extraFields)
        return try decoder.decode(T.self, from: jsonData)
    }

    // MARK: - Task-Augmented Requests (Server → Client)

    /// Send a task-augmented elicitation request to the client.
    ///
    /// The client returns a `CreateTaskResult` instead of an `ElicitResult`.
    /// Use client task polling to get the final result.
    ///
    /// Internal method used by experimental server task features.
    func sendElicitAsTask(_ params: Elicit.Parameters) async throws -> CreateTaskResult {
        // Check that client supports task-augmented elicitation
        try requireTaskAugmentedElicitation(clientCapabilities)

        // Check mode-specific capabilities
        switch params {
            case .form:
                guard clientCapabilities?.elicitation?.form != nil else {
                    throw MCPError.invalidRequest("Client does not support form elicitation")
                }
            case .url:
                guard clientCapabilities?.elicitation?.url != nil else {
                    throw MCPError.invalidRequest("Client does not support URL elicitation")
                }
        }

        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        // Build the request
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request: Request<Elicit> = Elicit.request(id: generateRequestId(), params)
        let requestData = try encoder.encode(request)

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<CreateTaskResult, Swift.Error>.makeStream()

        let requestId = request.id
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cleanUpPendingRequest(id: requestId) }
        }

        // Register the pending request
        pendingRequests[requestId] = AnyServerPendingRequest(continuation: continuation)

        // Send the request
        do {
            try await connection.send(requestData)
        } catch {
            pendingRequests.removeValue(forKey: requestId)
            continuation.finish(throwing: error)
            throw error
        }

        // Wait for single result
        for try await result in stream {
            return result
        }

        throw MCPError.internalError("No response received")
    }

    /// Send a task-augmented sampling request to the client.
    ///
    /// The client returns a `CreateTaskResult` instead of a `CreateSamplingMessage.Result`.
    /// Use client task polling to get the final result.
    ///
    /// Internal method used by experimental server task features.
    func sendCreateMessageAsTask(_ params: CreateSamplingMessage.Parameters) async throws -> CreateTaskResult {
        // Check that client supports task-augmented sampling
        try requireTaskAugmentedSampling(clientCapabilities)

        guard clientCapabilities?.sampling != nil else {
            throw MCPError.invalidRequest("Client does not support sampling capability")
        }

        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        // Build the request
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = CreateSamplingMessage.request(id: generateRequestId(), params)
        let requestData = try encoder.encode(request)

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<CreateTaskResult, Swift.Error>.makeStream()

        let requestId = request.id
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cleanUpPendingRequest(id: requestId) }
        }

        // Register the pending request
        pendingRequests[requestId] = AnyServerPendingRequest(continuation: continuation)

        // Send the request
        do {
            try await connection.send(requestData)
        } catch {
            pendingRequests.removeValue(forKey: requestId)
            continuation.finish(throwing: error)
            throw error
        }

        // Wait for single result
        for try await result in stream {
            return result
        }

        throw MCPError.internalError("No response received")
    }
}
