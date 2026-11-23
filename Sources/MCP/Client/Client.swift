import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol client
public actor Client {
    /// The client configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the client:
        /// - Requires server capabilities to be initialized before making requests
        /// - Rejects all requests that require capabilities before initialization
        ///
        /// While the MCP specification requires servers to respond to initialize requests
        /// with their capabilities, some implementations may not follow this.
        /// Disabling strict mode allows the client to be more lenient with non-compliant
        /// servers, though this may lead to undefined behavior.
        public var strict: Bool

        /// How the client opens a connection.
        public var protocolMode: ProtocolMode

        /// The lowest log level to request on stateless (2026-07-28) connections,
        /// sent in each request's `_meta`. `nil` requests no log notifications.
        public var logLevel: LogLevel?

        /// How long ``ProtocolMode/automatic`` waits for the answer to
        /// `server/discover` before it falls back to `initialize`. `nil`
        /// waits indefinitely. Other requests, and `connect` as a whole,
        /// have no timeout.
        public var discoveryTimeout: Duration?

        public init(
            strict: Bool = false,
            protocolMode: ProtocolMode = .handshake,
            logLevel: LogLevel? = nil,
            discoveryTimeout: Duration? = .seconds(10)
        ) {
            self.strict = strict
            self.protocolMode = protocolMode
            self.logLevel = logLevel
            self.discoveryTimeout = discoveryTimeout
        }

        private enum CodingKeys: String, CodingKey {
            case strict, protocolMode, logLevel, discoveryTimeout
        }

        /// Decodes a configuration; keys added after `strict` are optional.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            strict = try container.decode(Bool.self, forKey: .strict)
            protocolMode = try container.decodeIfPresent(ProtocolMode.self, forKey: .protocolMode) ?? .handshake
            logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel)
            discoveryTimeout =
                container.contains(.discoveryTimeout)
                ? try container.decodeIfPresent(Duration.self, forKey: .discoveryTimeout) : .seconds(10)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(strict, forKey: .strict)
            try container.encode(protocolMode, forKey: .protocolMode)
            try container.encodeIfPresent(logLevel, forKey: .logLevel)
            try container.encode(discoveryTimeout, forKey: .discoveryTimeout)
        }
    }

    /// How the client opens a connection.
    public enum ProtocolMode: Hashable, Codable, Sendable {
        /// Use the `initialize` handshake (2025-11-25 and earlier).
        case handshake
        /// Send `server/discover` at the newest stateless revision, retry once
        /// with a version the server lists on -32022, and fall back to
        /// `initialize` when the server does not serve a stateless revision:
        /// it answers with a JSON-RPC error, lists only handshake revisions,
        /// refuses the request with HTTP 400, 404 or 405, or does not answer
        /// within ``Configuration/discoveryTimeout``. Other transport errors,
        /// such as authorization failures, 429 or 5xx, are rethrown.
        case automatic
        /// Use one stateless revision; fail if the server does not serve it.
        case stateless(String)
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The client name
        public var name: String
        /// A human-readable title for display purposes
        public var title: String?
        /// The client version
        public var version: String
        /// Optional description of the client
        public var description: String?
        /// Optional website URL for the client
        public var websiteUrl: String?
        /// Optional set of sized icons for display in a user interface
        public var icons: [Icon]?

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

    /// The client capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// The roots capabilities
        public struct Roots: Hashable, Codable, Sendable {
            /// Whether the list of roots has changed
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// The sampling capabilities
        public struct Sampling: Hashable, Sendable {
            /// Tools sub-capability for sampling
            public struct Tools: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Context sub-capability for sampling
            public struct Context: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Whether tools are supported in sampling
            public var tools: Tools?
            /// Whether context is supported in sampling
            public var context: Context?

            public init(tools: Tools? = nil, context: Context? = nil) {
                self.tools = tools
                self.context = context
            }
        }

        /// The elicitation capabilities
        public struct Elicitation: Hashable, Sendable {
            /// Form-based elicitation sub-capability
            public struct Form: Hashable, Codable, Sendable {
                public init() {}
            }

            /// URL-based elicitation sub-capability
            public struct URL: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Whether form-based elicitation is supported
            public var form: Form?
            /// Whether URL-based elicitation is supported
            public var url: URL?

            public init(form: Form? = Form(), url: URL? = nil) {
                self.form = form
                self.url = url
            }
        }

        /// Whether the client supports sampling
        public var sampling: Sampling?
        /// Whether the client supports elicitation
        public var elicitation: Elicitation?
        /// Experimental features supported by the client
        public var experimental: [String: Value]?
        /// Whether the client supports roots
        public var roots: Capabilities.Roots?
        /// Protocol extensions supported by the client, keyed by extension
        /// identifier (for example `io.modelcontextprotocol/tasks`), with
        /// extension-defined settings (SEP-2133).
        public var extensions: [String: Value]?

        public init(
            sampling: Sampling? = nil,
            elicitation: Elicitation? = nil,
            experimental: [String: Value]? = nil,
            roots: Capabilities.Roots? = nil,
            extensions: [String: Value]? = nil
        ) {
            self.sampling = sampling
            self.elicitation = elicitation
            self.experimental = experimental
            self.roots = roots
            self.extensions = extensions
        }
    }

    /// The connection to the server
    private var connection: (any Transport)?
    /// The logger for the client
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The client information
    private let clientInfo: Client.Info
    /// The client name
    public nonisolated var name: String { clientInfo.name }
    /// A human-readable client title
    public nonisolated var title: String? { clientInfo.title }
    /// The client version
    public nonisolated var version: String { clientInfo.version }

    /// The client capabilities
    public var capabilities: Client.Capabilities
    /// The client configuration
    public var configuration: Configuration

    /// The server capabilities, known after ``connect(transport:)``.
    public private(set) var serverCapabilities: Server.Capabilities?
    /// The negotiated protocol version, known after ``connect(transport:)``.
    public private(set) var negotiatedProtocolVersion: String?
    /// The server implementation, known after ``connect(transport:)``.
    public private(set) var serverInfo: Server.Info?
    /// The server instructions
    private var instructions: String?
    /// `x-mcp-header` arguments of listed tools, by tool name.
    private(set) var toolHeaderParameters: [String: [MCPRequestHeaders.Parameter]] = [:]
    /// Whether the connection uses a stateless revision (2026-07-28 and later),
    /// where every request carries its `_meta` envelope.
    public var isStateless: Bool {
        negotiatedProtocolVersion.map { Version.profile(for: $0).usesRequestMeta } ?? false
    }

    /// A dictionary of type-erased notification handlers, keyed by method name
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// Method handlers for server-to-client requests
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    /// A dictionary of type-erased pending requests, keyed by request ID
    private var pendingRequests: [ID: AnyPendingRequest] = [:]
    // Add reusable JSON encoder/decoder
    private let encoder = JSONEncoder()
    /// Decodes incoming messages with `data:` URL strings kept as strings;
    /// handlers get `.data` from their own typed decode.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.userInfo[.valuePreservesStrings] = true
        return decoder
    }()

    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        websiteUrl: String? = nil,
        icons: [Icon]? = nil,
        capabilities: Capabilities = Capabilities(),
        configuration: Configuration = .default
    ) {
        self.clientInfo = Client.Info(
            name: name, version: version, title: title,
            description: description, websiteUrl: websiteUrl, icons: icons)
        self.capabilities = capabilities
        self.configuration = configuration
    }

    /// Connect to the server using the given transport
    @discardableResult
    public func connect(transport: any Transport) async throws -> Initialize.Result {
        // A reconnect negotiates afresh; requests must not carry the
        // previous connection's stateless `_meta`.
        serverCapabilities = nil
        negotiatedProtocolVersion = nil
        serverInfo = nil
        instructions = nil
        self.connection = transport
        toolHeaderParameters = [:]
        try await self.connection?.connect()

        await logger?.debug(
            "Client connected", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        task = Task {
            guard let connection = self.connection else { return }
            repeat {
                // Check for cancellation before starting the iteration
                if Task.isCancelled { break }

                do {
                    let stream = await connection.receive()
                    for try await data in stream {
                        if Task.isCancelled { break }  // Check inside loop too

                        // Attempt to decode data
                        // Try decoding as a batch response first
                        if let batchResponse = try? decoder.decode([AnyResponse].self, from: data) {
                            await handleBatchResponse(batchResponse)
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            await handleResponse(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            await handleIncomingRequest(request)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            await handleMessage(message)
                        } else {
                            var metadata: Logger.Metadata = [:]
                            if let string = String(data: data, encoding: .utf8) {
                                metadata["message"] = .string(string)
                            }
                            await logger?.warning(
                                "Unexpected message received by client (not single/batch response or notification)",
                                metadata: metadata
                            )
                        }
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    await logger?.error(
                        "Error in message handling loop", metadata: ["error": "\(error)"])
                    break
                }
            } while true
            await self.logger?.debug("Client message handling loop task is terminating.")
        }

        // Register cancellation notification handler
        await self.onNotification(CancelledNotification.self) { message in

            let requestId = message.params.requestId
            let reason = message.params.reason

            await self.logger?.debug(
                "Received cancellation notification",
                metadata: [
                    "requestId": requestId.map { "\($0)" } ?? "none",
                    "reason": reason.map { "\($0)" } ?? "none",
                ]
            )

            // Remove the pending request and resume with cancellation error
            if let requestId = requestId,
                let pendingRequest = await self.removePendingRequest(id: requestId)
            {
                pendingRequest.resume(throwing: CancellationError())
            }
        }

        // Open the protocol connection
        switch configuration.protocolMode {
        case .handshake:
            return try await _initialize()
        case .automatic:
            return try await discoverOrInitialize(Version.stateless[0], fallback: true)
        case .stateless(let version):
            return try await discoverOrInitialize(version, fallback: false)
        }
    }

    /// Disconnect the client and cancel all pending requests
    public func disconnect() async {
        await logger?.debug("Initiating client disconnect...")

        // Part 1: Inside actor - Grab state and clear internal references
        let taskToCancel = self.task
        let connectionToDisconnect = self.connection
        let pendingRequestsToCancel = self.pendingRequests

        self.task = nil
        self.connection = nil
        self.pendingRequests = [:]  // Use empty dictionary literal
        self.toolHeaderParameters = [:]

        // Part 2: Outside actor - Resume continuations, disconnect transport, await task

        // Resume continuations first
        for (_, request) in pendingRequestsToCancel {
            request.resume(throwing: MCPError.internalError("Client disconnected"))
        }
        await logger?.debug("Pending requests cancelled.")

        // Cancel the task
        taskToCancel?.cancel()
        await logger?.debug("Message loop task cancellation requested.")

        // Disconnect the transport *before* awaiting the task
        // This should ensure the transport stream is finished, unblocking the loop.
        if let conn = connectionToDisconnect {
            await conn.disconnect()
            await logger?.debug("Transport disconnected.")
        } else {
            await logger?.debug("No active transport connection to disconnect.")
        }

        // Await the task completion *after* transport disconnect
        _ = await taskToCancel?.value
        await logger?.debug("Client message loop task finished.")

        await logger?.debug("Client disconnect complete.")
    }

    // MARK: - Registration

    /// Register a handler for a notification
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self {
        notificationHandlers[N.name, default: []].append(TypedNotificationHandler(handler))
        return self
    }

    /// Register a handler for server-to-client requests
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

    /// Send a notification to the server
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a response back to the server for a server-to-client request
    private func send<M: Method>(_ response: Response<M>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }
        let responseData = try encoder.encode(response)
        try await connection.send(responseData)
    }

    // MARK: - Requests

    /// Send a request and return a RequestContext that wraps both the request ID and the Task.
    ///
    /// This allows you to track and cancel the request by sending a CancelledNotification
    /// to the server using the requestID.
    ///
    /// Example:
    /// ```swift
    /// let context = try await client.send(request)
    /// // Later, to cancel:
    /// try await client.cancelRequest(context.requestID, reason: "User cancelled")
    /// // Await the result:
    /// let result = try await context.value
    /// ```
    ///
    /// - Parameter request: The request to send
    /// - Returns: A RequestContext containing the request ID and Task
    /// - Throws: MCPError if the client is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    public func send<M: Method>(_ request: Request<M>) throws -> RequestContext<M.Result> {
        try send(request, markingSendFailures: false)
    }

    /// A transport error raised while sending a request, as opposed to the
    /// peer's answer.
    private struct SendFailure: Swift.Error {
        let error: Swift.Error
    }

    /// Sends a request. With `markingSendFailures`, transport errors are
    /// wrapped in ``SendFailure``.
    private func send<M: Method>(
        _ request: Request<M>, markingSendFailures: Bool
    ) throws -> RequestContext<M.Result> {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        var request = request
        var headers: [String: String] = [:]
        if isStateless, let version = negotiatedProtocolVersion {
            request._meta = requestMeta(version: version, merging: request._meta)
            if let call = request.params as? CallTool.Parameters,
                let parameters = toolHeaderParameters[call.name]
            {
                headers = MCPRequestHeaders.parameterHeaders(
                    parameters, arguments: call.arguments.map(Value.object))
            }
        }
        let requestData = try encoder.encode(request)
        let firstToolPage = (request.params as? ListTools.Parameters).map { $0.cursor == nil } ?? false

        let requestTask = Task<M.Result, Error> {
            let value: M.Result = try await withCheckedThrowingContinuation { continuation in
                Task {
                    // Add the pending request before attempting to send
                    self.addPendingRequest(
                        id: request.id,
                        continuation: continuation,
                        type: M.Result.self
                    )

                    // Send the request data
                    do {
                        if !headers.isEmpty {
                            try await connection.send(requestData, additionalHeaders: headers)
                        } else {
                            try await connection.send(requestData)
                        }
                    } catch {
                        // If send fails, try to remove the pending request.
                        if self.removePendingRequest(id: request.id) != nil {
                            continuation.resume(throwing: markingSendFailures ? SendFailure(error: error) : error)
                        }
                    }
                }
            }
            if let listed = value as? ListTools.Result,
                let filtered = await self.recordTools(listed, firstPage: firstToolPage)
            {
                return filtered as! M.Result
            }
            return value
        }

        return RequestContext(requestID: request.id, requestTask: requestTask)
    }

    /// Cancel a request by sending a CancelledNotification to the server.
    ///
    /// According to the MCP specification, cancellation is advisory:
    /// - The server SHOULD stop processing and free resources
    /// - The server MAY ignore the cancellation if the request is unknown, already completed,
    ///   or cannot be cancelled
    /// - The client SHOULD ignore any response that arrives after cancellation
    ///
    /// This method removes the pending request and resumes it with CancellationError,
    /// ensuring that any response arriving after cancellation is ignored.
    ///
    /// - Parameters:
    ///   - requestID: The ID of the request to cancel
    ///   - reason: An optional human-readable reason for the cancellation
    /// - Throws: MCPError if the notification cannot be sent
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    public func cancelRequest(_ requestID: ID, reason: String? = nil) async throws {
        // Remove the pending request and resume with cancellation error
        // This ensures any response that arrives after cancellation is ignored
        if let pendingRequest = removePendingRequest(id: requestID) {
            pendingRequest.resume(throwing: CancellationError())
        }

        // Send cancellation notification to server
        let notification = CancelledNotification.message(
            .init(requestId: requestID, reason: reason)
        )
        try await notify(notification)
    }


    private func addPendingRequest<T: Sendable & Decodable>(
        id: ID,
        continuation: CheckedContinuation<T, Swift.Error>,
        type: T.Type  // Keep type for AnyPendingRequest internal logic
    ) {
        pendingRequests[id] = AnyPendingRequest(
            PendingRequest(continuation: continuation)
        )
    }

    private func removePendingRequest(id: ID) -> AnyPendingRequest? {
        return pendingRequests.removeValue(forKey: id)
    }

    // MARK: - Batching

    /// A batch of requests.
    ///
    /// Objects of this type are passed as an argument to the closure
    /// of the ``Client/withBatch(body:)`` method.
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

            // Return a Task that registers the pending request and awaits its result.
            // The continuation is resumed when the response arrives.
            return Task<M.Result, Swift.Error> {
                try await withCheckedThrowingContinuation { continuation in
                    // We are already inside a Task, but need another Task
                    // to bridge to the client actor's context.
                    Task {
                        await client.addPendingRequest(
                            id: request.id,
                            continuation: continuation,
                            type: M.Result.self
                        )
                    }
                }
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
    public func withBatch(body: @escaping @Sendable (Batch) async throws -> Void) async throws {
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

    // MARK: - Lifecycle

    /// Initialize the connection with the server.
    ///
    /// - Important: This method is deprecated. Initialization now happens automatically
    ///   when calling `connect(transport:)`. You should use that method instead.
    ///
    /// - Returns: The server's initialization response containing capabilities and server info
    @available(
        *, deprecated,
        message:
            "Initialization now happens automatically during connect. Use connect(transport:) instead."
    )
    public func initialize() async throws -> Initialize.Result {
        return try await _initialize()
    }

    /// Internal initialization implementation
    private func _initialize() async throws -> Initialize.Result {
        let request = Initialize.request(
            .init(
                protocolVersion: Version.latest,
                capabilities: capabilities,
                clientInfo: clientInfo
            ))

        let result = try await send(request).value

        self.serverCapabilities = result.capabilities
        self.negotiatedProtocolVersion = result.protocolVersion
        self.serverInfo = result.serverInfo
        self.instructions = result.instructions

        // For HTTP transport, ensure subsequent MCP-Protocol-Version headers
        // reflect the negotiated lifecycle version.
        if let httpTransport = connection as? HTTPClientTransport {
            await httpTransport.updateNegotiatedProtocolVersion(result.protocolVersion)
        }

        try await notify(InitializedNotification.message())

        return result
    }

    /// On stateless connections, records the `x-mcp-header` arguments of each
    /// listed tool and drops tools with invalid annotations (SEP-2243).
    /// Returns `nil` on handshake connections.
    /// Records the `x-mcp-header` parameters of listed tools and drops
    /// tools with invalid annotations. A first page (no cursor) replaces
    /// what earlier listings recorded.
    private func recordTools(_ result: ListTools.Result, firstPage: Bool) async -> ListTools.Result? {
        guard isStateless else { return nil }
        if firstPage { toolHeaderParameters = [:] }
        var valid: [Tool] = []
        for tool in result.tools {
            do {
                toolHeaderParameters[tool.name] = try tool.headerParameters()
                valid.append(tool)
            } catch {
                toolHeaderParameters[tool.name] = nil
                await logger?.warning(
                    "Ignoring tool with an invalid x-mcp-header annotation",
                    metadata: ["tool": "\(MCPRequestHeaders.sanitized(tool.name))", "error": "\(error)"])
            }
        }
        guard valid.count != result.tools.count else { return result }
        return ListTools.Result(
            tools: valid, nextCursor: result.nextCursor, _meta: result._meta,
            ttlMs: result.ttlMs, cacheScope: result.cacheScope)
    }

    /// The `_meta` envelope of a stateless request; keys already in `existing` win.
    private func requestMeta(version: String, merging existing: Metadata?) -> Metadata {
        var meta = Metadata()
        meta.protocolVersion = version
        meta.clientCapabilities = capabilities
        meta.clientInfo = clientInfo
        meta.logLevel = configuration.logLevel
        if let existing {
            meta.fields.merge(existing.fields) { _, own in own }
        }
        return meta
    }

    /// Opens a stateless connection with `server/discover` (SEP-2575).
    ///
    /// On -32022 the request is retried once with the newest stateless
    /// version the server lists. With `fallback`, any other protocol error,
    /// or a server without a stateless revision in common, falls back to
    /// `initialize`. Transport errors are rethrown.
    private func discoverOrInitialize(_ preferred: String, fallback: Bool) async throws
        -> Initialize.Result
    {
        var version = preferred
        var retried = false
        while true {
            let request = ServerDiscover.request(
                .init(), _meta: requestMeta(version: version, merging: nil))
            // Only discovery runs inside the do: an error from the
            // `initialize` fallback must not be handled as a discovery error.
            let result: ServerDiscover.Result
            do {
                let context = try send(request, markingSendFailures: true)
                result = try await discoverResult(
                    context, timeout: fallback ? configuration.discoveryTimeout : nil)
            } catch MCPError.unsupportedProtocolVersion(let supported, let requested) {
                if fallback, !retried, let mutual = supported.first(where: Version.stateless.contains) {
                    retried = true
                    version = mutual
                    continue
                }
                if fallback, supported.isEmpty || supported.contains(where: Version.handshake.contains) {
                    return try await _initialize()
                }
                throw MCPError.unsupportedProtocolVersion(supported: supported, requested: requested)
            } catch let failure as SendFailure {
                guard fallback, HTTPClientTransport.isSessionlessRefusal(failure.error) else {
                    throw failure.error
                }
                await logger?.info(
                    "server/discover refused; falling back to initialize",
                    metadata: ["error": "\(failure.error)"])
                return try await _initialize()
            } catch is DiscoverTimeout {
                await logger?.info("server/discover timed out; falling back to initialize")
                return try await _initialize()
            } catch let error as MCPError where fallback {
                // The peer answered with a JSON-RPC error.
                await logger?.info(
                    "server/discover failed; falling back to initialize",
                    metadata: ["error": "\(error)"])
                return try await _initialize()
            }
            let served =
                result.supportedVersions.contains(version)
                ? version
                : fallback ? result.supportedVersions.first(where: Version.stateless.contains) : nil
            guard let served else {
                if fallback { return try await _initialize() }
                throw MCPError.unsupportedProtocolVersion(
                    supported: result.supportedVersions, requested: version)
            }
            return await adopt(result, version: served)
        }
    }

    /// The probe of ``ProtocolMode/automatic`` went unanswered.
    private struct DiscoverTimeout: Swift.Error {}

    /// Awaits a `server/discover` result. After `timeout`, the request is
    /// abandoned, its HTTP POST closed, and ``DiscoverTimeout`` thrown.
    private func discoverResult(
        _ context: RequestContext<ServerDiscover.Result>, timeout: Duration?
    ) async throws -> ServerDiscover.Result {
        guard let timeout else { return try await context.value }
        let timer = Task {
            guard (try? await Task.sleep(for: timeout)) != nil,
                let pending = removePendingRequest(id: context.requestID)
            else { return }
            // No notifications/cancelled: the server may not know the request.
            await (connection as? HTTPClientTransport)?.cancelRequest(context.requestID)
            pending.resume(throwing: DiscoverTimeout())
        }
        defer { timer.cancel() }
        return try await context.value
    }

    /// Records a `server/discover` result as the connection state.
    private func adopt(_ result: ServerDiscover.Result, version: String) async -> Initialize.Result {
        let info = result.serverInfo ?? Server.Info(name: "", version: "")
        serverCapabilities = result.capabilities
        negotiatedProtocolVersion = version
        serverInfo = info
        instructions = result.instructions
        if let httpTransport = connection as? HTTPClientTransport {
            await httpTransport.useStatelessProtocol(version)
        }
        return Initialize.Result(
            protocolVersion: version,
            capabilities: result.capabilities,
            serverInfo: info,
            instructions: result.instructions
        )
    }

    /// Checks that the server is reachable.
    ///
    /// On stateless connections, where `ping` does not exist, this sends
    /// `server/discover` instead.
    public func ping() async throws {
        if isStateless {
            _ = try await send(ServerDiscover.request(.init())).value
            return
        }
        let request = Ping.request()
        _ = try await send(request).value
    }

    // MARK: - Prompts

    public func getPrompt(name: String, arguments: [String: String]? = nil) async throws
        -> (description: String?, messages: [Prompt.Message])
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        let result = try await send(request).value
        return (description: result.description, messages: result.messages)
    }

    public func listPrompts(cursor: String? = nil) async throws
        -> (prompts: [Prompt], nextCursor: String?)
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request: Request<ListPrompts>
        if let cursor = cursor {
            request = ListPrompts.request(.init(cursor: cursor))
        } else {
            request = ListPrompts.request(.init())
        }
        let result = try await send(request).value
        return (prompts: result.prompts, nextCursor: result.nextCursor)
    }

    // MARK: - Resources

    public func readResource(uri: String) async throws -> [Resource.Content] {
        try validateServerCapability(\.resources, "Resources")
        let request = ReadResource.request(.init(uri: uri))
        let result = try await send(request).value
        return result.contents
    }

    public func listResources(cursor: String? = nil) async throws -> (
        resources: [Resource], nextCursor: String?
    ) {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResources>
        if let cursor = cursor {
            request = ListResources.request(.init(cursor: cursor))
        } else {
            request = ListResources.request(.init())
        }
        let result = try await send(request).value
        return (resources: result.resources, nextCursor: result.nextCursor)
    }

    public func subscribeToResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await send(request).value
    }

    public func listResourceTemplates(cursor: String? = nil) async throws -> (
        templates: [Resource.Template], nextCursor: String?
    ) {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResourceTemplates>
        if let cursor = cursor {
            request = ListResourceTemplates.request(.init(cursor: cursor))
        } else {
            request = ListResourceTemplates.request(.init())
        }
        let result = try await send(request).value
        return (templates: result.templates, nextCursor: result.nextCursor)
    }

    // MARK: - Tools

    public func listTools(cursor: String? = nil) async throws -> (
        tools: [Tool], nextCursor: String?
    ) {
        try validateServerCapability(\.tools, "Tools")
        let request: Request<ListTools>
        if let cursor = cursor {
            request = ListTools.request(.init(cursor: cursor))
        } else {
            request = ListTools.request(.init())
        }
        let result = try await send(request).value
        return (tools: result.tools, nextCursor: result.nextCursor)
    }

    /// Call a tool on the server.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Arguments to use for the tool call.
    ///   - meta: Optional request metadata including progress token. If `progressToken` is specified,
    ///           the caller is requesting out-of-band progress notifications for this request.
    ///           Use `onNotification(ProgressNotification.self)` to receive progress updates.
    /// - Returns: A tuple containing the tool's content response and an optional error flag.
    /// - Note: For advanced use cases requiring cancellation support, use `send()` directly to get a `RequestContext`.
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#calling-tools
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil,
        meta: Metadata? = nil
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments, meta: meta))
        let result = try await send(request).value
        return (content: result.content, isError: result.isError)
    }

    /// Call a tool on the server.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Arguments to use for the tool call.
    ///   - meta: Optional request metadata including progress token. If `progressToken` is specified,
    ///           the caller is requesting out-of-band progress notifications for this request.
    ///           Use `onNotification(ProgressNotification.self)` to receive progress updates.
    /// - Returns: A tuple containing the tool's content response and an optional error flag.
    /// - Note: For advanced use cases requiring cancellation support, use `send()` directly to get a `RequestContext`.
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#calling-tools
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil,
        meta: Metadata? = nil
    ) throws -> RequestContext<CallTool.Result> {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments, meta: meta))
        return try send(request)
    }

    // MARK: - Sampling

    /// Register a handler for sampling requests from servers
    ///
    /// Sampling allows servers to request LLM completions through the client,
    /// enabling sophisticated agentic behaviors while maintaining human-in-the-loop control.
    ///
    /// The sampling flow follows these steps:
    /// 1. Server sends a `sampling/createMessage` request to the client
    /// 2. Client reviews the request and can modify it (via this handler)
    /// 3. Client samples from an LLM (via this handler)
    /// 4. Client reviews the completion (via this handler)
    /// 5. Client returns the result to the server
    ///
    /// - Parameter handler: A closure that processes sampling requests and returns completions
    /// - Returns: Self for method chaining
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/sampling#how-sampling-works
    @discardableResult
    public func withSamplingHandler(
        _ handler:
            @escaping @Sendable (CreateSamplingMessage.Parameters) async throws ->
            CreateSamplingMessage.Result
    ) -> Self {
        return withMethodHandler(CreateSamplingMessage.self, handler: handler)
    }

    // MARK: - Elicitation

    /// Register a handler for elicitation requests from servers
    ///
    /// The elicitation flow lets servers collect structured input from users during
    /// ongoing interactions. Clients remain in control by mediating the prompt,
    /// collecting the response, and returning the chosen action to the server.
    ///
    /// - Parameter handler: A closure that processes elicitation requests and returns user actions
    /// - Returns: Self for method chaining
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
    @discardableResult
    public func withElicitationHandler(
        _ handler:
            @escaping @Sendable (CreateElicitation.Parameters) async throws ->
            CreateElicitation.Result
    ) -> Self {
        return withMethodHandler(CreateElicitation.self, handler: handler)
    }

    // MARK: - Roots

    /// Register a handler for roots/list requests from servers
    ///
    /// Roots define filesystem boundaries that servers can operate within.
    /// Unlike other MCP features, roots use bidirectional communication where
    /// servers send requests TO clients to discover available roots.
    ///
    /// - Parameter handler: A closure that returns the list of available roots
    /// - Returns: Self for method chaining
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    @discardableResult
    public func withRootsHandler(
        _ handler: @escaping @Sendable () async throws -> [Root]
    ) -> Self {
        return withMethodHandler(ListRoots.self) { _ in
            let roots = try await handler()
            return ListRoots.Result(roots: roots)
        }
    }

    /// Notify the server that the list of roots has changed
    ///
    /// Clients should send this notification when roots are added, removed,
    /// or modified to inform connected servers of the change.
    ///
    /// - Throws: MCPError if the client is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    /// Notifies the server that the client's roots changed.
    ///
    /// Does nothing on stateless connections, where servers read roots per
    /// request instead.
    public func notifyRootsChanged() async throws {
        if isStateless { return }
        let notification = RootsListChangedNotification.message()
        try await notify(notification)
    }

    // MARK: - Logging

    /// Set the minimum logging level for server log messages.
    ///
    /// Servers that declare the `logging` capability will send log messages via
    /// `notifications/message` notifications. Use this method to control which
    /// severity levels the server should send.
    ///
    /// - Parameter level: The minimum log level to receive
    /// - Throws: MCPError if the client is not connected or if the server doesn't support logging
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    /// Sets the lowest log level the server should send.
    ///
    /// On stateless connections `logging/setLevel` does not exist: the level
    /// is sent in the `_meta` of every following request instead.
    public func setLoggingLevel(_ level: LogLevel) async throws {
        try validateServerCapability(\.logging, "Logging")
        if isStateless {
            configuration.logLevel = level
            return
        }
        let request = SetLoggingLevel.request(.init(level: level))
        _ = try await send(request).value
    }

    // MARK: - Completions

    /// Request completion suggestions for a prompt argument.
    ///
    /// Servers that declare the `completions` capability can provide autocompletion
    /// suggestions for prompt arguments as users type.
    ///
    /// - Parameters:
    ///   - promptName: The name of the prompt
    ///   - argumentName: The name of the argument being completed
    ///   - argumentValue: The current (partial) value of the argument
    ///   - context: Optional context with already-resolved arguments
    /// - Returns: A completion result containing suggested values
    /// - Throws: MCPError if the client is not connected or if the server doesn't support completions
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion/
    public func complete(
        promptName: String,
        argumentName: String,
        argumentValue: String,
        context: [String: String]? = nil
    ) async throws -> Complete.Result.Completion {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(
            .init(
                ref: .prompt(.init(name: promptName)),
                argument: .init(name: argumentName, value: argumentValue),
                context: context.map { .init(arguments: $0) }
            )
        )
        let result = try await send(request).value
        return result.completion
    }

    /// Request completion suggestions for a resource template argument.
    ///
    /// Servers that declare the `completions` capability can provide autocompletion
    /// suggestions for resource template arguments as users type.
    ///
    /// - Parameters:
    ///   - resourceURI: The URI of the resource template
    ///   - argumentName: The name of the argument being completed
    ///   - argumentValue: The current (partial) value of the argument
    ///   - context: Optional context with already-resolved arguments
    /// - Returns: A completion result containing suggested values
    /// - Throws: MCPError if the client is not connected or if the server doesn't support completions
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion/
    public func complete(
        resourceURI: String,
        argumentName: String,
        argumentValue: String,
        context: [String: String]? = nil
    ) async throws -> Complete.Result.Completion {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(
            .init(
                ref: .resource(.init(uri: resourceURI)),
                argument: .init(name: argumentName, value: argumentValue),
                context: context.map { .init(arguments: $0) }
            )
        )
        let result = try await send(request).value
        return result.completion
    }

    // MARK: -

    private func handleResponse(_ response: Response<AnyMethod>) async {
        await logger?.trace(
            "Processing response",
            metadata: ["id": "\(response.id)"])

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

    private func handleMessage(_ message: Message<AnyNotification>) async {
        await logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

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

    private func handleIncomingRequest(_ request: Request<AnyMethod>) async {
        await logger?.trace(
            "Processing incoming request from server",
            metadata: ["method": "\(request.method)", "id": "\(request.id)"])

        guard let handler = methodHandlers[request.method] else {
            await logger?.warning(
                "No handler registered for method",
                metadata: ["method": "\(request.method)"])
            let error = MCPError.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)
            do {
                try await send(response)
            } catch {
                await logger?.error(
                    "Failed to send error response",
                    metadata: ["error": "\(error)"])
            }
            return
        }

        do {
            let response = try await handler(request)
            try await send(response)
        } catch {
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)
            do {
                try await send(response)
            } catch {
                await logger?.error(
                    "Failed to send error response",
                    metadata: ["error": "\(error)"])
            }
        }
    }

    // MARK: -

    /// Validate the server capabilities.
    /// Throws an error if the client is configured to be strict and the capability is not supported.
    private func validateServerCapability<T>(
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
    private func handleBatchResponse(_ responses: [AnyResponse]) async {
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

// MARK: - Codable

extension Client.Capabilities.Sampling: Codable {
    private enum CodingKeys: String, CodingKey {
        case tools, context
    }

    public init(from decoder: Decoder) throws {
        // Handle both empty object {} and object with sub-capabilities
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.tools = try container.decodeIfPresent(Tools.self, forKey: .tools)
            self.context = try container.decodeIfPresent(Context.self, forKey: .context)
        } else {
            // Empty object - no capabilities
            self.tools = nil
            self.context = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(context, forKey: .context)
    }
}

extension Client.Capabilities.Elicitation: Codable {
    private enum CodingKeys: String, CodingKey {
        case form, url
    }

    public init(from decoder: Decoder) throws {
        // Handle both empty object {} and object with sub-capabilities
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.form = try container.decodeIfPresent(Form.self, forKey: .form)
            self.url = try container.decodeIfPresent(URL.self, forKey: .url)
            // If both are nil, default to form for backward compatibility
            if self.form == nil && self.url == nil {
                self.form = Form()
            }
        } else {
            // Empty object - default to form-only for backward compatibility
            self.form = Form()
            self.url = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(form, forKey: .form)
        try container.encodeIfPresent(url, forKey: .url)
    }
}
