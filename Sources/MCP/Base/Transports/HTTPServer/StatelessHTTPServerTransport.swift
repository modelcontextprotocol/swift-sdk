import Foundation
import Logging

/// A stateless HTTP server transport that returns single JSON responses.
///
/// This transport implements a minimal subset of the MCP Streamable HTTP specification:
/// - No session management (no `Mcp-Session-Id` header)
/// - No standalone GET event stream; listen and progress requests can open per-request SSE streams
/// - Client cancellation notifications are scoped by Authorization, Cookie, or
///   the hosting adapter's `HTTPRequest.clientIdentity`; notifications without
///   a matching identity are ignored because request IDs alone are not client-scoped.
/// - GET and DELETE requests return 405 Method Not Allowed
///
/// ## Usage
///
/// ```swift
/// let transport = StatelessHTTPServerTransport()
///
/// // Start the MCP server with this transport
/// try await server.start(transport: transport)
///
/// // In your HTTP framework handler:
/// let response = await transport.handleRequest(httpRequest)
/// // Convert response to your framework's response type and return it
/// ```
///
/// ## When to Use
///
/// Use this transport when:
/// - You don't need server-initiated messages (no GET SSE stream)
/// - You want simple request-response semantics
/// - Session management is handled externally or not needed
///
/// For full streaming and session support, use ``StatefulHTTPServerTransport`` instead.
public actor StatelessHTTPServerTransport: Transport, HTTPContextProviding, HTTPToolSchemaProviderInstalling {
    public nonisolated let logger: Logger

    // MARK: - Dependencies

    private let validationPipeline: any HTTPRequestValidationPipeline

    // MARK: - State

    private var terminated = false
    private var started = false
    private var toolSchemas = MCPToolSchemaRegistry()
    private var toolSchemaProvider: (@Sendable (HTTPRequest) async -> Data?)?

    // MARK: - Incoming message stream (client → server)

    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    // MARK: - Response waiters

    /// Maps request ID → continuation waiting for the server's response.
    /// When the server calls `send()` with a response, the matching continuation is resumed.
    private var responseWaiters: [String: CheckedContinuation<Data, any Error>] = [:]
    /// Prevents concurrent clients that reuse an ID from replacing each other's
    /// response, listen, progress, or HTTP-context state.
    private var activeRequestIDs: Set<String> = []

    /// Maps request ID → originating HTTP request, surfaced to handlers via
    /// ``Server/currentHTTPContext``. Entries live only while a JSON-RPC request
    /// is in flight.
    private var httpRequestContexts: [String: HTTPRequest] = [:]
    private var listenStreams: [String: AsyncThrowingStream<Data, Swift.Error>.Continuation] = [:]
    private var listenFilters: [String: SubscriptionsListen.NotificationFilter] = [:]
    private var pendingListenFilters: [String: SubscriptionsListen.NotificationFilter] = [:]
    private var listenIDs: [String: ID] = [:]
    private var progressStreams: [String: AsyncThrowingStream<Data, Swift.Error>.Continuation] = [:]
    private var progressTokens: [String: ProgressToken] = [:]

    // MARK: - Init

    /// Creates a new stateless HTTP server transport.
    ///
    /// - Parameters:
    ///   - validationPipeline: Custom validation pipeline. If `nil`, uses sensible defaults:
    ///     origin validation (localhost), Accept header (JSON only), Content-Type,
    ///     and protocol version validation.
    ///   - logger: Optional logger. If `nil`, a no-op logger is used.
    public init(
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        logger: Logger? = nil
    ) {
        self.validationPipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            MCPRoutingHeaderValidator(),
        ])
        self.logger = logger ?? Logger(
            label: "mcp.transport.http.server.stateless",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = stream
        self.incomingContinuation = continuation
    }

    // MARK: - Transport Conformance

    public func connect() async throws {
        guard !started else {
            throw MCPError.internalError("Transport already started")
        }
        started = true
        logger.debug("Stateless HTTP server transport started")
    }

    public func disconnect() async {
        await terminate()
    }

    package func setToolSchemaProvider(
        _ provider: (@Sendable (HTTPRequest) async -> Data?)?
    ) async {
        toolSchemaProvider = provider
    }

    /// Routes outgoing server messages to the appropriate waiting HTTP handler.
    ///
    /// - Responses are matched by JSON-RPC ID and delivered to the waiting `handleRequest` call.
    /// - Notifications and server-initiated requests are logged and dropped
    ///   (no streaming channel available in stateless mode).
    public func send(_ data: Data) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        guard let kind = JSONRPCMessageKind(data: data) else {
            logger.warning("Could not classify outgoing message for routing")
            return
        }

        if case .notification(let method) = kind, method == ToolListChangedNotification.name {
            toolSchemas.invalidateAll()
        }

        if case .response(let id) = kind, let context = httpRequestContexts[id] {
            toolSchemas.record(responseData: data, for: context)
        }

        switch kind {
        case .response(let id):
            activeRequestIDs.remove(id)
            if let continuation = listenStreams[id] {
                continuation.yield(SSEEvent.message(data: data).formatted())
                continuation.finish()
                clearListen(id)
                return
            }
            if let continuation = progressStreams.removeValue(forKey: id) {
                continuation.yield(SSEEvent.message(data: data).formatted())
                continuation.finish()
                progressTokens.removeValue(forKey: id)
                httpRequestContexts.removeValue(forKey: id)
                return
            }
            guard let continuation = responseWaiters.removeValue(forKey: id) else {
                logger.debug(
                    "No waiter for response, may have timed out",
                    metadata: ["requestID": "\(id)"]
                )
                return
            }
            continuation.resume(returning: data)

        case .notification(let method):
            if method == SubscriptionsAcknowledgedNotification.name {
                guard let subscriptionID = JSONRPCMessageKind.subscriptionID(inBody: data),
                    let requestID = listenIDs.first(where: { $0.value == subscriptionID })?.key,
                    let continuation = listenStreams[requestID]
                else { return }
                guard let requestedFilter = pendingListenFilters.removeValue(forKey: requestID),
                    let acceptedFilter = Self.notificationFilter(from: data)
                else { return }
                listenFilters[requestID] = requestedFilter.intersection(with: acceptedFilter)
                continuation.yield(SSEEvent.message(data: data).formatted())
                return
            }

            for (requestID, filter) in listenFilters where Self.notification(method, matches: filter, body: data) {
                guard let continuation = listenStreams[requestID] else { continue }
                continuation.yield(SSEEvent.message(data: Self.tagged(data, subscriptionID: listenIDs[requestID] ?? .string(requestID))).formatted())
            }
            if method == ProgressNotification.name,
               let token = JSONRPCMessageKind.progressToken(inBody: data) {
                for (requestID, expectedToken) in progressTokens where expectedToken == token {
                    progressStreams[requestID]?.yield(SSEEvent.message(data: data).formatted())
                }
            }

        case .request(_, let method):
            logger.debug(
                "Server-initiated request dropped in stateless mode (no GET SSE stream)",
                metadata: ["method": "\(method)"]
            )
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    // MARK: - HTTP Request Handler

    /// Handles an incoming HTTP request from the framework adapter.
    ///
    /// Only POST is supported:
    /// - **POST**: JSON-RPC messages (requests, notifications)
    /// - **GET**: 405 Method Not Allowed
    /// - **DELETE**: 405 Method Not Allowed
    /// - Others: 405 Method Not Allowed
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if terminated {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Transport has been terminated")
            )
        }

        switch request.method.uppercased() {
        case "POST":
            return await handlePost(request)
        default:
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                extraHeaders: [HTTPHeaderName.allow: "POST"]
            )
        }
    }

    // MARK: - POST Handler

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse body first to determine message type
        guard let body = request.body, !body.isEmpty else {
            return .error(
                statusCode: 400,
                .parseError("Empty request body")
            )
        }

        guard let messageKind = JSONRPCMessageKind(data: body) else {
            return .error(
                statusCode: 400,
                .parseError("Invalid JSON-RPC message")
            )
        }

        let bodyProtocolVersion = JSONRPCMessageKind.protocolVersion(inBody: body)
        let headerProtocolVersion = request.header(HTTPHeaderName.protocolVersion)
        let isModern = JSONRPCMessageKind.isModernProfile(
            kind: messageKind,
            body: body,
            headerProtocolVersion: headerProtocolVersion
        )
        let isModernHTTPRequest = isModern || (headerProtocolVersion.map(Version.isModern) ?? false)

        // Build validation context
        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: messageKind.isInitializeRequest,
            isDiscoverRequest: messageKind.isDiscoverRequest,
            isModernRequest: isModernHTTPRequest,
            bodyProtocolVersion: bodyProtocolVersion,
            supportedProtocolVersions: isModernHTTPRequest ? Version.modern : Version.supported
        )

        // Run validation pipeline
        if let errorResponse = validationPipeline.validate(request, context: context) {
            return Self.responsePreservingRequestID(errorResponse, body: body)
        }

        if isModernHTTPRequest, messageKind.methodName == CallTool.name {
            var schemas = toolSchemas.schemas(for: request)
            if let toolName = MCPToolHeaderSupport.toolName(in: body), schemas[toolName] == nil,
                !toolSchemas.isComplete(for: request)
            {
                guard let provider = toolSchemaProvider,
                    let responseData = await provider(request)
                else {
                    return Self.responsePreservingRequestID(
                        .error(statusCode: 400, .serverError(code: -32020, message: "Unable to resolve tool schema for custom-header validation")),
                        body: body
                    )
                }
                toolSchemas.record(responseData: responseData, for: request)
                schemas = toolSchemas.schemas(for: request)
            }
            if let mismatch = MCPToolHeaderSupport.validateCall(body: body, request: request, schemas: schemas) {
                return Self.responsePreservingRequestID(
                    .error(statusCode: 400, .serverError(code: -32020, message: mismatch)),
                    body: body
                )
            }
        }

        if isModernHTTPRequest, case .request(_, let method) = messageKind, method == Initialize.name {
            return Self.responsePreservingRequestID(
                .error(statusCode: 404, .methodNotFound("initialize is not available in stateless modern HTTP")),
                body: body
            )
        }

        // Handle by message type
        switch messageKind {
        case .notification(let method):
            if method == CancelledNotification.name,
                !cancellationMatchesRequestPrincipal(body: body, request: request)
            {
                // This transport has no session identity, and cancellation carries
                // only a request ID. Do not let an unauthenticated or differently
                // authenticated caller cancel another caller's in-flight request.
                return .accepted()
            }
            incomingContinuation.yield(body)
            return .accepted()

        case .response:
            // Yield to server and return 202 Accepted
            incomingContinuation.yield(body)
            return .accepted()

        case .request(let id, let method):
            guard activeRequestIDs.insert(id).inserted else {
                return Self.responsePreservingRequestID(
                    .error(
                        statusCode: 409,
                        .invalidRequest("A request with this JSON-RPC id is already active")
                    ),
                    body: body
                )
            }
            // subscriptions/listen parks until cancel and requires a per-request
            // SSE stream; the stateless transport waits for a single JSON body.
            if method == SubscriptionsListen.name {
                return handleListen(body, requestID: id, request: request)
            }
            if JSONRPCMessageKind.progressToken(inBody: body) != nil {
                return handleProgressRequest(body, requestID: id, request: request)
            }
            return await handleJSONRPCRequest(body, requestID: id, request: request)
        }
    }

    private func cancellationMatchesRequestPrincipal(body: Data, request: HTTPRequest) -> Bool {
        guard let message = try? JSONDecoder().decode(Message<CancelledNotification>.self, from: body),
            let requestID = message.params.requestId,
            let activeRequest = httpRequestContexts[requestID.transportKey],
            let callerIdentity = Self.cancellationIdentity(for: request),
            callerIdentity == Self.cancellationIdentity(for: activeRequest)
        else { return false }
        return true
    }

    private static func cancellationIdentity(for request: HTTPRequest) -> String? {
        if let clientIdentity = request.clientIdentity, !clientIdentity.isEmpty {
            return "client:\(clientIdentity)"
        }
        if let authorization = request.header(HTTPHeaderName.authorization) {
            return "authorization:\(authorization)"
        }
        if let cookie = request.header("Cookie") {
            return "cookie:\(cookie)"
        }
        return nil
    }

    private static func responsePreservingRequestID(_ response: HTTPResponse, body: Data) -> HTTPResponse {
        guard case .error(let status, _, _, let extraHeaders) = response,
              let bodyObject = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = bodyObject["id"],
              var envelope = response.bodyData.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            return response
        }
        envelope["id"] = id
        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope) else { return response }
        return .httpData(statusCode: status, encoded, headers: [HTTPHeaderName.contentType: ContentType.json].merging(extraHeaders) { _, new in new })
    }

    private func handleJSONRPCRequest(
        _ body: Data,
        requestID: String,
        request: HTTPRequest
    ) async -> HTTPResponse {
        httpRequestContexts[requestID] = request
        // Yield the incoming message to the server
        incomingContinuation.yield(body)

        // Wait for the server to process and send a response
        let responseData: Data
        do {
            responseData = try await withCheckedThrowingContinuation { continuation in
                responseWaiters[requestID] = continuation
            }
        } catch {
            activeRequestIDs.remove(requestID)
            httpRequestContexts.removeValue(forKey: requestID)
            return .error(
                statusCode: 500,
                .internalError("Error processing request: \(error.localizedDescription)")
            )
        }

        activeRequestIDs.remove(requestID)
        httpRequestContexts.removeValue(forKey: requestID)
        let headers = [HTTPHeaderName.contentType: ContentType.json]
        if let statusCode = Self.httpStatus(forJSONRPCError: responseData) {
            return .httpData(statusCode: statusCode, responseData, headers: headers)
        }
        return .data(responseData, headers: headers)
    }

    private static func httpStatus(forJSONRPCError data: Data) -> Int? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = envelope["error"] as? [String: Any],
              let code = error["code"] as? Int else { return nil }
        switch code {
        case -32601: return 404
        case -32600, -32602, -32020, -32021: return 400
        default: return nil
        }
    }

    private func handleListen(_ body: Data, requestID: String, request: HTTPRequest) -> HTTPResponse {
        guard let filter = Self.notificationFilter(from: body),
              let jsonID = JSONRPCMessageKind.jsonRPCID(inBody: body) else {
            activeRequestIDs.remove(requestID)
            return Self.responsePreservingRequestID(
                .error(statusCode: 400, .invalidParams("subscriptions/listen requires params.notifications")),
                body: body
            )
        }
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        listenStreams[requestID] = continuation
        pendingListenFilters[requestID] = filter
        listenIDs[requestID] = jsonID
        httpRequestContexts[requestID] = request
        continuation.onTermination = { [weak self] _ in
            Task { await self?.listenTerminated(requestID) }
        }
        incomingContinuation.yield(body)
        return .stream(stream, headers: [
            HTTPHeaderName.contentType: ContentType.sse,
            HTTPHeaderName.cacheControl: "no-cache, no-transform",
            HTTPHeaderName.connection: "keep-alive",
        ])
    }

    private func handleProgressRequest(_ body: Data, requestID: String, request: HTTPRequest) -> HTTPResponse {
        guard let token = JSONRPCMessageKind.progressToken(inBody: body) else {
            activeRequestIDs.remove(requestID)
            return .error(statusCode: 400, .invalidParams("Missing progress token"))
        }
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        progressStreams[requestID] = continuation
        progressTokens[requestID] = token
        httpRequestContexts[requestID] = request
        continuation.onTermination = { [weak self] _ in
            Task { await self?.progressTerminated(requestID) }
        }
        incomingContinuation.yield(body)
        return .stream(stream, headers: [
            HTTPHeaderName.contentType: ContentType.sse,
            HTTPHeaderName.cacheControl: "no-cache, no-transform",
            HTTPHeaderName.connection: "keep-alive",
        ])
    }

    private func progressTerminated(_ requestID: String) {
        activeRequestIDs.remove(requestID)
        guard let id = JSONRPCMessageKind.jsonRPCID(inBody: httpRequestContexts[requestID]?.body ?? Data()) else { return }
        progressStreams.removeValue(forKey: requestID)
        progressTokens.removeValue(forKey: requestID)
        httpRequestContexts.removeValue(forKey: requestID)
        if let data = try? JSONEncoder().encode(CancelledNotification.message(.init(requestId: id, reason: "SSE stream closed"))) {
            incomingContinuation.yield(data)
        }
    }

    private func listenTerminated(_ requestID: String) {
        guard let id = listenIDs[requestID] else { return }
        clearListen(requestID)
        if let data = try? JSONEncoder().encode(CancelledNotification.message(.init(requestId: id, reason: "SSE stream closed"))) {
            incomingContinuation.yield(data)
        }
    }

    private func clearListen(_ requestID: String) {
        activeRequestIDs.remove(requestID)
        listenStreams.removeValue(forKey: requestID)
        listenFilters.removeValue(forKey: requestID)
        pendingListenFilters.removeValue(forKey: requestID)
        listenIDs.removeValue(forKey: requestID)
        httpRequestContexts.removeValue(forKey: requestID)
    }

    private static func notificationFilter(from body: Data) -> SubscriptionsListen.NotificationFilter? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let params = object["params"] as? [String: Any],
              let notifications = params["notifications"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: notifications) else { return nil }
        return try? JSONDecoder().decode(SubscriptionsListen.NotificationFilter.self, from: data)
    }

    private static func notification(_ method: String, matches filter: SubscriptionsListen.NotificationFilter, body: Data) -> Bool {
        switch method {
        case "notifications/tools/list_changed": return filter.toolsListChanged == true
        case "notifications/resources/list_changed": return filter.resourcesListChanged == true
        case "notifications/prompts/list_changed": return filter.promptsListChanged == true
        case "notifications/resources/updated":
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let params = object["params"] as? [String: Any],
                  let uri = params["uri"] as? String else { return false }
            return filter.resourceSubscriptions?.contains(uri) == true
        default: return false
        }
    }

    private static func tagged(_ data: Data, subscriptionID: ID) -> Data {
        JSONRPCMessageKind.taggingSubscriptionNotification(data, subscriptionID: subscriptionID)
    }

    // MARK: - HTTPContextProviding

    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        httpRequestContexts[id.transportKey]
    }

    public func closeRequestStream(for id: ID) async {
        let key = id.transportKey
        if let continuation = listenStreams[key] {
            clearListen(key)
            continuation.finish()
        }
        if let continuation = progressStreams.removeValue(forKey: key) {
            activeRequestIDs.remove(key)
            progressTokens.removeValue(forKey: key)
            httpRequestContexts.removeValue(forKey: key)
            continuation.finish()
        }
        if let waiter = responseWaiters.removeValue(forKey: key) {
            activeRequestIDs.remove(key)
            httpRequestContexts.removeValue(forKey: key)
            waiter.resume(throwing: CancellationError())
        }
    }

    // MARK: - Termination

    private func terminate() async {
        guard !terminated else { return }
        terminated = true

        logger.debug("Stateless HTTP server transport terminated")

        // Cancel all waiting continuations
        for (id, continuation) in responseWaiters {
            continuation.resume(throwing: MCPError.connectionClosed)
            logger.debug("Cancelled waiter for request", metadata: ["requestID": "\(id)"])
        }
        responseWaiters.removeAll()
        activeRequestIDs.removeAll()
        for (_, continuation) in listenStreams { continuation.finish() }
        listenStreams.removeAll()
        listenFilters.removeAll()
        pendingListenFilters.removeAll()
        listenIDs.removeAll()
        for (_, continuation) in progressStreams { continuation.finish() }
        progressStreams.removeAll()
        progressTokens.removeAll()
        httpRequestContexts.removeAll()

        // Close incoming stream
        incomingContinuation.finish()
    }
}
