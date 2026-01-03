import Foundation

extension Client {
    // MARK: - Tasks (Experimental)
    // Note: These methods are internal. Access via client.experimental.*

    func getTask(taskId: String) async throws -> GetTask.Result {
        try validateServerCapability(\.tasks, "Tasks")
        let request = GetTask.request(.init(taskId: taskId))
        return try await send(request)
    }

    func listTasks(cursor: String? = nil) async throws -> (tasks: [MCPTask], nextCursor: String?) {
        try validateServerCapability(\.tasks, "Tasks")
        let request: Request<ListTasks>
        if let cursor {
            request = ListTasks.request(.init(cursor: cursor))
        } else {
            request = ListTasks.request(.init())
        }
        let result = try await send(request)
        return (tasks: result.tasks, nextCursor: result.nextCursor)
    }

    func cancelTask(taskId: String) async throws -> CancelTask.Result {
        try validateServerCapability(\.tasks, "Tasks")
        let request = CancelTask.request(.init(taskId: taskId))
        return try await send(request)
    }

    func getTaskResult(taskId: String) async throws -> GetTaskPayload.Result {
        try validateServerCapability(\.tasks, "Tasks")
        let request = GetTaskPayload.request(.init(taskId: taskId))
        return try await send(request)
    }

    /// Get the task result decoded as a specific type.
    ///
    /// This method retrieves the task result and decodes the `extraFields` as the specified type.
    /// The `extraFields` contain the actual result payload (e.g., CallTool.Result fields).
    func getTaskResultAs<T: Decodable & Sendable>(taskId: String, type: T.Type) async throws -> T {
        let result = try await getTaskResult(taskId: taskId)

        // The result's extraFields contain the actual result payload
        // We need to encode them back to JSON and decode as the target type
        guard let extraFields = result.extraFields else {
            throw MCPError.invalidParams("Task result has no payload")
        }

        // Convert extraFields to the target type
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Encode the extraFields as JSON
        let jsonData = try encoder.encode(extraFields)

        // Decode as the target type
        return try decoder.decode(T.self, from: jsonData)
    }

    func callToolAsTask(
        name: String,
        arguments: [String: Value]? = nil,
        ttl: Int? = nil
    ) async throws -> CreateTaskResult {
        try validateServerCapability(\.tasks, "Tasks")
        try validateServerCapability(\.tools, "Tools")

        let taskMetadata = TaskMetadata(ttl: ttl)
        let request = CallTool.request(.init(
            name: name,
            arguments: arguments,
            task: taskMetadata
        ))

        // The server should return CreateTaskResult for task-augmented requests
        // We need to decode as CreateTaskResult instead of CallTool.Result
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let requestData = try encoder.encode(request)

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<CreateTaskResult, Swift.Error>.makeStream()

        let requestId = request.id
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cleanUpPendingRequest(id: requestId) }
        }

        addPendingRequest(id: request.id, continuation: continuation)

        do {
            try await connection.send(requestData)
        } catch {
            if removePendingRequest(id: request.id) != nil {
                continuation.finish(throwing: error)
            }
            throw error
        }

        for try await result in stream {
            return result
        }

        throw MCPError.internalError("No response received")
    }

    func pollTask(taskId: String) -> AsyncThrowingStream<GetTask.Result, any Error> {
        AsyncThrowingStream { continuation in
            let pollingTask = Task {
                do {
                    while !Task.isCancelled {
                        let task = try await self.getTask(taskId: taskId)
                        continuation.yield(task)

                        if isTerminalStatus(task.status) {
                            continuation.finish()
                            return
                        }

                        // Wait based on pollInterval (default 1 second)
                        let intervalMs = task.pollInterval ?? 1000
                        try await Task.sleep(for: .milliseconds(intervalMs))
                    }
                    // Task was cancelled
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Cancel the polling task when the stream is terminated
            continuation.onTermination = { _ in
                pollingTask.cancel()
            }
        }
    }

    func pollUntilTerminal(taskId: String) async throws -> GetTask.Result {
        for try await status in pollTask(taskId: taskId) {
            if isTerminalStatus(status.status) {
                return status
            }
        }
        // This shouldn't happen, but handle it gracefully
        throw MCPError.internalError("Task polling ended unexpectedly")
    }

    func callToolAsTaskAndWait(
        name: String,
        arguments: [String: Value]? = nil,
        ttl: Int? = nil
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        // Start the task
        let createResult = try await callToolAsTask(name: name, arguments: arguments, ttl: ttl)
        let taskId = createResult.task.taskId

        // Wait for the result (uses blocking getTaskResult)
        let payloadResult = try await getTaskResult(taskId: taskId)

        // Decode the result as CallTool.Result
        // Per MCP spec, the result fields are flattened directly in the response (via extraFields)
        guard let extraFields = payloadResult.extraFields else {
            throw MCPError.internalError("Task completed but no result available")
        }

        // Convert extraFields back to Value for decoding
        let resultValue = Value.object(extraFields)
        let resultData = try encoder.encode(resultValue)
        let toolResult = try decoder.decode(CallTool.Result.self, from: resultData)
        return (content: toolResult.content, isError: toolResult.isError)
    }

    func callToolStream(
        name: String,
        arguments: [String: Value]? = nil,
        ttl: Int? = nil
    ) -> AsyncThrowingStream<TaskStreamMessage, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task {
                do {
                    // Step 1: Create the task
                    let createResult = try await self.callToolAsTask(name: name, arguments: arguments, ttl: ttl)
                    let task = createResult.task
                    continuation.yield(.taskCreated(task))

                    // Step 2: Poll for status updates until terminal
                    var lastStatus = task.status
                    var finalTask = task

                    while !isTerminalStatus(lastStatus) {
                        // Wait based on pollInterval (default 1 second)
                        let intervalMs = finalTask.pollInterval ?? 1000
                        try await Task.sleep(for: .milliseconds(intervalMs))

                        // Get updated status
                        let statusResult = try await self.getTask(taskId: task.taskId)
                        finalTask = MCPTask(
                            taskId: statusResult.taskId,
                            status: statusResult.status,
                            ttl: statusResult.ttl,
                            createdAt: statusResult.createdAt,
                            lastUpdatedAt: statusResult.lastUpdatedAt,
                            pollInterval: statusResult.pollInterval,
                            statusMessage: statusResult.statusMessage
                        )

                        // Only yield if status or message changed
                        if statusResult.status != lastStatus || statusResult.statusMessage != nil {
                            continuation.yield(.taskStatus(finalTask))
                        }
                        lastStatus = statusResult.status
                    }

                    // Step 3: Get the final result
                    if finalTask.status == .completed {
                        let payloadResult = try await self.getTaskResult(taskId: task.taskId)

                        // Decode the result as CallTool.Result
                        if let extraFields = payloadResult.extraFields {
                            let resultValue = Value.object(extraFields)
                            let resultData = try self.encoder.encode(resultValue)
                            let toolResult = try self.decoder.decode(CallTool.Result.self, from: resultData)
                            continuation.yield(.result(toolResult))
                        } else {
                            // No result available - return empty result
                            continuation.yield(.result(CallTool.Result(content: [])))
                        }
                    } else if finalTask.status == .failed {
                        let error = MCPError.internalError(finalTask.statusMessage ?? "Task failed")
                        continuation.yield(.error(error))
                    } else if finalTask.status == .cancelled {
                        let error = MCPError.internalError("Task was cancelled")
                        continuation.yield(.error(error))
                    }

                    continuation.finish()
                } catch let error as MCPError {
                    continuation.yield(.error(error))
                    continuation.finish()
                } catch {
                    let mcpError = MCPError.internalError(error.localizedDescription)
                    continuation.yield(.error(mcpError))
                    continuation.finish()
                }
            }

            // Cancel the stream task if the stream is terminated
            continuation.onTermination = { _ in
                streamTask.cancel()
            }
        }
    }
}
