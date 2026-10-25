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
        /// Experimental features supported by the server
        public var experimental: [String: Value]?
        /// Protocol extensions supported by the server, keyed by extension
        /// identifier, with extension-defined settings (SEP-2133).
        public var extensions: [String: Value]?

        public init(
            completions: Completions? = nil,
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil,
            experimental: [String: Value]? = nil,
            extensions: [String: Value]? = nil
        ) {
            self.completions = completions
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
            self.experimental = experimental
            self.extensions = extensions
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
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// Pending request tasks (for cancellation support)
    private var pendingRequestTasks: [ID: Task<Response<AnyMethod>, Error>] = [:]
    /// Requests received whose handler task is not registered yet, and
    /// whether `notifications/cancelled` arrived for them meanwhile.
    private var startingRequests: [ID: Bool] = [:]

    /// `x-mcp-header` parameters by tool name (SEP-2243). Filled on the
    /// first `tools/call` that needs them; cleared when a
    /// `ToolListChangedNotification` is sent or the `tools/list` handler is
    /// replaced.
    private var toolHeaderCache: [String: ToolHeaders]?
    private var toolHeaderLoad: Task<[String: ToolHeaders]?, Never>?
    private var toolHeaderGeneration = 0

    /// Pending requests sent to the client, awaiting responses
    private var pendingRequests: [ID: AnyPendingRequest] = [:]

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
    /// - Parameters:
    ///   - transport: The transport to use for the server
    ///   - initializeHook: An optional hook that runs when the client sends an initialize request
    ///   - statelessRequestHook: An optional hook that runs before every
    ///     stateless request (2026-07-28 and later), which never sends
    ///     `initialize`. When `initializeHook` is set and this hook is not,
    ///     stateless requests are refused with -32022, so a gate in
    ///     `initializeHook` cannot be bypassed; clients then fall back to
    ///     `initialize`.
    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil,
        statelessRequestHook: StatelessRequestHook? = nil
    ) async throws {
        self.connection = transport
        self.hasInitializeHook = initializeHook != nil
        self.statelessRequestHook = statelessRequestHook
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
                            // Off the receive loop: a batched request may wait
                            // for the client's answer to a bridged input request.
                            Task {
                                do {
                                    try await self.handleBatch(batch)
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
                                _ = try? await self.handleRequest(request, sendResponse: true)
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
    ///
    /// Open `subscriptions/listen` streams end with their result, as with
    /// ``closeSubscriptions()``, and `stop()` waits until those results are
    /// sent before it closes the transport. A stream that is still being
    /// authorized is refused.
    public func stop() async {
        isStopping = true
        defer { isStopping = false }
        closeSubscriptions()
        // The handlers resume only once this suspends: closing the
        // transport first lost their results.
        let ending = listeners.values.compactMap { listenRequests[$0.context.id] }
        for handling in ending { await handling.value }

        task?.cancel()
        task = nil

        // Clear pending requests with errors
        let pendingRequestsToCancel = self.pendingRequests
        self.pendingRequests = [:]
        for (_, request) in pendingRequestsToCancel {
            request.resume(throwing: MCPError.internalError("Server disconnected"))
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

        /// The feature profile of ``protocolVersion``.
        public var profile: ProtocolProfile? { protocolVersion.map(Version.profile(for:)) }

        package init(
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
    /// with the responses, up to 10 rounds, so one handler serves both.
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
        if M.name == ListTools.name { invalidateToolHeaders() }
        return self
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
                    if let consume = boundary.protection.consume,
                        await !consume(verified.tokenID, verified.expiry)
                    {
                        throw InvalidRequestState("replayed")
                    }
                    params = params.retrying(inputResponses: params.inputResponses, requestState: verified.state)
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
            if asking.inputRequests == nil, asking.requestState == nil {
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
                    "\(M.name) asked for input more than \(MRTR.maxRounds) times")
            }
            let requests = asking.inputRequests ?? [:]
            if requests.isEmpty {
                // Only state: the handler is not done yet. Wait as a
                // 2026-07-28 client would before the next round.
                try await Task.sleep(for: stateOnlyDelay)
                stateOnlyDelay = min(stateOnlyDelay * 2, MRTR.stateOnlyMaximumDelay)
            } else {
                stateOnlyDelay = MRTR.stateOnlyInitialDelay
                // As at 2026-07-28, whatever `strict` says.
                try Self.checkCapabilities(requests, method: M.name, declared: context.clientCapabilities)
            }
            let responses = try await fulfill(requests)
            params = params.retrying(
                inputResponses: responses.isEmpty ? nil : responses, requestState: asking.requestState)
            round += 1
        }
    }

    /// Throws -32021 when input requests need capabilities the client did not declare.
    private static func checkCapabilities(
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
    private func fulfill(_ requests: [String: InputRequest]) async throws -> [String: InputResponse] {
        try await withThrowingTaskGroup(of: (String, InputResponse).self) { group in
            for (key, request) in requests {
                group.addTask { (key, try await self.fulfill(request)) }
            }
            var responses: [String: InputResponse] = [:]
            for try await (key, response) in group {
                responses[key] = response
            }
            return responses
        }
    }

    private func fulfill(_ request: InputRequest) async throws -> InputResponse {
        switch request {
        case .elicitation(let params):
            return .elicitation(try await ask(CreateElicitation.request(params)))
        case .sampling(let params):
            return .sampling(try await ask(CreateSamplingMessage.request(params)))
        case .listRoots:
            return .roots(try await ask(ListRoots.request()))
        }
    }

    /// Sends one bridged request to the client. A client error fails the
    /// carrier with -32603; cancellation withdraws the request.
    private func ask<M: Method>(_ request: Request<M>) async throws -> M.Result {
        let task = try send(request)
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.withdraw(request.id) }
            }
        } catch let error as MCPError {
            throw MCPError.internalError("The client failed \(M.name): \(error.localizedDescription)")
        }
    }

    /// Ends a bridged request whose carrier was cancelled, and tells the
    /// client.
    private func withdraw(_ id: ID) async {
        guard let pending = removePendingResponse(id: id) else { return }
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
    /// the connection. Every caller's matching stream receives them; use
    /// ``notify(_:to:)`` to reach only some callers.
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        try await notify(notification, matching: nil)
    }

    /// Sends a list-changed or resource-updated notification only to the
    /// `subscriptions/listen` streams whose caller `recipients` accepts, for
    /// example by the principal in `context.httpContext`.
    ///
    /// On an `initialize` session the notification is also sent on the
    /// connection, as ``notify(_:)`` does: that session has one client.
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

        if N.name == ToolListChangedNotification.name { invalidateToolHeaders() }
        let notificationData = try encoder.encode(notification)
        if let event = SubscriptionEvent(notification) {
            publish(event, to: recipients)
            guard isInitialized else { return }
        }
        try await connection.send(
            notificationData, relatedRequestID: Server.currentHandlerContext?.id)
    }

    // MARK: - Subscriptions (2026-07-28)

    private struct Listener {
        let filter: SubscriptionFilter
        /// `filter.resourceSubscriptions`, for lookups.
        let resources: Set<String>
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
        for listener in listeners.values where event.matches(listener.filter, resources: listener.resources) {
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
                ? requested.resourceSubscriptions : nil)
    }

    /// The requested filter with duplicate URIs removed; throws -32602 for
    /// too many or too long URIs.
    private func checked(_ requested: SubscriptionFilter) throws -> SubscriptionFilter {
        guard let uris = requested.resourceSubscriptions else { return requested }
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
        var filter = requested
        filter.resourceSubscriptions = unique
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
        if let authorize = subscriptionAuthorizer {
            requested = try checked(try await authorize(requested, context))
            try checkCapacity()
        }
        // The server may have stopped, or be stopping, while the authorizer ran.
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
            filter: filter, resources: Set(filter.resourceSubscriptions ?? []), context: context,
            events: continuation)
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
        // A stateless request receives log notifications only at or above
        // the level it set in `_meta`, and none when it set no level.
        if let context = Server.currentHandlerContext, context.isStateless {
            guard let minimum = context.logLevel, level >= minimum else { return }
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

        // Until the handler task is registered, a cancellation of this
        // request is recorded in `startingRequests`.
        var registered = false
        defer {
            if !registered { startingRequests.removeValue(forKey: request.id) }
        }

        await logger?.trace(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        // Replies with an error without running a handler.
        func reject(_ error: MCPError) async throws -> Response<AnyMethod>? {
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
        let handlerContext: HandlerContext
        switch era {
        case .handshake:
            handlerContext = HandlerContext(
                id: request.id, httpContext: httpContext,
                protocolVersion: protocolVersion,
                clientCapabilities: clientCapabilities,
                clientInfo: clientInfo)
        case .stateless(let info):
            handlerContext = HandlerContext(
                id: request.id, httpContext: httpContext,
                protocolVersion: info.protocolVersion,
                clientCapabilities: info.clientCapabilities,
                clientInfo: info.clientInfo,
                logLevel: info.logLevel,
                isStateless: true)
        }
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

        let statelessHook = handlerContext.isStateless ? statelessRequestHook : nil

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

                    if let http = headerCheck,
                        let mismatch = await self.parameterHeaderError(request, http: http, context: handlerContext)
                    {
                        return AnyMethod.response(id: request.id, error: mismatch)
                    }

                    // Handle request and get response
                    var response = try await handler(request)
                    if handlerContext.isStateless, request.method == ListTools.name {
                        response = await self.droppingInvalidHeaderTools(response)
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

        // Ensure cleanup happens regardless of success or failure
        defer {
            pendingRequestTasks.removeValue(forKey: request.id)
        }

        do {
            let response = try await handlerTask.value

            if sendResponse {
                try await send(response)
                return nil
            }

            return response
        } catch is CancellationError {
            // Request was cancelled, don't send a response per MCP spec
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

    // MARK: - Custom headers (SEP-2243)

    /// Checks the `Mcp-Param-*` headers of a `tools/call` against its
    /// arguments, using the input schemas of the `tools/list` handler.
    ///
    /// Fails closed: a call that carries `Mcp-Param-*` headers is refused
    /// with -32020 when the tool's schema cannot be found, and a call to a
    /// tool hidden for an invalid annotation is always refused.
    private func parameterHeaderError(
        _ request: Request<AnyMethod>, http: HTTPRequest, context: HandlerContext
    ) async -> MCPError? {
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

        switch await toolHeaders(context: context, request: request)?[name] {
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

    /// The parameters of every tool the `tools/list` handler lists, from one
    /// pass through its pages. Concurrent calls share the pass; the result
    /// is kept until the tool list changes. `nil` when the pass fails.
    private func toolHeaders(context: HandlerContext, request: Request<AnyMethod>) async
        -> [String: ToolHeaders]?
    {
        if let cached = toolHeaderCache { return cached }
        if let pending = toolHeaderLoad { return await pending.value }
        guard let handler = methodHandlers[ListTools.name] else { return nil }
        let generation = toolHeaderGeneration
        let load = Task { () -> [String: ToolHeaders]? in
            var headers: [String: ToolHeaders] = [:]
            var cursor: String?
            for _ in 0..<Self.maxToolListPages {
                var params: [String: Value] = [:]
                if let cursor { params["cursor"] = .string(cursor) }
                let list = Request<AnyMethod>(
                    id: request.id, method: ListTools.name, params: .object(params), _meta: request._meta)
                let response = try? await Server.$currentHandlerContext.withValue(context) {
                    try await handler(list)
                }
                guard case .success(let result)? = response?.result else { return nil }
                for tool in result.objectValue?["tools"]?.arrayValue ?? [] {
                    guard let name = tool.objectValue?["name"]?.stringValue else { continue }
                    let parameters = try? MCPRequestHeaders.parameters(in: tool.objectValue?["inputSchema"] ?? .null)
                    headers[name] = parameters.map(ToolHeaders.valid) ?? .invalid
                }
                guard let next = result.objectValue?["nextCursor"]?.stringValue else { return headers }
                cursor = next
            }
            return nil
        }
        toolHeaderLoad = load
        let headers = await load.value
        if toolHeaderGeneration == generation {
            toolHeaderLoad = nil
            toolHeaderCache = headers
        }
        if headers == nil {
            await logger?.warning(
                "Cannot read the tools/list input schemas; calls with Mcp-Param headers are refused")
        }
        return headers
    }

    /// Forgets the cached tool schemas.
    private func invalidateToolHeaders() {
        toolHeaderGeneration &+= 1
        toolHeaderCache = nil
        toolHeaderLoad = nil
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

    /// The handshake revisions this server serves, newest first.
    private var handshakeVersions: [String] {
        configuration.protocolVersions.filter { Version.handshake.contains($0) }
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
            guard let capabilities = Server.currentHandlerContext?.clientCapabilities
                ?? clientCapabilities
            else {
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

        // Notification streams (2026-07-28 and later)
        withMethodHandler(SubscriptionsListen.self) { params in
            try await self.serveListen(params)
        }

        // Discovery (2026-07-28 and later)
        withMethodHandler(ServerDiscover.self) { _ in
            ServerDiscover.Result(
                supportedVersions: await self.configuration.protocolVersions,
                capabilities: await self.capabilities,
                instructions: self.instructions
            )
        }
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
