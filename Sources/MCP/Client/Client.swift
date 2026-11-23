import Logging

import struct Foundation.Data
import struct Foundation.UUID
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

        /// How the client answers input-required results (SEP-2322).
        public var multiRoundTrip: MultiRoundTrip

        /// The most server-to-client requests (sampling, elicitation, roots)
        /// whose handlers run at once. Up to 64 more wait; beyond that a
        /// request is refused with -32603.
        public var maxConcurrentServerRequests: Int

        public init(
            strict: Bool = false,
            protocolMode: ProtocolMode = .automatic,
            logLevel: LogLevel? = nil,
            discoveryTimeout: Duration? = .seconds(10),
            multiRoundTrip: MultiRoundTrip = .init(),
            maxConcurrentServerRequests: Int = 4
        ) {
            self.strict = strict
            self.protocolMode = protocolMode
            self.logLevel = logLevel
            self.discoveryTimeout = discoveryTimeout
            self.multiRoundTrip = multiRoundTrip
            self.maxConcurrentServerRequests = maxConcurrentServerRequests
        }

        private enum CodingKeys: String, CodingKey {
            case strict, protocolMode, logLevel, discoveryTimeout, multiRoundTrip, maxConcurrentServerRequests
        }

        /// Decodes a configuration; keys added after `strict` are optional.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            strict = try container.decode(Bool.self, forKey: .strict)
            protocolMode = try container.decodeIfPresent(ProtocolMode.self, forKey: .protocolMode) ?? .automatic
            logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel)
            discoveryTimeout =
                container.contains(.discoveryTimeout)
                ? try container.decodeIfPresent(Duration.self, forKey: .discoveryTimeout) : .seconds(10)
            multiRoundTrip = try container.decodeIfPresent(MultiRoundTrip.self, forKey: .multiRoundTrip) ?? .init()
            maxConcurrentServerRequests =
                try container.decodeIfPresent(Int.self, forKey: .maxConcurrentServerRequests) ?? 4
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(strict, forKey: .strict)
            try container.encode(protocolMode, forKey: .protocolMode)
            try container.encodeIfPresent(logLevel, forKey: .logLevel)
            try container.encode(discoveryTimeout, forKey: .discoveryTimeout)
            try container.encode(multiRoundTrip, forKey: .multiRoundTrip)
            try container.encode(maxConcurrentServerRequests, forKey: .maxConcurrentServerRequests)
        }

        /// How the client answers input-required results (SEP-2322).
        ///
        /// When enabled, ``Client/send(_:)`` fulfills the input requests of a
        /// `tools/call`, `prompts/get` or `resources/read` result with the
        /// registered sampling, elicitation and roots handlers, and retries
        /// the request with the responses and the echoed `requestState`
        /// until the result is complete.
        public struct MultiRoundTrip: Hashable, Codable, Sendable {
            /// Whether the client retries by itself. When `false`, ``Client/send(_:)``
            /// returns input-required results, and the convenience methods
            /// `callTool`, `getPrompt` and `readResource` throw for them.
            public var isEnabled: Bool
            /// The most retries before the request fails.
            public var maxRounds: Int
            /// The most input requests one result may carry. A result with
            /// more fails the request before any handler runs.
            public var maxInputRequests: Int

            public init(isEnabled: Bool = true, maxRounds: Int = 10, maxInputRequests: Int = 16) {
                self.isEnabled = isEnabled
                self.maxRounds = maxRounds
                self.maxInputRequests = maxInputRequests
            }

            private enum CodingKeys: String, CodingKey {
                case isEnabled, maxRounds, maxInputRequests
            }

            /// Decodes the options; missing keys take their defaults.
            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let defaults = MultiRoundTrip()
                isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
                maxRounds = try container.decodeIfPresent(Int.self, forKey: .maxRounds) ?? defaults.maxRounds
                maxInputRequests =
                    try container.decodeIfPresent(Int.self, forKey: .maxInputRequests) ?? defaults.maxInputRequests
            }
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
        /// The default.
        case automatic
        /// Use one stateless revision; fail with
        /// ``MCPError/unsupportedProtocolVersion(supported:requested:)`` if the
        /// server does not serve it. Never retries or falls back.
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
    /// The background `subscriptions/listen` stream (2026-07-28): the list
    /// changes the client has handlers for, and the subscribed resources.
    private(set) var notificationStream: Subscription?
    /// The filter requested for `notificationStream`.
    private var notificationStreamRequest: SubscriptionFilter?
    /// The filter of the stream being opened, or of the open one; `nil` when none.
    private var notificationStreamFilter: SubscriptionFilter?
    /// Incremented on each change, so stale openings are discarded.
    private var notificationStreamGeneration = 0
    /// Failures in a row to open or keep the stream; sets the retry delay.
    private(set) var notificationStreamFailures = 0
    /// When the background stream, or the one it replaced, was opened.
    private var notificationStreamSince: ContinuousClock.Instant?
    /// The pending reopen of a stream that failed.
    private var notificationStreamRetry: Task<Void, Never>?
    /// Replaced background streams that have not ended yet. Their
    /// notifications are delivered while the client still wants them: one
    /// the server sent before it registered the successor exists only on
    /// the replaced stream, so a notification sent during the overlap may
    /// arrive twice.
    private var retiredNotificationStreams: Set<ID> = []
    /// Resource URIs subscribed at 2026-07-28, in subscription order.
    private(set) var subscribedResources: [String] = []
    /// The subscribed URIs that `subscribeToResource` added and no stream has
    /// served yet; one is dropped when the last call waiting for it is cancelled.
    private var unservedResources: Set<String> = []
    /// `subscribeToResource` calls waiting for a stream that names their URI.
    private(set) var resourceWaiters: [(id: UUID, uri: String, continuation: CheckedContinuation<Void, Swift.Error>)] = []
    /// Multi round-trip exchanges in progress: first request id to the id of the current round.
    private var roundTrips: [ID: ID] = [:]
    /// Exchanges cancelled between rounds.
    private var cancelledRoundTrips: Set<ID> = []
    /// Cancels the task that runs an exchange's rounds, by first request id.
    private var roundTripCancellers: [ID: @Sendable () -> Void] = [:]
    /// Waiters for `subscriptions/listen` acknowledgements, by request id.
    private var listenAcknowledgements:
        [ID: AsyncStream<Result<SubscriptionFilter, Swift.Error>>.Continuation] = [:]
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
    /// Changes on every connect, disconnect and close of the connection. A
    /// message loop or a batch only acts on the connection while the
    /// generation it captured is current.
    private var connectionGeneration = 0

    /// A dictionary of type-erased pending requests, keyed by request ID
    private var pendingRequests: [ID: AnyPendingRequest] = [:]
    /// Registered requests not yet handed to the transport. A request
    /// cancelled while here is never sent.
    private var unsentRequests: Set<ID> = []
    /// A running handler of a server-to-client request.
    private struct IncomingHandler {
        /// Tells this run from a later request that reuses the id.
        let token: UUID
        let task: Task<Void, Never>
    }

    /// Handlers of server-to-client requests that are still running.
    private var incomingRequests: [ID: IncomingHandler] = [:]
    /// Cancelled handlers that have not returned yet. They keep their slot.
    private var drainingIncomingRequests: Set<UUID> = []
    /// Server-to-client requests waiting for a free handler slot.
    private var queuedIncomingRequests: [Request<AnyMethod>] = []
    /// The most server-to-client requests that wait for a slot.
    static let incomingRequestBacklog = 64

    /// Notifications in arrival order. Their handlers run one at a time.
    private var inboundQueue: AsyncStream<Message<AnyNotification>>.Continuation?
    private var inboundTask: Task<Void, Never>?
    /// Requests sent from a notification handler. Their responses never
    /// wait for queued notifications, so that the handler can wait for them.
    private var immediateResponses: Set<ID> = []
    /// The progress tokens of requests in flight, recorded while progress
    /// handlers are registered.
    private var progressTokens: [ID: ProgressToken] = [:]
    /// Progress notifications queued and not yet handled, by token.
    private var queuedProgress: [ProgressToken: Int] = [:]
    /// Responses that wait for the queued progress notifications of their
    /// request, by token.
    private var parkedResponses: [ProgressToken: [Response<AnyMethod>]] = [:]

    /// Set while a notification handler runs.
    @TaskLocal private static var isHandlingNotification = false
    /// The slot of the server-to-client request whose handler runs.
    @TaskLocal private static var incomingHandlerToken: UUID?

    /// Notifications the client itself handles inside the receive loop,
    /// before later messages: it only updates its state. Handlers registered
    /// for them run in the inbound queue, like any other.
    private static let inlineNotifications: Set<String> = [
        CancelledNotification.name, SubscriptionsAcknowledgedNotification.name,
    ]
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
    ///
    /// If the client is already connected, it first disconnects the previous
    /// transport, and that connection's pending requests fail as they do with
    /// ``disconnect()``.
    ///
    /// If the transport later closes the connection, which it signals by
    /// finishing its receive stream, the client does what ``disconnect()``
    /// does and fails every pending request with ``MCPError/connectionClosed``.
    /// If the stream ended with an error, requests fail with that error
    /// instead, wrapped in ``MCPError/transportError(_:)`` unless it is an
    /// ``MCPError``. Call `connect(transport:)` again with a new transport to
    /// reconnect.
    ///
    /// - Throws: The error the pending requests fail with when the connection
    ///   closes before the server answered; `MCPError.internalError("Client
    ///   disconnected")` if ``disconnect()`` or another `connect(transport:)`
    ///   runs while the previous transport disconnects or this one connects;
    ///   or any error from connecting the transport or opening the protocol
    ///   connection.
    @discardableResult
    public func connect(transport: any Transport) async throws -> Initialize.Result {
        // Release the previous connection, so that its transport and message
        // loop stop and its requests don't wait for a response.
        if connection != nil {
            let released = await releaseConnection()
            guard connectionGeneration == released else {
                throw MCPError.internalError("Client disconnected")
            }
        }
        connectionGeneration += 1
        let generation = connectionGeneration
        // A reconnect negotiates afresh; requests must not carry the
        // previous connection's stateless `_meta`.
        serverCapabilities = nil
        negotiatedProtocolVersion = nil
        serverInfo = nil
        instructions = nil
        self.connection = transport
        toolHeaderParameters = [:]
        try await transport.connect()
        guard connectionGeneration == generation else {
            throw MCPError.internalError("Client disconnected")
        }

        await logger?.debug(
            "Client connected", metadata: ["name": "\(name)", "version": "\(version)"])

        // Notification handlers run in arrival order, outside the receive
        // loop, so that a handler may await a request on this client.
        let (inbound, queue) = AsyncStream<Message<AnyNotification>>.makeStream()
        inboundQueue = queue
        inboundTask = Task {
            for await message in inbound {
                // A handler that reconnected is not cancelled; the
                // notifications queued behind it belong to the old connection.
                if connectionGeneration != generation { break }
                await Client.$isHandlingNotification.withValue(true) {
                    await self.handleMessage(message)
                }
                if let token = Self.progressToken(of: message) {
                    await self.progressHandled(token)
                }
            }
        }

        // Start message handling loop
        task = Task {
            let connection = transport
            var streamError: (any Swift.Error)?
            repeat {
                // Stop if cancelled, or if this connection was closed or replaced.
                if Task.isCancelled || connectionGeneration != generation { break }

                do {
                    let stream = await connection.receive()
                    for try await data in stream {
                        if Task.isCancelled || connectionGeneration != generation { break }

                        // Attempt to decode data
                        // Try decoding as a batch response first
                        if let batchResponse = try? decoder.decode([AnyResponse].self, from: data) {
                            for response in batchResponse {
                                await deliver(response)
                            }
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            await deliver(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            startIncomingRequest(request, on: connection)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            if Self.inlineNotifications.contains(message.method) {
                                await handleBuiltIn(message)
                            }
                            if notificationHandlers[message.method]?.isEmpty == false {
                                if let token = Self.progressToken(of: message) {
                                    queuedProgress[token, default: 0] += 1
                                }
                                inboundQueue?.yield(message)
                            }
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
                    // The stream finished, so the transport is closed. Calling
                    // receive() again would return a stream that has already ended.
                    break
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    await logger?.error(
                        "Error in message handling loop", metadata: ["error": "\(error)"])
                    streamError = error
                    break
                }
            } while true
            await self.logger?.debug("Client message handling loop task is terminating.")
            await connectionDidClose(generation: generation, error: streamError)
        }

        // Open the protocol connection
        let result: Initialize.Result
        switch configuration.protocolMode {
        case .handshake:
            result = try await _initialize()
        case .automatic:
            result = try await discoverOrInitialize(Version.stateless[0], fallback: true)
        case .stateless(let version):
            result = try await discoverOrInitialize(version, fallback: false)
        }
        refreshNotificationStream()
        return result
    }

    /// Disconnect the client and cancel all pending requests
    public func disconnect() async {
        await logger?.debug("Initiating client disconnect...")
        // A message loop that ends from here on leaves the teardown to this method.
        connectionGeneration += 1

        // Close the listen stream while the connection is still open.
        let (stream, waiters) = closeNotificationStream()
        for waiter in waiters {
            waiter.resume(throwing: MCPError.internalError("Client disconnected"))
        }
        await stream?.cancel()

        // Grab state and clear internal references. This also fails a
        // subscribeToResource call made while the stream was closing.
        let closed = detachConnection(sparingCaller: false)

        // Resume continuations first
        closed.fail(with: MCPError.internalError("Client disconnected"))
        await logger?.debug("Pending requests cancelled.")

        // Cancel the task
        closed.task?.cancel()
        await logger?.debug("Message loop task cancellation requested.")

        // Disconnect the transport *before* awaiting the task
        // This should ensure the transport stream is finished, unblocking the loop.
        if let conn = closed.transport {
            await conn.disconnect()
            await logger?.debug("Transport disconnected.")
        } else {
            await logger?.debug("No active transport connection to disconnect.")
        }

        // Await the task completion *after* transport disconnect
        _ = await closed.task?.value
        await logger?.debug("Client message loop task finished.")

        await logger?.debug("Client disconnect complete.")
    }

    /// What is left to finish once the state of a connection is cleared.
    private struct ClosedConnection {
        let transport: (any Transport)?
        let task: Task<Void, Never>?
        let pendingRequests: [AnyPendingRequest]
        let resourceWaiters: [CheckedContinuation<Void, Swift.Error>]

        /// Fails the requests and `subscribeToResource` calls that waited
        /// for the connection.
        func fail(with error: Swift.Error) {
            for request in pendingRequests {
                request.resume(throwing: error)
            }
            for waiter in resourceWaiters {
                waiter.resume(throwing: error)
            }
        }
    }

    /// Forgets the background stream and its retry, and takes the
    /// `subscribeToResource` calls waiting for it, for the caller to fail.
    private func closeNotificationStream() -> (
        stream: Subscription?, waiters: [CheckedContinuation<Void, Swift.Error>]
    ) {
        let stream = notificationStream
        notificationStream = nil
        notificationStreamRequest = nil
        notificationStreamFilter = nil
        notificationStreamGeneration += 1
        notificationStreamFailures = 0
        notificationStreamSince = nil
        notificationStreamRetry?.cancel()
        notificationStreamRetry = nil
        retiredNotificationStreams = []
        subscribedResources = []
        unservedResources = []
        let waiters = resourceWaiters.map(\.continuation)
        resourceWaiters = []
        return (stream, waiters)
    }

    /// Clears the state of the current connection and stops its handlers.
    /// There is no suspension point, so nothing registers on the connection
    /// in between. The caller disconnects the transport and fails what the
    /// connection leaves.
    ///
    /// - Parameter sparingCaller: Whether the handler that calls this, to
    ///   reconnect, keeps running. Its task is not cancelled.
    private func detachConnection(sparingCaller: Bool) -> ClosedConnection {
        connectionGeneration += 1
        let closed = ClosedConnection(
            transport: connection, task: task, pendingRequests: Array(pendingRequests.values),
            resourceWaiters: closeNotificationStream().waiters)

        self.task = nil
        self.connection = nil
        self.pendingRequests = [:]
        for cancel in roundTripCancellers.values { cancel() }
        roundTripCancellers = [:]
        roundTrips = [:]
        cancelledRoundTrips = []
        self.toolHeaderParameters = [:]
        self.unsentRequests = []

        // Stop the handlers. They are not awaited: disconnect may be called
        // from one of them.
        let caller = sparingCaller ? Client.incomingHandlerToken : nil
        for handler in incomingRequests.values where handler.token != caller {
            handler.task.cancel()
        }
        // They keep their slots until they return, also on the next connection.
        drainingIncomingRequests.formUnion(incomingRequests.values.map(\.token))
        incomingRequests = [:]
        queuedIncomingRequests = []
        immediateResponses = []
        progressTokens = [:]
        queuedProgress = [:]
        parkedResponses = [:]
        inboundQueue?.finish()
        inboundQueue = nil
        if !(sparingCaller && Client.isHandlingNotification) {
            inboundTask?.cancel()
        }
        inboundTask = nil
        return closed
    }

    /// Releases the current connection before `connect(transport:)` uses a
    /// new one. Unlike ``disconnect()``, this does not cancel the handler
    /// that called it nor wait for the message loop, which stops at its next
    /// message because the connection generation changed.
    ///
    /// - Returns: The connection generation after the release.
    private func releaseConnection() async -> Int {
        let closed = detachConnection(sparingCaller: true)
        let released = connectionGeneration
        closed.task?.cancel()
        await closed.transport?.disconnect()
        closed.fail(with: MCPError.internalError("Client disconnected"))
        return released
    }

    /// Handles the end of the message loop when the transport finished its
    /// stream, normally or by throwing: does what ``disconnect()`` does and
    /// fails what waited for the connection with the stream's error, or
    /// ``MCPError/connectionClosed``. Does nothing if ``disconnect()`` or a
    /// later ``connect(transport:)`` already closed this connection.
    private func connectionDidClose(generation: Int, error: (any Swift.Error)?) async {
        guard connectionGeneration == generation else { return }

        let failure: MCPError
        if let error = error as? MCPError {
            failure = error
        } else if let error {
            failure = .transportError(error)
        } else {
            failure = .connectionClosed
        }
        let closed = detachConnection(sparingCaller: false)

        // Release the transport before resuming the callers, so that a caller
        // that reconnects with the same transport is not disconnected afterwards.
        await closed.transport?.disconnect()
        closed.fail(with: failure)
        await closed.transport?.logger.warning(
            "Client connection closed by the transport",
            metadata: [
                "error": "\(failure)",
                "failedRequests": "\(closed.pendingRequests.count)",
            ])
    }

    // MARK: - Registration

    /// Register a handler for a notification
    ///
    /// Notification handlers run one at a time, in arrival order. A request
    /// with a progress token is answered only after its progress
    /// notifications that arrived first were handled, so a handler must not
    /// await a request with a progress token sent outside a notification
    /// handler: when its progress is queued behind the handler, its response
    /// waits for it and the handler waits forever. Start a `Task` for that
    /// wait instead.
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self {
        notificationHandlers[N.name, default: []].append(TypedNotificationHandler(handler))
        if Self.listChangeMethods.contains(N.name) {
            refreshNotificationStream()
        }
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

    /// Send a response back to the server for a server-to-client request, on
    /// the transport the request came from
    private func send<M: Method>(_ response: Response<M>, on transport: any Transport) async throws {
        let responseData = try encoder.encode(response)
        try await transport.send(responseData)
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
        let first = try dispatch(request)
        return RequestContext(requestID: request.id, requestTask: withRoundTrips(request, first: first))
    }

    /// Runs the multi round-trip loop on the result of `first` when the
    /// method can return an input-required result (SEP-2322).
    private func withRoundTrips<M: Method>(
        _ request: Request<M>, first: Task<M.Result, Error>
    ) -> Task<M.Result, Error> {
        let options = configuration.multiRoundTrip
        guard MRTR.carriers.contains(M.name), options.isEnabled else { return first }
        // Registered before the first response can arrive, so a
        // cancelRequest always finds the exchange.
        roundTrips[request.id] = request.id
        let task = Task<M.Result, Error> {
            defer { self.endRoundTrips(request.id) }
            return try await self.resolveInputRequests(
                request, first: Self.result(of: first), options: options)
        }
        roundTripCancellers[request.id] = { task.cancel() }
        return task
    }

    /// Fulfills input requests and retries until the result is complete (SEP-2322).
    private func resolveInputRequests<M: Method>(
        _ request: Request<M>, first: M.Result, options: Configuration.MultiRoundTrip
    ) async throws -> M.Result {
        var result = first
        var params = request.params
        var rounds = 0
        var stateOnlyDelay = MRTR.stateOnlyInitialDelay
        while let asking = result as? any InputRequiringResult, asking.isInputRequired,
            let current = params as? any InputRespondingParameters
        {
            try Task.checkCancellation()
            if cancelledRoundTrips.contains(request.id) { throw CancellationError() }
            rounds += 1
            guard rounds <= options.maxRounds else {
                throw MCPError.internalError(
                    "\(M.name): the server asked for input more than \(options.maxRounds) times")
            }
            var responses: [String: InputResponse]?
            if let requests = asking.inputRequests, requests.count > options.maxInputRequests {
                throw MCPError.internalError(
                    "\(M.name): the server asked for \(requests.count) inputs at once, more than \(options.maxInputRequests)")
            }
            if let requests = asking.inputRequests, !requests.isEmpty {
                stateOnlyDelay = MRTR.stateOnlyInitialDelay
                responses = try await fulfillInputRequests(requests)
            } else {
                // Only state, or neither: the server is not done yet.
                try await Task.sleep(for: stateOnlyDelay)
                stateOnlyDelay = min(stateOnlyDelay * 2, MRTR.stateOnlyMaximumDelay)
            }
            try Task.checkCancellation()
            if cancelledRoundTrips.contains(request.id) { throw CancellationError() }
            params = current.retrying(inputResponses: responses, requestState: asking.requestState) as! M.Parameters
            let retry = Request<M>(method: M.name, params: params, _meta: request._meta)
            roundTrips[request.id] = retry.id
            result = try await Self.result(of: dispatch(retry))
        }
        return result
    }

    /// The value of `task`; cancelling the caller cancels `task`.
    private static func result<T>(of task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func endRoundTrips(_ id: ID) {
        roundTrips[id] = nil
        cancelledRoundTrips.remove(id)
        roundTripCancellers[id] = nil
    }

    /// Runs the registered handlers for input requests, concurrently.
    private func fulfillInputRequests(_ requests: [String: InputRequest]) async throws
        -> [String: InputResponse]
    {
        var calls: [(String, InputRequest, RequestHandlerBox, AnyRequest)] = []
        for (key, request) in requests {
            guard let handler = methodHandlers[request.method] else {
                throw MCPError.methodNotFound("No handler registered for \(request.method)")
            }
            calls.append((key, request, handler, Request(method: request.method, params: try request.params())))
        }
        return try await withThrowingTaskGroup(of: (String, InputResponse).self) { group in
            for (key, request, handler, anyRequest) in calls {
                group.addTask {
                    let response = try await handler(anyRequest)
                    switch response.result {
                    case .success(let value):
                        return (key, try InputResponse(method: request.method, result: value))
                    case .failure(let error):
                        throw error
                    }
                }
            }
            var responses: [String: InputResponse] = [:]
            for try await (key, response) in group {
                responses[key] = response
            }
            return responses
        }
    }

    /// A request encoded and registered, ready to be handed to the transport.
    struct OutgoingRequest: Sendable {
        let id: ID
        let data: Data
        /// SEP-2243 `Mcp-Param-*` headers, for HTTP.
        let headers: [String: String]
    }

    /// Adds the 2026-07-28 envelope, encodes the request and registers its
    /// response slot. The request is not sent: it is in `unsentRequests`.
    ///
    /// Registration happens before this returns, so a response or a
    /// `cancelRequest(_:)` that follows always finds the request.
    private func register<M: Method>(_ request: Request<M>) throws -> (OutgoingRequest, Task<M.Result, Error>) {
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
        let data = try encoder.encode(request)
        let firstToolPage = (request.params as? ListTools.Parameters).map { $0.cursor == nil } ?? false

        let slot = ResponseSlot<M.Result>()
        pendingRequests[request.id] = AnyPendingRequest(slot)
        unsentRequests.insert(request.id)
        if Client.isHandlingNotification {
            immediateResponses.insert(request.id)
        }
        if notificationHandlers[ProgressNotification.name]?.isEmpty == false,
            let token = Self.progressToken(ofRequest: data)
        {
            progressTokens[request.id] = token
        }

        let id = request.id
        let isInitialize = M.name == Initialize.name
        let task = Task<M.Result, Error> {
            // Cancelling the task cancels the request. `initialize` must not
            // be cancelled on the wire: it is only forgotten.
            let value = try await withTaskCancellationHandler {
                try await slot.value()
            } onCancel: {
                slot.resolve(.failure(CancellationError()))
                Task {
                    if isInitialize {
                        await self.forgetRequest(id)
                    } else {
                        try? await self.cancelRequest(id, reason: "Cancelled")
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
        return (OutgoingRequest(id: request.id, data: data, headers: headers), task)
    }

    /// A transport error raised while sending a request, as opposed to the
    /// peer's answer.
    private struct SendFailure: Swift.Error {
        let error: Swift.Error
    }

    /// Sends one request and returns the task for its result. With
    /// `markingSendFailures`, transport errors are wrapped in ``SendFailure``.
    private func dispatch<M: Method>(
        _ request: Request<M>, markingSendFailures: Bool = false
    ) throws -> Task<M.Result, Error> {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }
        let (outgoing, task) = try register(request)
        Task { await self.transmit(outgoing, on: connection, markingSendFailures: markingSendFailures) }
        return task
    }

    /// Hands a registered request to the transport, unless it was cancelled
    /// first. A failed send fails the request.
    private func transmit(
        _ outgoing: OutgoingRequest, on connection: any Transport, markingSendFailures: Bool = false
    ) async {
        guard unsentRequests.remove(outgoing.id) != nil else { return }
        do {
            if !outgoing.headers.isEmpty {
                try await connection.send(outgoing.data, additionalHeaders: outgoing.headers)
            } else {
                try await connection.send(outgoing.data)
            }
        } catch {
            removePendingRequest(id: outgoing.id)?.resume(
                throwing: markingSendFailures ? SendFailure(error: error) : error)
        }
    }

    // MARK: - Subscriptions (2026-07-28)

    /// An open `subscriptions/listen` stream.
    ///
    /// Notifications on the stream are delivered to the handlers registered
    /// with ``Client/onNotification(_:handler:)``.
    public struct Subscription: Sendable {
        /// The JSON-RPC id of the listen request; notifications on the
        /// stream carry it in `_meta["io.modelcontextprotocol/subscriptionId"]`.
        public let id: ID
        /// The notification types the server agreed to send.
        public let notifications: SubscriptionFilter

        private let client: Client
        private let request: RequestContext<SubscriptionsListen.Result>

        init(
            id: ID, notifications: SubscriptionFilter, client: Client,
            request: RequestContext<SubscriptionsListen.Result>
        ) {
            self.id = id
            self.notifications = notifications
            self.client = client
            self.request = request
        }

        /// Closes the stream.
        public func cancel() async {
            try? await client.cancelRequest(id, reason: "Subscription cancelled")
        }

        /// Waits for the stream to end. Returns when the server closes it
        /// gracefully; throws when it fails or is cancelled.
        public func finished() async throws {
            _ = try await request.value
        }
    }

    private static let listChangeMethods: Set<String> = [
        ToolListChangedNotification.name, PromptListChangedNotification.name,
        ResourceListChangedNotification.name,
    ]

    /// What the background stream listens for: the list changes the server
    /// sends and the client has a handler for, and the subscribed resources.
    private var wantedNotifications: SubscriptionFilter {
        func wants(_ method: String, _ declared: Bool?) -> Bool? {
            declared == true && notificationHandlers[method]?.isEmpty == false ? true : nil
        }
        return SubscriptionFilter(
            toolsListChanged: wants(ToolListChangedNotification.name, serverCapabilities?.tools?.listChanged),
            promptsListChanged: wants(
                PromptListChangedNotification.name, serverCapabilities?.prompts?.listChanged),
            resourcesListChanged: wants(
                ResourceListChangedNotification.name, serverCapabilities?.resources?.listChanged),
            resourceSubscriptions: subscribedResources.isEmpty ? nil : subscribedResources)
    }

    /// The first delay before a background stream that ended is reopened; it
    /// doubles while streams keep ending, up to ``notificationStreamMaxDelay``.
    static let notificationStreamBaseDelay: Duration = .seconds(1)
    static let notificationStreamMaxDelay: Duration = .seconds(60)

    /// Whether the transport can read the streamed responses of
    /// `subscriptions/listen`.
    private var streamsResponses: Bool {
        HTTPClientTransport.streamsResponses || !(connection is HTTPClientTransport)
    }

    /// Opens, replaces or closes the background stream so that it matches
    /// the registered handlers and subscribed resources (2026-07-28). The
    /// stream opens in the background; a replaced stream closes once its
    /// successor is acknowledged, and stays open when the successor fails.
    private func refreshNotificationStream() {
        guard isStateless, connection != nil, streamsResponses else { return }
        let wanted = wantedNotifications
        let none = SubscriptionFilter()
        guard wanted != (notificationStreamFilter ?? none) else { return }
        notificationStreamRetry?.cancel()
        notificationStreamRetry = nil
        notificationStreamGeneration += 1
        let generation = notificationStreamGeneration
        guard wanted != none else {
            if let previous = notificationStream { retire(previous) }
            notificationStream = nil
            notificationStreamRequest = nil
            notificationStreamFilter = nil
            return
        }
        notificationStreamFilter = wanted
        Task { await self.openNotificationStream(wanted, generation: generation) }
    }

    private func openNotificationStream(_ wanted: SubscriptionFilter, generation: Int) async {
        let opened: Subscription
        do {
            opened = try await listen(wanted)
        } catch {
            guard generation == notificationStreamGeneration else { return }
            await logger?.warning(
                "Could not open the notification stream", metadata: ["error": "\(error)"])
            // Keep the stream that works.
            notificationStreamFilter = notificationStreamRequest
            failResourceWaiters(requested: wanted, error: error)
            notificationStreamFailures += 1
            scheduleNotificationStreamRetry()
            return
        }
        let current = generation == notificationStreamGeneration
        // A superseded opening still serves until its successor is
        // acknowledged, unless a stream is open or none is wanted.
        guard current || (notificationStream == nil && wantedNotifications != SubscriptionFilter()) else {
            await opened.cancel()
            return
        }
        if current {
            // The previous stream may have ended meanwhile, which cleared the
            // filter and scheduled a reopen; this stream serves what is wanted.
            notificationStreamFilter = wanted
            notificationStreamRetry?.cancel()
            notificationStreamRetry = nil
        } else if notificationStreamFilter == nil {
            notificationStreamFilter = wanted
        }
        let previous = notificationStream
        if previous == nil { notificationStreamSince = .now }
        notificationStream = opened
        notificationStreamRequest = wanted
        if let previous { retire(previous) }
        resolveResourceWaiters(requested: wanted, honored: opened.notifications)
        Task {
            _ = try? await opened.finished()
            self.notificationStreamEnded(id: opened.id)
        }
    }

    /// Closes a replaced background stream. Until it ends, its
    /// notifications the client no longer wants are dropped.
    private func retire(_ stream: Subscription) {
        retiredNotificationStreams.insert(stream.id)
        Task {
            await stream.cancel()
            self.forgetRetired(stream.id)
        }
    }

    private func forgetRetired(_ id: ID) {
        retiredNotificationStreams.remove(id)
    }

    /// Forgets a background stream that ended and reopens it after a delay,
    /// also when the server ended it with its result, as it does when it
    /// stops for a restart. The delay keeps growing while streams end sooner
    /// than ``notificationStreamMaxDelay`` after opening.
    private func notificationStreamEnded(id: ID) {
        guard notificationStream?.id == id else { return }
        notificationStream = nil
        notificationStreamRequest = nil
        notificationStreamFilter = nil
        if notificationStreamSince.map({ .now - $0 >= Self.notificationStreamMaxDelay }) == true {
            notificationStreamFailures = 0
        }
        notificationStreamSince = nil
        notificationStreamFailures += 1
        scheduleNotificationStreamRetry()
    }

    /// Retries ``refreshNotificationStream()`` after the backoff delay.
    private func scheduleNotificationStreamRetry() {
        guard notificationStreamRetry == nil, connection != nil,
            wantedNotifications != (notificationStreamFilter ?? SubscriptionFilter())
        else { return }
        let delay = Self.notificationStreamDelay(failures: notificationStreamFailures)
        let generation = connectionGeneration
        notificationStreamRetry = Task {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self.retryNotificationStream(generation: generation)
        }
    }

    /// Reopens the stream, unless the connection it was for has closed.
    private func retryNotificationStream(generation: Int) {
        guard connectionGeneration == generation else { return }
        notificationStreamRetry = nil
        refreshNotificationStream()
    }

    /// The delay before reopening after `failures` failures in a row.
    static func notificationStreamDelay(failures: Int) -> Duration {
        let exponent = min(max(failures - 1, 0), 16)
        return min(notificationStreamBaseDelay * (1 << exponent), notificationStreamMaxDelay)
    }

    /// Completes the `subscribeToResource` calls for the URIs `requested`
    /// named. URIs the server did not honor fail and are unsubscribed.
    private func resolveResourceWaiters(requested: SubscriptionFilter, honored: SubscriptionFilter) {
        let named = Set(requested.resourceSubscriptions ?? [])
        let served = Set(honored.resourceSubscriptions ?? [])
        let refused = named.subtracting(served)
        unservedResources.subtract(named)
        if !refused.isEmpty {
            subscribedResources.removeAll { refused.contains($0) }
            if wantedNotifications == SubscriptionFilter() {
                refreshNotificationStream()  // closes the stream
            } else {
                // The open stream already serves what remains.
                notificationStreamFilter = wantedNotifications
            }
        }
        var waiting: [(id: UUID, uri: String, continuation: CheckedContinuation<Void, Swift.Error>)] = []
        for waiter in resourceWaiters {
            if served.contains(waiter.uri) {
                waiter.continuation.resume()
            } else if refused.contains(waiter.uri) {
                waiter.continuation.resume(
                    throwing: MCPError.invalidRequest("The server does not send updates for \(waiter.uri)"))
            } else {
                waiting.append(waiter)
            }
        }
        resourceWaiters = waiting
    }

    /// Fails the `subscribeToResource` calls whose URI only `requested`, a
    /// stream that could not be opened, named. Established subscriptions
    /// stay, so a stream that failed keeps being reopened for them.
    private func failResourceWaiters(requested: SubscriptionFilter, error: Swift.Error) {
        let served = Set(notificationStream?.notifications.resourceSubscriptions ?? [])
        let failed = Set(requested.resourceSubscriptions ?? [])
            .intersection(resourceWaiters.map(\.uri))
            .subtracting(served)
        guard !failed.isEmpty else { return }
        subscribedResources.removeAll { failed.contains($0) }
        unservedResources.subtract(failed)
        var waiting: [(id: UUID, uri: String, continuation: CheckedContinuation<Void, Swift.Error>)] = []
        for waiter in resourceWaiters {
            if failed.contains(waiter.uri) {
                waiter.continuation.resume(throwing: error)
            } else {
                waiting.append(waiter)
            }
        }
        resourceWaiters = waiting
    }

    /// Opens a `subscriptions/listen` stream (2026-07-28, SEP-2575) and waits
    /// for the server to acknowledge it.
    ///
    /// At protocol 2026-07-28, list-changed and resource-updated notifications
    /// are sent only on these streams. Register handlers with
    /// ``onNotification(_:handler:)`` before listening.
    ///
    /// - Throws: ``MCPError/invalidRequest(_:)`` on handshake connections,
    ///   or the server's error.
    public func listen(_ notifications: SubscriptionFilter) async throws -> Subscription {
        guard isStateless else {
            throw MCPError.invalidRequest(
                "\(SubscriptionsListen.name) requires protocol version 2026-07-28 or later")
        }
        guard streamsResponses else {
            throw MCPError.internalError(
                "\(SubscriptionsListen.name) needs a streamed response, which HTTPClientTransport does not read on Linux")
        }
        let request = SubscriptionsListen.request(.init(notifications: notifications))
        // The acknowledgement, or the request ending before one arrives.
        let (outcomes, outcome) = AsyncStream<Result<SubscriptionFilter, Swift.Error>>.makeStream()
        listenAcknowledgements[request.id] = outcome
        defer { listenAcknowledgements[request.id] = nil }

        let context = try send(request)
        Task {
            do {
                _ = try await context.value
                outcome.yield(
                    .failure(MCPError.internalError("\(SubscriptionsListen.name) ended before it was acknowledged")))
            } catch {
                outcome.yield(.failure(error))
            }
        }
        var honored: SubscriptionFilter?
        for await result in outcomes {
            honored = try result.get()
            break
        }
        guard let honored else {
            // The caller was cancelled while waiting.
            try? await cancelRequest(request.id)
            throw CancellationError()
        }
        return Subscription(id: request.id, notifications: honored, client: self, request: context)
    }

    private func acknowledge(_ id: ID, _ notifications: SubscriptionFilter) {
        listenAcknowledgements[id]?.yield(.success(notifications))
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
        // A request in a multi round-trip exchange: stop its rounds, which
        // cancels running input handlers, and cancel its current round.
        var requestID = requestID
        var inRoundTrip = false
        if let current = roundTrips[requestID] {
            cancelledRoundTrips.insert(requestID)
            roundTripCancellers[requestID]?()
            requestID = current
            inRoundTrip = true
        }

        // Remove the pending request and resume with cancellation error
        // This ensures any response that arrives after cancellation is ignored
        if let pendingRequest = removePendingRequest(id: requestID) {
            pendingRequest.resume(throwing: CancellationError())
        } else if inRoundTrip {
            // Between rounds: the server has nothing in flight to cancel.
            return
        }

        // Not sent yet: it never will be, and the server has nothing to cancel.
        if unsentRequests.remove(requestID) != nil {
            return
        }

        // At 2026-07-28 over HTTP, closing the response stream cancels the request.
        if isStateless, let http = connection as? HTTPClientTransport {
            await http.cancelRequest(requestID)
            return
        }

        // Send cancellation notification to server
        let notification = CancelledNotification.message(
            .init(requestId: requestID, reason: reason)
        )
        try await notify(notification)
    }


    /// Stops tracking a request without telling the server.
    private func forgetRequest(_ id: ID) {
        removePendingRequest(id: id)?.resume(throwing: CancellationError())
        unsentRequests.remove(id)
    }

    private func removePendingRequest(id: ID) -> AnyPendingRequest? {
        immediateResponses.remove(id)
        progressTokens[id] = nil
        return pendingRequests.removeValue(forKey: id)
    }

    // MARK: - Inbound ordering

    /// Delivers a response at once, unless progress notifications of its
    /// request are still queued: then after them.
    private func deliver(_ response: Response<AnyMethod>) async {
        if !immediateResponses.contains(response.id), let token = progressTokens[response.id],
            queuedProgress[token, default: 0] > 0
        {
            parkedResponses[token, default: []].append(response)
            return
        }
        await handleResponse(response)
    }

    private func progressHandled(_ token: ProgressToken) async {
        let remaining = (queuedProgress[token] ?? 1) - 1
        queuedProgress[token] = remaining > 0 ? remaining : nil
        guard remaining <= 0, let parked = parkedResponses.removeValue(forKey: token) else { return }
        for response in parked {
            await handleResponse(response)
        }
    }

    /// The token of a `notifications/progress` message.
    private static func progressToken(of message: Message<AnyNotification>) -> ProgressToken? {
        guard message.method == ProgressNotification.name else { return nil }
        switch message.params.objectValue?["progressToken"] {
        case .string(let string): return .string(string)
        case .int(let int): return .integer(int)
        default: return nil
        }
    }

    /// The `params._meta.progressToken` of an encoded request.
    private static func progressToken(ofRequest data: Data) -> ProgressToken? {
        struct Probe: Decodable {
            struct Params: Decodable {
                struct Meta: Decodable { let progressToken: ProgressToken? }
                let _meta: Meta?
            }
            let params: Params?
        }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.params?._meta?.progressToken
    }

    private static func decode<T: Decodable>(_ value: Value, as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The client's own handling of `notifications/cancelled` and
    /// `notifications/subscriptions/acknowledged`.
    private func handleBuiltIn(_ message: Message<AnyNotification>) async {
        switch message.method {
        case SubscriptionsAcknowledgedNotification.name:
            guard let id = message._meta?.subscriptionID,
                let params = Self.decode(message.params, as: SubscriptionsAcknowledgedNotification.Parameters.self)
            else { return }
            acknowledge(id, params.notifications)
        case CancelledNotification.name:
            guard let params = Self.decode(message.params, as: CancelledNotification.Parameters.self) else { return }
            await logger?.debug(
                "Received cancellation notification",
                metadata: [
                    "requestId": params.requestId.map { "\($0)" } ?? "none",
                    "reason": params.reason.map { "\($0)" } ?? "none",
                ])
            guard let requestId = params.requestId else { return }
            // The server cancels a request it sent: stop its handler.
            if cancelIncomingRequest(requestId) { return }
            if let pendingRequest = removePendingRequest(id: requestId) {
                pendingRequest.resume(throwing: CancellationError())
            }
        default:
            break
        }
    }

    // MARK: - Batching

    /// A batch of requests.
    ///
    /// Objects of this type are passed as an argument to the closure
    /// of the ``Client/withBatch(body:)`` method.
    public actor Batch {
        unowned let client: Client
        /// The client's connection generation when the batch was created.
        let generation: Int
        var requests: [OutgoingRequest] = []

        init(client: Client, generation: Int) {
            self.client = client
            self.generation = generation
        }

        /// Adds a request to the batch and prepares its expected response task.
        /// The actual sending happens when the `withBatch` scope completes.
        ///
        /// The request gets what ``Client/send(_:)`` adds: the 2026-07-28
        /// `_meta` envelope and header parameters, and the multi round-trip
        /// loop for `tools/call`, `prompts/get` and `resources/read`.
        /// - Returns: A `Task` that will eventually produce the result or throw an error.
        public func addRequest<M: Method>(_ request: Request<M>) async throws -> Task<
            M.Result, Swift.Error
        > {
            let (outgoing, task) = try await client.registerBatchRequest(request, generation: generation)
            requests.append(outgoing)
            return task
        }
    }

    private func registerBatchRequest<M: Method>(_ request: Request<M>, generation: Int) throws -> (
        OutgoingRequest, Task<M.Result, Error>
    ) {
        // The connection the batch is for closed or was replaced.
        guard connectionGeneration == generation else {
            throw MCPError.connectionClosed
        }
        guard connection != nil else {
            throw MCPError.internalError("Client connection not initialized")
        }
        let (outgoing, first) = try register(request)
        return (outgoing, withRoundTrips(request, first: first))
    }

    /// Fails registered batch requests that will not be sent.
    private func abandonBatch(_ requests: [OutgoingRequest], with error: Swift.Error) {
        for request in requests where unsentRequests.remove(request.id) != nil {
            removePendingRequest(id: request.id)?.resume(throwing: error)
        }
    }

    /// Sends the batch requests that were not cancelled as one JSON array.
    /// On a stateless connection each request is sent alone: 2026-07-28
    /// requests carry per-request HTTP headers.
    private func sendBatch(_ requests: [OutgoingRequest], on connection: any Transport) async throws {
        if isStateless {
            for request in requests {
                Task { await self.transmit(request, on: connection) }
            }
            return
        }
        let ready = requests.filter { unsentRequests.remove($0.id) != nil }
        guard !ready.isEmpty else { return }
        var data = Data("[".utf8)
        data.append(Data(ready.map(\.data).joined(separator: Data(",".utf8))))
        data.append(Data("]".utf8))
        do {
            try await connection.send(data)
        } catch {
            for request in ready {
                removePendingRequest(id: request.id)?.resume(throwing: error)
            }
            throw error
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
    ///           `MCPError.connectionClosed` if, while `body` ran, the connection
    ///           closed or was replaced by ``disconnect()`` or
    ///           ``connect(transport:)``; the batch is then not sent.
    ///           Can also rethrow errors from the `body` closure or from sending the batch request.
    public func withBatch(body: @escaping @Sendable (Batch) async throws -> Void) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Create Batch actor, passing self (Client)
        let generation = connectionGeneration
        let batch = Batch(client: self, generation: generation)

        // Populate the batch actor by calling the user's closure.
        do {
            try await body(batch)
        } catch {
            // The requests added so far are never sent.
            abandonBatch(await batch.requests, with: error)
            throw error
        }

        // Get the collected requests from the batch actor
        let requests = await batch.requests

        // Check if there are any requests to send
        guard !requests.isEmpty else {
            await logger?.debug("Batch requested but no requests were added.")
            return  // Nothing to send
        }

        await logger?.debug(
            "Sending batch request", metadata: ["count": "\(requests.count)"])
        // Not on a connection that closed or was replaced while the batch was built.
        guard connectionGeneration == generation else {
            abandonBatch(requests, with: MCPError.connectionClosed)
            throw MCPError.connectionClosed
        }
        try await sendBatch(requests, on: connection)

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

    /// Records the `x-mcp-header` arguments of each listed tool and drops
    /// tools with invalid annotations, at revisions that define
    /// `Mcp-Param-*` headers (SEP-2243). Returns `nil` at other revisions.
    /// A first page (no cursor) replaces what earlier listings recorded.
    ///
    /// The record is replaced in one step before the warnings are logged:
    /// logging awaits the transport's logger, and a `tools/call` sent
    /// meanwhile must find every tool of the page.
    private func recordTools(_ result: ListTools.Result, firstPage: Bool) async -> ListTools.Result? {
        guard let version = negotiatedProtocolVersion, Version.profile(for: version).usesStandardHeaders
        else { return nil }
        var recorded = firstPage ? [:] : toolHeaderParameters
        var valid: [Tool] = []
        var rejected: [(tool: String, error: String)] = []
        for tool in result.tools {
            do {
                recorded[tool.name] = try tool.headerParameters()
                valid.append(tool)
            } catch {
                recorded[tool.name] = nil
                rejected.append((MCPRequestHeaders.sanitized(tool.name), "\(error)"))
            }
        }
        toolHeaderParameters = recorded
        for (tool, error) in rejected {
            await logger?.warning(
                "Ignoring tool with an invalid x-mcp-header annotation",
                metadata: ["tool": "\(tool)", "error": "\(error)"])
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
    /// - Parameter fallback: `true` for `.automatic`: on -32022 retry once
    ///   with the newest stateless version the server lists; fall back to
    ///   `initialize` on a JSON-RPC error, a server without a stateless
    ///   revision in common, an HTTP 400/404/405 refusal or no answer within
    ///   ``Configuration/discoveryTimeout``. Other transport errors are
    ///   rethrown. `false` for `.stateless(_:)`: only `preferred` is accepted.
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
                let context = RequestContext(
                    requestID: request.id, requestTask: try dispatch(request, markingSendFailures: true))
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
            } catch let error as MCPError where fallback && connection != nil {
                // The peer answered with a JSON-RPC error. On a closed
                // connection the error is rethrown: there is nothing to fall back on.
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
        let result = try Self.complete(try await send(request).value, GetPrompt.name)
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
        let result = try Self.complete(try await send(request).value, ReadResource.name)
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

    /// Asks for `notifications/resources/updated` when the resource at `uri` changes.
    ///
    /// On handshake connections this sends `resources/subscribe`. At
    /// 2026-07-28 the URI joins the background `subscriptions/listen`
    /// stream, which is replaced by one that names it; this returns once the
    /// server acknowledges that stream. Subscribing again to a subscribed URI
    /// does nothing. Cancelling the calling task ends the wait with
    /// `CancellationError`; the URI is dropped again when no stream has
    /// served it yet and no other call waits for it.
    ///
    /// - Throws: ``MCPError/invalidRequest(_:)`` when the server does not
    ///   send updates for `uri`, or the error that kept the stream from
    ///   opening.
    public func subscribeToResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        guard isStateless else {
            let request = ResourceSubscribe.request(.init(uri: uri))
            _ = try await send(request).value
            return
        }
        guard connection != nil else { throw MCPError.internalError("Client disconnected") }
        guard streamsResponses else {
            throw MCPError.internalError(
                "Resource subscriptions at 2026-07-28 need streamed responses, which HTTPClientTransport does not read on Linux")
        }
        if subscribedResourceURIs.contains(uri) { return }
        try Task.checkCancellation()
        if !subscribedResources.contains(uri) {
            subscribedResources.append(uri)
            unservedResources.insert(uri)
        }
        let waiter = UUID()
        try await withTaskCancellationHandler { () async throws -> Void in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                addResourceWaiter(waiter, uri: uri, continuation: continuation)
            }
        } onCancel: {
            Task { await self.abandonResourceWaiter(waiter, uri: uri) }
        }
    }

    /// Records a `subscribeToResource` call and reopens the stream for it.
    private func addResourceWaiter(
        _ id: UUID, uri: String, continuation: CheckedContinuation<Void, Swift.Error>
    ) {
        guard !Task.isCancelled else {
            // The cancellation handler drops the URI; opening a stream for
            // it now would only be replaced again.
            continuation.resume(throwing: CancellationError())
            return
        }
        resourceWaiters.append((id: id, uri: uri, continuation: continuation))
        refreshNotificationStream()
    }

    /// Ends a `subscribeToResource` call whose task was cancelled. Once no
    /// call waits for the URI, it is dropped if no stream has served it yet.
    private func abandonResourceWaiter(_ id: UUID, uri: String) {
        if let index = resourceWaiters.firstIndex(where: { $0.id == id }) {
            resourceWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        guard unservedResources.contains(uri), !resourceWaiters.contains(where: { $0.uri == uri })
        else { return }
        unservedResources.remove(uri)
        subscribedResources.removeAll { $0 == uri }
        refreshNotificationStream()
    }

    /// Stops `notifications/resources/updated` for the resource at `uri`.
    ///
    /// On handshake connections this sends `resources/unsubscribe`. At
    /// 2026-07-28 the background stream is replaced by one without the URI;
    /// updates may arrive until the server acknowledges the replacement. It
    /// does nothing when the URI is not subscribed.
    public func unsubscribeFromResource(uri: String) async throws {
        guard isStateless else {
            try validateServerCapability(\.resources?.subscribe, "Resource subscription")
            let request = ResourceUnsubscribe.request(.init(uri: uri))
            _ = try await send(request).value
            return
        }
        guard subscribedResources.contains(uri) else { return }
        subscribedResources.removeAll { $0 == uri }
        unservedResources.remove(uri)
        var waiting: [(id: UUID, uri: String, continuation: CheckedContinuation<Void, Swift.Error>)] = []
        for waiter in resourceWaiters {
            if waiter.uri == uri {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                waiting.append(waiter)
            }
        }
        resourceWaiters = waiting
        refreshNotificationStream()
    }

    /// The subscribed URIs the open background stream serves (2026-07-28).
    public var subscribedResourceURIs: Set<String> {
        Set(notificationStream?.notifications.resourceSubscriptions ?? []).intersection(subscribedResources)
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
        let result = try Self.complete(try await send(request).value, CallTool.name)
        return (content: result.content, isError: result.isError)
    }

    /// Rejects an input-required result, returned when multi round-trip is disabled.
    private static func complete<R: InputRequiringResult>(_ result: R, _ method: String) throws -> R {
        guard result.isInputRequired else { return result }
        throw MCPError.invalidRequest(
            "\(method) requires input; enable Configuration.multiRoundTrip or use send(_:)")
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

    /// Notifies the server that the client's roots changed.
    ///
    /// Send it when roots are added, removed or modified. Does nothing on
    /// stateless connections, where servers ask for roots per request.
    ///
    /// - Throws: MCPError if the client is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    public func notifyRootsChanged() async throws {
        if isStateless { return }
        let notification = RootsListChangedNotification.message()
        try await notify(notification)
    }

    // MARK: - Logging

    /// Sets the lowest log level the server should send.
    ///
    /// On handshake connections this sends `logging/setLevel`. On stateless
    /// connections that method does not exist: the level is sent in the
    /// `_meta` of every following request instead.
    ///
    /// - Parameter level: The minimum log level to receive
    /// - Throws: MCPError if the client is not connected or if the server doesn't support logging
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
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

        // A replaced background stream may carry what its successor does not.
        if let stream = message._meta?.subscriptionID, retiredNotificationStreams.contains(stream),
            !wantsNotification(message)
        {
            return
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

    /// Whether the background stream still asks for `message`.
    private func wantsNotification(_ message: Message<AnyNotification>) -> Bool {
        let wanted = wantedNotifications
        switch message.method {
        case ToolListChangedNotification.name: return wanted.toolsListChanged == true
        case PromptListChangedNotification.name: return wanted.promptsListChanged == true
        case ResourceListChangedNotification.name: return wanted.resourcesListChanged == true
        case ResourceUpdatedNotification.name:
            guard case .string(let uri)? = message.params.objectValue?["uri"] else { return false }
            return subscribedResources.contains(uri)
        default: return true
        }
    }

    /// Runs the handler of a server-to-client request in its own task, so
    /// that the receive loop keeps reading while it runs. At most
    /// ``Configuration/maxConcurrentServerRequests`` run at once; up to
    /// ``incomingRequestBacklog`` more wait, and further ones are refused.
    private func startIncomingRequest(_ request: Request<AnyMethod>, on transport: any Transport) {
        func refuse(_ error: MCPError) {
            Task { try? await self.send(AnyMethod.response(id: request.id, error: error), on: transport) }
        }
        // 2026-07-28 has no server-to-client requests.
        if isStateless {
            refuse(.methodNotFound("\(request.method) cannot be sent at protocol version \(negotiatedProtocolVersion ?? "")"))
            return
        }
        // Answered at once, outside the handler slots: it checks liveness.
        if request.method == Ping.name {
            Task {
                if self.methodHandlers[Ping.name] != nil {
                    await self.handleIncomingRequest(request, on: transport)
                } else {
                    try? await self.send(Response<AnyMethod>(id: request.id, result: .object([:])), on: transport)
                }
            }
            return
        }
        if incomingRequests[request.id] != nil || queuedIncomingRequests.contains(where: { $0.id == request.id }) {
            refuse(.invalidRequest("A request with id \(request.id) is already in progress"))
            return
        }
        if hasFreeIncomingSlot {
            runIncomingRequest(request, on: transport)
            return
        }
        guard queuedIncomingRequests.count < Self.incomingRequestBacklog else {
            refuse(.internalError("Too many requests from the server"))
            return
        }
        queuedIncomingRequests.append(request)
    }

    private func runIncomingRequest(_ request: Request<AnyMethod>, on transport: any Transport) {
        let token = UUID()
        let task = Task {
            await Client.$incomingHandlerToken.withValue(token) {
                await self.handleIncomingRequest(request, on: transport)
            }
            self.incomingRequestFinished(request.id, token: token)
        }
        incomingRequests[request.id] = IncomingHandler(token: token, task: task)
    }

    /// Frees the slot of a finished handler and starts waiting requests.
    private func incomingRequestFinished(_ id: ID, token: UUID) {
        if incomingRequests[id]?.token == token {
            incomingRequests[id] = nil
        }
        drainingIncomingRequests.remove(token)
        startQueuedIncomingRequests()
    }

    /// Whether a handler may start: running and cancelled-but-running
    /// handlers count against ``Configuration/maxConcurrentServerRequests``.
    private var hasFreeIncomingSlot: Bool {
        incomingRequests.count + drainingIncomingRequests.count
            < max(configuration.maxConcurrentServerRequests, 1)
    }

    private func startQueuedIncomingRequests() {
        // The queue belongs to the current connection; closing it empties the queue.
        guard let connection else { return }
        while hasFreeIncomingSlot, !queuedIncomingRequests.isEmpty {
            runIncomingRequest(queuedIncomingRequests.removeFirst(), on: connection)
        }
    }

    /// Cancels the handler of a server-to-client request, or drops it while
    /// it waits. Returns `false` when there is no such request.
    private func cancelIncomingRequest(_ id: ID) -> Bool {
        if let index = queuedIncomingRequests.firstIndex(where: { $0.id == id }) {
            queuedIncomingRequests.remove(at: index)
            return true
        }
        guard let handler = incomingRequests.removeValue(forKey: id) else { return false }
        drainingIncomingRequests.insert(handler.token)
        handler.task.cancel()
        return true
    }

    private func handleIncomingRequest(_ request: Request<AnyMethod>, on transport: any Transport) async {
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
                try await send(response, on: transport)
            } catch {
                await logger?.error(
                    "Failed to send error response",
                    metadata: ["error": "\(error)"])
            }
            return
        }

        do {
            let response = try await handler(request)
            // A cancelled request is not answered.
            guard !Task.isCancelled else { return }
            try await send(response, on: transport)
        } catch {
            guard !Task.isCancelled else { return }
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)
            do {
                try await send(response, on: transport)
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
