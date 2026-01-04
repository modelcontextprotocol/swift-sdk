import Foundation

extension Server {
    // MARK: - Request Handling

    /// A JSON-RPC batch containing multiple requests and/or notifications
    struct Batch: Sendable {
        /// An item in a JSON-RPC batch
        enum Item: Sendable {
            case request(Request<AnyMethod>)
            case notification(Message<AnyNotification>)

        }

        var items: [Item]

        init(items: [Item]) {
            self.items = items
        }
    }

    /// Process a batch of requests and/or notifications
    func handleBatch(_ batch: Batch) async throws {
        // Capture the connection at batch start.
        // This ensures all batch responses go to the correct client.
        let capturedConnection = self.connection

        await logger?.trace("Processing batch request", metadata: ["size": "\(batch.items.count)"])

        if batch.items.isEmpty {
            // Empty batch is invalid according to JSON-RPC spec
            let error = MCPError.invalidRequest("Batch array must not be empty")
            let response = AnyMethod.response(id: .random, error: error)
            // Use captured connection for error response
            if let connection = capturedConnection {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let responseData = try encoder.encode(response)
                try await connection.send(responseData)
            }
            return
        }

        // Process each item in the batch and collect responses
        var responses: [Response<AnyMethod>] = []

        for item in batch.items {
            do {
                switch item {
                    case .request(let request):
                        // For batched requests, collect responses instead of sending immediately
                        if let response = try await handleRequest(request, sendResponse: false) {
                            responses.append(response)
                        }

                    case .notification(let notification):
                        // Handle notification (no response needed)
                        try await handleMessage(notification)
                }
            } catch {
                // Only add errors to response for requests (notifications don't have responses)
                if case .request(let request) = item {
                    let mcpError =
                    error as? MCPError ?? MCPError.internalError(error.localizedDescription)
                    responses.append(AnyMethod.response(id: request.id, error: mcpError))
                }
            }
        }

        // Send collected responses if any (using captured connection)
        if !responses.isEmpty {
            guard let connection = capturedConnection else {
                await logger?.warning("Cannot send batch response - connection was nil at batch start")
                return
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let responseData = try encoder.encode(responses)

            try await connection.send(responseData)
        }
    }

    // MARK: - Request and Message Handling

    /// Internal context for routing responses to the correct transport.
    ///
    /// When handling requests, we capture the current connection at request time.
    /// This ensures that when the handler completes (which may be async), the response
    /// is sent to the correct client even if `self.connection` has changed in the meantime.
    ///
    /// This pattern is critical for HTTP transports where multiple clients can connect
    /// and the server's `connection` reference gets reassigned.
    struct RequestContext {
        /// The transport connection captured at request time
        let capturedConnection: (any Transport)?
        /// The ID of the request being handled
        let requestId: RequestId
        /// The session ID from the transport, if available.
        ///
        /// For HTTP transports with multiple concurrent clients, this identifies
        /// the specific session. Used for per-session features like log levels.
        let sessionId: String?
    }

    /// Wrapper for encoding type-erased notifications as JSON-RPC messages.
    private struct NotificationWrapper: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: Value

        init(notification: any Notification) {
            self.method = type(of: notification).name

            // Encode the notification's params to Value
            // Since Notification is Codable, we encode it and extract the params field
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            if let data = try? encoder.encode(notification),
               let dict = try? decoder.decode([String: Value].self, from: data),
               let params = dict["params"] {
                self.params = params
            } else {
                self.params = .object([:])
            }
        }
    }

    /// Send a response using the captured request context.
    ///
    /// This ensures responses are routed to the correct client by:
    /// 1. Using the connection that was active when the request was received
    /// 2. Passing the request ID so multiplexing transports can route correctly
    func send<M: Method>(_ response: Response<M>, using context: RequestContext) async throws {
        guard let connection = context.capturedConnection else {
            await logger?.warning(
                "Cannot send response - connection was nil at request time",
                metadata: ["requestId": "\(context.requestId)"]
            )
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let responseData = try encoder.encode(response)
        try await connection.send(responseData, relatedRequestId: context.requestId)
    }

    /// Handle a request and either send the response immediately or return it
    ///
    /// - Parameters:
    ///   - request: The request to handle
    ///   - sendResponse: Whether to send the response immediately (true) or return it (false)
    /// - Returns: The response when sendResponse is false
    func handleRequest(_ request: Request<AnyMethod>, sendResponse: Bool = true)
    async throws -> Response<AnyMethod>?
    {
        // Capture the connection and session ID at request time.
        // This ensures responses go to the correct client even if self.connection
        // changes while the handler is executing (e.g., another client connects).
        let capturedConnection = self.connection
        let context = RequestContext(
            capturedConnection: capturedConnection,
            requestId: request.id,
            sessionId: await capturedConnection?.sessionId
        )

        // Check if this is a pre-processed error request (empty method)
        if request.method.isEmpty && !sendResponse {
            // This is a placeholder for an invalid request that couldn't be parsed in batch mode
            return AnyMethod.response(
                id: request.id,
                error: MCPError.invalidRequest("Invalid batch item format")
            )
        }

        await logger?.trace(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        if configuration.strict {
            // The client SHOULD NOT send requests other than pings
            // before the server has responded to the initialize request.
            switch request.method {
                case Initialize.name, Ping.name:
                    break
                default:
                    try checkInitialized()
            }
        }

        // Find handler for method name
        guard let handler = methodHandlers[request.method] else {
            let error = MCPError.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)

            if sendResponse {
                try await send(response, using: context)
                return nil
            }

            return response
        }

        // Create the public handler context with sendNotification capability
        let handlerContext = RequestHandlerContext(
            sendNotification: { [context] notification in
                guard let connection = context.capturedConnection else {
                    throw MCPError.internalError("Cannot send notification - connection was nil at request time")
                }

                // Wrap the notification in a JSON-RPC message structure
                let wrapper = NotificationWrapper(notification: notification)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

                let notificationData = try encoder.encode(wrapper)
                try await connection.send(notificationData, relatedRequestId: context.requestId)
            },
            sendMessage: { [context] message in
                guard let connection = context.capturedConnection else {
                    throw MCPError.internalError("Cannot send notification - connection was nil at request time")
                }

                // Message<N> already encodes to JSON-RPC format with method and params
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

                let messageData = try encoder.encode(message)
                try await connection.send(messageData, relatedRequestId: context.requestId)
            },
            sendData: { [context] data in
                guard let connection = context.capturedConnection else {
                    throw MCPError.internalError("Cannot send data - connection was nil at request time")
                }

                // Send raw data (used for queued task messages)
                try await connection.send(data, relatedRequestId: context.requestId)
            },
            sessionId: context.sessionId,
            shouldSendLogMessage: { [weak self, context] level in
                guard let self else { return true }
                return await self.shouldSendLogMessage(at: level, forSession: context.sessionId)
            }
        )

        do {
            // Handle request and get response
            let response: Response<AnyMethod> = try await handler(request, context: handlerContext)

            // Check cancellation before sending response (per MCP spec:
            // "Receivers of a cancellation notification SHOULD... Not send a response
            // for the cancelled request")
            if Task.isCancelled {
                await logger?.debug(
                    "Request cancelled, suppressing response",
                    metadata: ["id": "\(request.id)"]
                )
                return nil
            }

            if sendResponse {
                try await send(response, using: context)
                return nil
            }

            return response
        } catch {
            // Also check cancellation on error path - don't send error response if cancelled
            if Task.isCancelled {
                await logger?.debug(
                    "Request cancelled during error handling, suppressing response",
                    metadata: ["id": "\(request.id)"]
                )
                return nil
            }

            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response: Response<AnyMethod> = AnyMethod.response(id: request.id, error: mcpError)

            if sendResponse {
                try await send(response, using: context)
                return nil
            }

            return response
        }
    }

    func handleMessage(_ message: Message<AnyNotification>) async throws {
        await logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        if configuration.strict {
            // Check initialization state unless this is an initialized notification
            if message.method != InitializedNotification.name {
                try checkInitialized()
            }
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

    /// Handle a response from the client (for server→client requests).
    func handleClientResponse(_ response: Response<AnyMethod>) async {
        await logger?.trace(
            "Processing client response",
            metadata: ["id": "\(response.id)"])

        // Check response routers first (e.g., for task-related responses)
        for router in responseRouters {
            switch response.result {
                case .success(let value):
                    if await router.routeResponse(requestId: response.id, response: value) {
                        await logger?.trace(
                            "Response routed via router",
                            metadata: ["id": "\(response.id)"])
                        return
                    }
                case .failure(let error):
                    if await router.routeError(requestId: response.id, error: error) {
                        await logger?.trace(
                            "Error routed via router",
                            metadata: ["id": "\(response.id)"])
                        return
                    }
            }
        }

        // Fall back to normal pending request handling
        if let pendingRequest = pendingRequests.removeValue(forKey: response.id) {
            switch response.result {
                case .success(let value):
                    pendingRequest.resume(returning: value)
                case .failure(let error):
                    pendingRequest.resume(throwing: error)
            }
        } else {
            await logger?.warning(
                "Received response for unknown request",
                metadata: ["id": "\(response.id)"])
        }
    }
}
