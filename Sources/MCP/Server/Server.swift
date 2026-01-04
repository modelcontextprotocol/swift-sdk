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
    struct AnyServerPendingRequest {
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
    let serverInfo: Server.Info
    /// The server connection
    var connection: (any Transport)?
    /// The server logger
    var logger: Logger? {
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
    var methodHandlers: [String: RequestHandlerBox] = [:]
    /// Notification handlers
    var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Pending requests sent from server to client (for bidirectional communication)
    var pendingRequests: [RequestId: AnyServerPendingRequest] = [:]
    /// Counter for generating unique request IDs
    var nextRequestId = 0
    /// Response routers for intercepting responses before normal handling
    var responseRouters: [any ResponseRouter] = []

    /// Whether the server is initialized
    var isInitialized = false
    /// The client information
    var clientInfo: Client.Info?
    /// The client capabilities
    var clientCapabilities: Client.Capabilities?
    /// The protocol version
    var protocolVersion: String?
    /// The list of subscriptions
    var subscriptions: [String: Set<RequestId>] = [:]
    /// The task for the message handling loop
    var task: Task<Void, Never>?
    /// Per-session minimum log levels set by clients.
    ///
    /// For HTTP transports with multiple concurrent clients, each session can
    /// independently set its own log level. The key is the session ID (`nil` for
    /// transports without session support like stdio).
    ///
    /// Log messages below a session's level will be filtered out for that session.
    var loggingLevels: [String?: LoggingLevel] = [:]

    /// In-flight request handler Tasks, tracked by request ID.
    /// Used for protocol-level cancellation when CancelledNotification is received.
    var inFlightHandlerTasks: [RequestId: Task<Void, Never>] = [:]

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

    func registerDefaultHandlers(
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
    func setLoggingLevel(_ level: LoggingLevel, forSession sessionId: String?) {
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

    func setInitialState(
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
