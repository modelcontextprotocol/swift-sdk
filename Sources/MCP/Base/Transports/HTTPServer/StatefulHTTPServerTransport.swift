import Foundation
import Logging

/// A stateful HTTP server transport that manages sessions and uses SSE for streaming responses.
///
/// This transport implements the MCP Streamable HTTP specification with full session management:
/// - Assigns a session ID during initialization (via `Mcp-Session-Id` header)
/// - POST requests receive SSE-streamed responses
/// - GET requests establish a standalone SSE stream for server-initiated messages
///   that are not related to an in-flight request
/// - DELETE requests terminate the session
/// - Built-in event store for resumability (reconnection with `Last-Event-ID`)
///
/// ## Usage
///
/// ```swift
/// let transport = StatefulHTTPServerTransport()  // Uses UUID by default
///
/// // Start the MCP server with this transport
/// try await server.start(transport: transport)
///
/// // In your HTTP framework handler:
/// let response = await transport.handleRequest(httpRequest)
/// // Convert response to your framework's response type and return it
/// ```
///
/// ## Framework Integration
///
/// This transport is framework-agnostic. You provide incoming requests as `HTTPRequest`
/// and receive `HTTPResponse` values to convert to your framework's native types.
/// For SSE responses, the `.stream` case provides an `AsyncThrowingStream<Data, Error>`
/// to pipe to the client.
public actor StatefulHTTPServerTransport: Transport, HTTPContextProviding {
    public nonisolated let logger: Logger

    // MARK: - Dependencies

    private let sessionIDGenerator: any SessionIDGenerator
    private let validationPipeline: any HTTPRequestValidationPipeline
    private let retryInterval: Int?

    // MARK: - State

    private var sessionID: String?
    /// The JSON-RPC id of the `initialize` request that created the session,
    /// until it is answered.
    private var initializeRequestID: String?
    private var terminated = false
    private var started = false

    // MARK: - Incoming message stream (client → server)

    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    // MARK: - SSE streams for POST request responses

    /// Maps request ID → SSE stream continuation for active POST request streams.
    private var requestSSEContinuations: [String: AsyncThrowingStream<Data, Swift.Error>.Continuation] = [:]

    /// Maps request ID → originating HTTP request, surfaced to handlers via
    /// ``Server/currentHTTPContext``. Cleared when the response is routed,
    /// the stream is closed, or the session terminates.
    private var httpRequestContexts: [String: HTTPRequest] = [:]

    /// IDs of client requests that have not been answered yet. Messages
    /// related to one of these are stored on its stream even while the
    /// stream is disconnected, so a resuming client receives them.
    private var openRequestIDs: Set<String> = []

    // MARK: - Standalone GET SSE stream

    /// The standalone SSE stream continuation for server-initiated messages.
    /// Only one GET stream is allowed per session.
    private var standaloneSSEContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?

    /// Internal identifier for the standalone GET stream in the event store.
    private let standaloneStreamID = "_GET_stream"

    /// The generation of each registered SSE stream, by stream ID. A stream
    /// the client disconnects unregisters itself only while it is still the
    /// current one for its ID, so it never removes a stream that replaced it.
    private var streamGenerations: [String: Int] = [:]
    private var streamGenerationCounter = 0

    // MARK: - Event Store (Resumability)

    private struct StoredEvent {
        let streamID: String
        let eventID: String
        let message: Data?
    }

    private var storedEvents: [StoredEvent] = []
    private var eventCounter: Int = 0

    // MARK: - Init

    /// Creates a new stateful HTTP server transport.
    ///
    /// - Parameters:
    ///   - sessionIDGenerator: Generator for session IDs. The IDs MUST contain
    ///     only visible ASCII characters (0x21-0x7E) per the MCP specification.
    ///     Defaults to ``UUIDSessionIDGenerator``.
    ///   - validationPipeline: Custom validation pipeline. If `nil`, uses sensible defaults:
    ///     origin validation (localhost), Accept header (SSE required), Content-Type,
    ///     protocol version, and session validation.
    ///   - retryInterval: Retry interval in milliseconds for SSE priming events.
    ///     Controls how long clients wait before attempting to reconnect.
    ///   - logger: Optional logger. If `nil`, a no-op logger is used.
    public init(
        sessionIDGenerator: any SessionIDGenerator = UUIDSessionIDGenerator(),
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        retryInterval: Int? = nil,
        logger: Logger? = nil
    ) {
        self.sessionIDGenerator = sessionIDGenerator
        self.validationPipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
        self.retryInterval = retryInterval
        self.logger = logger ?? Logger(
            label: "mcp.transport.http.server.stateful",
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
        logger.debug("Stateful HTTP server transport started")
    }

    public func disconnect() async {
        terminate()
    }

    /// Routes outgoing server messages to the appropriate client connection.
    ///
    /// - Responses are routed to the SSE stream matching the response's JSON-RPC ID.
    /// - Notifications and server-initiated requests are routed to the standalone GET stream.
    public func send(_ data: Data) async throws {
        try await send(data, relatedRequestID: nil)
    }

    /// Routes outgoing server messages to the appropriate client connection.
    ///
    /// Notifications and server-initiated requests related to a request that
    /// has not been answered yet go to that request's SSE stream; others go
    /// to the standalone GET stream.
    public func send(_ data: Data, relatedRequestID: ID?) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        guard let kind = JSONRPCMessageKind(data: data) else {
            logger.warning("Could not classify outgoing message for routing")
            return
        }

        switch kind {
        case .response(let id):
            routeResponse(data, requestID: id)
            if id == initializeRequestID {
                initializeRequestID = nil
                // A refused `initialize` (for example by the server's
                // initialize hook) leaves no session behind.
                if JSONRPCMessageFields.errorCode(in: data) != nil {
                    logger.info("Initialization failed; session dropped", metadata: ["sessionID": "\(sessionID ?? "none")"])
                    sessionID = nil
                }
            }
        case .notification, .request:
            if let related = relatedRequestID?.description, openRequestIDs.contains(related) {
                routeToRequestStream(data, requestID: related)
            } else {
                routeServerInitiatedMessage(data)
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    // MARK: - HTTP Request Handler

    /// Handles an incoming HTTP request from the framework adapter.
    ///
    /// Routes by HTTP method:
    /// - **POST**: JSON-RPC messages (requests, notifications)
    /// - **GET**: Establish standalone SSE stream for server-initiated messages
    /// - **DELETE**: Terminate the session
    /// - Others: 405 Method Not Allowed
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if terminated {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Session has been terminated"),
                sessionID: sessionID
            )
        }

        switch request.method.uppercased() {
        case "POST":
            return handlePost(request)
        case "GET":
            return handleGet(request)
        case "DELETE":
            return handleDelete(request)
        default:
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                sessionID: sessionID,
                extraHeaders: [HTTPHeaderName.allow: "GET, POST, DELETE"]
            )
        }
    }

    // MARK: - POST Handler

    private func handlePost(_ request: HTTPRequest) -> HTTPResponse {
        // Parse body first so we can determine if it's an initialization request
        guard let body = request.body, !body.isEmpty else {
            return .error(
                statusCode: 400,
                .parseError("Empty request body"),
                sessionID: sessionID
            )
        }

        guard let messageKind = JSONRPCMessageKind(data: body) else {
            return .error(
                statusCode: 400,
                .parseError("Invalid JSON-RPC message"),
                sessionID: sessionID
            )
        }

        // Requests at 2026-07-28 and later carry no session; this transport
        // serves handshake revisions only, whether the stateless version is
        // in the header or only in `_meta`. They pass the validators that do
        // not depend on a session (origin, media types, authentication), then
        // get -32022, whose data lets the client fall back to `initialize`.
        if case .request(let id, _) = messageKind, !messageKind.isInitializeRequest,
            let version = request.statelessProtocolVersion
                ?? JSONRPCMessageFields.metaProtocolVersion(in: body).flatMap({
                    Version.handshake.contains($0) ? nil : $0
                })
        {
            let sessionless = HTTPValidationContext(
                httpMethod: "POST", sessionID: nil, isInitializationRequest: true,
                supportedProtocolVersions: Version.supported)
            if let errorResponse = validationPipeline.validate(request, context: sessionless) {
                return errorResponse
            }
            // Echo the session ID only to a client that already holds it.
            let knownSession = request.header(HTTPHeaderName.sessionID) == sessionID ? sessionID : nil
            return .error(
                statusCode: 400,
                .unsupportedProtocolVersion(supported: Version.handshake, requested: version),
                id: JSONRPCMessageFields.id(in: body) ?? .string(id),
                sessionID: knownSession
            )
        }

        // Build validation context
        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: sessionID,
            isInitializationRequest: messageKind.isInitializeRequest,
            supportedProtocolVersions: Version.supported
        )

        // Run validation pipeline
        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse
        }

        // Handle initialization request specially
        if messageKind.isInitializeRequest {
            return handleInitializationRequest(body, request: request)
        }

        // Handle by message type
        switch messageKind {
        case .notification(let method):
            if method == CancelledNotification.name,
                let cancelled = JSONRPCMessageKind.cancelledRequestID(in: body)
            {
                releaseCancelledRequest(cancelled)
            }
            incomingContinuation.yield(body)
            return .accepted(headers: sessionHeaders())

        case .response:
            // Yield to server and return 202 Accepted
            incomingContinuation.yield(body)
            return .accepted(headers: sessionHeaders())

        case .request(let id, _):
            return handleJSONRPCRequest(body, requestID: id, request: request)
        }
    }

    private func handleInitializationRequest(_ body: Data, request: HTTPRequest) -> HTTPResponse {
        // Reject re-initialization at the transport level
        if sessionID != nil {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Session already initialized"),
                sessionID: sessionID
            )
        }

        // Generate session ID
        let newSessionID = sessionIDGenerator.generateSessionID()

        // Validate session ID contains only visible ASCII (0x21-0x7E)
        guard isValidSessionID(newSessionID) else {
            logger.error("Generated session ID contains invalid characters")
            return .error(
                statusCode: 500,
                .internalError("Internal error: Invalid session ID generated")
            )
        }

        self.sessionID = newSessionID
        logger.info("Session initialized", metadata: ["sessionID": "\(newSessionID)"])

        // Extract request ID for routing the response
        guard case .request(let requestID, _) = JSONRPCMessageKind(data: body) else {
            return .error(
                statusCode: 400,
                .parseError("Invalid initialize request"),
                sessionID: newSessionID
            )
        }

        // For the initialize request, use SSE streaming like any other request
        initializeRequestID = requestID
        return handleJSONRPCRequest(body, requestID: requestID, request: request)
    }

    private func handleJSONRPCRequest(_ body: Data, requestID: String, request: HTTPRequest) -> HTTPResponse {
        // Create SSE stream for this request
        let (sseStream, sseContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        register(sseContinuation, streamID: requestID)
        httpRequestContexts[requestID] = request
        openRequestIDs.insert(requestID)

        // Extract protocol version for priming event decision
        let protocolVersion = extractProtocolVersion(from: body, request: request)

        // Send priming event for resumability
        sendPrimingEvent(
            streamID: requestID,
            continuation: sseContinuation,
            protocolVersion: protocolVersion
        )

        // Yield the incoming message to the server
        incomingContinuation.yield(body)

        // Build response headers
        var headers = sessionHeaders()
        headers[HTTPHeaderName.contentType] = ContentType.sse
        headers[HTTPHeaderName.cacheControl] = "no-cache, no-transform"
        headers[HTTPHeaderName.connection] = "keep-alive"

        return .stream(sseStream, headers: headers)
    }

    // MARK: - GET Handler

    private func handleGet(_ request: HTTPRequest) -> HTTPResponse {
        // Build validation context (GET is never an initialization request)
        let context = HTTPValidationContext(
            httpMethod: "GET",
            sessionID: sessionID,
            isInitializationRequest: false,
            supportedProtocolVersions: Version.supported
        )

        // Run validation pipeline
        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse
        }

        // Handle resumability: check for Last-Event-ID header
        if let lastEventID = request.header(HTTPHeaderName.lastEventID) {
            return handleResumeRequest(lastEventID: lastEventID, request: request)
        }

        // Only one standalone GET stream per session
        guard standaloneSSEContinuation == nil else {
            return .error(
                statusCode: 409,
                .invalidRequest("Conflict: Only one SSE stream is allowed per session"),
                sessionID: sessionID
            )
        }

        // Create standalone SSE stream
        let (sseStream, sseContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        register(sseContinuation, streamID: standaloneStreamID)

        // Extract protocol version for priming event
        let protocolVersion = request.header(HTTPHeaderName.protocolVersion) ?? Version.latest

        // Send priming event
        sendPrimingEvent(
            streamID: standaloneStreamID,
            continuation: sseContinuation,
            protocolVersion: protocolVersion
        )

        // Build response headers
        var headers = sessionHeaders()
        headers[HTTPHeaderName.contentType] = ContentType.sse
        headers[HTTPHeaderName.cacheControl] = "no-cache, no-transform"
        headers[HTTPHeaderName.connection] = "keep-alive"

        return .stream(sseStream, headers: headers)
    }

    // MARK: - DELETE Handler

    private func handleDelete(_ request: HTTPRequest) -> HTTPResponse {
        // Validate session
        let context = HTTPValidationContext(
            httpMethod: "DELETE",
            sessionID: sessionID,
            isInitializationRequest: false,
            supportedProtocolVersions: Version.supported
        )

        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse
        }

        terminate()

        return .ok(headers: sessionHeaders())
    }

    // MARK: - Stream Registration

    /// Registers `continuation` as the current stream for `streamID` and
    /// unregisters it when the client disconnects. A stream it replaces is
    /// finished: nothing is sent on it any more.
    private func register(
        _ continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation, streamID: String
    ) {
        streamGenerationCounter += 1
        let generation = streamGenerationCounter
        streamGenerations[streamID] = generation
        let replaced: AsyncThrowingStream<Data, Swift.Error>.Continuation?
        if streamID == standaloneStreamID {
            replaced = standaloneSSEContinuation
            standaloneSSEContinuation = continuation
        } else {
            replaced = requestSSEContinuations.updateValue(continuation, forKey: streamID)
        }
        replaced?.finish()
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.streamDisconnected(streamID, generation: generation) }
        }
    }

    /// Forgets a stream the client disconnected. Messages for it are still
    /// stored, so a client that resumes receives them.
    private func streamDisconnected(_ streamID: String, generation: Int) {
        guard streamGenerations[streamID] == generation else { return }
        streamGenerations[streamID] = nil
        if streamID == standaloneStreamID {
            standaloneSSEContinuation = nil
        } else {
            requestSSEContinuations[streamID] = nil
        }
        logger.debug("SSE stream disconnected", metadata: ["streamID": "\(streamID)"])
    }

    /// Releases a request the client cancelled (`notifications/cancelled`).
    /// The server sends no response for it, so nothing else would.
    private func releaseCancelledRequest(_ requestID: String) {
        guard openRequestIDs.remove(requestID) != nil else { return }
        httpRequestContexts.removeValue(forKey: requestID)
        streamGenerations[requestID] = nil
        requestSSEContinuations.removeValue(forKey: requestID)?.finish()
        logger.debug("Released a cancelled request", metadata: ["requestID": "\(requestID)"])
    }

    // MARK: - Message Routing

    /// Routes a message to a specific request's SSE stream without closing it.
    /// Used for server-initiated messages during request handling.
    private func routeToRequestStream(_ data: Data, requestID: String) {
        let eventID = storeEvent(streamID: requestID, message: data)

        guard let continuation = requestSSEContinuations[requestID] else {
            logger.debug(
                "No active stream for request, message stored for replay",
                metadata: ["requestID": "\(requestID)"]
            )
            return
        }

        // Format as SSE and yield (but don't close the stream)
        let sseEvent = SSEEvent.message(data: data, id: eventID)
        continuation.yield(sseEvent.formatted())
    }

    /// Routes a response to a specific request's SSE stream and closes it.
    /// Used for final responses to client requests.
    private func routeResponse(_ data: Data, requestID: String) {
        routeToRequestStream(data, requestID: requestID)
        openRequestIDs.remove(requestID)

        // Response means the request is complete — close the stream
        streamGenerations[requestID] = nil
        if let continuation = requestSSEContinuations[requestID] {
            continuation.finish()
            requestSSEContinuations.removeValue(forKey: requestID)
        }
        httpRequestContexts.removeValue(forKey: requestID)
    }

    private func routeServerInitiatedMessage(_ data: Data) {
        let eventID = storeEvent(streamID: standaloneStreamID, message: data)

        guard let continuation = standaloneSSEContinuation else {
            logger.debug("No standalone GET stream connected, message stored for replay")
            return
        }

        let sseEvent = SSEEvent.message(data: data, id: eventID)
        continuation.yield(sseEvent.formatted())
    }

    // MARK: - Resumability

    private func handleResumeRequest(lastEventID: String, request: HTTPRequest) -> HTTPResponse {
        guard let replay = replayEventsAfter(lastEventID) else {
            return .error(
                statusCode: 400,
                .invalidRequest("Invalid Last-Event-ID"),
                sessionID: sessionID
            )
        }

        let (sseStream, sseContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()

        // Replay stored events
        for (eventID, message) in replay.events {
            let sseEvent = SSEEvent.message(data: message, id: eventID)
            sseContinuation.yield(sseEvent.formatted())
        }

        // A request stream whose request is answered or cancelled has
        // nothing more to send: replay it and close it.
        if replay.streamID != standaloneStreamID, !openRequestIDs.contains(replay.streamID) {
            sseContinuation.finish()
            var headers = sessionHeaders()
            headers[HTTPHeaderName.contentType] = ContentType.sse
            headers[HTTPHeaderName.cacheControl] = "no-cache, no-transform"
            return .stream(sseStream, headers: headers)
        }

        // Re-register the stream for future messages
        register(sseContinuation, streamID: replay.streamID)

        // Send a new priming event so the client can resume again if disconnected
        let protocolVersion = request.header(HTTPHeaderName.protocolVersion) ?? Version.latest
        sendPrimingEvent(
            streamID: replay.streamID,
            continuation: sseContinuation,
            protocolVersion: protocolVersion
        )

        var headers = sessionHeaders()
        headers[HTTPHeaderName.contentType] = ContentType.sse
        headers[HTTPHeaderName.cacheControl] = "no-cache, no-transform"
        headers[HTTPHeaderName.connection] = "keep-alive"

        return .stream(sseStream, headers: headers)
    }

    // MARK: - Internal Event Store

    private func storeEvent(streamID: String, message: Data?) -> String {
        eventCounter += 1
        let eventID = "\(streamID)_\(eventCounter)"
        storedEvents.append(StoredEvent(streamID: streamID, eventID: eventID, message: message))
        return eventID
    }

    private func replayEventsAfter(_ lastEventID: String) -> (streamID: String, events: [(eventID: String, message: Data)])? {
        guard let index = storedEvents.firstIndex(where: { $0.eventID == lastEventID }) else {
            return nil
        }
        let streamID = storedEvents[index].streamID
        let eventsToReplay = storedEvents[(index + 1)...]
            .filter { $0.streamID == streamID && $0.message != nil }
            .map { (eventID: $0.eventID, message: $0.message!) }
        return (streamID, eventsToReplay)
    }

    // MARK: - SSE Helpers

    private func sendPrimingEvent(
        streamID: String,
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation,
        protocolVersion: String
    ) {
        guard Version.profile(for: protocolVersion).allowsPrimingEvents else { return }

        let primingEventID = storeEvent(streamID: streamID, message: nil)
        let primingEvent = SSEEvent.priming(id: primingEventID, retry: retryInterval)
        continuation.yield(primingEvent.formatted())
    }

    private func extractProtocolVersion(from body: Data, request: HTTPRequest) -> String {
        // For initialize requests, extract from the request body params
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let method = json["method"] as? String, method == "initialize",
           let params = json["params"] as? [String: Any],
           let version = params["protocolVersion"] as? String
        {
            // The revision the session is negotiated to, but a client asking
            // for an older one than any served keeps its own.
            return min(version, Version.negotiate(clientRequestedVersion: version))
        }
        // For other requests, use the header
        return request.header(HTTPHeaderName.protocolVersion) ?? Version.latest
    }

    // MARK: - Session Helpers

    private func sessionHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let sessionID {
            headers[HTTPHeaderName.sessionID] = sessionID
        }
        return headers
    }

    private func isValidSessionID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return id.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    // MARK: - Stream Control

    /// Closes the SSE stream for a specific request without sending a response.
    ///
    /// Used to trigger client reconnection mid-call (SEP-1699). The response,
    /// when eventually sent, will be stored and replayed to the reconnected stream.
    package func closeSSEStream(forRequestID requestID: String) {
        guard let continuation = requestSSEContinuations[requestID] else { return }
        streamGenerations[requestID] = nil
        continuation.finish()
        requestSSEContinuations.removeValue(forKey: requestID)
        httpRequestContexts.removeValue(forKey: requestID)
    }

    // MARK: - HTTPContextProviding

    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        httpRequestContexts[id.description]
    }

    // MARK: - Termination

    /// Terminates the session, closing all active streams.
    /// After termination, all requests receive 404 Not Found.
    private func terminate() {
        guard !terminated else { return }
        terminated = true

        logger.info("Terminating session", metadata: ["sessionID": "\(sessionID ?? "none")"])

        // Close all request SSE streams
        for (_, continuation) in requestSSEContinuations {
            continuation.finish()
        }
        requestSSEContinuations.removeAll()
        httpRequestContexts.removeAll()
        openRequestIDs.removeAll()
        streamGenerations.removeAll()

        // Close standalone GET stream
        standaloneSSEContinuation?.finish()
        standaloneSSEContinuation = nil

        // Clear stored events
        storedEvents.removeAll()

        // Close incoming stream
        incomingContinuation.finish()
    }
}
