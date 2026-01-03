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

        public init(strict: Bool = false) {
            self.strict = strict
        }
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The client name
        public var name: String
        /// The client version
        public var version: String
        /// A human-readable title for the client, intended for UI display.
        /// If not provided, the `name` should be used for display.
        public var title: String?
        /// An optional human-readable description of what this implementation does.
        public var description: String?
        /// Optional icons representing this implementation.
        public var icons: [Icon]?
        /// An optional URL of the website for this implementation.
        public var websiteUrl: String?

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
        public struct Sampling: Hashable, Codable, Sendable {
            /// Context capability for sampling requests.
            ///
            /// When declared, indicates the client supports the `includeContext` parameter
            /// with values "thisServer" and "allServers". If not declared, servers should
            /// only use `includeContext: "none"` (or omit it).
            public struct Context: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Tools capability for sampling requests
            public struct Tools: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Whether the client supports includeContext parameter
            public var context: Context?
            /// Whether the client supports tools in sampling requests
            public var tools: Tools?

            public init(context: Context? = nil, tools: Tools? = nil) {
                self.context = context
                self.tools = tools
            }
        }

        /// The elicitation capabilities
        public struct Elicitation: Hashable, Codable, Sendable {
            /// Form mode capabilities
            public struct Form: Hashable, Codable, Sendable {
                /// Whether the client applies schema defaults to missing fields.
                public var applyDefaults: Bool?

                public init(applyDefaults: Bool? = nil) {
                    self.applyDefaults = applyDefaults
                }
            }

            /// URL mode capabilities (for out-of-band flows like OAuth)
            public struct URL: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Form mode capabilities
            public var form: Form?
            /// URL mode capabilities
            public var url: URL?

            public init(form: Form? = nil, url: URL? = nil) {
                self.form = form
                self.url = url
            }
        }

        /// Whether the client supports sampling
        public var sampling: Sampling?
        /// Whether the client supports elicitation (user input requests)
        public var elicitation: Elicitation?
        /// Experimental, non-standard capabilities that the client supports.
        public var experimental: [String: [String: Value]]?
        /// Whether the client supports roots
        public var roots: Capabilities.Roots?
        /// Task capabilities (experimental, for bidirectional task support)
        public var tasks: Tasks?

        public init(
            sampling: Sampling? = nil,
            elicitation: Elicitation? = nil,
            experimental: [String: [String: Value]]? = nil,
            roots: Capabilities.Roots? = nil,
            tasks: Tasks? = nil
        ) {
            self.sampling = sampling
            self.elicitation = elicitation
            self.experimental = experimental
            self.roots = roots
            self.tasks = tasks
        }
    }

    /// Context provided to client request handlers.
    ///
    /// This context is passed to handlers for server→client requests (e.g., sampling,
    /// elicitation, roots) and provides:
    /// - Cancellation checking via `isCancelled` and `checkCancellation()`
    /// - Notification sending to the server
    /// - Progress reporting convenience methods
    ///
    /// ## Example
    ///
    /// ```swift
    /// client.withRequestHandler(CreateSamplingMessage.self) { params, context in
    ///     // Check for cancellation periodically
    ///     try context.checkCancellation()
    ///
    ///     // Report progress back to server
    ///     try await context.sendProgressNotification(
    ///         token: progressToken,
    ///         progress: 50.0,
    ///         total: 100.0,
    ///         message: "Processing..."
    ///     )
    ///
    ///     return result
    /// }
    /// ```
    public struct RequestHandlerContext: Sendable {
        /// Send a notification to the server.
        ///
        /// Use this to send notifications from within a request handler.
        let sendNotification: @Sendable (any NotificationMessageProtocol) async throws -> Void

        // MARK: - Convenience Methods

        /// Send a progress notification to the server.
        ///
        /// Use this to report progress on long-running operations initiated by
        /// server→client requests.
        ///
        /// - Parameters:
        ///   - token: The progress token from the request's `_meta.progressToken`
        ///   - progress: The current progress value (should increase monotonically)
        ///   - total: The total progress value, if known
        ///   - message: An optional human-readable message describing current progress
        public func sendProgressNotification(
            token: ProgressToken,
            progress: Double,
            total: Double? = nil,
            message: String? = nil
        ) async throws {
            try await sendNotification(ProgressNotification.message(.init(
                progressToken: token,
                progress: progress,
                total: total,
                message: message
            )))
        }

        // MARK: - Cancellation Checking

        /// Whether the request has been cancelled.
        ///
        /// Check this property periodically during long-running operations
        /// to respond to cancellation requests from the server.
        ///
        /// This returns `true` when:
        /// - The server sends a `CancelledNotification` for this request
        /// - The client is disconnecting
        ///
        /// When cancelled, the handler should clean up resources and return
        /// or throw an error. Per MCP spec, responses are not sent for cancelled requests.
        ///
        /// ## Example
        ///
        /// ```swift
        /// client.withRequestHandler(CreateSamplingMessage.self) { params, context in
        ///     for chunk in largeInput {
        ///         // Check cancellation periodically
        ///         guard !context.isCancelled else {
        ///             throw CancellationError()
        ///         }
        ///         try await process(chunk)
        ///     }
        ///     return result
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
        /// client.withRequestHandler(CreateSamplingMessage.self) { params, context in
        ///     for chunk in largeInput {
        ///         try context.checkCancellation()  // Throws if cancelled
        ///         try await process(chunk)
        ///     }
        ///     return result
        /// }
        /// ```
        ///
        /// - Throws: `CancellationError` if the request has been cancelled.
        public func checkCancellation() throws {
            try Task.checkCancellation()
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
    /// The client version
    public nonisolated var version: String { clientInfo.version }

    /// The client capabilities
    public var capabilities: Client.Capabilities
    /// The client configuration
    public var configuration: Configuration

    /// Experimental APIs for tasks and other features.
    ///
    /// Access experimental features via this property:
    /// ```swift
    /// let result = try await client.experimental.tasks.callToolAsTask(name: "tool", arguments: [:])
    /// let status = try await client.experimental.tasks.getTask(result.task.taskId)
    /// ```
    ///
    /// - Warning: These APIs are experimental and may change without notice.
    public var experimental: ExperimentalClientFeatures {
        ExperimentalClientFeatures(client: self)
    }

    /// The server capabilities
    private var serverCapabilities: Server.Capabilities?
    /// The server version
    private var serverVersion: String?
    /// The server instructions
    private var instructions: String?

    /// A dictionary of type-erased notification handlers, keyed by method name
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// A dictionary of type-erased request handlers for server→client requests, keyed by method name
    private var requestHandlers: [String: ClientRequestHandlerBox] = [:]
    /// Task-augmented sampling handler (called when request has `task` field)
    private var taskAugmentedSamplingHandler: ExperimentalClientTaskHandlers.TaskAugmentedSamplingHandler?
    /// Task-augmented elicitation handler (called when request has `task` field)
    private var taskAugmentedElicitationHandler: ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler?
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    /// In-flight server request handler Tasks, tracked by request ID.
    /// Used for protocol-level cancellation when CancelledNotification is received.
    private var inFlightServerRequestTasks: [RequestId: Task<Void, Never>] = [:]

    /// An error indicating a type mismatch when decoding a pending request
    private struct TypeMismatchError: Swift.Error {}

    /// A type-erased pending request using AsyncThrowingStream for cancellation-aware waiting.
    private struct AnyPendingRequest {
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
                        continuation.finish(throwing: TypeMismatchError())
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

    /// A dictionary of type-erased pending requests, keyed by request ID
    private var pendingRequests: [RequestId: AnyPendingRequest] = [:]
    /// Progress callbacks for requests, keyed by progress token.
    /// Used to invoke callbacks when progress notifications are received.
    private var progressCallbacks: [ProgressToken: ProgressCallback] = [:]
    /// Timeout controllers for requests with progress-aware timeouts.
    /// Used to reset timeouts when progress notifications are received.
    private var timeoutControllers: [ProgressToken: TimeoutController] = [:]
    /// Mapping from request ID to progress token.
    /// Used to detect task-augmented responses and keep progress handlers alive.
    private var requestProgressTokens: [RequestId: ProgressToken] = [:]
    /// Mapping from task ID to progress token.
    /// Keeps progress handlers alive for task-augmented requests until the task completes.
    /// Per MCP spec 2025-11-25: "For task-augmented requests, the progressToken provided
    /// in the original request MUST continue to be used for progress notifications
    /// throughout the task's lifetime, even after the CreateTaskResult has been returned."
    private var taskProgressTokens: [String: ProgressToken] = [:]
    // Add reusable JSON encoder/decoder
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Controls timeout behavior for a single request, supporting reset on progress.
    ///
    /// This actor manages the timeout state for requests that use `resetTimeoutOnProgress`.
    /// When progress is received, calling `signalProgress()` resets the timeout clock.
    private actor TimeoutController {
        /// The per-interval timeout duration.
        let timeout: Duration
        /// Whether to reset timeout when progress is received.
        let resetOnProgress: Bool
        /// Maximum total time to wait regardless of progress.
        let maxTotalTimeout: Duration?
        /// The start time of the request (for maxTotalTimeout tracking).
        let startTime: ContinuousClock.Instant
        /// The current deadline (updated when progress is received).
        private var deadline: ContinuousClock.Instant
        /// Whether the controller has been cancelled.
        private var isCancelled = false
        /// Continuation for signaling progress.
        private var progressContinuation: AsyncStream<Void>.Continuation?

        init(timeout: Duration, resetOnProgress: Bool, maxTotalTimeout: Duration?) {
            self.timeout = timeout
            self.resetOnProgress = resetOnProgress
            self.maxTotalTimeout = maxTotalTimeout
            self.startTime = ContinuousClock.now
            self.deadline = ContinuousClock.now.advanced(by: timeout)
        }

        /// Signal that progress was received, resetting the timeout.
        func signalProgress() {
            guard resetOnProgress, !isCancelled else { return }
            deadline = ContinuousClock.now.advanced(by: timeout)
            progressContinuation?.yield()
        }

        /// Cancel the timeout controller.
        func cancel() {
            isCancelled = true
            progressContinuation?.finish()
        }

        /// Wait until the timeout expires.
        ///
        /// If `resetOnProgress` is true, the timeout resets each time `signalProgress()` is called.
        /// If `maxTotalTimeout` is set, the wait will end when that limit is exceeded.
        ///
        /// - Throws: `MCPError.requestTimeout` when the timeout expires.
        func waitForTimeout() async throws {
            let clock = ContinuousClock()

            // Create a stream for progress signals
            let (progressStream, continuation) = AsyncStream<Void>.makeStream()
            self.progressContinuation = continuation

            while !isCancelled {
                // Check maxTotalTimeout
                if let maxTotal = maxTotalTimeout {
                    let elapsed = clock.now - startTime
                    if elapsed >= maxTotal {
                        throw MCPError.requestTimeout(
                            timeout: maxTotal,
                            message: "Request exceeded maximum total timeout"
                        )
                    }
                }

                // Calculate time until deadline
                let now = clock.now
                let timeUntilDeadline = deadline - now

                if timeUntilDeadline <= .zero {
                    throw MCPError.requestTimeout(
                        timeout: timeout,
                        message: "Request timed out"
                    )
                }

                // Wait for either timeout or progress signal
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // Timeout task
                        group.addTask {
                            try await Task.sleep(for: timeUntilDeadline)
                        }

                        // Progress signal task (if reset is enabled)
                        if resetOnProgress {
                            group.addTask {
                                for await _ in progressStream {
                                    // Progress received, exit to recalculate deadline
                                    return
                                }
                            }
                        }

                        // Wait for whichever completes first
                        _ = try await group.next()
                        group.cancelAll()
                    }
                } catch is CancellationError {
                    return // Task was cancelled, exit gracefully
                }

                // If we get here after a progress signal, loop to recalculate deadline
                // If we get here after timeout, the next iteration will throw
            }
        }
    }

    public init(
        name: String,
        version: String,
        configuration: Configuration = .default
    ) {
        self.clientInfo = Client.Info(name: name, version: version)
        self.capabilities = Capabilities()
        self.configuration = configuration
    }

    /// Set the client capabilities.
    ///
    /// This should be called before `connect()` to configure what capabilities
    /// the client will advertise to the server during initialization.
    ///
    /// - Parameter capabilities: The capabilities to set.
    public func setCapabilities(_ capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    /// Returns the server capabilities received during initialization.
    ///
    /// Use this method to check what capabilities the server supports after
    /// successfully connecting. This can be useful for:
    /// - Conditionally enabling features based on server support
    /// - Logging or debugging connection details
    /// - Building adaptive clients that work with various server implementations
    ///
    /// - Returns: The server's capabilities, or `nil` if the client has not
    ///   been initialized yet (i.e., `connect()` has not been called or failed).
    public func getServerCapabilities() -> Server.Capabilities? {
        return serverCapabilities
    }

    /// Connect to the server using the given transport
    @discardableResult
    public func connect(transport: any Transport) async throws -> Initialize.Result {
        self.connection = transport
        try await self.connection?.connect()

        await logger?.debug(
            "Client connected", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        //
        // The receive loop:
        // - Calls receive() once to get the stream
        // - Iterates until the stream ends or throws
        // - Cleans up pending requests on exit
        //
        // EAGAIN is handled by the transport layer internally.
        task = Task {
            guard let connection = self.connection else { return }

            defer {
                // When the receive loop exits unexpectedly (transport closed without
                // disconnect() being called), clean up pending requests.
                Task {
                    await self.cleanupPendingRequestsOnUnexpectedDisconnect()
                }
            }

            do {
                let stream = await connection.receive()
                for try await data in stream {
                    if Task.isCancelled { break }

                    // Attempt to decode data
                    // Try decoding as a batch response first
                    if let batchResponse = try? decoder.decode([AnyResponse].self, from: data) {
                        await handleBatchResponse(batchResponse)
                    } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                        await handleResponse(response)
                    } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                        // Handle incoming request from server (bidirectional communication)
                        // Spawn in a separate task to avoid blocking the message loop.
                        // This allows client request handlers to make nested requests
                        // back to the server if needed.
                        let requestId = request.id
                        let handlerTask = Task { [weak self] in
                            guard let self else { return }
                            defer {
                                Task { await self.removeInFlightServerRequest(requestId) }
                            }
                            await self.handleIncomingRequest(request)
                        }
                        trackInFlightServerRequest(requestId, task: handlerTask)
                    } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                        await handleMessage(message)
                    } else {
                        var metadata: Logger.Metadata = [:]
                        if let string = String(data: data, encoding: .utf8) {
                            metadata["message"] = .string(string)
                        }
                        await logger?.warning(
                            "Unexpected message received by client (not single/batch response, request, or notification)",
                            metadata: metadata
                        )
                    }
                }
                await logger?.debug("Client receive stream ended")
            } catch {
                await logger?.error(
                    "Error in message handling loop", metadata: ["error": "\(error)"])
            }
            await self.logger?.debug("Client message handling loop task is terminating.")
        }

        // Register default handler for CancelledNotification (protocol-level cancellation)
        _ = await onNotification(CancelledNotification.self) { [weak self] message in
            guard let self else { return }
            guard let requestId = message.params.requestId else {
                // Per protocol 2025-11-25+, requestId is optional.
                // If not provided, we cannot cancel a specific request.
                return
            }
            await self.cancelInFlightServerRequest(requestId, reason: message.params.reason)
        }

        // Automatically initialize after connecting
        return try await _initialize()
    }

    /// Disconnect the client and cancel all pending requests
    public func disconnect() async {
        await logger?.debug("Initiating client disconnect...")

        // Cancel all in-flight server request handlers
        for (requestId, handlerTask) in inFlightServerRequestTasks {
            handlerTask.cancel()
            await logger?.debug(
                "Cancelled in-flight server request during disconnect",
                metadata: ["id": "\(requestId)"]
            )
        }
        inFlightServerRequestTasks.removeAll()

        // Part 1: Inside actor - Grab state and clear internal references
        let taskToCancel = self.task
        let connectionToDisconnect = self.connection
        let pendingRequestsToCancel = self.pendingRequests

        self.task = nil
        self.connection = nil
        self.pendingRequests = [:]  // Use empty dictionary literal

        // Clear all progress-related state
        progressCallbacks.removeAll()
        timeoutControllers.removeAll()
        requestProgressTokens.removeAll()
        taskProgressTokens.removeAll()

        // Part 2: Outside actor - Resume continuations, disconnect transport, await task

        // Resume pending request continuations with connection closed error
        for (_, request) in pendingRequestsToCancel {
            request.resume(throwing: MCPError.connectionClosed)
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

    /// Cleans up pending requests when the receive loop exits unexpectedly.
    ///
    /// This is called from the receive loop's defer block when the transport closes
    /// without `disconnect()` being called (e.g., server process exits). We only
    /// clean up requests that haven't already been handled by `disconnect()`.
    private func cleanupPendingRequestsOnUnexpectedDisconnect() async {
        guard !pendingRequests.isEmpty else { return }

        await logger?.debug(
            "Cleaning up pending requests after unexpected disconnect",
            metadata: ["count": "\(pendingRequests.count)"])

        for (_, request) in pendingRequests {
            request.resume(throwing: MCPError.connectionClosed)
        }
        pendingRequests.removeAll()
    }

    // MARK: - In-Flight Server Request Tracking (Protocol-Level Cancellation)

    /// Track an in-flight server request handler Task.
    private func trackInFlightServerRequest(_ requestId: RequestId, task: Task<Void, Never>) {
        inFlightServerRequestTasks[requestId] = task
    }

    /// Remove an in-flight server request handler Task.
    private func removeInFlightServerRequest(_ requestId: RequestId) {
        inFlightServerRequestTasks.removeValue(forKey: requestId)
    }

    /// Cancel an in-flight server request handler Task.
    ///
    /// Called when a CancelledNotification is received for a specific requestId.
    /// Per MCP spec, if the request is unknown or already completed, this is a no-op.
    private func cancelInFlightServerRequest(_ requestId: RequestId, reason: String?) async {
        if let task = inFlightServerRequestTasks[requestId] {
            task.cancel()
            await logger?.debug(
                "Cancelled in-flight server request",
                metadata: [
                    "id": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ]
            )
        }
        // Per spec: MAY ignore if request is unknown - no error needed
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

    /// Send a notification to the server
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a progress notification to the server.
    ///
    /// This is a convenience method for sending progress notifications from the client
    /// to the server. This enables bidirectional progress reporting where clients can
    /// inform servers about their own progress (e.g., during client-side processing).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Client reports its own progress to the server
    /// try await client.sendProgressNotification(
    ///     token: .string("client-task-123"),
    ///     progress: 50.0,
    ///     total: 100.0,
    ///     message: "Processing client-side data..."
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - token: The progress token to associate with this notification
    ///   - progress: The current progress value (should increase monotonically)
    ///   - total: The total progress value, if known
    ///   - message: An optional human-readable message describing current progress
    public func sendProgressNotification(
        token: ProgressToken,
        progress: Double,
        total: Double? = nil,
        message: String? = nil
    ) async throws {
        try await notify(ProgressNotification.message(.init(
            progressToken: token,
            progress: progress,
            total: total,
            message: message
        )))
    }

    /// Send a notification that the list of available roots has changed.
    ///
    /// Servers that receive this notification should request an updated
    /// list of roots via the roots/list request.
    ///
    /// - Throws: `MCPError.invalidRequest` if the client has not declared
    ///   the `roots.listChanged` capability.
    public func sendRootsChanged() async throws {
        guard capabilities.roots?.listChanged == true else {
            throw MCPError.invalidRequest(
                "Client does not support roots.listChanged capability")
        }
        try await notify(RootsListChangedNotification.message(.init()))
    }

    /// Register a handler for server→client requests.
    ///
    /// This enables bidirectional communication where the server can send requests
    /// to the client (e.g., sampling, roots, elicitation).
    ///
    /// - Parameters:
    ///   - type: The method type to handle
    ///   - handler: The handler function that receives parameters and returns a result
    /// - Returns: Self for chaining
    @discardableResult
    public func withRequestHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        requestHandlers[M.name] = TypedClientRequestHandler<M>(handler)
        return self
    }

    /// Register a handler for `roots/list` requests from the server.
    ///
    /// When the server requests the list of roots, this handler will be called
    /// to provide the available filesystem directories.
    ///
    /// - Important: The client must have declared `roots` capability during initialization.
    ///
    /// - Parameter handler: A closure that returns the list of available roots.
    /// - Returns: Self for chaining.
    /// - Precondition: `capabilities.roots` must be non-nil.
    @discardableResult
    public func withRootsHandler(
        _ handler: @escaping @Sendable () async throws -> [Root]
    ) -> Self {
        precondition(
            capabilities.roots != nil,
            "Cannot register roots handler: Client does not have roots capability"
        )
        return withRequestHandler(ListRoots.self) { _ in
            ListRoots.Result(roots: try await handler())
        }
    }

    /// Register a handler for `sampling/createMessage` requests from the server.
    ///
    /// When the server requests a sampling completion, this handler will be called
    /// to generate the LLM response.
    ///
    /// The handler receives parameters that may or may not include tools. Check `params.hasTools`
    /// to determine if tool use is enabled for this request.
    ///
    /// - Important: The client must have declared `sampling` capability during initialization.
    ///
    /// ## Example
    ///
    /// ```swift
    /// client.withSamplingHandler { params in
    ///     // Call your LLM with the messages
    ///     let response = try await llm.complete(
    ///         messages: params.messages,
    ///         tools: params.tools,  // May be nil
    ///         maxTokens: params.maxTokens
    ///     )
    ///
    ///     return ClientSamplingRequest.Result(
    ///         model: "gpt-4",
    ///         stopReason: .endTurn,
    ///         role: .assistant,
    ///         content: .text(response.text)
    ///     )
    /// }
    /// ```
    ///
    /// - Parameter handler: A closure that receives sampling parameters and returns the result.
    /// - Returns: Self for chaining.
    /// - Precondition: `capabilities.sampling` must be non-nil.
    @discardableResult
    public func withSamplingHandler(
        _ handler: @escaping @Sendable (ClientSamplingRequest.Parameters) async throws -> ClientSamplingRequest.Result
    ) -> Self {
        precondition(
            capabilities.sampling != nil,
            "Cannot register sampling handler: Client does not have sampling capability"
        )
        return withRequestHandler(ClientSamplingRequest.self, handler: handler)
    }

    /// Register a handler for `elicitation/create` requests from the server.
    ///
    /// When the server requests user input via elicitation, this handler will be called
    /// to collect the input and return the result.
    ///
    /// - Important: The client must have declared `elicitation` capability during initialization.
    ///
    /// - Parameter handler: A closure that receives elicitation parameters and returns the result.
    /// - Returns: Self for chaining.
    /// - Precondition: `capabilities.elicitation` must be non-nil.
    @discardableResult
    public func withElicitationHandler(
        _ handler: @escaping @Sendable (Elicit.Parameters) async throws -> Elicit.Result
    ) -> Self {
        precondition(
            capabilities.elicitation != nil,
            "Cannot register elicitation handler: Client does not have elicitation capability"
        )
        return withRequestHandler(Elicit.self, handler: handler)
    }

    /// Internal method to set a request handler box directly.
    ///
    /// This is used by task-augmented handlers that need to return different result types
    /// based on whether the request has a `task` field.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setRequestHandler(method: String, handler: ClientRequestHandlerBox) {
        requestHandlers[method] = handler
    }

    /// Internal method to get an existing request handler box.
    ///
    /// This is used to retrieve the existing handler before wrapping it with
    /// a task-aware handler that preserves the normal handler as a fallback.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _getRequestHandler(method: String) -> ClientRequestHandlerBox? {
        requestHandlers[method]
    }

    /// Internal method to set the task-augmented sampling handler.
    ///
    /// This handler is called when the server sends a `sampling/createMessage` request
    /// with a `task` field. The handler should return `CreateTaskResult` instead of
    /// the normal sampling result.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setTaskAugmentedSamplingHandler(
        _ handler: @escaping ExperimentalClientTaskHandlers.TaskAugmentedSamplingHandler
    ) {
        taskAugmentedSamplingHandler = handler
    }

    /// Internal method to set the task-augmented elicitation handler.
    ///
    /// This handler is called when the server sends an `elicitation/create` request
    /// with a `task` field. The handler should return `CreateTaskResult` instead of
    /// the normal elicitation result.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setTaskAugmentedElicitationHandler(
        _ handler: @escaping ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler
    ) {
        taskAugmentedElicitationHandler = handler
    }

    // MARK: - Request Options

    /// Options that can be given per request.
    ///
    /// Similar to TypeScript SDK's `RequestOptions`, this allows configuring
    /// timeout behavior for individual requests, including progress-aware timeouts.
    public struct RequestOptions: Sendable {
        /// The default request timeout (60 seconds), matching TypeScript SDK.
        public static let defaultTimeout: Duration = .seconds(60)

        /// A timeout for this request.
        ///
        /// If exceeded, the request will be cancelled and an `MCPError.requestTimeout`
        /// will be thrown. A `CancelledNotification` will also be sent to the server.
        ///
        /// If `nil`, no timeout is applied (the request can wait indefinitely).
        /// Default is `nil` to match existing behavior.
        public var timeout: Duration?

        /// If `true`, receiving a progress notification resets the timeout clock.
        ///
        /// This is useful for long-running operations that send periodic progress updates.
        /// As long as the server keeps sending progress, the request won't time out.
        ///
        /// When combined with `maxTotalTimeout`, this allows both:
        /// - Per-interval timeout that resets on progress
        /// - Overall hard limit that prevents infinite waiting
        ///
        /// Default is `false`.
        ///
        /// - Note: Only effective when `timeout` is set and the request uses `onProgress`.
        public var resetTimeoutOnProgress: Bool

        /// Maximum total time to wait for the request, regardless of progress.
        ///
        /// When `resetTimeoutOnProgress` is `true`, this provides a hard upper limit
        /// on the total wait time. Even if progress notifications keep arriving,
        /// the request will be cancelled if this limit is exceeded.
        ///
        /// If `nil`, there's no maximum total timeout (only the regular `timeout`
        /// applies, potentially reset by progress).
        ///
        /// - Note: Only effective when both `timeout` and `resetTimeoutOnProgress` are set.
        public var maxTotalTimeout: Duration?

        /// Creates request options with the specified configuration.
        ///
        /// - Parameters:
        ///   - timeout: The timeout duration, or `nil` for no timeout.
        ///   - resetTimeoutOnProgress: Whether to reset the timeout when progress is received.
        ///   - maxTotalTimeout: Maximum total time to wait regardless of progress.
        public init(
            timeout: Duration? = nil,
            resetTimeoutOnProgress: Bool = false,
            maxTotalTimeout: Duration? = nil
        ) {
            self.timeout = timeout
            self.resetTimeoutOnProgress = resetTimeoutOnProgress
            self.maxTotalTimeout = maxTotalTimeout
        }

        /// Request options with the default timeout (60 seconds).
        public static let withDefaultTimeout = RequestOptions(timeout: defaultTimeout)

        /// Request options with no timeout.
        public static let noTimeout = RequestOptions(timeout: nil)
    }

    // MARK: - Requests

    /// Send a request and receive its response.
    ///
    /// This method sends a request without a timeout. For timeout support,
    /// use `send(_:options:)` instead.
    public func send<M: Method>(_ request: Request<M>) async throws -> M.Result {
        try await send(request, options: nil)
    }

    /// Send a request and receive its response with options.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    public func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?
    ) async throws -> M.Result {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let requestData = try encoder.encode(request)

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<M.Result, Swift.Error>.makeStream()

        // Track whether we've timed out (for the onTermination handler)
        let requestId = request.id
        let timeout = options?.timeout

        // Clean up pending request if caller cancels (e.g., task cancelled or timeout)
        // and send CancelledNotification to server per MCP spec
        continuation.onTermination = { @Sendable [weak self] termination in
            Task {
                guard let self else { return }
                await self.cleanupPendingRequest(id: requestId)

                // Per MCP spec: send notifications/cancelled when cancelling a request
                // Only send if the stream was cancelled (not finished normally)
                if case .cancelled = termination {
                    let reason = if let timeout {
                        "Request timed out after \(timeout)"
                    } else {
                        "Client cancelled the request"
                    }
                    await self.sendCancellationNotification(
                        requestId: requestId,
                        reason: reason
                    )
                }
            }
        }

        // Add the pending request before attempting to send
        addPendingRequest(id: request.id, continuation: continuation)

        // Send the request data
        do {
            try await connection.send(requestData)
        } catch {
            // If send fails, remove the pending request and rethrow
            if removePendingRequest(id: request.id) != nil {
                continuation.finish(throwing: error)
            }
            throw error
        }

        // Wait for response with optional timeout
        if let timeout {
            // Use withTimeout pattern for cancellation-aware timeout
            return try await withThrowingTaskGroup(of: M.Result.self) { group in
                // Add the main task that waits for the response
                group.addTask {
                    for try await result in stream {
                        return result
                    }
                    throw MCPError.internalError("No response received")
                }

                // Add the timeout task
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MCPError.requestTimeout(timeout: timeout, message: "Request timed out")
                }

                // Return whichever completes first
                guard let result = try await group.next() else {
                    throw MCPError.internalError("No response received")
                }

                // Cancel the other task
                group.cancelAll()

                return result
            }
        } else {
            // No timeout - wait indefinitely for response
            for try await result in stream {
                return result
            }

            // Stream closed without yielding a response
            throw MCPError.internalError("No response received")
        }
    }

    /// Send a request with a progress callback.
    ///
    /// This method automatically sets up progress tracking by:
    /// 1. Generating a unique progress token based on the request ID
    /// 2. Injecting the token into the request's `_meta.progressToken`
    /// 3. Invoking the callback when progress notifications are received
    ///
    /// The callback is automatically cleaned up when the request completes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = try await client.send(
    ///     CallTool.request(.init(name: "slow_operation", arguments: ["steps": 5])),
    ///     onProgress: { progress in
    ///         print("Progress: \(progress.value)/\(progress.total ?? 0) - \(progress.message ?? "")")
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - request: The request to send
    ///   - onProgress: A callback invoked when progress notifications are received
    /// - Returns: The response result
    public func send<M: Method>(
        _ request: Request<M>,
        onProgress: @escaping ProgressCallback
    ) async throws -> M.Result {
        try await send(request, options: nil, onProgress: onProgress)
    }

    /// Send a request with options and a progress callback.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    ///   - onProgress: A callback invoked when progress notifications are received.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    public func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?,
        onProgress: @escaping ProgressCallback
    ) async throws -> M.Result {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Generate a progress token from the request ID
        let progressToken: ProgressToken = switch request.id {
        case .number(let n): .integer(n)
        case .string(let s): .string(s)
        }

        // Encode the request, inject progressToken into _meta, then re-encode
        let requestData = try encoder.encode(request)
        var requestDict = try decoder.decode([String: Value].self, from: requestData)

        // Ensure params exists and inject _meta.progressToken
        var params = requestDict["params"]?.objectValue ?? [:]
        var meta = params["_meta"]?.objectValue ?? [:]
        meta["progressToken"] = switch progressToken {
        case .string(let s): .string(s)
        case .integer(let n): .int(n)
        }
        params["_meta"] = .object(meta)
        requestDict["params"] = .object(params)

        let modifiedRequestData = try encoder.encode(requestDict)

        // Register the progress callback and track the request → token mapping
        // (used to detect task-augmented responses and keep progress handlers alive)
        progressCallbacks[progressToken] = onProgress
        requestProgressTokens[request.id] = progressToken

        // Create timeout controller if resetTimeoutOnProgress is enabled
        let timeoutController: TimeoutController?
        if let timeout = options?.timeout, options?.resetTimeoutOnProgress == true {
            let controller = TimeoutController(
                timeout: timeout,
                resetOnProgress: true,
                maxTotalTimeout: options?.maxTotalTimeout
            )
            timeoutControllers[progressToken] = controller
            timeoutController = controller
        } else {
            timeoutController = nil
        }

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<M.Result, Swift.Error>.makeStream()

        let requestId = request.id
        let timeout = options?.timeout
        continuation.onTermination = { @Sendable [weak self] termination in
            Task {
                guard let self else { return }
                await self.cleanupPendingRequest(id: requestId)
                await self.removeRequestProgressToken(id: requestId)
                await self.removeProgressCallback(token: progressToken)
                await self.removeTimeoutController(token: progressToken)

                if case .cancelled = termination {
                    let reason = if let timeout {
                        "Request timed out after \(timeout)"
                    } else {
                        "Client cancelled the request"
                    }
                    await self.sendCancellationNotification(
                        requestId: requestId,
                        reason: reason
                    )
                }
            }
        }

        // Add the pending request before attempting to send
        addPendingRequest(id: request.id, continuation: continuation)

        // Send the modified request data
        do {
            try await connection.send(modifiedRequestData)
        } catch {
            if removePendingRequest(id: request.id) != nil {
                continuation.finish(throwing: error)
            }
            removeRequestProgressToken(id: request.id)
            removeProgressCallback(token: progressToken)
            removeTimeoutController(token: progressToken)
            throw error
        }

        // Wait for response with optional timeout
        if let timeout {
            // Use TimeoutController if resetTimeoutOnProgress is enabled
            if let controller = timeoutController {
                return try await withThrowingTaskGroup(of: M.Result.self) { group in
                    group.addTask {
                        for try await result in stream {
                            return result
                        }
                        throw MCPError.internalError("No response received")
                    }

                    group.addTask {
                        try await controller.waitForTimeout()
                        throw MCPError.internalError("Unreachable - timeout should throw")
                    }

                    guard let result = try await group.next() else {
                        throw MCPError.internalError("No response received")
                    }

                    group.cancelAll()
                    await controller.cancel()
                    removeProgressCallback(token: progressToken)
                    removeTimeoutController(token: progressToken)
                    return result
                }
            } else {
                // Simple timeout without progress-aware reset
                return try await withThrowingTaskGroup(of: M.Result.self) { group in
                    group.addTask {
                        for try await result in stream {
                            return result
                        }
                        throw MCPError.internalError("No response received")
                    }

                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw MCPError.requestTimeout(timeout: timeout, message: "Request timed out")
                    }

                    guard let result = try await group.next() else {
                        throw MCPError.internalError("No response received")
                    }

                    group.cancelAll()
                    removeProgressCallback(token: progressToken)
                    return result
                }
            }
        } else {
            for try await result in stream {
                removeProgressCallback(token: progressToken)
                removeTimeoutController(token: progressToken)
                return result
            }

            removeProgressCallback(token: progressToken)
            removeTimeoutController(token: progressToken)
            throw MCPError.internalError("No response received")
        }
    }

    /// Remove a progress callback for the given token.
    ///
    /// If the token is being tracked for a task (task-augmented response), the callback
    /// is NOT removed. This keeps progress handlers alive until the task completes.
    private func removeProgressCallback(token: ProgressToken) {
        // Check if this token is being tracked for a task
        // If so, don't remove the callback - it needs to stay alive until task completes
        let isTaskProgressToken = taskProgressTokens.values.contains(token)
        if isTaskProgressToken {
            return
        }
        progressCallbacks.removeValue(forKey: token)
    }

    /// Remove a timeout controller for the given token.
    ///
    /// If the token is being tracked for a task (task-augmented response), the controller
    /// is NOT removed. This keeps timeout tracking alive until the task completes.
    private func removeTimeoutController(token: ProgressToken) {
        // Check if this token is being tracked for a task
        // If so, don't remove the controller - it needs to stay alive until task completes
        let isTaskProgressToken = taskProgressTokens.values.contains(token)
        if isTaskProgressToken {
            return
        }
        timeoutControllers.removeValue(forKey: token)
    }

    /// Remove the request → progress token mapping for the given request ID.
    private func removeRequestProgressToken(id: RequestId) {
        requestProgressTokens.removeValue(forKey: id)
    }

    private func addPendingRequest<T: Sendable & Decodable>(
        id: RequestId,
        continuation: AsyncThrowingStream<T, Swift.Error>.Continuation
    ) {
        pendingRequests[id] = AnyPendingRequest(continuation: continuation)
    }

    private func removePendingRequest(id: RequestId) -> AnyPendingRequest? {
        return pendingRequests.removeValue(forKey: id)
    }

    /// Removes a pending request without returning it.
    /// Used by onTermination handlers when the request has been cancelled.
    private func cleanupPendingRequest(id: RequestId) {
        pendingRequests.removeValue(forKey: id)
    }

    /// Send a CancelledNotification to the server for a cancelled request.
    ///
    /// Per MCP spec: "When a party wants to cancel an in-progress request, it sends
    /// a `notifications/cancelled` notification containing the ID of the request to cancel."
    ///
    /// This is called when a client Task waiting for a response is cancelled.
    /// The notification is sent on a best-effort basis - failures are logged but not thrown.
    private func sendCancellationNotification(requestId: RequestId, reason: String?) async {
        guard let connection = connection else {
            await logger?.debug(
                "Cannot send cancellation notification - connection is nil",
                metadata: ["requestId": "\(requestId)"]
            )
            return
        }

        let notification = CancelledNotification.message(.init(
            requestId: requestId,
            reason: reason
        ))

        do {
            let notificationData = try encoder.encode(notification)
            try await connection.send(notificationData)
            await logger?.debug(
                "Sent cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ]
            )
        } catch {
            // Log but don't throw - cancellation notification is best-effort
            // per MCP spec's fire-and-forget nature of notifications
            await logger?.debug(
                "Failed to send cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "error": "\(error)",
                ]
            )
        }
    }

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
                    await client.cleanupPendingRequest(id: requestId)

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

        let result = try await send(request)

        // Per MCP spec: "If the client does not support the version in the
        // server's response, it SHOULD disconnect."
        guard Version.supported.contains(result.protocolVersion) else {
            await disconnect()
            throw MCPError.invalidRequest(
                "Server responded with unsupported protocol version: \(result.protocolVersion). " +
                "Supported versions: \(Version.supported.sorted().joined(separator: ", "))"
            )
        }

        self.serverCapabilities = result.capabilities
        self.serverVersion = result.protocolVersion
        self.instructions = result.instructions

        // HTTP transports must set the protocol version in headers after initialization
        if let httpTransport = connection as? HTTPClientTransport {
            await httpTransport.setProtocolVersion(result.protocolVersion)
        }

        try await notify(InitializedNotification.message())

        return result
    }

    public func ping() async throws {
        let request = Ping.request()
        _ = try await send(request)
    }

    // MARK: - Prompts

    public func getPrompt(name: String, arguments: [String: String]? = nil) async throws
        -> (description: String?, messages: [Prompt.Message])
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
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
        let result = try await send(request)
        return (prompts: result.prompts, nextCursor: result.nextCursor)
    }

    // MARK: - Resources

    public func readResource(uri: String) async throws -> [Resource.Content] {
        try validateServerCapability(\.resources, "Resources")
        let request = ReadResource.request(.init(uri: uri))
        let result = try await send(request)
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
        let result = try await send(request)
        return (resources: result.resources, nextCursor: result.nextCursor)
    }

    public func subscribeToResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    public func unsubscribeFromResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceUnsubscribe.request(.init(uri: uri))
        _ = try await send(request)
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
        let result = try await send(request)
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
        let result = try await send(request)
        return (tools: result.tools, nextCursor: result.nextCursor)
    }

    public func callTool(name: String, arguments: [String: Value]? = nil) async throws -> (
        content: [Tool.Content], structuredContent: Value?, isError: Bool?
    ) {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
        // TODO: Add client-side output validation against the tool's outputSchema.
        // TypeScript and Python SDKs cache tool outputSchemas from listTools() and
        // validate structuredContent when receiving tool results.
        return (content: result.content, structuredContent: result.structuredContent, isError: result.isError)
    }

    // MARK: - Completions

    /// Request completion suggestions from the server.
    ///
    /// Completions provide autocomplete suggestions for prompt arguments or resource
    /// template URI parameters.
    ///
    /// - Parameters:
    ///   - ref: A reference to the prompt or resource template to get completions for.
    ///   - argument: The argument being completed, including its name and partial value.
    ///   - context: Optional additional context with previously-resolved argument values.
    /// - Returns: The completion suggestions from the server.
    public func complete(
        ref: CompletionReference,
        argument: CompletionArgument,
        context: CompletionContext? = nil
    ) async throws -> CompletionSuggestions {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(.init(ref: ref, argument: argument, context: context))
        let result = try await send(request)
        return result.completion
    }

    // MARK: - Logging

    /// Set the minimum log level for messages from the server.
    ///
    /// After calling this method, the server should only send log messages
    /// at the specified level or higher (more severe).
    ///
    /// - Parameter level: The minimum log level to receive.
    public func setLoggingLevel(_ level: LoggingLevel) async throws {
        try validateServerCapability(\.logging, "Logging")
        let request = SetLoggingLevel.request(.init(level: level))
        _ = try await send(request)
    }

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
            Task { await self?.cleanupPendingRequest(id: requestId) }
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

    // MARK: -

    private func handleResponse(_ response: Response<AnyMethod>) async {
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
    private func checkForTaskResponse(response: Response<AnyMethod>, value: [String: Value]) {
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
    public func cleanupTaskProgressHandler(taskId: String) {
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

    private func handleMessage(_ message: Message<AnyNotification>) async {
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
    private func handleProgressNotification(_ message: Message<AnyNotification>) async {
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
    private func handleTaskStatusNotification(_ message: Message<AnyNotification>) async {
        do {
            // Decode as TaskStatusNotification.Parameters
            let paramsData = try encoder.encode(message.params)
            let params = try decoder.decode(TaskStatusNotification.Parameters.self, from: paramsData)

            // If the task reached a terminal status, clean up its progress handler
            if params.status.isTerminal {
                cleanupTaskProgressHandler(taskId: params.taskId)
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
    private func handleIncomingRequest(_ request: Request<AnyMethod>) async {
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
    private func validateElicitationMode(_ request: Request<AnyMethod>) async -> Response<AnyMethod>? {
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
    private func handleTaskAugmentedRequest(_ request: Request<AnyMethod>) async -> Response<AnyMethod>? {
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
    private func sendResponse(_ response: Response<AnyMethod>) async {
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
