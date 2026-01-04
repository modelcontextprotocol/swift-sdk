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
    var connection: (any Transport)?
    /// The logger for the client
    var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The client information
    let clientInfo: Client.Info
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
    var serverCapabilities: Server.Capabilities?
    /// The server version
    var serverVersion: String?
    /// The server instructions
    var instructions: String?

    /// A dictionary of type-erased notification handlers, keyed by method name
    var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// A dictionary of type-erased request handlers for server→client requests, keyed by method name
    var requestHandlers: [String: ClientRequestHandlerBox] = [:]
    /// Task-augmented sampling handler (called when request has `task` field)
    var taskAugmentedSamplingHandler: ExperimentalClientTaskHandlers.TaskAugmentedSamplingHandler?
    /// Task-augmented elicitation handler (called when request has `task` field)
    var taskAugmentedElicitationHandler: ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler?
    /// The task for the message handling loop
    var task: Task<Void, Never>?

    /// In-flight server request handler Tasks, tracked by request ID.
    /// Used for protocol-level cancellation when CancelledNotification is received.
    var inFlightServerRequestTasks: [RequestId: Task<Void, Never>] = [:]

    /// An error indicating a type mismatch when decoding a pending request
    struct TypeMismatchError: Swift.Error {}

    /// A type-erased pending request using AsyncThrowingStream for cancellation-aware waiting.
    struct AnyPendingRequest {
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
    var pendingRequests: [RequestId: AnyPendingRequest] = [:]
    /// Progress callbacks for requests, keyed by progress token.
    /// Used to invoke callbacks when progress notifications are received.
    var progressCallbacks: [ProgressToken: ProgressCallback] = [:]
    /// Timeout controllers for requests with progress-aware timeouts.
    /// Used to reset timeouts when progress notifications are received.
    var timeoutControllers: [ProgressToken: TimeoutController] = [:]
    /// Mapping from request ID to progress token.
    /// Used to detect task-augmented responses and keep progress handlers alive.
    var requestProgressTokens: [RequestId: ProgressToken] = [:]
    /// Mapping from task ID to progress token.
    /// Keeps progress handlers alive for task-augmented requests until the task completes.
    /// Per MCP spec 2025-11-25: "For task-augmented requests, the progressToken provided
    /// in the original request MUST continue to be used for progress notifications
    /// throughout the task's lifetime, even after the CreateTaskResult has been returned."
    var taskProgressTokens: [String: ProgressToken] = [:]
    // Add reusable JSON encoder/decoder
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    /// Controls timeout behavior for a single request, supporting reset on progress.
    ///
    /// This actor manages the timeout state for requests that use `resetTimeoutOnProgress`.
    /// When progress is received, calling `signalProgress()` resets the timeout clock.
    actor TimeoutController {
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
                    await self.cleanUpPendingRequestsOnUnexpectedDisconnect()
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
    func cleanUpPendingRequestsOnUnexpectedDisconnect() async {
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
    func trackInFlightServerRequest(_ requestId: RequestId, task: Task<Void, Never>) {
        inFlightServerRequestTasks[requestId] = task
    }

    /// Remove an in-flight server request handler Task.
    func removeInFlightServerRequest(_ requestId: RequestId) {
        inFlightServerRequestTasks.removeValue(forKey: requestId)
    }

    /// Cancel an in-flight server request handler Task.
    ///
    /// Called when a CancelledNotification is received for a specific requestId.
    /// Per MCP spec, if the request is unknown or already completed, this is a no-op.
    func cancelInFlightServerRequest(_ requestId: RequestId, reason: String?) async {
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
    func _initialize() async throws -> Initialize.Result {
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
}
