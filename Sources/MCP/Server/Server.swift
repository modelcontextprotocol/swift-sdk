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

        public init(name: String, version: String) {
            self.name = name
            self.version = version
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

        /// Sampling capabilities
        public struct Sampling: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Sampling capabilities
        public var sampling: Sampling?
        /// Tools capabilities
        public var tools: Tools?

        public init(
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            sampling: Sampling? = nil,
            tools: Tools? = nil
        ) {
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.sampling = sampling
            self.tools = tools
        }
    }
    
    /// Context provided to request handlers for sending notifications during execution.
    ///
    /// When a request handler needs to send notifications (e.g., progress updates during
    /// a long-running tool), it should use this context to ensure the notification is
    /// routed to the correct client, even if other clients have connected in the meantime.
    ///
    /// This context provides:
    /// - Request identification (`requestId`, `_meta`)
    /// - Session tracking (`sessionId`)
    /// - Authentication context (`authInfo`)
    /// - Notification sending (`sendNotification`, `sendMessage`, `sendProgress`)
    /// - Bidirectional requests (`elicit`, `elicitUrl`)
    /// - Cancellation checking (`isCancelled`, `checkCancellation`)
    /// - SSE stream management (`closeSSEStream`, `closeStandaloneSSEStream`)
    ///
    /// Example:
    /// ```swift
    /// server.withMethodHandler(CallTool.self) { params, context in
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
        
        /// The JSON-RPC ID of the request being handled.
        ///
        /// This can be useful for tracking, logging, or correlating messages.
        /// It matches the TypeScript SDK's `extra.requestId`.
        public let requestId: ID
        
        /// The request metadata from the `_meta` field, if present.
        ///
        /// Contains metadata like the progress token for progress notifications.
        /// This matches the TypeScript SDK's `extra._meta` and Python's `ctx.meta`.
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withMethodHandler(CallTool.self) { request, context in
        ///     if let progressToken = context._meta?.progressToken {
        ///         try await context.sendProgress(token: progressToken, progress: 50, total: 100)
        ///     }
        ///     return CallTool.Result(content: [.text("Done")])
        /// }
        /// ```
        public let _meta: RequestMeta?
        
        /// The task ID for task-augmented requests, if present.
        ///
        /// This is a convenience property that extracts the task ID from the
        /// `_meta["io.modelcontextprotocol/related-task"]` field.
        ///
        /// This matches the TypeScript SDK's `extra.taskId`.
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withMethodHandler(CallTool.self) { params, context in
        ///     if let taskId = context.taskId {
        ///         print("Handling request as part of task: \(taskId)")
        ///     }
        ///     return CallTool.Result(content: [.text("Done")])
        /// }
        /// ```
        public var taskId: String? {
            _meta?.relatedTaskId
        }
        
        /// Authentication information for this request.
        ///
        /// Contains validated access token information when using HTTP transports
        /// with OAuth or other token-based authentication.
        ///
        /// This matches the TypeScript SDK's `extra.authInfo`.
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withMethodHandler(CallTool.self) { params, context in
        ///     if let authInfo = context.authInfo {
        ///         print("Authenticated as: \(authInfo.clientId)")
        ///         print("Scopes: \(authInfo.scopes)")
        ///
        ///         // Check if token has required scope
        ///         guard authInfo.scopes.contains("tools:execute") else {
        ///             throw MCPError.invalidRequest("Missing required scope")
        ///         }
        ///     }
        ///     return CallTool.Result(content: [.text("Done")])
        /// }
        /// ```
        public let authInfo: AuthInfo?
        
        /// Information about the incoming HTTP request.
        ///
        /// Contains HTTP headers from the original request. Only available for
        /// HTTP transports.
        ///
        /// This matches the TypeScript SDK's `extra.requestInfo`.
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withMethodHandler(CallTool.self) { params, context in
        ///     if let requestInfo = context.requestInfo {
        ///         // Access custom headers
        ///         if let apiVersion = requestInfo.header("X-API-Version") {
        ///             print("Client API version: \(apiVersion)")
        ///         }
        ///     }
        ///     return CallTool.Result(content: [.text("Done")])
        /// }
        /// ```
        public let requestInfo: RequestInfo?
        
        /// Send a request to the client and wait for a response.
        ///
        /// This enables bidirectional communication from within a request handler,
        /// allowing servers to request information from the client (e.g., elicitation,
        /// sampling) during request processing.
        ///
        /// This matches the TypeScript SDK's `extra.sendRequest()` functionality.
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withMethodHandler(CallTool.self) { request, context in
        ///     // Request user input via elicitation
        ///     let result = try await context.elicit(
        ///         message: "Please confirm the operation",
        ///         requestedSchema: ElicitationSchema(properties: [
        ///             "confirm": .boolean(BooleanSchema(title: "Confirm"))
        ///         ])
        ///     )
        ///
        ///     if result.action == .accept {
        ///         // Process confirmed action
        ///     }
        ///     return CallTool.Result(content: [.text("Done")])
        /// }
        /// ```
        let sendRequest: @Sendable (Data) async throws -> Value
        
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
        /// server.withMethodHandler(CallTool.self) { params, context in
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
        /// server.withMethodHandler(CallTool.self) { params, context in
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
    

    /// Request handlers
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Whether the server is initialized
    private var isInitialized = false
    /// The client information
    private var clientInfo: Client.Info?
    /// The client capabilities
    private var clientCapabilities: Client.Capabilities?
    /// The protocol version
    private var protocolVersion: String?
    /// The list of subscriptions
    private var subscriptions: [String: Set<ID>] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

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

                    var requestID: ID?
                    do {
                        // Attempt to decode as batch first, then as individual request or notification
                        let decoder = JSONDecoder()
                        if let batch = try? decoder.decode(Server.Batch.self, from: data) {
                            try await handleBatch(batch)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            _ = try await handleRequest(request, sendResponse: true)
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
                    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                        // Resource temporarily unavailable, retry after a short delay
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    } catch {
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

    /// Register a method handler
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = TypedRequestHandler { (request: Request<M>) -> Response<M> in
            let result = try await handler(request.params)
            return Response(id: request.id, result: result)
        }
        return self
    }

    /// Register a notification handler
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
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

    // MARK: - Sampling

    /// Request sampling from the connected client
    ///
    /// Sampling allows servers to request LLM completions through the client,
    /// enabling sophisticated agentic behaviors while maintaining human-in-the-loop control.
    ///
    /// The sampling flow follows these steps:
    /// 1. Server sends a `sampling/createMessage` request to the client
    /// 2. Client reviews the request and can modify it
    /// 3. Client samples from an LLM
    /// 4. Client reviews the completion
    /// 5. Client returns the result to the server
    ///
    /// - Parameters:
    ///   - messages: The conversation history to send to the LLM
    ///   - modelPreferences: Model selection preferences
    ///   - systemPrompt: Optional system prompt
    ///   - includeContext: What MCP context to include
    ///   - temperature: Controls randomness (0.0 to 1.0)
    ///   - maxTokens: Maximum tokens to generate
    ///   - stopSequences: Array of sequences that stop generation
    ///   - metadata: Additional provider-specific parameters
    /// - Returns: The sampling result containing the model used, stop reason, role, and content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/sampling#how-sampling-works
    public func requestSampling(
        messages: [Sampling.Message],
        modelPreferences: Sampling.ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        maxTokens: Int,
        stopSequences: [String]? = nil,
        metadata: [String: Value]? = nil
    ) async throws -> CreateSamplingMessage.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        // Note: This is a conceptual implementation. The actual implementation would require
        // bidirectional communication support in the transport layer, allowing servers to
        // send requests to clients and receive responses.

        _ = CreateSamplingMessage.request(
            .init(
                messages: messages,
                modelPreferences: modelPreferences,
                systemPrompt: systemPrompt,
                includeContext: includeContext,
                temperature: temperature,
                maxTokens: maxTokens,
                stopSequences: stopSequences,
                metadata: metadata
            )
        )

        // This would need to be implemented with proper request/response handling
        // similar to how the client sends requests to servers
        throw MCPError.internalError(
            "Bidirectional sampling requests not yet implemented in transport layer")
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
        await logger?.trace("Processing batch request", metadata: ["size": "\(batch.items.count)"])

        if batch.items.isEmpty {
            // Empty batch is invalid according to JSON-RPC spec
            let error = MCPError.invalidRequest("Batch array must not be empty")
            let response = AnyMethod.response(id: .random, error: error)
            try await send(response)
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

        // Send collected responses if any
        if !responses.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let responseData = try encoder.encode(responses)

            guard let connection = connection else {
                throw MCPError.internalError("Server connection not initialized")
            }

            try await connection.send(responseData)
        }
    }

    // MARK: - Request and Message Handling

    /// Handle a request and either send the response immediately or return it
    ///
    /// - Parameters:
    ///   - request: The request to handle
    ///   - sendResponse: Whether to send the response immediately (true) or return it (false)
    /// - Returns: The response when sendResponse is false
    private func handleRequest(_ request: Request<AnyMethod>, sendResponse: Bool = true)
        async throws -> Response<AnyMethod>?
    {
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
                try await send(response)
                return nil
            }

            return response
        }

        do {
            // Handle request and get response
            let response = try await handler(request)

            if sendResponse {
                try await send(response)
                return nil
            }

            return response
        } catch {
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)

            if sendResponse {
                try await send(response)
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

    private func checkInitialized() throws {
        guard isInitialized else {
            throw MCPError.invalidRequest("Server is not initialized")
        }
    }

    private func registerDefaultHandlers(
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)?
    ) {
        // Initialize
        withMethodHandler(Initialize.self) { [weak self] params in
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
        withMethodHandler(Ping.self) { _ in return Empty() }
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
