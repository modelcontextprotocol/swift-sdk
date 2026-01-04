import Foundation

extension Client {
    // MARK: - Batching

    /// A batch of requests.
    ///
    /// Objects of this type are passed as an argument to the closure
    /// of the ``Client/withBatch(_:)`` method.
    public actor Batch {
        unowned let client: Client
        var requests: [AnyRequest] = []

        init(client: Client) {
            self.client = client
        }

        /// Adds a request to the batch and prepares its expected response task.
        /// The actual sending happens when the `withBatch` scope completes.
        /// - Returns: A `Task` that will eventually produce the result or throw an error.
        public func addRequest<M: Method>(_ request: Request<M>) async throws -> Task<
            M.Result, Swift.Error
        > {
            requests.append(try AnyRequest(request))

            // Create stream for receiving the response
            let (stream, continuation) = AsyncThrowingStream<M.Result, Swift.Error>.makeStream()

            // Clean up pending request if caller cancels (e.g., task cancelled)
            // and send CancelledNotification to server per MCP spec
            let requestId = request.id
            continuation.onTermination = { @Sendable [weak client] termination in
                Task {
                    guard let client else { return }
                    await client.cleanUpPendingRequest(id: requestId)

                    // Per MCP spec: send notifications/cancelled when cancelling a request
                    // Only send if the stream was cancelled (not finished normally)
                    if case .cancelled = termination {
                        await client.sendCancellationNotification(
                            requestId: requestId,
                            reason: "Client cancelled the batch request"
                        )
                    }
                }
            }

            // Register the pending request
            await client.addPendingRequest(id: request.id, continuation: continuation)

            // Return a Task that waits for the response via the stream
            return Task<M.Result, Swift.Error> {
                for try await result in stream {
                    return result
                }
                throw MCPError.internalError("No response received")
            }
        }
    }

    /// Executes multiple requests in a single batch.
    ///
    /// This method allows you to group multiple MCP requests together,
    /// which are then sent to the server as a single JSON array.
    /// The server processes these requests and sends back a corresponding
    /// JSON array of responses.
    ///
    /// Within the `body` closure, use the provided `Batch` actor to add
    /// requests using `batch.addRequest(_:)`. Each call to `addRequest`
    /// returns a `Task` handle representing the asynchronous operation
    /// for that specific request's result.
    ///
    /// It's recommended to collect these `Task` handles into an array
    /// within the `body` closure`. After the `withBatch` method returns
    /// (meaning the batch request has been sent), you can then process
    /// the results by awaiting each `Task` in the collected array.
    ///
    /// Example 1: Batching multiple tool calls and collecting typed tasks:
    /// ```swift
    /// // Array to hold the task handles for each tool call
    /// var toolTasks: [Task<CallTool.Result, Error>] = []
    /// try await client.withBatch { batch in
    ///     for i in 0..<10 {
    ///         toolTasks.append(
    ///             try await batch.addRequest(
    ///                 CallTool.request(.init(name: "square", arguments: ["n": i]))
    ///             )
    ///         )
    ///     }
    /// }
    ///
    /// // Process results after the batch is sent
    /// print("Processing \(toolTasks.count) tool results...")
    /// for (index, task) in toolTasks.enumerated() {
    ///     do {
    ///         let result = try await task.value
    ///         print("\(index): \(result.content)")
    ///     } catch {
    ///         print("\(index) failed: \(error)")
    ///     }
    /// }
    /// ```
    ///
    /// Example 2: Batching different request types and awaiting individual tasks:
    /// ```swift
    /// // Declare optional task variables beforehand
    /// var pingTask: Task<Ping.Result, Error>?
    /// var promptTask: Task<GetPrompt.Result, Error>?
    ///
    /// try await client.withBatch { batch in
    ///     // Assign the tasks within the batch closure
    ///     pingTask = try await batch.addRequest(Ping.request())
    ///     promptTask = try await batch.addRequest(GetPrompt.request(.init(name: "greeting")))
    /// }
    ///
    /// // Await the results after the batch is sent
    /// do {
    ///     if let pingTask = pingTask {
    ///         try await pingTask.value // Await ping result (throws if ping failed)
    ///         print("Ping successful")
    ///     }
    ///     if let promptTask = promptTask {
    ///         let promptResult = try await promptTask.value // Await prompt result
    ///         print("Prompt description: \(promptResult.description ?? "None")")
    ///     }
    /// } catch {
    ///     print("Error processing batch results: \(error)")
    /// }
    /// ```
    ///
    /// - Parameter body: An asynchronous closure that takes a `Batch` object as input.
    ///                   Use this object to add requests to the batch.
    /// - Throws: `MCPError.internalError` if the client is not connected.
    ///           Can also rethrow errors from the `body` closure or from sending the batch request.
    public func withBatch(body: @escaping (Batch) async throws -> Void) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Create Batch actor, passing self (Client)
        let batch = Batch(client: self)

        // Populate the batch actor by calling the user's closure.
        try await body(batch)

        // Get the collected requests from the batch actor
        let requests = await batch.requests

        // Check if there are any requests to send
        guard !requests.isEmpty else {
            await logger?.debug("Batch requested but no requests were added.")
            return  // Nothing to send
        }

        await logger?.debug(
            "Sending batch request", metadata: ["count": "\(requests.count)"])

        // Encode the array of AnyMethod requests into a single JSON payload
        let data = try encoder.encode(requests)
        try await connection.send(data)

        // Responses will be handled asynchronously by the message loop and handleBatchResponse/handleResponse.
    }
}
