import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol server
public actor Server {
    /// The server configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the server:
        /// - Requires clients to send an initialize request before any other requests
        /// - Rejects all requests from uninitialized clients with a protocol error
        ///
        /// While the MCP specification requires clients to initialize the connection
        /// before sending other requests, some implementations may not follow this.
        /// Disabling strict mode allows the server to be more lenient with non-compliant
        /// clients, though this may lead to undefined behavior.
        public var strict: Bool
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The server name
        public let name: String
        /// The server version
        public let version: String
        /// A human-readable title for the server, intended for UI display.
        /// If not provided, the `name` should be used for display.
        public let title: String?
        /// An optional human-readable description of what this implementation does.
        public let description: String?
        /// Optional icons representing this implementation.
        public let icons: [Icon]?
        /// An optional URL of the website for this implementation.
        public let websiteUrl: String?

        public init(
            name: String,
            version: String,
            title: String? = nil,
            description: String? = nil,
            icons: [Icon]? = nil,
            websiteUrl: String? = nil
        ) {
            self.name = name
            self.version = version
            self.title = title
            self.description = description
            self.icons = icons
            self.websiteUrl = websiteUrl
        }
    }

    /// Server capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// Resources capabilities
        public struct Resources: Hashable, Codable, Sendable {
            /// Whether the resource can be subscribed to
            public var subscribe: Bool?
            /// Whether the list of resources has changed
            public var listChanged: Bool?

            public init(
                subscribe: Bool? = nil,
                listChanged: Bool? = nil
            ) {
                self.subscribe = subscribe
                self.listChanged = listChanged
            }
        }

        /// Tools capabilities
        public struct Tools: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when tools change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Prompts capabilities
        public struct Prompts: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when prompts change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Logging capabilities
        public struct Logging: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Completions capabilities
        public struct Completions: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Tools capabilities
        public var tools: Tools?
        /// Completions capabilities
        public var completions: Completions?
        /// Tasks capabilities (experimental)
        public var tasks: Tasks?
        /// Experimental, non-standard capabilities that the server supports.
        public var experimental: [String: [String: Value]]?

        public init(
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil,
            completions: Completions? = nil,
            tasks: Tasks? = nil,
            experimental: [String: [String: Value]]? = nil
        ) {
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
            self.completions = completions
            self.tasks = tasks
            self.experimental = experimental
        }
    }

    /// Context provided to request handlers for sending notifications during execution.
    ///
    /// When a request handler needs to send notifications (e.g., progress updates during
    /// a long-running tool), it should use this context to ensure the notification is
    /// routed to the correct client, even if other clients have connected in the meantime.
    ///
    /// Example:
    /// ```swift
    /// server.withRequestHandler(CallTool.self) { params, context in
    ///     // Send progress notification using convenience method
    ///     try await context.sendProgress(
    ///         token: progressToken,
    ///         progress: 50.0,
    ///         total: 100.0,
    ///         message: "Processing..."
    ///     )
    ///     // ... do work ...
    ///     return result
    /// }
    /// ```
    public struct RequestHandlerContext: Sendable {
        /// Send a notification without parameters to the client that initiated this request.
        ///
        /// The notification will be routed to the correct client even if other clients
        /// have connected since the request was received.
        ///
        /// - Parameter notification: The notification to send (for notifications without parameters)
        public let sendNotification: @Sendable (any Notification) async throws -> Void

        /// Send a notification message with parameters to the client that initiated this request.
        ///
        /// Use this method to send notifications that have parameters, such as `ProgressNotification`
        /// or `LogMessageNotification`.
        ///
        /// Example:
        /// ```swift
        /// try await context.sendMessage(ProgressNotification.message(.init(
        ///     progressToken: token,
        ///     progress: 50.0,
        ///     total: 100.0,
        ///     message: "Halfway done"
        /// )))
        /// ```
        ///
        /// - Parameter message: The notification message to send
        public let sendMessage: @Sendable (any NotificationMessageProtocol) async throws -> Void

        /// Send raw data to the client that initiated this request.
        ///
        /// This is used internally for sending queued task messages (such as elicitation
        /// or sampling requests that were queued during task execution).
        ///
        /// - Important: This is an internal API primarily used by the task system.
        ///
        /// - Parameter data: The raw JSON data to send
        public let sendData: @Sendable (Data) async throws -> Void

        /// The session identifier for the client that initiated this request.
        ///
        /// For HTTP transports with multiple concurrent clients, each client session
        /// has a unique identifier. This can be used for per-session features like
        /// independent log levels.
        ///
        /// For simple transports (stdio, single-connection), this is `nil`.
        public let sessionId: String?

        /// Check if a log message at the given level should be sent.
        ///
        /// This respects the minimum log level set by the client via `logging/setLevel`.
        /// Messages below the threshold will be silently dropped.
        let shouldSendLogMessage: @Sendable (LoggingLevel) async -> Bool

        // MARK: - Convenience Methods

        /// Send a progress notification to the client.
        ///
        /// Use this to report progress on long-running operations.
        ///
        /// - Parameters:
        ///   - token: The progress token from the request's `_meta.progressToken`
        ///   - progress: The current progress value (should increase monotonically)
        ///   - total: The total progress value, if known
        ///   - message: An optional human-readable message describing current progress
        public func sendProgress(
            token: ProgressToken,
            progress: Double,
            total: Double? = nil,
            message: String? = nil
        ) async throws {
            try await sendMessage(ProgressNotification.message(.init(
                progressToken: token,
                progress: progress,
                total: total,
                message: message
            )))
        }

        /// Send a log message notification to the client.
        ///
        /// The message will only be sent if its level is at or above the minimum
        /// log level set by the client via `logging/setLevel`. Messages below the
        /// threshold are silently dropped.
        ///
        /// - Parameters:
        ///   - level: The severity level of the log message
        ///   - logger: An optional name for the logger producing the message
        ///   - data: The log message data (can be a string or structured data)
        public func sendLogMessage(
            level: LoggingLevel,
            logger: String? = nil,
            data: Value
        ) async throws {
            // Check if this message should be sent based on the current log level
            guard await shouldSendLogMessage(level) else { return }

            try await sendMessage(LogMessageNotification.message(.init(
                level: level,
                logger: logger,
                data: data
            )))
        }

        /// Send a resource list changed notification to the client.
        ///
        /// Call this when the list of available resources has changed.
        public func sendResourceListChanged() async throws {
            try await sendNotification(ResourceListChangedNotification())
        }

        /// Send a resource updated notification to the client.
        ///
        /// Call this when a specific resource's content has been updated.
        ///
        /// - Parameter uri: The URI of the resource that was updated
        public func sendResourceUpdated(uri: String) async throws {
            try await sendMessage(ResourceUpdatedNotification.message(.init(uri: uri)))
        }

        /// Send a tool list changed notification to the client.
        ///
        /// Call this when the list of available tools has changed.
        public func sendToolListChanged() async throws {
            try await sendNotification(ToolListChangedNotification())
        }

        /// Send a prompt list changed notification to the client.
        ///
        /// Call this when the list of available prompts has changed.
        public func sendPromptListChanged() async throws {
            try await sendNotification(PromptListChangedNotification())
        }

        /// Send a cancellation notification to the client.
        ///
        /// - Parameters:
        ///   - requestId: The ID of the request being cancelled (optional in protocol 2025-11-25+)
        ///   - reason: An optional reason for the cancellation
        public func sendCancelled(requestId: RequestId? = nil, reason: String? = nil) async throws {
            try await sendMessage(CancelledNotification.message(.init(
                requestId: requestId,
                reason: reason
            )))
        }

        /// Send an elicitation complete notification to the client.
        ///
        /// This notifies the client that an out-of-band (URL mode) elicitation
        /// request has been completed.
        ///
        /// - Parameter elicitationId: The ID of the elicitation that completed.
        public func sendElicitationComplete(elicitationId: String) async throws {
            try await sendMessage(ElicitationCompleteNotification.message(.init(
                elicitationId: elicitationId
            )))
        }

        /// Send a task status notification to the client.
        ///
        /// This notifies the client of a change in task status.
        ///
        /// - Parameter task: The task to send the status notification for.
        public func sendTaskStatus(task: MCPTask) async throws {
            try await sendMessage(TaskStatusNotification.message(.init(task: task)))
        }

        // MARK: - Cancellation Checking

        /// Whether the request has been cancelled.
        ///
        /// Check this property periodically during long-running operations
        /// to respond to cancellation requests from the client.
        ///
        /// This returns `true` when:
        /// - The client sends a `CancelledNotification` for this request
        /// - The server is shutting down
        ///
        /// When cancelled, the handler should clean up resources and return
        /// or throw an error. Per MCP spec, responses are not sent for cancelled requests.
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withRequestHandler(CallTool.self) { params, context in
        ///     for item in largeDataset {
        ///         // Check cancellation periodically
        ///         guard !context.isCancelled else {
        ///             throw CancellationError()
        ///         }
        ///         try await process(item)
        ///     }
        ///     return CallTool.Result(content: [.text("Done")])
        /// }
        /// ```
        public var isCancelled: Bool {
            Task.isCancelled
        }

        /// Check if the request has been cancelled and throw if so.
        ///
        /// Call this method periodically during long-running operations.
        /// If the request has been cancelled, this throws `CancellationError`.
        ///
        /// This is equivalent to checking `isCancelled` and throwing manually,
        /// but provides a more idiomatic Swift concurrency pattern.
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withRequestHandler(CallTool.self) { params, context in
        ///     for item in largeDataset {
        ///         try context.checkCancellation()  // Throws if cancelled
        ///         try await process(item)
        ///     }
        ///     return CallTool.Result(content: [.text("Done")])
        /// }
        /// ```
        ///
        /// - Throws: `CancellationError` if the request has been cancelled.
        public func checkCancellation() throws {
            try Task.checkCancellation()
        }
    }

    /// A type-erased pending request for server→client requests (bidirectional communication).
    private struct AnyServerPendingRequest {
        private let _yield: (Result<Any, Swift.Error>) -> Void
        private let _finish: () -> Void

        init<T: Sendable & Decodable>(
            continuation: AsyncThrowingStream<T, Swift.Error>.Continuation
        ) {
            _yield = { result in
                switch result {
                case .success(let value):
                    if let typedValue = value as? T {
                        continuation.yield(typedValue)
                        continuation.finish()
                    } else if let value = value as? Value,
                        let data = try? JSONEncoder().encode(value),
                        let decoded = try? JSONDecoder().decode(T.self, from: data)
                    {
                        continuation.yield(decoded)
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: MCPError.internalError("Type mismatch in response"))
                    }
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
            _finish = {
                continuation.finish()
            }
        }

        func resume(returning value: Any) {
            _yield(.success(value))
        }

        func resume(throwing error: Swift.Error) {
            _yield(.failure(error))
        }

        func finish() {
            _finish()
        }
    }

    /// Server information
    private let serverInfo: Server.Info
    /// The server connection
    private var connection: (any Transport)?
    /// The server logger
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The server name
    public nonisolated var name: String { serverInfo.name }
    /// The server version
    public nonisolated var version: String { serverInfo.version }
    /// Instructions describing how to use the server and its features
    ///
    /// This can be used by clients to improve the LLM's understanding of 
    /// available tools, resources, etc. 
    /// It can be thought of like a "hint" to the model. 
    /// For example, this information MAY be added to the system prompt.
    public nonisolated let instructions: String?
    /// The server capabilities
    public var capabilities: Capabilities
    /// The server configuration
    public var configuration: Configuration

    /// Experimental APIs for tasks and other features.
    ///
    /// Access experimental features via this property:
    /// ```swift
    /// // Enable task support with in-memory storage
    /// await server.experimental.tasks.enable()
    ///
    /// // Or with custom configuration
    /// let taskSupport = TaskSupport.inMemory()
    /// await server.experimental.tasks.enable(taskSupport)
    /// ```
    ///
    /// - Warning: These APIs are experimental and may change without notice.
    public var experimental: ExperimentalServerFeatures {
        ExperimentalServerFeatures(server: self)
    }

    /// Request handlers
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Pending requests sent from server to client (for bidirectional communication)
    private var pendingRequests: [RequestId: AnyServerPendingRequest] = [:]
    /// Counter for generating unique request IDs
    private var nextRequestId = 0
    /// Response routers for intercepting responses before normal handling
    private var responseRouters: [any ResponseRouter] = []

    /// Whether the server is initialized
    private var isInitialized = false
    /// The client information
    private var clientInfo: Client.Info?
    /// The client capabilities
    private var clientCapabilities: Client.Capabilities?
    /// The protocol version
    private var protocolVersion: String?
    /// The list of subscriptions
    private var subscriptions: [String: Set<RequestId>] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?
    /// Per-session minimum log levels set by clients.
    ///
    /// For HTTP transports with multiple concurrent clients, each session can
    /// independently set its own log level. The key is the session ID (`nil` for
    /// transports without session support like stdio).
    ///
    /// Log messages below a session's level will be filtered out for that session.
    private var loggingLevels: [String?: LoggingLevel] = [:]

    /// In-flight request handler Tasks, tracked by request ID.
    /// Used for protocol-level cancellation when CancelledNotification is received.
    private var inFlightHandlerTasks: [RequestId: Task<Void, Never>] = [:]

    public init(
        name: String,
        version: String,
        instructions: String? = nil,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default
    ) {
        self.serverInfo = Server.Info(name: name, version: version)
        self.capabilities = capabilities
        self.configuration = configuration
        self.instructions = instructions
    }

    /// Start the server
    /// - Parameters:
    ///   - transport: The transport to use for the server
    ///   - initializeHook: An optional hook that runs when the client sends an initialize request
    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil
    ) async throws {
        self.connection = transport
        registerDefaultHandlers(initializeHook: initializeHook)
        try await transport.connect()

        await logger?.debug(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        task = Task {
            do {
                let stream = await transport.receive()
                for try await data in stream {
                    if Task.isCancelled { break }  // Check cancellation inside loop

                    var requestID: RequestId?
                    do {
                        // Attempt to decode as batch first, then as individual request, response, or notification
                        let decoder = JSONDecoder()
                        if let batch = try? decoder.decode(Server.Batch.self, from: data) {
                            // Spawn batch handler in a separate task for the same reason
                            // as individual requests - to support nested server-to-client
                            // requests within batch item handlers.
                            Task { [weak self] in
                                guard let self else { return }
                                do {
                                    try await self.handleBatch(batch)
                                } catch {
                                    await self.logger?.error(
                                        "Error handling batch",
                                        metadata: ["error": "\(error)"]
                                    )
                                }
                            }
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            // Handle response from client (for server→client requests)
                            await handleClientResponse(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            // Spawn request handler in a separate task to avoid blocking
                            // the message loop. This allows nested server-to-client requests
                            // (like elicitation or sampling) to work correctly - the handler
                            // can await a response while the message loop continues processing
                            // incoming messages including that response.
                            let requestId = request.id
                            let handlerTask = Task { [weak self] in
                                guard let self else { return }
                                defer {
                                    Task { await self.removeInFlightRequest(requestId) }
                                }
                                do {
                                    _ = try await self.handleRequest(request, sendResponse: true)
                                } catch {
                                    // handleRequest already sends error responses, so this
                                    // only catches errors from send() itself
                                    await self.logger?.error(
                                        "Error sending response",
                                        metadata: ["error": "\(error)", "requestId": "\(request.id)"]
                                    )
                                }
                            }
                            trackInFlightRequest(requestId, task: handlerTask)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            try await handleMessage(message)
                        } else {
                            // Try to extract request ID from raw JSON if possible
                            if let json = try? JSONDecoder().decode(
                                [String: Value].self, from: data),
                                let idValue = json["id"]
                            {
                                if let strValue = idValue.stringValue {
                                    requestID = .string(strValue)
                                } else if let intValue = idValue.intValue {
                                    requestID = .number(intValue)
                                }
                            }
                            throw MCPError.parseError("Invalid message format")
                        }
                    } catch {
                        // Note: EAGAIN handling is not needed here - the transport layer
                        // handles it internally. Message handling code won't throw EAGAIN.
                        await logger?.error(
                            "Error processing message", metadata: ["error": "\(error)"])
                        let response = AnyMethod.response(
                            id: requestID ?? .random,
                            error: error as? MCPError
                                ?? MCPError.internalError(error.localizedDescription)
                        )
                        try? await send(response)
                    }
                }
            } catch {
                await logger?.error(
                    "Fatal error in message handling loop", metadata: ["error": "\(error)"])
            }
            await logger?.debug("Server finished", metadata: [:])
        }
    }

    /// Stop the server
    public func stop() async {
        // Cancel all in-flight request handlers
        for (requestId, handlerTask) in inFlightHandlerTasks {
            handlerTask.cancel()
            await logger?.debug(
                "Cancelled in-flight request during shutdown",
                metadata: ["id": "\(requestId)"]
            )
        }
        inFlightHandlerTasks.removeAll()

        task?.cancel()
        task = nil
        if let connection = connection {
            await connection.disconnect()
        }
        connection = nil
    }

    public func waitUntilCompleted() async {
        await task?.value
    }

    // MARK: - Registration

    /// Register a method handler with access to request context.
    ///
    /// The context provides capabilities like sending notifications during request
    /// processing, with correct routing to the requesting client.
    ///
    /// - Parameters:
    ///   - type: The method type to handle
    ///   - handler: The handler function receiving parameters and context
    /// - Returns: Self for chaining
    @discardableResult
    public func withRequestHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters, RequestHandlerContext) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = TypedRequestHandler { (request: Request<M>, context: RequestHandlerContext) -> Response<M> in
            let result = try await handler(request.params, context)
            return Response(id: request.id, result: result)
        }
        return self
    }

    /// Register a method handler without context.
    ///
    /// - Parameters:
    ///   - type: The method type to handle
    ///   - handler: The handler function receiving only parameters
    /// - Returns: Self for chaining
    @available(*, deprecated, message: "Use withRequestHandler(_:handler:) with RequestHandlerContext for correct notification routing")
    @discardableResult
    public func withRequestHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        withRequestHandler(type) { params, _ in
            try await handler(params)
        }
    }

    // MARK: - Deprecated Method Handler Registration

    /// Register a request handler for a method (deprecated, use withRequestHandler instead)
    @available(*, deprecated, renamed: "withRequestHandler")
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters, RequestHandlerContext) async throws -> M.Result
    ) -> Self {
        withRequestHandler(type, handler: handler)
    }

    /// Register a request handler for a method (deprecated, use withRequestHandler instead)
    @available(*, deprecated, renamed: "withRequestHandler")
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        withRequestHandler(type, handler: handler)
    }

    /// Register a notification handler
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) -> Self {
        notificationHandlers[N.name, default: []].append(TypedNotificationHandler(handler))
        return self
    }

    /// Register a response router to intercept responses before normal handling.
    ///
    /// Response routers are checked in order before falling back to the default
    /// pending request handling. This is used by TaskResultHandler to route
    /// responses for queued task requests back to their resolvers.
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// - Parameter router: The response router to add
    /// - Returns: Self for chaining
    @discardableResult
    public func addResponseRouter(_ router: any ResponseRouter) -> Self {
        responseRouters.append(router)
        return self
    }

    // MARK: - Sending

    /// Send a response to a request
    public func send<M: Method>(_ response: Response<M>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let responseData = try encoder.encode(response)
        try await connection.send(responseData)
    }

    /// Send a notification to connected clients
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a log message notification to connected clients.
    ///
    /// This method can be called outside of request handlers to send log messages
    /// asynchronously. The message will only be sent if:
    /// - The server has declared the `logging` capability
    /// - The message's level is at or above the minimum level set by the session
    ///
    /// If the logging capability is not declared, this method silently returns without
    /// sending (matching TypeScript SDK behavior).
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: An optional name for the logger producing the message
    ///   - data: The log message data (can be a string or structured data)
    ///   - sessionId: Optional session ID for per-session log level filtering.
    ///     If `nil`, the log level for the nil-session (default) is used.
    public func sendLogMessage(
        level: LoggingLevel,
        logger: String? = nil,
        data: Value,
        sessionId: String? = nil
    ) async throws {
        // Check if logging capability is declared (matching TypeScript SDK behavior)
        guard capabilities.logging != nil else { return }

        // Check if this message should be sent based on the session's log level
        guard shouldSendLogMessage(at: level, forSession: sessionId) else { return }

        try await notify(LogMessageNotification.message(.init(
            level: level,
            logger: logger,
            data: data
        )))
    }

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
    private func handleBatch(_ batch: Batch) async throws {
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
    private struct RequestContext {
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
    private func send<M: Method>(_ response: Response<M>, using context: RequestContext) async throws {
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
    private func handleRequest(_ request: Request<AnyMethod>, sendResponse: Bool = true)
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

    private func handleMessage(_ message: Message<AnyNotification>) async throws {
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
    private func handleClientResponse(_ response: Response<AnyMethod>) async {
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

    // MARK: - Server→Client Requests (Bidirectional Communication)

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
            Task { await self?.cleanupPendingRequest(id: requestId) }
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

    private func cleanupPendingRequest(id: RequestId) {
        pendingRequests.removeValue(forKey: id)
    }

    // MARK: - In-Flight Request Tracking (Protocol-Level Cancellation)

    /// Track an in-flight request handler Task.
    private func trackInFlightRequest(_ requestId: RequestId, task: Task<Void, Never>) {
        inFlightHandlerTasks[requestId] = task
    }

    /// Remove an in-flight request handler Task.
    private func removeInFlightRequest(_ requestId: RequestId) {
        inFlightHandlerTasks.removeValue(forKey: requestId)
    }

    /// Cancel an in-flight request handler Task.
    ///
    /// Called when a CancelledNotification is received for a specific requestId.
    /// Per MCP spec, if the request is unknown or already completed, this is a no-op.
    private func cancelInFlightRequest(_ requestId: RequestId, reason: String?) async {
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
    private func generateRequestId() -> RequestId {
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

    private func checkInitialized() throws {
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
            Task { await self?.cleanupPendingRequest(id: requestId) }
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
            Task { await self?.cleanupPendingRequest(id: requestId) }
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

    private func registerDefaultHandlers(
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)?
    ) {
        // Initialize
        withRequestHandler(Initialize.self) { [weak self] params, _ in
            guard let self = self else {
                throw MCPError.internalError("Server was deallocated")
            }

            guard await !self.isInitialized else {
                throw MCPError.invalidRequest("Server is already initialized")
            }

            // Call initialization hook if registered
            if let hook = initializeHook {
                try await hook(params.clientInfo, params.capabilities)
            }

            // Perform version negotiation
            let clientRequestedVersion = params.protocolVersion
            let negotiatedProtocolVersion = Version.negotiate(
                clientRequestedVersion: clientRequestedVersion)

            // Set initial state with the negotiated protocol version
            await self.setInitialState(
                clientInfo: params.clientInfo,
                clientCapabilities: params.capabilities,
                protocolVersion: negotiatedProtocolVersion
            )

            return Initialize.Result(
                protocolVersion: negotiatedProtocolVersion,
                capabilities: await self.capabilities,
                serverInfo: self.serverInfo,
                instructions: self.instructions
            )
        }

        // Ping
        withRequestHandler(Ping.self) { _, _ in return Empty() }

        // CancelledNotification: Handle cancellation of in-flight requests
        onNotification(CancelledNotification.self) { [weak self] message in
            guard let self else { return }
            guard let requestId = message.params.requestId else {
                // Per protocol 2025-11-25+, requestId is optional.
                // If not provided, we cannot cancel a specific request.
                return
            }
            await self.cancelInFlightRequest(requestId, reason: message.params.reason)
        }

        // Logging: Set minimum log level (only if logging capability is enabled)
        if capabilities.logging != nil {
            withRequestHandler(SetLoggingLevel.self) { [weak self] params, context in
                guard let self else {
                    throw MCPError.internalError("Server was deallocated")
                }
                await self.setLoggingLevel(params.level, forSession: context.sessionId)
                return Empty()
            }
        }
    }

    /// Set the minimum log level for messages sent to a specific session.
    ///
    /// After this is set, only log messages at this level or higher (more severe)
    /// will be sent to clients in this session via `sendLogMessage`.
    ///
    /// - Parameters:
    ///   - level: The minimum log level to send.
    ///   - sessionId: The session identifier, or `nil` for transports without sessions.
    private func setLoggingLevel(_ level: LoggingLevel, forSession sessionId: String?) {
        loggingLevels[sessionId] = level
    }

    /// Check if a log message at the given level should be sent to a specific session.
    ///
    /// Returns `false` if:
    /// - The logging capability is not declared, OR
    /// - The message level is below the minimum level set by the client for this session
    ///
    /// - Parameters:
    ///   - level: The level of the log message to check.
    ///   - sessionId: The session identifier, or `nil` for transports without sessions.
    /// - Returns: `true` if the message should be sent, `false` if it should be filtered out.
    func shouldSendLogMessage(at level: LoggingLevel, forSession sessionId: String?) -> Bool {
        // Check if logging capability is declared (matching TypeScript SDK behavior)
        guard capabilities.logging != nil else { return false }

        guard let sessionLevel = loggingLevels[sessionId] else {
            // If no level is set for this session, send all messages (per MCP spec:
            // "If no logging/setLevel request has been sent from the client, the server
            // MAY decide which messages to send automatically")
            return true
        }
        return level.isAtLeast(sessionLevel)
    }

    private func setInitialState(
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        protocolVersion: String
    ) async {
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.protocolVersion = protocolVersion
        self.isInitialized = true
    }
}

extension Server.Batch: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var items: [Item] = []
        for item in try container.decode([Value].self) {
            let data = try encoder.encode(item)
            try items.append(decoder.decode(Item.self, from: data))
        }

        self.items = items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items)
    }
}

extension Server.Batch.Item: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Check if it's a request (has id) or notification (no id)
        if container.contains(.id) {
            self = .request(try Request<AnyMethod>(from: decoder))
        } else {
            self = .notification(try Message<AnyNotification>(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let request):
            try request.encode(to: encoder)
        case .notification(let notification):
            try notification.encode(to: encoder)
        }
    }
}
