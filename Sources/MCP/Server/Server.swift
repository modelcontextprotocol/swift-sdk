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
        /// A human-readable server title for display
        public let title: String?
        /// The server version
        public let version: String
        /// Optional description of the server
        public let description: String?
        /// Optional website URL for the server
        public let websiteUrl: String?
        /// Optional set of sized icons for display in a user interface
        public let icons: [Icon]?

        public init(
            name: String,
            version: String,
            title: String? = nil,
            description: String? = nil,
            websiteUrl: String? = nil,
            icons: [Icon]? = nil
        ) {
            self.name = name
            self.title = title
            self.version = version
            self.description = description
            self.websiteUrl = websiteUrl
            self.icons = icons
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

        /// Completions capabilities
        public var completions: Completions?
        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Tools capabilities
        public var tools: Tools?

        public init(
            completions: Completions? = nil,
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil
        ) {
            self.completions = completions
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
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

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private let decoder = JSONDecoder()

    /// The server name
    public nonisolated var name: String { serverInfo.name }
    /// A human-readable server title
    public nonisolated var title: String? { serverInfo.title }
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
    /// Pending request tasks (for cancellation support)
    private var pendingRequestTasks: [ID: Task<Response<AnyMethod>, Error>] = [:]

    /// In-flight `subscriptions/listen` request ids (subset of `pendingRequestTasks`).
    private var activeListenSubscriptions: Set<ID> = []

    /// Pending requests sent to the client, awaiting responses
    private var pendingRequests: [ID: AnyPendingRequest] = [:]

    /// Whether the server is initialized
    private var isInitialized = false
    /// Whether any modern (2026-07-28+) request has been accepted.
    /// Modern clients never call `initialize`; notifications must still work.
    private var hasAcceptedModernRequest = false
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
        title: String? = nil,
        instructions: String? = nil,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default
    ) {
        self.serverInfo = Server.Info(name: name, version: version, title: title)
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
        registerCancellationHandler()
        try await transport.connect()

        await logger?.debug(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"]
        )

        // Start message handling loop
        task = Task {
            do {
                let stream = await transport.receive()
                for try await data in stream {
                    if Task.isCancelled { break }  // Check cancellation inside loop

                    var requestID: ID?
                    do {
                        // Attempt to decode as batch first, then as individual response, request, or notification
                        if let batch = try? decoder.decode(Server.Batch.self, from: data) {
                            try await handleBatch(batch)
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            await handleResponse(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            // Handle request in a separate task to avoid blocking the receive loop
                            Task {
                                _ = try? await self.handleRequest(request, sendResponse: true)
                            }
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            try await handleMessage(message)
                        } else {
                            // Try to extract request ID from raw JSON if possible
                            if let json = try? decoder.decode(
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

        // Clear pending requests with errors
        let pendingRequestsToCancel = self.pendingRequests
        self.pendingRequests = [:]
        for (_, request) in pendingRequestsToCancel {
            request.resume(throwing: MCPError.internalError("Server disconnected"))
        }

        // Cancel in-flight method handlers (e.g. parked subscriptions/listen)
        let pendingTasks = pendingRequestTasks
        pendingRequestTasks = [:]
        activeListenSubscriptions = []
        hasAcceptedModernRequest = false
        isInitialized = false
        clientCapabilities = nil
        for (_, handlerTask) in pendingTasks {
            handlerTask.cancel()
        }

        if let connection = connection {
            await connection.disconnect()
        }
        connection = nil
    }

    public func waitUntilCompleted() async {
        await task?.value
    }

    // MARK: - Request Context

    /// Per-dispatch context the SDK attaches to the currently executing handler.
    ///
    /// Exposed via the ``Server/currentHandlerContext`` task-local so method
    /// handlers can observe the originating HTTP request (headers, auth, path,
    /// body) without changing the `withMethodHandler` signature.
    public struct HandlerContext: Sendable {
        /// The JSON-RPC request id of the in-flight request.
        ///
        /// Use with ``completeSubscriptionsListen(id:)`` to end a parked
        /// `subscriptions/listen` stream from outside the listen handler.
        public let id: ID

        /// The originating HTTP request, if the active transport conforms to
        /// ``HTTPContextProviding``. `nil` for transports that don't carry HTTP
        /// context (stdio, in-memory) or for handlers reached off the dispatch
        /// path.
        public let httpContext: HTTPRequest?

        /// Per-request client capabilities from modern `_meta`, when present.
        public let clientCapabilities: Client.Capabilities?

        package init(
            id: ID,
            httpContext: HTTPRequest?,
            clientCapabilities: Client.Capabilities? = nil
        ) {
            self.id = id
            self.httpContext = httpContext
            self.clientCapabilities = clientCapabilities
        }
    }

    /// The handler context for the currently executing method handler.
    ///
    /// Set via `@TaskLocal` before dispatching each request, so it propagates
    /// automatically into the handler task. `nil` outside of a handler.
    ///
    /// When spawning `Task.detached { … }` from inside a handler, capture the
    /// value up front — detached tasks do not inherit task-locals:
    ///
    /// ```swift
    /// let ctx = Server.currentHandlerContext
    /// Task.detached { await doWork(with: ctx?.httpContext) }
    /// ```
    @TaskLocal public static var currentHandlerContext: HandlerContext? = nil

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
        notificationHandlers[N.name, default: []].append(TypedNotificationHandler(handler))
        return self
    }

    // MARK: - Sending

    /// Send a response to a request
    public func send<M: Method>(_ response: Response<M>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let responseData = try encoder.encode(response)
        try await connection.send(responseData)
    }

    /// Send a notification to connected clients
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a request to the client and return a Task for the response
    private func send<M: Method>(_ request: Request<M>) throws -> Task<M.Result, Error> {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let requestData = try encoder.encode(request)

        let requestTask = Task<M.Result, Error> {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    // Add pending response before sending
                    self.addPendingResponse(
                        id: request.id,
                        continuation: continuation,
                        type: M.Result.self
                    )

                    // Send the request
                    do {
                        try await connection.send(requestData)
                    } catch {
                        // If send fails, remove pending response and resume with error
                        if self.removePendingResponse(id: request.id) != nil {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }

        return requestTask
    }


    private func addPendingResponse<T: Sendable & Decodable>(
        id: ID,
        continuation: CheckedContinuation<T, Swift.Error>,
        type: T.Type
    ) {
        pendingRequests[id] = AnyPendingRequest(
            PendingRequest(continuation: continuation)
        )
    }

    private func removePendingResponse(id: ID) -> AnyPendingRequest? {
        return pendingRequests.removeValue(forKey: id)
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
    ///   - _meta: Optional request metadata
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
        _meta: Metadata? = nil
    ) async throws -> CreateSamplingMessage.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.sampling, "Sampling")

        let request = CreateSamplingMessage.request(
            .init(
                messages: messages,
                modelPreferences: modelPreferences,
                systemPrompt: systemPrompt,
                includeContext: includeContext,
                temperature: temperature,
                maxTokens: maxTokens,
                stopSequences: stopSequences,
                _meta: _meta
            )
        )

        let result = try await send(request).value
        return result
    }

    // MARK: - Elicitation

    /// Request user input from the client using form-based elicitation
    ///
    /// Elicitation allows servers to request user input during operations.
    /// This is useful for collecting user feedback, confirmations, or data
    /// that the server needs but doesn't have.
    ///
    /// The flow:
    /// 1. Server requests elicitation with a message and optional schema
    /// 2. Client displays the request to the user
    /// 3. User provides input or declines
    /// 4. Client returns the result to the server
    ///
    /// - Parameters:
    ///   - message: The message to display to the user
    ///   - mode: The elicitation mode (form or url)
    ///   - requestedSchema: Optional JSON schema describing the expected response
    ///   - _meta: Optional request metadata
    /// - Returns: The elicitation result containing the action and optional content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/elicitation
    public func requestElicitation(
        message: String,
        requestedSchema: Elicitation.RequestSchema,
        mode: Elicitation.Mode? = nil,
        _meta: Metadata? = nil
    ) async throws -> CreateElicitation.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.elicitation, "Elicitation")

        let request = CreateElicitation.request(
            .form(
                .init(
                    message: message,
                    mode: mode,
                    requestedSchema: requestedSchema,
                    _meta: _meta
                )
            )
        )

        let result = try await send(request).value
        return result
    }

    /// Request user input from the client using URL-based elicitation
    ///
    /// URL-based elicitation directs the user to an external URL for authentication
    /// or data collection. This is useful for OAuth flows or other web-based input.
    ///
    /// - Parameters:
    ///   - message: The message to display to the user
    ///   - url: The URL to direct the user to
    ///   - elicitationId: Unique identifier for this elicitation
    ///   - _meta: Optional request metadata
    /// - Returns: The elicitation result containing the action and optional content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/elicitation
    public func requestElicitation(
        message: String,
        url: String,
        elicitationId: String,
        _meta: Metadata? = nil
    ) async throws -> CreateElicitation.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.elicitation, "Elicitation")

        let request = CreateElicitation.request(
            .url(
                .init(
                    message: message,
                    url: url,
                    elicitationId: elicitationId,
                    _meta: _meta
                )
            )
        )

        let result = try await send(request).value
        return result
    }

    // MARK: - Logging

    /// Send a log message notification to connected clients.
    ///
    /// Servers that declare the `logging` capability can send structured log messages
    /// to clients. The client controls which severity levels it wants to receive via
    /// the `logging/setLevel` request.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: Optional logger name to identify the source
    ///   - data: Arbitrary JSON-serializable data for the log message
    /// - Throws: MCPError if the server is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    public func log(
        level: LogLevel,
        logger: String? = nil,
        data: Value
    ) async throws {
        let notification = LogMessageNotification.message(
            .init(level: level, logger: logger, data: data)
        )
        try await notify(notification)
    }

    /// Send a log message notification with codable data.
    ///
    /// Convenience method that encodes data to JSON before sending.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: Optional logger name to identify the source
    ///   - data: Any codable data for the log message
    /// - Throws: MCPError if the server is not connected or encoding fails
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    public func log<T: Codable>(
        level: LogLevel,
        logger: String? = nil,
        data: T
    ) async throws {
        let value = try Value(data)
        try await log(level: level, logger: logger, data: value)
    }

    // MARK: - Roots

    /// Request the list of roots from the connected client
    ///
    /// Roots define filesystem boundaries that servers can operate within.
    /// The client must have declared the `roots` capability and registered
    /// a roots handler for this to work.
    ///
    /// - Returns: Array of Root objects representing accessible directories/files
    /// - Throws: MCPError if the client doesn't support roots or request fails
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    public func listRoots() async throws -> [Root] {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.roots, "Roots")

        let request = ListRoots.request()
        let result = try await send(request).value
        return result.roots
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

        // Modern (2026-07-28+) requests carry protocol version in params._meta
        // and do not require initialize. Legacy strict mode still gates other methods.
        let requestProtocolVersion = ModernRequestMeta.protocolVersion(from: request.params)
        let hasPerRequestCaps =
            ModernRequestMeta.clientCapabilities(from: request.params) != nil
        // `initialize` is always legacy — never classify it as modern.
        let isModernRequest =
            request.method != Initialize.name
            && (request.method == Discover.name
                || request.method == SubscriptionsListen.name
                || (requestProtocolVersion.map(Version.isModern) ?? false)
                || hasPerRequestCaps)

        if request.method == Initialize.name,
            (requestProtocolVersion.map(Version.isModern) ?? false) || hasPerRequestCaps
        {
            let response = AnyMethod.response(
                id: request.id,
                error: .invalidRequest(
                    "initialize must not carry modern per-request metadata; use server/discover"
                )
            )
            if sendResponse {
                try await send(response)
                return nil
            }
            return response
        }

        if let requestProtocolVersion {
            do {
                if isModernRequest || Version.isModern(requestProtocolVersion) {
                    // Discover/listen and modern-meta requests only accept modern revisions.
                    try Version.requireSupported(requestProtocolVersion)
                } else if !Version.supported.contains(requestProtocolVersion) {
                    throw MCPError.unsupportedProtocolVersion(
                        requested: requestProtocolVersion,
                        supported: Array(Version.supported).sorted(by: >)
                    )
                }
            } catch {
                let mcpError =
                    error as? MCPError ?? MCPError.internalError(error.localizedDescription)
                let response = AnyMethod.response(id: request.id, error: mcpError)
                if sendResponse {
                    try await send(response)
                    return nil
                }
                return response
            }
        }

        // Modern requests MUST include per-request clientCapabilities (empty object OK).
        if isModernRequest,
            !ModernRequestMeta.hasRequiredClientCapabilities(params: request.params)
        {
            let response = AnyMethod.response(
                id: request.id,
                error: .invalidParams(
                    "Missing \(ProtocolMetaKey.clientCapabilities) in params._meta"
                )
            )
            if sendResponse {
                try await send(response)
                return nil
            }
            return response
        }

        // Modern-shaped requests require a protocol version (discover/listen always,
        // or any request that already declared clientCapabilities).
        if requestProtocolVersion == nil,
            isModernRequest
                || ModernRequestMeta.clientCapabilities(from: request.params) != nil
        {
            let response = AnyMethod.response(
                id: request.id,
                error: .invalidParams(
                    "Missing \(ProtocolMetaKey.protocolVersion) in params._meta"
                )
            )
            if sendResponse {
                try await send(response)
                return nil
            }
            return response
        }

        var requestClientCapabilities: Client.Capabilities? = nil
        if isModernRequest {
            if let capsValue = ModernRequestMeta.clientCapabilities(from: request.params),
                case .object = capsValue
            {
                if let capsData = try? JSONEncoder().encode(capsValue),
                    let caps = try? JSONDecoder().decode(Client.Capabilities.self, from: capsData)
                {
                    requestClientCapabilities = caps
                } else {
                    requestClientCapabilities = Client.Capabilities()
                }
            }
        }

        if configuration.strict && !isModernRequest {
            // The client SHOULD NOT send requests other than pings
            // before the server has responded to the initialize request.
            switch request.method {
            case Initialize.name, Ping.name, Discover.name:
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

        if isModernRequest {
            hasAcceptedModernRequest = true
        }

        // Ask the transport for the originating HTTP request so handlers can observe
        // headers/auth via `Server.currentHandlerContext?.httpContext`. Transports
        // that don't carry HTTP context (stdio, in-memory) don't conform.
        let httpContext = await (connection as? any HTTPContextProviding)?
            .httpRequestContext(for: request.id)
        let handlerContext = HandlerContext(
            id: request.id,
            httpContext: httpContext,
            clientCapabilities: requestClientCapabilities
        )
        let serverInfoValue: [String: Value] = [
            "name": .string(serverInfo.name),
            "version": .string(serverInfo.version),
        ]

        // Create a task to handle the request with cancellation support.
        // Set currentHandlerContext as a task local so handlers see it.
        var handlerTask: Task<Response<AnyMethod>, Error>!
        Server.$currentHandlerContext.withValue(handlerContext) {
            handlerTask = Task<Response<AnyMethod>, Error> {
                do {
                    // Check if task was cancelled before starting
                    try Task.checkCancellation()

                    // Handle request and get response
                    let response = try await handler(request)
                    guard isModernRequest else { return response }
                    switch response.result {
                    case .success(let value):
                        let enriched = value.ensuringModernCompleteResult(
                            serverInfo: serverInfoValue
                        )
                        return Response(id: response.id, result: enriched)
                    case .failure:
                        return response
                    }
                } catch is CancellationError {
                    // Request was cancelled, don't send a response per MCP spec
                    await logger?.debug(
                        "Request cancelled",
                        metadata: ["id": "\(request.id)", "method": "\(request.method)"]
                    )
                    throw CancellationError()
                } catch {
                    let mcpError =
                        error as? MCPError ?? MCPError.internalError(error.localizedDescription)
                    return AnyMethod.response(id: request.id, error: mcpError)
                }
            }
        }

        // Store the handler task for potential cancellation
        pendingRequestTasks[request.id] = handlerTask
        if request.method == SubscriptionsListen.name {
            activeListenSubscriptions.insert(request.id)
        }

        // Ensure cleanup happens regardless of success or failure
        defer {
            pendingRequestTasks.removeValue(forKey: request.id)
            if request.method == SubscriptionsListen.name {
                activeListenSubscriptions.remove(request.id)
            }
        }

        do {
            let response = try await handlerTask.value

            if sendResponse {
                try await send(response)
                return nil
            }

            return response
        } catch is CancellationError {
            // Request was cancelled, don't send a response per MCP spec.
            // Close any parked HTTP SSE so listen fan-out cannot keep delivering.
            await (connection as? any HTTPContextProviding)?
                .closeRequestStream(for: request.id)
            return nil
        } catch {
            // This should not happen as errors are caught in the task
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
            // Legacy clients must initialize. Modern clients never call initialize;
            // after any modern request (or for cancelled during listen setup), allow
            // notifications through.
            let modernExempt =
                hasAcceptedModernRequest
                || message.method == CancelledNotification.name
            if message.method != InitializedNotification.name && !modernExempt {
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

    private func handleResponse(_ response: Response<AnyMethod>) async {
        if let pendingRequest = self.removePendingResponse(id: response.id) {
            switch response.result {
            case .success(let value):
                pendingRequest.resume(returning: value)
            case .failure(let error):
                pendingRequest.resume(throwing: error)
            }
        } else {
            await logger?.warning(
                "Received response for unknown request",
                metadata: ["id": "\(response.id)"]
            )
        }
    }

    private func checkInitialized() throws {
        guard isInitialized else {
            throw MCPError.invalidRequest("Server is not initialized")
        }
    }

    /// Validate the client capabilities.
    /// Throws an error if the server is configured to be strict and the capability is not supported.
    private func validateClientCapability<T>(
        _ keyPath: KeyPath<Client.Capabilities, T?>,
        _ name: String
    )
        throws
    {
        if configuration.strict {
            let capabilities =
                Self.currentHandlerContext?.clientCapabilities ?? clientCapabilities
            guard let capabilities else {
                throw MCPError.methodNotFound("Client capabilities not initialized")
            }
            guard capabilities[keyPath: keyPath] != nil else {
                throw MCPError.methodNotFound("\(name) is not supported by the client")
            }
        }
    }

    private func registerDefaultHandlers(
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)?
    ) {
        // Initialize
        withMethodHandler(Initialize.self) { params in

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

        // Modern protocol: server/discover (no initialize required)
        withMethodHandler(Discover.self) { _ in
            let versions = Array(Array(Version.supported).sorted().reversed())
            var meta = Metadata()
            meta.fields[ProtocolMetaKey.serverInfo] = .object([
                "name": .string(self.serverInfo.name),
                "version": .string(self.serverInfo.version),
            ])
            return Discover.Result(
                supportedVersions: versions,
                capabilities: await self.capabilities,
                cacheScope: .private,
                ttlMs: 0,
                instructions: self.instructions,
                _meta: meta
            )
        }

        // Modern protocol: subscriptions/listen — parks until cancelled.
        // Client cancellation closes the stream / sends cancelled; no result.
        // Notification filters are enforced by the stateful HTTP transport.
        withMethodHandler(SubscriptionsListen.self) { params in
            if let version = params._meta[ProtocolMetaKey.protocolVersion]?.stringValue {
                try Version.requireSupported(version)
            }
            // Id is tracked at dispatch in handleRequest for completeSubscriptionsListen.
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3600))
            }
            throw CancellationError()
        }
    }

    /// Ends a modern `subscriptions/listen` stream gracefully with a complete result.
    ///
    /// Sends a `resultType: complete` response while the HTTP SSE stream is still
    /// registered, then cancels the parked listen handler. Unknown, already-finished,
    /// or non-listen request ids are ignored.
    ///
    /// Capture ``HandlerContext/id`` from ``currentHandlerContext`` while a listen
    /// (or any) request is in flight, or call ``completeAllSubscriptionsListen()``.
    public func completeSubscriptionsListen(id: ID) async throws {
        guard activeListenSubscriptions.contains(id) else { return }
        guard let task = removePendingRequest(id: id) else {
            activeListenSubscriptions.remove(id)
            return
        }
        activeListenSubscriptions.remove(id)
        // Emit complete before cancelling so response routing closes the SSE;
        // cancelling first races with closeRequestStream and drops the result.
        // Always cancel the parked handler — even when send throws — so it cannot
        // linger after being removed from pendingRequestTasks.
        let result = SubscriptionsListen.Result(subscriptionId: id)
        do {
            try await send(Response<SubscriptionsListen>(id: id, result: result))
        } catch {
            task.cancel()
            await (connection as? any HTTPContextProviding)?.closeRequestStream(for: id)
            throw error
        }
        task.cancel()
        _ = try? await task.value
    }

    /// Ends every in-flight modern `subscriptions/listen` stream.
    public func completeAllSubscriptionsListen() async throws {
        let ids = Array(activeListenSubscriptions)
        var firstError: Error?
        for id in ids {
            do {
                try await completeSubscriptionsListen(id: id)
            } catch {
                await logger?.warning(
                    "completeSubscriptionsListen failed",
                    metadata: ["id": "\(id)", "error": "\(error)"]
                )
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
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

    /// Cancel and remove a pending request task
    private func removePendingRequest(id: ID) -> Task<Response<AnyMethod>, Error>? {
        pendingRequestTasks.removeValue(forKey: id)
    }

    private func registerCancellationHandler() {
        onNotification(CancelledNotification.self) { message in

            let requestId = message.params.requestId
            let reason = message.params.reason

            await self.logger?.debug(
                "Received cancellation notification",
                metadata: [
                    "requestId": requestId.map { "\($0)" } ?? "none",
                    "reason": reason.map { "\($0)" } ?? "none",
                ]
            )

            guard let requestId = requestId else {
                await self.logger?.warning(
                    "Received cancellation notification with no requestId (violates spec MUST)",
                    metadata: ["reason": reason.map { "\($0)" } ?? "none"]
                )
                return
            }

            // Cancel the pending request task if it exists and remove from tracking
            if let task = await self.removePendingRequest(id: requestId) {
                task.cancel()
                await self.logger?.debug(
                    "Cancelled request",
                    metadata: ["requestId": "\(requestId)"]
                )
            } else {
                // Request may have already completed or is unknown
                // Per MCP spec, we should ignore this gracefully
                await self.logger?.trace(
                    "Cancellation notification for unknown or completed request",
                    metadata: ["requestId": "\(requestId)"]
                )
            }
            // Always attempt to close a parked HTTP SSE for this id (idempotent).
            await (self.connection as? any HTTPContextProviding)?
                .closeRequestStream(for: requestId)
        }
    }

    /// Cancel a request by sending a CancelledNotification to the client.
    ///
    /// This is used when the server needs to cancel an in-progress request it made to the client
    /// (e.g., a sampling request).
    ///
    /// According to the MCP specification, cancellation is advisory:
    /// - The client SHOULD stop processing and free resources
    /// - The client MAY ignore the cancellation if the request is unknown, already completed,
    ///   or cannot be cancelled
    /// - The server SHOULD ignore any response that arrives after cancellation
    ///
    /// - Parameters:
    ///   - requestID: The ID of the request to cancel
    ///   - reason: An optional human-readable reason for the cancellation
    /// - Throws: MCPError if the notification cannot be sent
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    public func cancelRequest(_ requestID: ID, reason: String? = nil) async throws {
        // Send cancellation notification to client
        let notification = CancelledNotification.message(
            .init(requestId: requestID, reason: reason)
        )
        try await notify(notification)
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
