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
        /// - Requires handshake-era clients to send an initialize request before
        ///   any other requests
        /// - Rejects requests from uninitialized handshake-era clients with a
        ///   protocol error
        ///
        /// Stateless requests (2026-07-28 and later) carry their client's
        /// capabilities and are never initialized; strict mode does not gate
        /// them. To gate clients, pass an `initializeHook` and a
        /// `statelessRequestHook` to ``Server/start(transport:initializeHook:statelessRequestHook:)``.
        ///
        /// While the MCP specification requires clients to initialize the connection
        /// before sending other requests, some implementations may not follow this.
        /// Disabling strict mode allows the server to be more lenient with non-compliant
        /// clients, though this may lead to undefined behavior.
        public var strict: Bool

        /// The protocol versions the server serves, newest first.
        ///
        /// Handshake revisions are negotiated through `initialize`; stateless
        /// revisions (2026-07-28 and later) are served per request. Requests
        /// for other versions are rejected with -32022.
        public var protocolVersions: [String]

        /// Cache hints for results of cacheable methods that do not set their
        /// own, keyed by method name (for example `tools/list`). Applies to
        /// stateless requests only.
        public var cacheHints: [String: CacheHint]

        /// Cache hint for cacheable methods missing from ``cacheHints``.
        public var defaultCacheHint: CacheHint

        /// The most `subscriptions/listen` streams open at once. Further
        /// streams are refused with -32600.
        public var maxSubscriptionStreams: Int

        /// The most resource URIs one `subscriptions/listen` stream may name.
        /// A stream that names more is refused with -32602.
        public var maxResourceSubscriptions: Int

        /// Creates a server configuration.
        public init(
            strict: Bool = false,
            protocolVersions: [String] = Version.stateless + Version.handshake,
            cacheHints: [String: CacheHint] = [:],
            defaultCacheHint: CacheHint = .uncached,
            maxSubscriptionStreams: Int = 1000,
            maxResourceSubscriptions: Int = 256
        ) {
            self.strict = strict
            self.protocolVersions = protocolVersions
            self.cacheHints = cacheHints
            self.defaultCacheHint = defaultCacheHint
            self.maxSubscriptionStreams = maxSubscriptionStreams
            self.maxResourceSubscriptions = maxResourceSubscriptions
        }

        private enum CodingKeys: String, CodingKey {
            case strict, protocolVersions, cacheHints, defaultCacheHint
            case maxSubscriptionStreams, maxResourceSubscriptions
        }

        /// Decodes a configuration; keys added after `strict` take their
        /// defaults when absent.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Configuration()
            strict = try container.decode(Bool.self, forKey: .strict)
            protocolVersions =
                try container.decodeIfPresent([String].self, forKey: .protocolVersions) ?? defaults.protocolVersions
            cacheHints = try container.decodeIfPresent([String: CacheHint].self, forKey: .cacheHints) ?? [:]
            defaultCacheHint =
                try container.decodeIfPresent(CacheHint.self, forKey: .defaultCacheHint) ?? defaults.defaultCacheHint
            maxSubscriptionStreams =
                try container.decodeIfPresent(Int.self, forKey: .maxSubscriptionStreams)
                ?? defaults.maxSubscriptionStreams
            maxResourceSubscriptions =
                try container.decodeIfPresent(Int.self, forKey: .maxResourceSubscriptions)
                ?? defaults.maxResourceSubscriptions
        }
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

        /// Creates the server implementation information.
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

            /// Creates the `resources` capability.
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

            /// Creates the `tools` capability.
            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Prompts capabilities
        public struct Prompts: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when prompts change
            public var listChanged: Bool?

            /// Creates the `prompts` capability.
            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Logging capabilities
        public struct Logging: Hashable, Codable, Sendable {
            /// Creates the `logging` capability, which has no settings.
            public init() {}
        }

        /// Completions capabilities
        public struct Completions: Hashable, Codable, Sendable {
            /// Creates the `completions` capability, which has no settings.
            public init() {}
        }

        /// The `tasks` capability of protocol 2025-11-25 (SEP-1686): which
        /// task methods the server serves and which requests it runs as tasks.
        ///
        /// ``Server/withTasks(_:)`` sets it for 2025-11-25 clients; at
        /// 2026-07-28 tasks are the `io.modelcontextprotocol/tasks` extension.
        public struct Tasks: Hashable, Codable, Sendable {
            /// The requests that may run as tasks.
            public struct Requests: Hashable, Codable, Sendable {
                /// Tool requests that may run as tasks.
                public struct Tools: Hashable, Codable, Sendable {
                    /// Present when `tools/call` may run as a task.
                    public var call: [String: Value]?

                    /// Creates the tool requests that may run as tasks.
                    public init(call: [String: Value]? = nil) {
                        self.call = call
                    }
                }

                /// Tool requests that may run as tasks.
                public var tools: Tools?

                /// Creates the requests that may run as tasks.
                public init(tools: Tools? = nil) {
                    self.tools = tools
                }
            }

            /// Present when the server serves `tasks/list`.
            public var list: [String: Value]?
            /// Present when the server serves `tasks/cancel`.
            public var cancel: [String: Value]?
            /// The requests that may run as tasks.
            public var requests: Requests?

            /// Creates the `tasks` capability.
            public init(
                list: [String: Value]? = nil, cancel: [String: Value]? = nil, requests: Requests? = nil
            ) {
                self.list = list
                self.cancel = cancel
                self.requests = requests
            }
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
        /// Task capabilities (2025-11-25)
        public var tasks: Tasks?
        /// Experimental features supported by the server
        public var experimental: [String: Value]?
        /// Protocol extensions supported by the server, keyed by extension
        /// identifier, with extension-defined settings (SEP-2133).
        public var extensions: [String: Value]?

        /// Creates server capabilities.
        public init(
            completions: Completions? = nil,
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil,
            experimental: [String: Value]? = nil,
            extensions: [String: Value]? = nil,
            tasks: Tasks? = nil
        ) {
            self.completions = completions
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
            self.experimental = experimental
            self.extensions = extensions
            self.tasks = tasks
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
    /// Decodes incoming messages with `data:` URL strings kept as strings;
    /// handlers get `.data` from their own typed decode.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.userInfo[.valuePreservesStrings] = true
        return decoder
    }()

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
    /// The methods whose handler is the SDK's default, which `start` may
    /// replace; a handler registered with `withMethodHandler` is never replaced.
    private var defaultHandlerMethods: Set<String> = []
    /// The level of the last `logging/setLevel` on this connection; `nil`
    /// before one, when every message is sent.
    private var clientLogLevel: LogLevel?
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// Whether the built-in `notifications/cancelled` handler is registered:
    /// once per server, not on every `start`.
    private var registeredCancellationHandler = false
    /// Pending request tasks (for cancellation support)
    private var pendingRequestTasks: [ID: Task<Response<AnyMethod>, Error>] = [:]
    /// Requests received whose handler task is not registered yet, and
    /// whether `notifications/cancelled` arrived for them meanwhile.
    private var startingRequests: [ID: Bool] = [:]

    /// Runs and keeps tasks; set by ``withTasks(_:)``.
    private var taskManager: TaskManager?
    /// This server's observer of `taskManager`'s changes.
    private var taskObserver: Int?
    private var observingTasks = false
    /// The 2025-11-25 tasks this server created, by the status last sent in
    /// `notifications/tasks/status`.
    private var notifiedTasks: [String: TaskStatus] = [:]

    /// Pending requests sent to the client, awaiting responses
    private var pendingRequests: [ID: AnyPendingRequest] = [:]
    /// Requests to the client that `send` created but has not registered in
    /// `pendingRequests` yet. Removing an id withdraws the request before it
    /// is sent.
    private var unsentRequests: Set<ID> = []
    /// Incremented by ``stop()``. Work started for a connection that `stop()`
    /// ended carries the old value: a request received on it is not answered,
    /// and a request to its client that was not sent yet is not sent.
    private var connectionGeneration = 0

    /// Whether the server is initialized
    private var isInitialized = false
    /// The client information
    private var clientInfo: Client.Info?
    /// The client capabilities
    private var clientCapabilities: Client.Capabilities?
    /// The protocol version
    private var protocolVersion: String?
    /// Open `subscriptions/listen` streams.
    private var listeners: [Int: Listener] = [:]
    private var nextListenerToken = 0
    /// The tasks handling `subscriptions/listen` requests, by request id, so
    /// that ``stop()`` can wait for the results of the streams it ends.
    private var listenRequests: [ID: Task<Void, Never>] = [:]
    /// Whether ``stop()`` is ending the listen streams; a stream that would
    /// open meanwhile is refused.
    private var isStopping = false
    /// The task for the message handling loop
    private var task: Task<Void, Never>?
    /// Whether ``start(transport:initializeHook:statelessRequestHook:)`` got an initialize hook.
    private var hasInitializeHook = false
    /// Runs before each stateless request; see ``start(transport:initializeHook:statelessRequestHook:)``.
    private var statelessRequestHook: StatelessRequestHook?

    /// A hook that runs before a stateless request (2026-07-28 and later) is
    /// handled, with the client info and capabilities from its `_meta`.
    /// ``Server/currentHandlerContext`` is set, so the hook can read the
    /// originating HTTP request. Throwing refuses the request: an
    /// ``MCPError`` is sent as is, any other error as -32600.
    ///
    /// Behind ``StatelessHTTPServerTransport`` it also runs before every
    /// handshake request other than `initialize`, with `nil` client info and
    /// empty capabilities: such a request has no session, so the
    /// `initialize` that passed the initialize hook does not cover it.
    public typealias StatelessRequestHook =
        @Sendable (_ clientInfo: Client.Info?, _ capabilities: Client.Capabilities) async throws -> Void

    /// Seals and verifies `requestState` at 2026-07-28; `nil` when disabled.
    private nonisolated let requestStateBoundary: RequestStateBoundary?

    /// Creates a server.
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - version: The server version.
    ///   - title: A human-readable title for display.
    ///   - description: What the server does, for display.
    ///   - websiteUrl: The URL of the server's website.
    ///   - icons: Icons for display in a user interface.
    ///   - instructions: How to use the server, for the client's model.
    ///   - capabilities: The features the server provides.
    ///   - configuration: Protocol and validation settings.
    ///   - requestStateProtection: How the `requestState` of input-required
    ///     results is protected at 2026-07-28 (SEP-2322). The default uses a
    ///     key held only by this process; servers with several instances pass
    ///     shared keys. `nil` sends the state as the handler wrote it and
    ///     trusts what clients echo: use it only when the state cannot affect
    ///     authorization, resource access or business logic.
    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        websiteUrl: String? = nil,
        icons: [Icon]? = nil,
        instructions: String? = nil,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default,
        requestStateProtection: RequestStateProtection? = .ephemeral()
    ) {
        self.serverInfo = Server.Info(
            name: name,
            version: version,
            title: title,
            description: description,
            websiteUrl: websiteUrl,
            icons: icons
        )
        self.capabilities = capabilities
        self.configuration = configuration
        self.instructions = instructions
        self.requestStateBoundary = requestStateProtection.map {
            RequestStateBoundary(protection: $0, audience: $0.audience ?? name)
        }
    }

    /// Start the server
    ///
    /// `start` adds the SDK's handlers for `initialize`, `ping`,
    /// `logging/setLevel` (with the `logging` capability),
    /// `subscriptions/listen` and `server/discover`, except where a handler
    /// registered with ``withMethodHandler(_:handler:)`` exists: that one is
    /// kept. An application `Initialize` handler therefore replaces the SDK's
    /// handshake: `initializeHook` and version negotiation do not run, and the
    /// server neither records the client's info and capabilities nor counts
    /// as initialized: list-changed and resource-updated notifications are
    /// not sent on the connection, and with
    /// ``Configuration/strict-swift.property`` later requests are refused.
    ///
    /// - Parameters:
    ///   - transport: The transport to use for the server
    ///   - initializeHook: An optional hook that runs when the client sends an
    ///     initialize request, in the SDK's `Initialize` handler
    ///   - statelessRequestHook: An optional hook that runs before every
    ///     stateless request (2026-07-28 and later), which never sends
    ///     `initialize`, and behind ``StatelessHTTPServerTransport`` before
    ///     every handshake request other than `initialize`, which has no
    ///     session. When `initializeHook` is set and this hook is not,
    ///     stateless requests are refused with -32022, so a gate in
    ///     `initializeHook` cannot be bypassed; clients then fall back to
    ///     `initialize`. Behind ``StatelessHTTPServerTransport`` handshake
    ///     requests other than `initialize` are then refused with -32600.
    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil,
        statelessRequestHook: StatelessRequestHook? = nil
    ) async throws {
        self.connection = transport
        self.hasInitializeHook = initializeHook != nil
        self.statelessRequestHook = statelessRequestHook
        registerDefaultHandlers(initializeHook: initializeHook)
        if !registeredCancellationHandler {
            registeredCancellationHandler = true
            registerCancellationHandler()
        }
        try await transport.connect()

        await logger?.debug(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"]
        )

        // Start message handling loop
        let generation = connectionGeneration
        task = Task {
            do {
                let stream = await transport.receive()
                for try await data in stream {
                    if Task.isCancelled { break }  // Check cancellation inside loop

                    var requestID: ID?
                    do {
                        // Attempt to decode as batch first, then as individual response, request, or notification
                        if let batch = try? decoder.decode(Server.Batch.self, from: data) {
                            // Recorded before the task, as for a single request,
                            // so that a cancellation arriving first is kept.
                            // Placeholders for invalid items (no method) never
                            // reach the cleanup in `handleRequest`.
                            for case .request(let request) in batch.items where !request.method.isEmpty {
                                startingRequests[request.id] = false
                            }
                            // Off the receive loop: a batched request may wait
                            // for the client's answer to a bridged input request.
                            Task {
                                do {
                                    try await self.handleBatch(batch, generation: generation)
                                } catch {
                                    await self.logger?.error(
                                        "Error processing batch", metadata: ["error": "\(error)"])
                                }
                            }
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            await handleResponse(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            // Handle request in a separate task to avoid blocking the receive loop
                            startingRequests[request.id] = false
                            let isListen = request.method == SubscriptionsListen.name
                            let handling = Task {
                                _ = try? await self.handleRequest(
                                    request, sendResponse: true, generation: generation)
                                if isListen { self.listenRequests[request.id] = nil }
                            }
                            if isListen { listenRequests[request.id] = handling }
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
                        let mcpError =
                            error as? MCPError ?? MCPError.internalError(error.localizedDescription)
                        if let requestID {
                            try? await send(AnyMethod.response(id: requestID, error: mcpError))
                        } else if case .parseError = mcpError {
                            // A message that could not be read: `"id": null`.
                            await sendUnattributedError(mcpError)
                        }
                        // Notifications are never answered.
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
    ///
    /// Open `subscriptions/listen` streams end with their result, as with
    /// ``closeSubscriptions()``, and `stop()` waits until those results are
    /// sent before it closes the transport. A stream that is still being
    /// authorized is refused.
    ///
    /// The server can be started again with
    /// ``start(transport:initializeHook:statelessRequestHook:)``; the next
    /// connection starts from a fresh handshake, with no client info,
    /// capabilities or negotiated protocol version from the previous one.
    public func stop() async {
        isStopping = true
        defer { isStopping = false }
        closeSubscriptions()
        // The handlers resume only once this suspends: closing the
        // transport first lost their results.
        let ending = listeners.values.compactMap { listenRequests[$0.context.id] }
        for handling in ending { await handling.value }

        if let manager = taskManager, let token = taskObserver {
            taskObserver = nil
            observingTasks = false
            await manager.removeObserver(token)
        }
        notifiedTasks = [:]
        task?.cancel()
        task = nil
        clientLogLevel = nil

        // Their responses can no longer be sent. The requests of this
        // connection are not answered from here on, and those whose handler
        // task is not registered yet do not start one.
        connectionGeneration += 1
        let handlerTasks = pendingRequestTasks
        pendingRequestTasks = [:]
        for handler in handlerTasks.values { handler.cancel() }
        startingRequests = [:]

        // Clear pending requests with errors. A request not registered yet
        // fails when it would register.
        let pendingRequestsToCancel = self.pendingRequests
        self.pendingRequests = [:]
        unsentRequests.removeAll()
        for (_, request) in pendingRequestsToCancel {
            request.resume(throwing: MCPError.internalError("Server disconnected"))
        }

        // The handshake belongs to the connection: after a restart the next
        // client sends its own `initialize`.
        isInitialized = false
        clientInfo = nil
        clientCapabilities = nil
        protocolVersion = nil
        servedStatelessRequest = false

        // Cleared first: nothing is sent on a transport that is disconnecting.
        let stoppedConnection = connection
        connection = nil
        await stoppedConnection?.disconnect()
    }

    /// Waits until the message handling loop ends.
    ///
    /// The loop ends when the transport stops delivering messages or on
    /// ``stop()``. Returns at once when the server was not started.
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
        /// The JSON-RPC request id of the in-flight request. SDK-internal use
        /// (e.g. transports closing an SSE stream mid-call per SEP-1699).
        package let id: ID

        /// The originating HTTP request, if the active transport conforms to
        /// ``HTTPContextProviding``. `nil` for transports that don't carry HTTP
        /// context (stdio, in-memory) or for handlers reached off the dispatch
        /// path.
        public let httpContext: HTTPRequest?

        /// The protocol version of the request: from its `_meta` for stateless
        /// requests, otherwise the version negotiated by `initialize`.
        public let protocolVersion: String?

        /// The capabilities the client declared for this request, or at
        /// `initialize` for handshake connections.
        public let clientCapabilities: Client.Capabilities?

        /// The client implementation, if it identified itself.
        public let clientInfo: Client.Info?

        /// The lowest log level the client wants for this request. Stateless
        /// requests that omit it receive no log notifications.
        public let logLevel: LogLevel?

        /// Whether the request is a self-contained 2026-07-28 request.
        public let isStateless: Bool

        /// The method of the request; `nil` for a context made by the application.
        var method: String?

        /// How the request may run as a task; set for `tools/call` on a
        /// server with ``Server/withTasks(_:)``.
        var taskRuntime: TaskRuntime?

        /// Sends input requests to the client during the request; set on
        /// connections that allow server requests.
        var inputBridge: InputBridge?

        /// Sends progress for the request's progress token; set when it has one.
        var progressReporter: ProgressReporter?

        /// The feature profile of ``protocolVersion``.
        public var profile: ProtocolProfile? { protocolVersion.map(Version.profile(for:)) }

        /// Creates a context, for example to test a handler that reads
        /// ``Server/currentHandlerContext`` without a connection:
        ///
        /// ```swift
        /// let context = Server.HandlerContext(id: 1, httpContext: nil, isStateless: true)
        /// let result = try await Server.$currentHandlerContext.withValue(context) {
        ///     try await handler(params)
        /// }
        /// ```
        public init(
            id: ID,
            httpContext: HTTPRequest?,
            protocolVersion: String? = nil,
            clientCapabilities: Client.Capabilities? = nil,
            clientInfo: Client.Info? = nil,
            logLevel: LogLevel? = nil,
            isStateless: Bool = false
        ) {
            self.id = id
            self.httpContext = httpContext
            self.protocolVersion = protocolVersion
            self.clientCapabilities = clientCapabilities
            self.clientInfo = clientInfo
            self.logLevel = logLevel
            self.isStateless = isStateless
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
    ///
    /// Handlers for `tools/call`, `prompts/get` and `resources/read` may
    /// return an input-required result (SEP-2322), made with
    /// `inputRequired(_:requestState:_meta:)`. At 2026-07-28 it goes to the
    /// client, which retries with the responses. For earlier clients the
    /// server sends the input requests itself and calls the handler again
    /// with the responses, calling it at most 10 times, so one handler serves both.
    ///
    /// A handler for a method the SDK answers itself (`initialize`, `ping`,
    /// `logging/setLevel`, `subscriptions/listen`, `server/discover`)
    /// replaces the SDK's, whether registered before or after
    /// ``start(transport:initializeHook:statelessRequestHook:)``. For
    /// `Initialize`, the `initializeHook` passed to `start` then does not run.
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        let roundTrips = MRTR.carriers.contains(M.name)
        methodHandlers[M.name] = TypedRequestHandler { [weak self] (request: Request<M>) -> Response<M> in
            guard roundTrips, let self else {
                return Response(id: request.id, result: try await handler(request.params))
            }
            let result = try await self.serveRoundTrips(M.self, request.params, handler: handler)
            return Response(id: request.id, result: result)
        }
        defaultHandlerMethods.remove(M.name)
        return self
    }

    /// Registers a default handler unless the application registered one.
    private func registerDefault<M: Method>(
        _ type: M.Type, handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) {
        guard methodHandlers[M.name] == nil || defaultHandlerMethods.contains(M.name) else { return }
        withMethodHandler(type, handler: handler)
        defaultHandlerMethods.insert(M.name)
    }

    // MARK: - Tasks (SEP-1686, SEP-2663)

    /// Serves tasks with `manager`.
    ///
    /// The server then answers the task methods of each protocol version it
    /// serves, and declares tasks to clients: at 2026-07-28 the
    /// `io.modelcontextprotocol/tasks` extension in `server/discover`. A
    /// `tools/call` handler runs work as a task with
    /// ``HandlerContext/runAsTask(ttl:pollInterval:_:)``; which tools may do
    /// so is declared by each tool's `execution.taskSupport` in `tools/list`.
    ///
    /// Servers that serve the same clients, such as the per-session servers
    /// of a stateful HTTP transport, should share one manager.
    @discardableResult
    public func withTasks(_ manager: TaskManager = TaskManager()) -> Self {
        taskManager = manager
        registerDefault(GetTask.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server is gone") }
            return try await self.serveGetTask(params)
        }
        registerDefault(UpdateTask.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server is gone") }
            return try await self.serveUpdateTask(params)
        }
        registerDefault(CancelTask.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server is gone") }
            return try await self.serveCancelTask(params)
        }
        registerDefault(GetTaskPayload.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server is gone") }
            return try await self.serveTaskPayload(params)
        }
        registerDefault(ListTasks.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server is gone") }
            return try await self.serveListTasks(params)
        }
        return self
    }

    /// The manager, the caller and the task generation of a task request.
    private func taskRequest(_ method: String) throws -> (TaskManager, HandlerContext, TaskGeneration) {
        guard let manager = taskManager, let context = Server.currentHandlerContext,
            let generation = context.profile?.taskGeneration
        else {
            throw MCPError.methodNotFound("\(method) is not available at this protocol version")
        }
        return (manager, context, generation)
    }

    private static func unknownTask(_ id: String) -> MCPError {
        .invalidParams("Unknown task: \(MCPRequestHeaders.sanitized(id))")
    }

    private func serveGetTask(_ params: GetTask.Parameters) async throws -> TaskSnapshot {
        let (manager, context, generation) = try taskRequest(GetTask.name)
        guard let record = try await manager.lookup(params.taskId, context: context, generation: generation) else {
            throw Self.unknownTask(params.taskId)
        }
        return record.snapshot(detailed: generation == .v2)
    }

    private func serveUpdateTask(_ params: UpdateTask.Parameters) async throws -> Empty {
        let (manager, context, generation) = try taskRequest(UpdateTask.name)
        guard generation == .v2 else {
            throw MCPError.methodNotFound("\(UpdateTask.name) is not available at this protocol version")
        }
        guard try await manager.lookup(params.taskId, context: context, generation: generation) != nil else {
            throw Self.unknownTask(params.taskId)
        }
        try await manager.submit(params.taskId, params.inputResponses)
        return Empty()
    }

    private func serveCancelTask(_ params: CancelTask.Parameters) async throws -> CancelTask.Result {
        let (manager, context, generation) = try taskRequest(CancelTask.name)
        guard let record = try await manager.lookup(params.taskId, context: context, generation: generation) else {
            throw Self.unknownTask(params.taskId)
        }
        switch generation {
        case .v2:
            try await manager.cancel(record.id)
            return CancelTask.Result()
        case .v1:
            guard !record.status.isTerminal else {
                throw MCPError.invalidParams("The task is already \(record.snapshot(detailed: false).status)")
            }
            let cancelled = try await manager.cancel(record.id) ?? record
            return CancelTask.Result(task: cancelled.snapshot(detailed: false))
        }
    }

    /// Waits for a task to finish and returns the result of its request
    /// (`tasks/result`, 2025-11-25).
    ///
    /// Until then it sends the task's input requests to the client on this
    /// request's stream, with related-task metadata, and records the answers.
    /// A request the client fails fails the call waiting for it; one not
    /// answered because this request or the connection ended (including
    /// ``stop()``) is sent again by the next `tasks/result`.
    private func serveTaskPayload(_ params: GetTaskPayload.Parameters) async throws -> Value {
        let (manager, context, generation) = try taskRequest(GetTaskPayload.name)
        guard generation == .v1 else {
            throw MCPError.methodNotFound("\(GetTaskPayload.name) is not available at this protocol version")
        }
        guard var record = try await manager.lookup(params.taskId, context: context, generation: .v1) else {
            throw Self.unknownTask(params.taskId)
        }
        while !record.status.isTerminal {
            try Task.checkCancellation()
            let input = await manager.claimInput(record.id)
            if input.isEmpty {
                try await manager.waitForChange(record.id, from: record, timeout: .seconds(30))
            } else {
                do {
                    // Delivery ends when the task does, withdrawing the requests.
                    let id = record.id
                    let responses = try await withThrowingTaskGroup(of: [String: InputResponse]?.self) { group in
                        group.addTask { try await self.fulfill(input, relatedTask: id) }
                        group.addTask {
                            try await manager.waitUntilFinished(id)
                            return nil
                        }
                        defer { group.cancelAll() }
                        return try await group.next() ?? nil
                    }
                    if let responses {
                        try await manager.submit(record.id, responses)
                    } else {
                        await manager.releaseInput(record.id, input.keys)
                    }
                } catch let error as MCPError
                    where !Task.isCancelled && connection != nil && !Self.isConnectionFailure(error)
                {
                    await manager.failInput(record.id, Set(input.keys), error)
                } catch {
                    await manager.releaseInput(record.id, input.keys)
                    throw error
                }
            }
            guard let next = try await manager.lookup(record.id, context: context, generation: .v1) else {
                throw Self.unknownTask(params.taskId)
            }
            record = next
        }
        switch record.status {
        case .completed:
            guard case .object(var result)? = record.result else {
                throw MCPError.internalError("The task has no result")
            }
            var meta = result["_meta"]?.objectValue ?? [:]
            meta[MetaKey.relatedTask] = ["taskId": .string(record.id)]
            result["_meta"] = .object(meta)
            return .object(result)
        case .failed:
            throw record.error ?? MCPError.internalError("The task failed")
        default:
            throw MCPError.internalError("The task was cancelled")
        }
    }

    /// The caller's tasks (`tasks/list`, 2025-11-25), oldest first, 100 a
    /// page. Served only when tasks are bound to principals.
    private func serveListTasks(_ params: ListTasks.Parameters) async throws -> ListTasks.Result {
        let (manager, context, generation) = try taskRequest(ListTasks.name)
        guard generation == .v1, manager.bindsPrincipals else {
            throw MCPError.methodNotFound("\(ListTasks.name) is not available")
        }
        let tasks = try await manager.list(context: context, generation: .v1)
        var start = 0
        if let cursor = params.cursor {
            guard let index = tasks.firstIndex(where: { $0.id == cursor }) else {
                throw MCPError.invalidParams("Invalid cursor")
            }
            start = index
        }
        let page = tasks[start...].prefix(Self.taskPageSize)
        let next = start + page.count < tasks.count ? tasks[start + page.count].id : nil
        return ListTasks.Result(tasks: page.map { $0.snapshot(detailed: false) }, nextCursor: next)
    }

    private static let taskPageSize = 100

    /// Decides how a `tools/call` may run as a task, before its handler runs.
    ///
    /// - Throws: -32021 at 2026-07-28 for a tool that requires tasks and a
    ///   client that did not declare them; -32601 at 2025-11-25 for an
    ///   augmentation the tool does not allow, or none for a tool that
    ///   requires it.
    private func taskRuntime(
        for request: Request<AnyMethod>, context: HandlerContext, manager: TaskManager,
        listing: inout ToolListing?
    ) async throws -> TaskRuntime? {
        guard let generation = context.profile?.taskGeneration else { return nil }
        let params = request.params.objectValue
        let name = params?["name"]?.stringValue ?? ""
        let support =
            try await toolInfo(context: context, request: request, listing: &listing)?[name]?.taskSupport ?? .forbidden
        switch generation {
        case .v2:
            let declared = context.clientCapabilities?.declaresTasksExtension == true
            if support == .required, !declared {
                throw MCPError.missingRequiredClientCapabilities(
                    .init(extensions: [ExtensionID.tasks: [:]]),
                    message: "The tool runs only as a task: declare the \(ExtensionID.tasks) extension")
            }
            return TaskRuntime(
                manager: manager, generation: .v2, accepted: declared && support != .forbidden,
                requestedTTL: nil, support: support)
        case .v1:
            let task = params?["task"]
            let augmented = task != nil && task != .null
            if augmented, support == .forbidden {
                throw MCPError.methodNotFound("The tool does not run as a task")
            }
            if !augmented, support == .required {
                throw MCPError.methodNotFound("The tool runs only as a task")
            }
            let requested = task.flatMap { try? TaskMetadata(decoding: $0) }?.ttl
            var runtime = TaskRuntime(
                manager: manager, generation: .v1, accepted: augmented, requestedTTL: requested, support: support)
            if manager.configuration.sendsStatusNotifications {
                runtime.created = { [weak self] record in await self?.trackTask(record) }
            }
            return runtime
        }
    }

    /// Starts observing the task manager's changes, once.
    private func observeTasks(_ manager: TaskManager) async {
        guard !observingTasks else { return }
        observingTasks = true
        taskObserver = await manager.addObserver { [weak self] record in
            await self?.taskChanged(record)
        }
    }

    /// Records a 2025-11-25 task this server created, for status notifications.
    private func trackTask(_ record: TaskRecord) async {
        guard let manager = taskManager else { return }
        notifiedTasks[record.id] = record.snapshot(detailed: false).status
        await observeTasks(manager)
    }

    /// Sends a task's change: `notifications/tasks/status` on the connection
    /// for a 2025-11-25 task this server created, `notifications/tasks` on
    /// the listen streams that name a 2026-07-28 task.
    private func taskChanged(_ record: TaskRecord) async {
        switch record.generation {
        case .v1:
            guard let last = notifiedTasks[record.id] else { return }
            let snapshot = record.snapshot(detailed: false)
            guard snapshot.status != last else { return }
            notifiedTasks[record.id] = snapshot.status.isTerminal ? nil : snapshot.status
            guard isInitialized, let connection,
                let data = try? encoder.encode(TaskStatusNotification.message(snapshot))
            else { return }
            try? await connection.send(data)
        case .v2:
            guard listeners.values.contains(where: { $0.tasks.contains(record.id) }),
                let snapshot = try? Value(record.snapshot(detailed: true))
            else { return }
            publish(.task(id: record.id, snapshot: snapshot), to: nil)
        }
    }

    /// The tasks of `ids` the caller of `context` may see at 2026-07-28.
    private func visibleTasks(_ ids: [String], context: HandlerContext) async throws -> [String]? {
        guard let manager = taskManager else { return nil }
        var visible: [String] = []
        for id in ids where try await manager.lookup(id, context: context, generation: .v2) != nil {
            visible.append(id)
        }
        await observeTasks(manager)
        return visible.isEmpty ? nil : visible
    }

    /// The capabilities to declare at `version`, with the task
    /// capabilities the SDK derives.
    private func advertisedCapabilities(for version: String?) -> Capabilities {
        var advertised = capabilities
        guard let manager = taskManager else { return advertised }
        switch version.map(Version.profile(for:))?.taskGeneration {
        case .v2?:
            var extensions = advertised.extensions ?? [:]
            if extensions[ExtensionID.tasks] == nil { extensions[ExtensionID.tasks] = [:] }
            advertised.extensions = extensions
            advertised.tasks = nil
        case .v1?:
            if advertised.tasks == nil {
                // `list` only with principals: unbound tasks must not be listed.
                advertised.tasks = .init(
                    list: manager.bindsPrincipals ? [:] : nil, cancel: [:],
                    requests: .init(tools: .init(call: [:])))
            }
        case nil:
            advertised.tasks = nil
        }
        return advertised
    }

    /// Removes `execution` from a `tools/list` result: only 2025-11-25 has it.
    private static func strippingExecution(_ response: Response<AnyMethod>) -> Response<AnyMethod> {
        guard case .success(let value) = response.result,
            var object = value.objectValue,
            let tools = object["tools"]?.arrayValue,
            tools.contains(where: { $0.objectValue?["execution"] != nil })
        else { return response }
        object["tools"] = .array(
            tools.map { tool in
                guard var fields = tool.objectValue else { return tool }
                fields["execution"] = nil
                return .object(fields)
            })
        return Response(id: response.id, result: .object(object))
    }

    // MARK: - Multi round-trip requests (SEP-2322)

    /// Runs a handler that may ask for input: verifies and seals
    /// `requestState` at 2026-07-28, and fulfills input requests itself for
    /// earlier clients.
    private nonisolated func serveRoundTrips<M: Method>(
        _: M.Type, _ params: M.Parameters,
        handler: @Sendable (M.Parameters) async throws -> M.Result
    ) async throws -> M.Result {
        guard let context = Server.currentHandlerContext,
            var params = params as? any InputRespondingParameters
        else { return try await handler(params) }

        // Computed once: the arguments do not change between rounds.
        let original = params
        var cachedBinding: RequestStateBoundary.Binding?
        func binding() -> RequestStateBoundary.Binding {
            if let cachedBinding { return cachedBinding }
            let (target, arguments) = original.stateBinding
            let computed = RequestStateBoundary.binding(target: target, arguments: arguments)
            cachedBinding = computed
            return computed
        }

        if context.isStateless {
            if let token = params.requestState, let boundary = requestStateBoundary {
                do {
                    let verified = try boundary.unseal(
                        token, method: M.name, binding: binding, context: context)
                    if let consume = boundary.protection.consume {
                        let fresh: Bool
                        do {
                            fresh = try await consume(verified.tokenID, verified.expiry)
                        } catch let error as CancellationError {
                            throw error
                        } catch {
                            // Not a replay: the check could not be made.
                            await logger?.error(
                                "requestState replay check failed",
                                metadata: ["method": "\(M.name)", "error": "\(error)"])
                            throw MCPError.internalError("Could not check requestState")
                        }
                        if !fresh { throw InvalidRequestState("replayed") }
                    }
                    params = params.retrying(inputResponses: params.inputResponses, requestState: verified.state)
                } catch let error as MCPError {
                    throw error
                } catch let error as CancellationError {
                    throw error
                } catch {
                    await logger?.warning(
                        "requestState rejected",
                        metadata: ["method": "\(M.name)", "reason": "\((error as? InvalidRequestState)?.reason ?? "\(error)")"])
                    throw RequestStateBoundary.rejection
                }
            }
        } else if params.inputResponses != nil || params.requestState != nil {
            // Not part of the protocol before 2026-07-28: only the bridge below sets them.
            params = params.retrying(inputResponses: nil, requestState: nil)
        }

        var round = 1
        var stateOnlyDelay = MRTR.stateOnlyInitialDelay
        while true {
            try Task.checkCancellation()
            let result = try await handler(params as! M.Parameters)
            guard var asking = result as? any InputRequiringResult else { return result }
            if asking.isInputRequired, asking.hasContent {
                await logger?.error("Handler returned both content and input requests", metadata: ["method": "\(M.name)"])
                throw MCPError.internalError(
                    "Server bug: result has both content and inputRequests or requestState")
            }
            guard asking.isInputRequired else { return result }
            // An empty `inputRequests` asks for nothing, so the retry would be the same request.
            if asking.inputRequests?.isEmpty != false, asking.requestState == nil {
                throw MCPError.internalError("Server bug: input-required result without inputRequests or requestState")
            }

            if context.isStateless {
                try Self.checkCapabilities(
                    asking.inputRequests ?? [:], method: M.name, declared: context.clientCapabilities)
                if let state = asking.requestState, let boundary = requestStateBoundary {
                    asking.requestState = try boundary.seal(
                        state, method: M.name, binding: binding(), context: context)
                }
                return asking as! M.Result
            }

            guard round < MRTR.maxRounds else {
                throw MCPError.internalError(
                    "\(M.name) asked for input \(MRTR.maxRounds) times")
            }
            let requests = asking.inputRequests ?? [:]
            if requests.isEmpty {
                // Only state: the handler is not done yet. Wait as a
                // 2026-07-28 client would before the next round.
                try await Task.sleep(for: stateOnlyDelay)
                stateOnlyDelay = min(stateOnlyDelay * 2, MRTR.stateOnlyMaximumDelay)
            } else {
                stateOnlyDelay = MRTR.stateOnlyInitialDelay
                // As at 2026-07-28, whatever `strict` says. A sessionless
                // request carries no capabilities: the client answers.
                let sessionless = await isSessionless
                if context.clientCapabilities != nil || !sessionless {
                    try Self.checkCapabilities(requests, method: M.name, declared: context.clientCapabilities)
                }
            }
            let responses = try await fulfill(requests)
            params = params.retrying(
                inputResponses: responses.isEmpty ? nil : responses, requestState: asking.requestState)
            round += 1
        }
    }

    /// Throws -32021 when input requests need capabilities the client did not declare.
    static func checkCapabilities(
        _ requests: [String: InputRequest], method: String, declared: Client.Capabilities?
    ) throws {
        var missing = Client.Capabilities()
        var methods: Set<String> = []
        for request in requests.values where !request.isSupported(by: declared ?? .init()) {
            request.require(in: &missing)
            methods.insert(request.method)
        }
        guard !methods.isEmpty else { return }
        throw MCPError.missingRequiredClientCapabilities(
            missing,
            message: "\(method) needs client capabilities for \(methods.sorted().joined(separator: ", "))")
    }

    /// Sends input requests to a client before 2026-07-28, concurrently.
    /// Cancelling the calling task cancels the requests still outstanding.
    /// `relatedTask` adds related-task metadata to each request.
    private func fulfill(_ requests: [String: InputRequest], relatedTask: String? = nil) async throws
        -> [String: InputResponse]
    {
        try await withThrowingTaskGroup(of: (String, InputResponse).self) { group in
            for (key, request) in requests {
                group.addTask { (key, try await self.fulfill(request, relatedTask: relatedTask)) }
            }
            var responses: [String: InputResponse] = [:]
            for try await (key, response) in group {
                responses[key] = response
            }
            return responses
        }
    }

    private func fulfill(_ request: InputRequest, relatedTask: String?) async throws -> InputResponse {
        var meta: Metadata?
        if let relatedTask {
            meta = Metadata()
            meta?.relatedTaskID = relatedTask
        }
        switch request {
        case .elicitation(let params):
            return .elicitation(try await ask(CreateElicitation.request(params, _meta: meta)))
        case .sampling(let params):
            return .sampling(try await ask(CreateSamplingMessage.request(params, _meta: meta)))
        case .listRoots:
            return .roots(try await ask(ListRoots.request(_meta: meta)))
        case .unknown(let method, let params):
            return .unknown(
                try await ask(Request<UnknownInputRequest>(method: method, params: params, _meta: meta)).value)
        }
    }

    /// A bridged input request of a method the SDK does not know: its
    /// result is kept as received, with `data:` URL strings as written.
    private enum UnknownInputRequest: Method {
        static var name: String { "" }
        typealias Parameters = Value
        typealias Result = Value.Preserved
    }

    /// Sends one bridged request to the client. A client error fails the
    /// carrier with -32603; a failure of the connection is thrown as it is;
    /// cancellation withdraws the request.
    private func ask<M: Method>(_ request: Request<M>) async throws -> M.Result {
        try Task.checkCancellation()
        let task = try send(request)
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.withdraw(request.id) }
            }
        } catch let error as MCPError where !Self.isConnectionFailure(error) {
            throw MCPError.internalError("The client failed \(request.method): \(error.localizedDescription)")
        }
    }

    /// Whether `error` is the transport's, not the client's answer.
    private static func isConnectionFailure(_ error: MCPError) -> Bool {
        switch error {
        case .connectionClosed, .transportError: return true
        default: return false
        }
    }

    /// Ends a bridged request whose carrier was cancelled, and tells the
    /// client. A request not sent yet is not sent at all.
    private func withdraw(_ id: ID) async {
        guard let pending = removePendingResponse(id: id) else {
            unsentRequests.remove(id)
            return
        }
        pending.resume(throwing: CancellationError())
        try? await notify(
            CancelledNotification.message(
                .init(requestId: id, reason: "The request that needed this input was cancelled")))
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

    /// Send a notification to connected clients.
    ///
    /// Called from a method handler, the notification is delivered on the
    /// stream of the request being handled when the transport has one.
    ///
    /// List-changed and resource-updated notifications are also delivered to
    /// the matching `subscriptions/listen` streams. At 2026-07-28 they are
    /// sent only there: without an `initialize` session they are not sent on
    /// the connection. Behind ``StatelessHTTPServerTransport`` a handler of a
    /// handshake request sends them on its request's stream. Every caller's
    /// matching stream receives them; use ``notify(_:to:)`` to reach only
    /// some callers.
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        try await notify(notification, matching: nil)
    }

    /// Sends a list-changed or resource-updated notification only to the
    /// `subscriptions/listen` streams whose caller `recipients` accepts, for
    /// example by the principal in `context.httpContext`.
    ///
    /// On an `initialize` session the notification is also sent on the
    /// connection, as ``notify(_:)`` does: that session has one client.
    /// Behind ``StatelessHTTPServerTransport`` a handler of a handshake
    /// request sends it on its request's stream only when `recipients`
    /// accepts that request's context.
    public func notify<N: Notification>(
        _ notification: Message<N>, to recipients: @escaping @Sendable (HandlerContext) -> Bool
    ) async throws {
        try await notify(notification, matching: recipients)
    }

    private func notify<N: Notification>(
        _ notification: Message<N>, matching recipients: ((HandlerContext) -> Bool)?
    ) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let notificationData = try encoder.encode(notification)
        if let event = SubscriptionEvent(notification) {
            publish(event, to: recipients)
            // A handshake handler behind a sessionless transport sends it
            // on its own request's stream, when `recipients` accepts that
            // caller: one server serves every client there.
            let sessionlessHandshake =
                isSessionless
                && Server.currentHandlerContext.map { !$0.isStateless && (recipients?($0) ?? true) } == true
            guard isInitialized || sessionlessHandshake else { return }
        }
        try await connection.send(
            notificationData, relatedRequestID: Server.currentHandlerContext?.id)
    }

    // MARK: - Subscriptions (2026-07-28)

    private struct Listener {
        let filter: SubscriptionFilter
        /// `filter.resourceSubscriptions`, for lookups.
        let resources: Set<String>
        /// `filter.taskIds`, for lookups.
        let tasks: Set<String>
        /// The caller, for ``notify(_:to:)``.
        let context: HandlerContext
        let events: AsyncStream<SubscriptionEvent>.Continuation
    }

    /// The longest resource URI a `subscriptions/listen` stream may name.
    static let maxSubscriptionURILength = 4096

    /// Narrows or refuses `subscriptions/listen` filters.
    private var subscriptionAuthorizer:
        (@Sendable (SubscriptionFilter, HandlerContext) async throws -> SubscriptionFilter)?

    /// Sets a check that runs for each `subscriptions/listen` stream
    /// (2026-07-28) with the requested filter and the caller's context,
    /// before the server acknowledges it. Return the filter to serve, for
    /// example without the resource URIs the caller may not read, or throw
    /// an `MCPError` to refuse the stream.
    ///
    /// Without one, any caller can listen to every list change and to any
    /// resource URI, and ``notify(_:)`` reaches every caller's matching
    /// stream.
    @discardableResult
    public func withSubscriptionAuthorizer(
        _ authorize: @escaping @Sendable (SubscriptionFilter, HandlerContext) async throws -> SubscriptionFilter
    ) -> Self {
        subscriptionAuthorizer = authorize
        return self
    }

    /// The most events buffered for a listen stream; older ones are dropped.
    /// Events are level triggers ("refetch"), so dropping duplicates is safe.
    private static let listenerBufferSize = 256

    private func publish(_ event: SubscriptionEvent, to recipients: ((HandlerContext) -> Bool)?) {
        for listener in listeners.values
        where event.matches(listener.filter, resources: listener.resources, tasks: listener.tasks) {
            if let recipients, !recipients(listener.context) { continue }
            listener.events.yield(event)
        }
    }

    /// The number of open `subscriptions/listen` streams.
    var openSubscriptionCount: Int { listeners.count }

    /// The number of `subscriptions/listen` requests still being handled.
    var listenRequestCount: Int { listenRequests.count }

    /// Ends every open `subscriptions/listen` stream with its result.
    public func closeSubscriptions() {
        for listener in listeners.values {
            listener.events.finish()
        }
    }

    /// The part of a filter this server honors: kinds whose capability it declares.
    private func honored(_ requested: SubscriptionFilter) -> SubscriptionFilter {
        SubscriptionFilter(
            toolsListChanged: requested.toolsListChanged == true && capabilities.tools?.listChanged == true
                ? true : nil,
            promptsListChanged: requested.promptsListChanged == true
                && capabilities.prompts?.listChanged == true ? true : nil,
            resourcesListChanged: requested.resourcesListChanged == true
                && capabilities.resources?.listChanged == true ? true : nil,
            resourceSubscriptions: capabilities.resources?.subscribe == true
                && requested.resourceSubscriptions?.isEmpty == false
                ? requested.resourceSubscriptions : nil,
            taskIds: requested.taskIds?.isEmpty == false ? requested.taskIds : nil)
    }

    /// The requested filter with duplicate URIs removed; throws -32602 for
    /// too many or too long URIs.
    private func checked(_ requested: SubscriptionFilter) throws -> SubscriptionFilter {
        var filter = requested
        if let uris = requested.resourceSubscriptions {
            var seen: Set<String> = []
            let unique = uris.filter { seen.insert($0).inserted }
            guard unique.count <= configuration.maxResourceSubscriptions else {
                throw MCPError.invalidParams(
                    "A listen stream may name at most \(configuration.maxResourceSubscriptions) resources")
            }
            guard unique.allSatisfy({ $0.utf8.count <= Self.maxSubscriptionURILength }) else {
                throw MCPError.invalidParams(
                    "Resource URIs may have at most \(Self.maxSubscriptionURILength) bytes")
            }
            filter.resourceSubscriptions = unique
        }
        if let ids = requested.taskIds {
            var seen: Set<String> = []
            let unique = ids.filter { seen.insert($0).inserted }
            guard unique.count <= configuration.maxResourceSubscriptions else {
                throw MCPError.invalidParams(
                    "A listen stream may name at most \(configuration.maxResourceSubscriptions) tasks")
            }
            guard unique.allSatisfy({ $0.utf8.count <= Self.maxSubscriptionURILength }) else {
                throw MCPError.invalidParams("Task ids may have at most \(Self.maxSubscriptionURILength) bytes")
            }
            filter.taskIds = unique
        }
        return filter
    }

    /// Serves one `subscriptions/listen` stream: acknowledges, then forwards
    /// matching events until the client goes away or the server closes it.
    private func serveListen(_ params: SubscriptionsListen.Parameters) async throws
        -> SubscriptionsListen.Result
    {
        guard let connection, let context = Server.currentHandlerContext else {
            throw MCPError.internalError("Server connection not initialized")
        }
        func checkCapacity() throws {
            guard listeners.count < configuration.maxSubscriptionStreams else {
                throw MCPError.invalidRequest("Too many open \(SubscriptionsListen.name) streams")
            }
        }
        try checkCapacity()
        var requested = try checked(params.notifications)
        if requested.taskIds?.isEmpty == false {
            guard context.clientCapabilities?.declaresTasksExtension == true else {
                throw MCPError.missingRequiredClientCapabilities(
                    .init(extensions: [ExtensionID.tasks: [:]]),
                    message: "Task notifications need the \(ExtensionID.tasks) extension")
            }
        }
        if let authorize = subscriptionAuthorizer {
            requested = try checked(try await authorize(requested, context))
            try checkCapacity()
        }
        if let ids = requested.taskIds, !ids.isEmpty {
            requested.taskIds = try await visibleTasks(ids, context: context)
            try checkCapacity()
        }
        // The server may have stopped, or be stopping, while the authorizer
        // or the task lookup ran.
        guard !isStopping, let current = self.connection, current === connection else {
            throw MCPError.internalError("Server stopped")
        }
        let filter = honored(requested)
        var meta = Metadata()
        meta.subscriptionID = context.id

        let (events, continuation) = AsyncStream<SubscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.listenerBufferSize))
        let token = nextListenerToken
        nextListenerToken += 1
        // Register before the acknowledgement so no event is lost; the
        // acknowledgement is still first because only this task writes.
        listeners[token] = Listener(
            filter: filter, resources: Set(filter.resourceSubscriptions ?? []), tasks: Set(filter.taskIds ?? []),
            context: context, events: continuation)
        defer { listeners[token] = nil }

        let ack = Message<SubscriptionsAcknowledgedNotification>(
            method: SubscriptionsAcknowledgedNotification.name,
            params: .init(notifications: filter), _meta: meta)
        try await connection.send(encoder.encode(ack), relatedRequestID: context.id)

        for await event in events {
            try await connection.send(
                encoder.encode(event.message(subscriptionID: context.id)), relatedRequestID: context.id)
        }
        try Task.checkCancellation()
        return SubscriptionsListen.Result(_meta: meta)
    }

    /// Send a request to the client and return a Task for the response
    private func send<M: Method>(_ request: Request<M>) throws -> Task<M.Result, Error> {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        if let context = Server.currentHandlerContext, context.profile?.allowsServerRequests == false {
            throw MCPError.invalidRequest(
                "\(M.name) cannot be sent at protocol version \(context.protocolVersion ?? "")")
        }

        let requestData = try encoder.encode(request)
        let relatedRequestID = Server.currentHandlerContext?.id
        let generation = connectionGeneration

        unsentRequests.insert(request.id)
        let requestTask = Task<M.Result, Error> {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    guard generation == self.connectionGeneration else {
                        // `stop()` ended the connection before the request was
                        // registered, and no longer resumes it.
                        continuation.resume(throwing: MCPError.internalError("Server disconnected"))
                        return
                    }
                    guard self.unsentRequests.remove(request.id) != nil else {
                        // Withdrawn before it was registered.
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    // Add pending response before sending
                    self.addPendingResponse(
                        id: request.id,
                        continuation: continuation,
                        type: M.Result.self
                    )

                    // Send the request
                    do {
                        try await connection.send(
                            requestData, relatedRequestID: relatedRequestID)
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
    /// to clients. A stateless (2026-07-28) request receives messages only at or above
    /// the level in its `_meta`. On handshake connections the built-in
    /// `logging/setLevel` handler records the client's level, and messages below it
    /// are not sent; before the client sets a level, every message is sent.
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
        // A stateless request receives log notifications only at or above
        // the level it set in `_meta`, and none when it set no level.
        if let context = Server.currentHandlerContext, context.isStateless {
            guard let minimum = context.logLevel, level >= minimum else { return }
        } else if let minimum = clientLogLevel, level < minimum {
            return
        }
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
    ///
    /// - Parameter generation: The ``connectionGeneration`` the batch was
    ///   received in; nothing is sent once ``stop()`` changed it.
    private func handleBatch(_ batch: Batch, generation: Int) async throws {
        await logger?.trace("Processing batch request", metadata: ["size": "\(batch.items.count)"])
        guard generation == connectionGeneration else { return }

        if batch.items.isEmpty {
            // Empty batch is invalid according to JSON-RPC spec
            await sendUnattributedError(MCPError.invalidRequest("Batch array must not be empty"))
            return
        }

        // Process each item in the batch and collect responses
        var responses: [Response<AnyMethod>] = []

        for item in batch.items {
            do {
                switch item {
                case .request(let request):
                    // For batched requests, collect responses instead of sending immediately
                    if let response = try await handleRequest(
                        request, sendResponse: false, generation: generation)
                    {
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
        if !responses.isEmpty, generation == connectionGeneration {
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
    ///   - generation: The ``connectionGeneration`` the request was received
    ///     in. Once ``stop()`` changed it, the request is not answered and
    ///     `nil` is returned.
    /// - Returns: The response when sendResponse is false
    private func handleRequest(
        _ request: Request<AnyMethod>, sendResponse: Bool = true, generation: Int
    ) async throws -> Response<AnyMethod>? {
        // Check if this is a pre-processed error request (empty method)
        if request.method.isEmpty && !sendResponse {
            // This is a placeholder for an invalid request that couldn't be parsed in batch mode
            return AnyMethod.response(
                id: request.id,
                error: MCPError.invalidRequest("Invalid batch item format")
            )
        }

        // Received on a connection that `stop()` ended, whose state is gone.
        guard generation == connectionGeneration else { return nil }

        // Until the handler task is registered, a cancellation of this
        // request is recorded in `startingRequests`. After `stop()` the
        // entry is gone, or belongs to the next connection.
        var registered = false
        defer {
            if !registered, generation == connectionGeneration {
                startingRequests.removeValue(forKey: request.id)
            }
        }

        await logger?.trace(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        // Replies with an error without running a handler; not once `stop()`
        // ended the connection.
        func reject(_ error: MCPError) async throws -> Response<AnyMethod>? {
            guard generation == connectionGeneration else { return nil }
            let response = AnyMethod.response(id: request.id, error: error)
            if sendResponse {
                try await send(response)
                return nil
            }
            return response
        }

        let era: RequestEra
        do {
            era = try StatelessRequests.classify(
                request._meta, served: configuration.protocolVersions)
        } catch let error as MCPError {
            return try await reject(error)
        }

        switch era {
        case .handshake:
            if StatelessRequests.statelessOnlyMethods.contains(request.method) {
                return try await reject(
                    .methodNotFound("\(request.method) requires protocol version 2026-07-28 or later"))
            }
            // A server that lists no handshake revision serves no handshake request.
            if handshakeVersions.isEmpty {
                let requested =
                    request.method == Initialize.name
                    ? request.params.objectValue?["protocolVersion"]?.stringValue
                    : request._meta?.protocolVersion
                return try await reject(
                    .unsupportedProtocolVersion(
                        supported: configuration.protocolVersions, requested: requested))
            }
            // The client SHOULD NOT send requests other than pings before the
            // server has responded to the initialize request. Without a
            // session there is nothing to initialize.
            if configuration.strict, !isInitialized, !isSessionless,
                request.method != Initialize.name, request.method != Ping.name
            {
                return try await reject(.invalidRequest("Server is not initialized"))
            }
            // Without a session, a request is not tied to the `initialize`
            // that passed the initialize hook: the stateless hook gates it,
            // and without one it is refused.
            if isSessionless, request.method != Initialize.name, hasInitializeHook,
                statelessRequestHook == nil
            {
                return try await reject(
                    .invalidRequest(
                        "Request refused: without a session the initialize hook cannot gate \(request.method)"))
            }
        case .stateless(let info):
            // An initialize hook gates handshake clients; without a stateless
            // hook, stateless requests would bypass it.
            if hasInitializeHook, statelessRequestHook == nil {
                return try await reject(
                    .unsupportedProtocolVersion(supported: handshakeVersions, requested: info.protocolVersion))
            }
            if StatelessRequests.removedMethods.contains(request.method) {
                return try await reject(
                    .methodNotFound(
                        "\(request.method) is not available at protocol version \(info.protocolVersion)"))
            }
            if !StatelessRequests.isDeclared(request.method, in: capabilities) {
                return try await reject(
                    .methodNotFound("\(request.method): capability not declared by the server"))
            }
            // Before the task is looked up: no existence leak to undeclared clients.
            if TaskMethods.v2.contains(request.method), taskManager != nil,
                !info.clientCapabilities.declaresTasksExtension
            {
                return try await reject(
                    .missingRequiredClientCapabilities(
                        .init(extensions: [ExtensionID.tasks: [:]]),
                        message: "\(request.method) needs the \(ExtensionID.tasks) extension"))
            }
        }

        // Find handler for method name
        guard let handler = methodHandlers[request.method] else {
            return try await reject(.methodNotFound("Unknown method: \(request.method)"))
        }

        // Ask the transport for the originating HTTP request so handlers can observe
        // headers/auth via `Server.currentHandlerContext?.httpContext`. Transports
        // that don't carry HTTP context (stdio, in-memory) don't conform.
        let httpContext = await (connection as? any HTTPContextProviding)?
            .httpRequestContext(for: request.id)
        // `stop()` may have run meanwhile, and a new connection may have started.
        guard generation == connectionGeneration else { return nil }
        var dispatchContext: HandlerContext
        switch era {
        case .handshake where isSessionless:
            // No session: each request stands alone, and only its
            // `MCP-Protocol-Version` header says which revision it uses.
            let header = httpContext?.header(HTTPHeaderName.protocolVersion)
            dispatchContext = HandlerContext(
                id: request.id, httpContext: httpContext,
                protocolVersion: header.flatMap { Version.handshake.contains($0) ? $0 : nil },
                clientCapabilities: nil,
                clientInfo: nil)
        case .handshake:
            dispatchContext = HandlerContext(
                id: request.id, httpContext: httpContext,
                protocolVersion: protocolVersion,
                clientCapabilities: clientCapabilities,
                clientInfo: clientInfo)
        case .stateless(let info):
            dispatchContext = HandlerContext(
                id: request.id, httpContext: httpContext,
                protocolVersion: info.protocolVersion,
                clientCapabilities: info.clientCapabilities,
                clientInfo: info.clientInfo,
                logLevel: info.logLevel,
                isStateless: true)
            servedStatelessRequest = true
        }
        dispatchContext.method = request.method
        if let token = request._meta?.progressToken {
            dispatchContext.progressReporter = { [weak self] progress, total, message in
                try await self?.notify(
                    ProgressNotification.message(
                        .init(progressToken: token, progress: progress, total: total, message: message)))
            }
        }
        if !dispatchContext.isStateless {
            dispatchContext.inputBridge = { [weak self] requests in
                guard let self else { throw MCPError.internalError("Server is gone") }
                return try await self.fulfill(requests)
            }
        }
        let taskManager = request.method == CallTool.name ? taskManager : nil
        let handlerContext = dispatchContext
        // Checked in the handler task, after the stateless hook, so it can be
        // cancelled and an unauthorized client cannot trigger it.
        let headerCheck: HTTPRequest? =
            handlerContext.isStateless && request.method == CallTool.name
                && handlerContext.profile?.usesStandardHeaders == true
            ? httpContext : nil
        let annotate: @Sendable (Response<AnyMethod>) -> Response<AnyMethod> = {
            [serverInfo, configuration] response in
            guard handlerContext.isStateless, case .success(let value) = response.result else {
                return response
            }
            let hint = configuration.cacheHints[request.method] ?? configuration.defaultCacheHint
            return Response(
                id: response.id,
                result: StatelessRequests.annotate(
                    value, method: request.method, serverInfo: serverInfo, cacheHint: hint))
        }

        // Sessionless handshake requests, other than `initialize`, pass the
        // same hook with no client info or capabilities.
        let gatesRequest =
            handlerContext.isStateless || (isSessionless && request.method != Initialize.name)
        let statelessHook = gatesRequest ? statelessRequestHook : nil

        // Create a task to handle the request with cancellation support.
        // Set currentHandlerContext as a task local so handlers see it.
        var handlerTask: Task<Response<AnyMethod>, Error>!
        Server.$currentHandlerContext.withValue(handlerContext) {
            handlerTask = Task<Response<AnyMethod>, Error> {
                do {
                    // Check if task was cancelled before starting
                    try Task.checkCancellation()

                    if let hook = statelessHook {
                        do {
                            try await hook(handlerContext.clientInfo, handlerContext.clientCapabilities ?? .init())
                        } catch let error as MCPError {
                            return AnyMethod.response(id: request.id, error: error)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return AnyMethod.response(
                                id: request.id, error: .invalidRequest("Request refused: \(error.localizedDescription)"))
                        }
                    }

                    var listing: ToolListing?
                    if let http = headerCheck,
                        let mismatch = try await self.parameterHeaderError(
                            request, http: http, context: handlerContext, listing: &listing)
                    {
                        return AnyMethod.response(id: request.id, error: mismatch)
                    }

                    var context = handlerContext
                    if let manager = taskManager {
                        do {
                            context.taskRuntime = try await self.taskRuntime(
                                for: request, context: handlerContext, manager: manager, listing: &listing)
                        } catch let error as MCPError {
                            return annotate(AnyMethod.response(id: request.id, error: error))
                        }
                    }

                    // Handle request and get response
                    var response = try await Server.$currentHandlerContext.withValue(context) {
                        try await handler(request)
                    }
                    if request.method == ListTools.name {
                        if handlerContext.isStateless {
                            response = await self.droppingInvalidHeaderTools(response)
                        }
                        if handlerContext.profile?.taskGeneration != .v1 {
                            response = Self.strippingExecution(response)
                        }
                    }
                    return annotate(response)
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
        registered = true
        if startingRequests.removeValue(forKey: request.id) == true {
            // `notifications/cancelled` arrived before the task was registered.
            handlerTask.cancel()
        }

        // Ensure cleanup happens regardless of success or failure. After
        // `stop()` the entry is gone, or belongs to the next connection.
        defer {
            if generation == connectionGeneration {
                pendingRequestTasks.removeValue(forKey: request.id)
            }
        }

        do {
            let response = try await handlerTask.value
            // Cancelled after it created a task: no one will learn the task's id.
            if handlerTask.isCancelled, let manager = taskManager,
                case .success(let value) = response.result,
                let taskID = value.objectValue?["taskId"]?.stringValue
                    ?? value.objectValue?["task"]?.objectValue?["taskId"]?.stringValue
            {
                _ = try? await manager.cancel(taskID)
                return nil
            }
            // `stop()` ended the connection while the handler ran.
            guard generation == connectionGeneration else { return nil }

            if sendResponse {
                try await send(response)
                return nil
            }

            return response
        } catch is CancellationError {
            // Request was cancelled, don't send a response per MCP spec
            return nil
        } catch {
            guard generation == connectionGeneration else { return nil }
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

    // MARK: - Custom headers (SEP-2243)

    /// Checks the `Mcp-Param-*` headers of a `tools/call` against its
    /// arguments, using the input schemas of the `tools/list` handler.
    ///
    /// Fails closed: a call that carries `Mcp-Param-*` headers is refused
    /// with -32020 when the tool's schema cannot be found, and a call to a
    /// tool hidden for an invalid annotation is always refused.
    private func parameterHeaderError(
        _ request: Request<AnyMethod>, http: HTTPRequest, context: HandlerContext, listing: inout ToolListing?
    ) async throws -> MCPError? {
        let params = request.params.objectValue
        let arguments = params?["arguments"]
        let prefix = MCPRequestHeaders.parameterPrefix.lowercased()
        let hasHeaders = http.headers.keys.contains { $0.lowercased().hasPrefix(prefix) }
        // Nothing to compare: skip the schema lookup.
        if arguments?.objectValue?.isEmpty ?? true, !hasHeaders { return nil }
        guard methodHandlers[ListTools.name] != nil else {
            return hasHeaders ? .headerMismatch("No input schema to check the Mcp-Param headers against") : nil
        }
        let name = params?["name"]?.stringValue ?? ""

        switch try await toolInfo(context: context, request: request, listing: &listing)?[name]?.headers {
        case .valid(let parameters)?:
            return MCPRequestHeaders.validate(parameters, arguments: arguments, header: http.header)
                .map { MCPError.headerMismatch($0) }
        case .invalid?:
            return .headerMismatch("The tool has an invalid \(MCPRequestHeaders.schemaKeyword) annotation")
        case nil:
            return hasHeaders ? .headerMismatch("No input schema to check the Mcp-Param headers against") : nil
        }
    }

    /// The `x-mcp-header` parameters of a listed tool.
    enum ToolHeaders: Sendable {
        case valid([MCPRequestHeaders.Parameter])
        /// Hidden from `tools/list` for an invalid annotation.
        case invalid
    }

    /// What `tools/call` needs to know about a listed tool.
    struct ToolInfo: Sendable {
        let headers: ToolHeaders
        let taskSupport: TaskSupport
    }

    /// What one `tools/call` read from the `tools/list` handler, so that its
    /// checks share one pass.
    struct ToolListing {
        /// `nil` when the pass failed.
        let tools: [String: ToolInfo]?
    }

    /// The parameters and task support of every tool the `tools/list`
    /// handler lists for the caller, from one pass through its pages run
    /// under the caller's context: the list may differ per caller, so it is
    /// not kept across calls. `listing` holds the pass for the rest of the
    /// call. `nil` when the pass fails.
    ///
    /// - Throws: `CancellationError` when the call is cancelled.
    private func toolInfo(
        context: HandlerContext, request: Request<AnyMethod>, listing: inout ToolListing?
    ) async throws -> [String: ToolInfo]? {
        if let listing { return listing.tools }
        guard let handler = methodHandlers[ListTools.name] else { return nil }
        let tools = try await Self.listTools(handler, context: context, request: request)
        listing = ToolListing(tools: tools)
        if tools == nil {
            await logger?.warning(
                "Cannot read the tools/list input schemas; calls with Mcp-Param headers are refused")
        }
        return tools
    }

    private static func listTools(
        _ handler: RequestHandlerBox, context: HandlerContext, request: Request<AnyMethod>
    ) async throws -> [String: ToolInfo]? {
        var tools: [String: ToolInfo] = [:]
        var cursor: String?
        for _ in 0..<maxToolListPages {
            try Task.checkCancellation()
            var params: [String: Value] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let list = Request<AnyMethod>(
                id: request.id, method: ListTools.name, params: .object(params), _meta: request._meta)
            let response = try? await Server.$currentHandlerContext.withValue(context) {
                try await handler(list)
            }
            try Task.checkCancellation()
            guard case .success(let result)? = response?.result else { return nil }
            for tool in result.objectValue?["tools"]?.arrayValue ?? [] {
                guard let name = tool.objectValue?["name"]?.stringValue else { continue }
                let parameters = try? MCPRequestHeaders.parameters(in: tool.objectValue?["inputSchema"] ?? .null)
                let support = tool.objectValue?["execution"]?.objectValue?["taskSupport"]?.stringValue
                tools[name] = ToolInfo(
                    headers: parameters.map(ToolHeaders.valid) ?? .invalid,
                    taskSupport: support.map(TaskSupport.init(rawValue:)) ?? .forbidden)
            }
            guard let next = result.objectValue?["nextCursor"]?.stringValue else { return tools }
            cursor = next
        }
        return nil
    }

    private static let maxToolListPages = 100

    /// Removes tools with invalid `x-mcp-header` annotations from a
    /// `tools/list` result: clients must ignore them (SEP-2243).
    private func droppingInvalidHeaderTools(_ response: Response<AnyMethod>) async
        -> Response<AnyMethod>
    {
        guard case .success(let value) = response.result,
            var object = value.objectValue,
            let tools = object["tools"]?.arrayValue
        else { return response }
        var valid: [Value] = []
        for tool in tools {
            do {
                _ = try MCPRequestHeaders.parameters(in: tool.objectValue?["inputSchema"] ?? .null)
                valid.append(tool)
            } catch {
                await logger?.warning(
                    "Tool not listed: invalid x-mcp-header annotation",
                    metadata: [
                        "tool": "\(MCPRequestHeaders.sanitized(tool.objectValue?["name"]?.stringValue ?? "?"))",
                        "error": "\(error)",
                    ])
            }
        }
        guard valid.count != tools.count else { return response }
        object["tools"] = .array(valid)
        return Response(id: response.id, result: .object(object))
    }

    private func handleMessage(_ message: Message<AnyNotification>) async throws {
        await logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        // A strict server ignores notifications of handshake clients before
        // `initialize`; a notification is never answered, not even with an
        // error. A connection that served a stateless request has a
        // 2026-07-28 client, which never initializes, and a cancellation is
        // always let through.
        if configuration.strict, !isInitialized, !isSessionless, !servedStatelessRequest,
            message.method != InitializedNotification.name, message.method != CancelledNotification.name
        {
            await logger?.warning(
                "Notification before initialize ignored", metadata: ["method": "\(message.method)"])
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

    /// Sends an error that answers no known request: `"id": null`
    /// (JSON-RPC 2.0, section 5).
    private func sendUnattributedError(_ error: MCPError) async {
        guard let connection else { return }
        do {
            let response = AnyMethod.response(id: .string(""), error: error)
            guard case .object(var object) = try decoder.decode(Value.self, from: encoder.encode(response))
            else { return }
            object["id"] = .null
            try await connection.send(try encoder.encode(Value.object(object)))
        } catch {
            await logger?.error("Failed to send error response", metadata: ["error": "\(error)"])
        }
    }

    /// The handshake revisions this server serves, newest first.
    private var handshakeVersions: [String] {
        configuration.protocolVersions.filter { Version.handshake.contains($0) }
    }

    /// Whether this connection has served a stateless (2026-07-28) request.
    private var servedStatelessRequest = false

    /// Whether the transport has no connection or session, so that each
    /// handshake request stands alone (``StatelessHTTPServerTransport``).
    private var isSessionless: Bool {
        connection is StatelessHTTPServerTransport
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
            guard let capabilities = Server.currentHandlerContext?.clientCapabilities
                ?? clientCapabilities
            else {
                // A sessionless handshake request carries no capabilities:
                // let the client answer.
                if isSessionless { return }
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
        // The handlers are stored on the server: capturing it strongly would
        // keep every started server alive.

        // Initialize
        registerDefault(Initialize.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server is gone") }
            // Behind a sessionless transport every client sends its own
            // `initialize`; the server keeps no per-client state.
            let sessionless = await self.isSessionless
            let initialized = await self.isInitialized
            guard sessionless || !initialized else {
                throw MCPError.invalidRequest("Server is already initialized")
            }

            // Negotiate among the configured handshake revisions.
            let handshakeVersions = await self.handshakeVersions
            guard let newest = handshakeVersions.first else {
                throw MCPError.unsupportedProtocolVersion(
                    supported: await self.configuration.protocolVersions,
                    requested: params.protocolVersion)
            }

            // Call initialization hook if registered
            if let hook = initializeHook {
                try await hook(params.clientInfo, params.capabilities)
            }

            let clientRequestedVersion = params.protocolVersion
            let negotiatedProtocolVersion =
                handshakeVersions.contains(clientRequestedVersion) ? clientRequestedVersion : newest

            if !sessionless {
                await self.setInitialState(
                    clientInfo: params.clientInfo,
                    clientCapabilities: params.capabilities,
                    protocolVersion: negotiatedProtocolVersion
                )
            }

            return Initialize.Result(
                protocolVersion: negotiatedProtocolVersion,
                capabilities: await self.advertisedCapabilities(for: negotiatedProtocolVersion),
                serverInfo: self.serverInfo,
                instructions: self.instructions
            )
        }

        // Ping
        registerDefault(Ping.self) { _ in return Empty() }

        // Log level (handshake connections; 2026-07-28 sets it per request)
        if capabilities.logging != nil {
            registerDefault(SetLoggingLevel.self) { [weak self] params in
                guard let self else { throw MCPError.internalError("Server is gone") }
                await self.setClientLogLevel(params.level)
                return Empty()
            }
        }

        // Notification streams (2026-07-28 and later)
        registerDefault(SubscriptionsListen.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server is gone") }
            return try await self.serveListen(params)
        }

        // Discovery (2026-07-28 and later)
        registerDefault(ServerDiscover.self) { [weak self] _ in
            guard let self else { throw MCPError.internalError("Server is gone") }
            return ServerDiscover.Result(
                supportedVersions: await self.configuration.protocolVersions,
                capabilities: await self.advertisedCapabilities(
                    for: Server.currentHandlerContext?.protocolVersion ?? Version.stateless[0]),
                instructions: self.instructions
            )
        }
    }

    /// Records the level of `logging/setLevel`. Behind a sessionless
    /// transport there is no connection to record it for.
    private func setClientLogLevel(_ level: LogLevel) {
        guard !isSessionless else { return }
        clientLogLevel = level
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

    /// Cancels the handler of the request `id` and stops tracking it. A
    /// request whose handler task is not registered yet is cancelled when it
    /// registers. Returns `false` for a request that is unknown or complete.
    private func cancelRequestHandler(id: ID) -> Bool {
        if let task = pendingRequestTasks.removeValue(forKey: id) {
            task.cancel()
            return true
        }
        guard startingRequests[id] != nil else { return false }
        startingRequests[id] = true
        return true
    }

    private func registerCancellationHandler() {
        onNotification(CancelledNotification.self) { [weak self] message in
            guard let self else { return }

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
            if await self.cancelRequestHandler(id: requestId) {
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
        decoder.userInfo[.valuePreservesStrings] = true

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
