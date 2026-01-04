import Foundation

extension Client {
    // MARK: - Message Handling

    func handleResponse(_ response: Response<AnyMethod>) async {
        await logger?.trace(
            "Processing response",
            metadata: ["id": "\(response.id)"])

        // Check for task-augmented response BEFORE resuming the request.
        // Per MCP spec 2025-11-25: progress tokens continue for task lifetime.
        // If this is a CreateTaskResult, we need to keep the progress handler alive.
        if case .success(let value) = response.result,
           case .object(let resultObject) = value {
            checkForTaskResponse(response: response, value: resultObject)
        }

        // Attempt to remove the pending request using the response ID.
        // Resume with the response only if it hadn't yet been removed.
        if let removedRequest = self.removePendingRequest(id: response.id) {
            // If we successfully removed it, resume its continuation.
            switch response.result {
                case .success(let value):
                    removedRequest.resume(returning: value)
                case .failure(let error):
                    removedRequest.resume(throwing: error)
            }
        } else {
            // Request was already removed (e.g., by send error handler or disconnect).
            // Log this, but it's not an error in race condition scenarios.
            await logger?.warning(
                "Attempted to handle response for already removed request",
                metadata: ["id": "\(response.id)"]
            )
        }
    }

    /// Check if a response is a task-augmented response (CreateTaskResult).
    ///
    /// If the response contains a `task` object with `taskId`, this is a task-augmented
    /// response. Per MCP spec, progress notifications can continue until the task reaches
    /// terminal status, so we migrate the progress handler from request tracking to task tracking.
    ///
    /// This matches the TypeScript SDK pattern where task progress tokens are kept alive
    /// until the task completes.
    func checkForTaskResponse(response: Response<AnyMethod>, value: [String: Value]) {
        // Check if we have a progress token for this request
        guard let progressToken = requestProgressTokens[response.id] else { return }

        // Check if response has task.taskId (CreateTaskResult pattern)
        // This mirrors TypeScript's check: result.task?.taskId
        guard let taskValue = value["task"],
              case .object(let taskObject) = taskValue,
              let taskIdValue = taskObject["taskId"],
              case .string(let taskId) = taskIdValue else {
            // Not a task response - clean up request tracking
            // (the progress callback itself is cleaned up in send() after receiving result)
            requestProgressTokens.removeValue(forKey: response.id)
            return
        }

        // This is a task-augmented response!
        // Migrate progress token from request tracking to task tracking.
        // This keeps the progress handler alive until the task completes.
        taskProgressTokens[taskId] = progressToken
        requestProgressTokens.removeValue(forKey: response.id)

        Task {
            await logger?.debug(
                "Keeping progress handler alive for task",
                metadata: [
                    "taskId": "\(taskId)",
                    "progressToken": "\(progressToken)",
                ]
            )
        }
    }

    /// Clean up the progress handler for a completed task.
    ///
    /// Call this method when a task reaches terminal status (completed, failed, cancelled)
    /// to remove the progress callback and timeout controller.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Register task status notification handler
    /// await client.onNotification(TaskStatusNotification.self) { message in
    ///     if message.params.status.isTerminal {
    ///         await client.cleanupTaskProgressHandler(taskId: message.params.taskId)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter taskId: The ID of the task that completed.
    public func cleanUpTaskProgressHandler(taskId: String) {
        guard let progressToken = taskProgressTokens.removeValue(forKey: taskId) else { return }

        progressCallbacks.removeValue(forKey: progressToken)
        timeoutControllers.removeValue(forKey: progressToken)

        Task {
            await logger?.debug(
                "Cleaned up progress handler for completed task",
                metadata: ["taskId": "\(taskId)"]
            )
        }
    }

    func handleMessage(_ message: Message<AnyNotification>) async {
        await logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        // Check if this is a progress notification and invoke any registered callback
        if message.method == ProgressNotification.name {
            await handleProgressNotification(message)
        }

        // Check if this is a task status notification and clean up progress handlers
        // for terminal task statuses (per MCP spec, progress tokens are valid until terminal status)
        if message.method == TaskStatusNotification.name {
            await handleTaskStatusNotification(message)
        }

        // Find notification handlers for this method
        guard let handlers = notificationHandlers[message.method] else { return }

        // Convert notification parameters to concrete type and call handlers
        for handler in handlers {
            do {
                try await handler(message)
            } catch {
                await logger?.error(
                    "Error handling notification",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    /// Handle a progress notification by invoking any registered callback.
    func handleProgressNotification(_ message: Message<AnyNotification>) async {
        do {
            // Decode as ProgressNotification.Parameters
            let paramsData = try encoder.encode(message.params)
            let params = try decoder.decode(ProgressNotification.Parameters.self, from: paramsData)

            // Look up the callback for this token
            guard let callback = progressCallbacks[params.progressToken] else {
                // TypeScript SDK logs an error for unknown progress tokens
                await logger?.warning(
                    "Received progress notification for unknown token",
                    metadata: ["progressToken": "\(params.progressToken)"])
                return
            }

            // Signal the timeout controller if one exists for this token
            // This allows resetTimeoutOnProgress to work
            if let timeoutController = timeoutControllers[params.progressToken] {
                await timeoutController.signalProgress()
            }

            // Invoke the callback
            let progress = Progress(
                value: params.progress,
                total: params.total,
                message: params.message
            )
            await callback(progress)
        } catch {
            await logger?.warning(
                "Failed to decode progress notification",
                metadata: ["error": "\(error)"])
        }
    }

    /// Handle a task status notification by cleaning up progress handlers for terminal tasks.
    ///
    /// Per MCP spec 2025-11-25: progress tokens continue throughout task lifetime until terminal status.
    /// This method automatically cleans up progress handlers when a task reaches completed, failed, or cancelled.
    func handleTaskStatusNotification(_ message: Message<AnyNotification>) async {
        do {
            // Decode as TaskStatusNotification.Parameters
            let paramsData = try encoder.encode(message.params)
            let params = try decoder.decode(TaskStatusNotification.Parameters.self, from: paramsData)

            // If the task reached a terminal status, clean up its progress handler
            if params.status.isTerminal {
                cleanUpTaskProgressHandler(taskId: params.taskId)
            }
        } catch {
            // Don't log errors for task status notifications - they may not be task-related
            // and the user may not have registered a handler for them
        }
    }

    /// Handle an incoming request from the server (bidirectional communication).
    ///
    /// This enables server→client requests such as sampling, roots, and elicitation.
    ///
    /// ## Task-Augmented Request Handling
    ///
    /// For `sampling/createMessage` and `elicitation/create` requests, this method
    /// checks for a `task` field in the request params. If present, it routes to
    /// the task-augmented handler (which returns `CreateTaskResult`) instead of
    /// the normal handler.
    ///
    /// This follows the Python SDK pattern of storing task-augmented handlers
    /// separately and checking at dispatch time, rather than the TypeScript pattern
    /// of wrapping handlers at registration time. The Python pattern was chosen
    /// because:
    /// - It allows handlers to be registered in any order without losing task-awareness
    /// - It keeps task logic separate from normal handler logic
    /// - It's more explicit about which handler is called for which request type
    func handleIncomingRequest(_ request: Request<AnyMethod>) async {
        await logger?.trace(
            "Processing incoming request from server",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        // Validate elicitation mode against client capabilities
        // Per spec: Client MUST return -32602 if server requests unsupported mode
        if request.method == Elicit.name {
            if let modeError = await validateElicitationMode(request) {
                await sendResponse(modeError)
                return
            }
        }

        // Check for task-augmented sampling/elicitation requests first
        // This matches the Python SDK pattern where task detection happens at dispatch time
        if let taskResponse = await handleTaskAugmentedRequest(request) {
            await sendResponse(taskResponse)
            return
        }

        // Find handler for method name
        guard let handler = requestHandlers[request.method] else {
            await logger?.warning(
                "No handler registered for server request",
                metadata: ["method": "\(request.method)"])

            // Send error response
            let response = AnyMethod.response(
                id: request.id,
                error: MCPError.methodNotFound("Client has no handler for: \(request.method)")
            )
            await sendResponse(response)
            return
        }

        // Execute the handler and send response
        do {
            let response = try await handler(request)

            // Check cancellation before sending response (per MCP spec:
            // "Receivers of a cancellation notification SHOULD... Not send a response
            // for the cancelled request")
            if Task.isCancelled {
                await logger?.debug(
                    "Server request cancelled, suppressing response",
                    metadata: ["id": "\(request.id)"]
                )
                return
            }

            await sendResponse(response)
        } catch {
            // Also check cancellation on error path - don't send error response if cancelled
            if Task.isCancelled {
                await logger?.debug(
                    "Server request cancelled during error handling, suppressing response",
                    metadata: ["id": "\(request.id)"]
                )
                return
            }

            await logger?.error(
                "Error handling server request",
                metadata: [
                    "method": "\(request.method)",
                    "error": "\(error)",
                ])
            let errorResponse = AnyMethod.response(
                id: request.id,
                error: (error as? MCPError) ?? MCPError.internalError(error.localizedDescription)
            )
            await sendResponse(errorResponse)
        }
    }

    /// Validate that an elicitation request uses a mode supported by client capabilities.
    ///
    /// Per MCP spec: Client MUST return -32602 (Invalid params) if server sends
    /// an elicitation/create request with a mode not declared in client capabilities.
    ///
    /// - Parameter request: The incoming elicitation request
    /// - Returns: An error response if mode is unsupported, nil if valid
    func validateElicitationMode(_ request: Request<AnyMethod>) async -> Response<AnyMethod>? {
        do {
            let paramsData = try encoder.encode(request.params)
            let params = try decoder.decode(Elicit.Parameters.self, from: paramsData)

            switch params {
                case .form:
                    // Form mode requires form capability
                    if capabilities.elicitation?.form == nil {
                        return Response(
                            id: request.id,
                            error: .invalidParams("Client does not support form elicitation mode")
                        )
                    }
                case .url:
                    // URL mode requires url capability
                    if capabilities.elicitation?.url == nil {
                        return Response(
                            id: request.id,
                            error: .invalidParams("Client does not support URL elicitation mode")
                        )
                    }
            }
        } catch {
            // If we can't decode the params, let the normal handler deal with it
            await logger?.warning(
                "Failed to decode elicitation params for mode validation",
                metadata: ["error": "\(error)"])
        }

        return nil
    }

    /// Check if a request is task-augmented and handle it if so.
    ///
    /// - Parameter request: The incoming request
    /// - Returns: A response if the request was task-augmented and handled, nil otherwise
    func handleTaskAugmentedRequest(_ request: Request<AnyMethod>) async -> Response<AnyMethod>? {
        do {
            // Check for task-augmented sampling request
            if request.method == CreateSamplingMessage.name,
               let taskHandler = taskAugmentedSamplingHandler {
                let paramsData = try encoder.encode(request.params)
                let params = try decoder.decode(CreateSamplingMessage.Parameters.self, from: paramsData)

                if let taskMetadata = params.task {
                    let result = try await taskHandler(params, taskMetadata)
                    let resultData = try encoder.encode(result)
                    let resultValue = try decoder.decode(Value.self, from: resultData)
                    return Response(id: request.id, result: resultValue)
                }
            }

            // Check for task-augmented elicitation request
            if request.method == Elicit.name,
               let taskHandler = taskAugmentedElicitationHandler {
                let paramsData = try encoder.encode(request.params)
                let params = try decoder.decode(Elicit.Parameters.self, from: paramsData)

                let taskMetadata: TaskMetadata? = switch params {
                    case .form(let formParams): formParams.task
                    case .url(let urlParams): urlParams.task
                }

                if let taskMetadata {
                    let result = try await taskHandler(params, taskMetadata)
                    let resultData = try encoder.encode(result)
                    let resultValue = try decoder.decode(Value.self, from: resultData)
                    return Response(id: request.id, result: resultValue)
                }
            }
        } catch let error as MCPError {
            return Response(id: request.id, error: error)
        } catch {
            return Response(id: request.id, error: MCPError.internalError(error.localizedDescription))
        }

        // Not a task-augmented request
        return nil
    }

    /// Send a response back to the server.
    func sendResponse(_ response: Response<AnyMethod>) async {
        guard let connection = connection else {
            await logger?.warning("Cannot send response - client not connected")
            return
        }

        do {
            let responseData = try encoder.encode(response)
            try await connection.send(responseData)
        } catch {
            await logger?.error(
                "Failed to send response to server",
                metadata: ["error": "\(error)"])
        }
    }

    // MARK: -

    /// Validate the server capabilities.
    /// Throws an error if the client is configured to be strict and the capability is not supported.
    func validateServerCapability<T>(
        _ keyPath: KeyPath<Server.Capabilities, T?>,
        _ name: String
    )
    throws
    {
        if configuration.strict {
            guard let capabilities = serverCapabilities else {
                throw MCPError.methodNotFound("Server capabilities not initialized")
            }
            guard capabilities[keyPath: keyPath] != nil else {
                throw MCPError.methodNotFound("\(name) is not supported by the server")
            }
        }
    }

    // Add handler for batch responses
    func handleBatchResponse(_ responses: [AnyResponse]) async {
        await logger?.trace("Processing batch response", metadata: ["count": "\(responses.count)"])
        for response in responses {
            // Attempt to remove the pending request.
            // If successful, pendingRequest contains the request.
            if let pendingRequest = self.removePendingRequest(id: response.id) {
                // If we successfully removed it, handle the response using the pending request.
                switch response.result {
                    case .success(let value):
                        pendingRequest.resume(returning: value)
                    case .failure(let error):
                        pendingRequest.resume(throwing: error)
                }
            } else {
                // If removal failed, it means the request ID was not found (or already handled).
                // Log a warning.
                await logger?.warning(
                    "Received response in batch for unknown or already handled request ID",
                    metadata: ["id": "\(response.id)"]
                )
            }
        }
    }
}
