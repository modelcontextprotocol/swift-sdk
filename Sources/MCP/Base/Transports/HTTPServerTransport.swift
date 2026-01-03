import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal stream state for managing SSE connections
private struct StreamState: Sendable {
    /// Continuation for pushing SSE data
    let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Cleanup function to close stream and remove mapping
    let cleanup: @Sendable () -> Void
}

/// Internal stream state for JSON response mode
private struct JsonStreamState: Sendable {
    /// Continuation for yielding the HTTP response
    let continuation: AsyncThrowingStream<HTTPResponse, Swift.Error>.Continuation
}

/// Server transport for Streamable HTTP: implements the MCP Streamable HTTP transport specification.
///
/// This transport can be integrated with any HTTP server framework (Hummingbird, Vapor, etc.)
/// by passing incoming requests to `handleRequest`.
///
/// Usage example:
/// ```swift
/// // Stateful mode - server manages session IDs
/// let transport = HTTPServerTransport(
///     options: .init(
///         sessionIdGenerator: { UUID().uuidString },
///         onSessionInitialized: { sessionId in
///             await sessions.store(sessionId, transport: transport)
///         },
///         onSessionClosed: { sessionId in
///             await sessions.remove(sessionId)
///         }
///     )
/// )
///
/// // Stateless mode
/// let statelessTransport = HTTPServerTransport()
///
/// // In your HTTP handler:
/// let response = try await transport.handleRequest(httpRequest)
/// ```
///
/// In stateful mode:
/// - Session ID is generated and included in response headers
/// - Requests with invalid session IDs are rejected with 404 Not Found
/// - Non-initialization requests without a session ID are rejected with 400 Bad Request
///
/// In stateless mode:
/// - No Session ID is included in responses
/// - No session validation is performed
public actor HTTPServerTransport: Transport {
    /// Logger for transport events
    public nonisolated let logger: Logger

    /// The session ID for this transport (nil in stateless mode)
    public private(set) var sessionId: String?

    /// Whether this transport has been initialized
    private var initialized = false

    /// Whether this session has been terminated (via DELETE)
    private var terminated = false

    /// Whether the transport has been started
    private var started = false

    /// The negotiated protocol version, set after initialization
    private var negotiatedProtocolVersion: String?

    // Configuration
    private let options: HTTPServerTransportOptions

    // Stream multiplexing (matching TypeScript's three maps pattern)
    private var streamMapping: [String: StreamState] = [:]
    private var jsonStreamMapping: [String: JsonStreamState] = [:]
    private var requestToStreamMapping: [RequestId: String] = [:]
    private var requestResponseMap: [RequestId: Data] = [:]

    // Standalone SSE stream ID for GET requests
    private let standaloneSseStreamId = "_GET_stream"

    // Server receive stream (messages from HTTP clients go here)
    private let serverStream: AsyncThrowingStream<Data, Swift.Error>
    private let serverContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Closure called when the transport is closed
    public var onClose: (@Sendable () async -> Void)?

    /// Creates a new HTTPServerTransport.
    ///
    /// - Parameters:
    ///   - options: Transport configuration options
    ///   - logger: Optional logger instance
    public init(
        options: HTTPServerTransportOptions = .init(),
        logger: Logger? = nil
    ) {
        self.options = options
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.http.server",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )

        // Create server receive stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.serverStream = AsyncThrowingStream { continuation = $0 }
        self.serverContinuation = continuation
    }

    // MARK: - Transport Protocol

    /// Starts the transport.
    /// This is required by the Transport interface but is a no-op for HTTP transports
    /// as connections are managed per-request.
    public func connect() async throws {
        guard !started else {
            throw MCPError.internalError("Transport already started")
        }
        started = true
    }

    /// Disconnects and closes the transport.
    public func disconnect() async {
        await close()
    }

    /// Sends data to the appropriate client connection.
    ///
    /// For responses, the request ID is extracted from the message.
    /// For notifications during tool execution, use `send(_:relatedRequestId:)`.
    public func send(_ data: Data) async throws {
        try await send(data, relatedRequestId: nil)
    }

    /// Sends data with an optional related request ID for response routing.
    ///
    /// - Parameters:
    ///   - data: The data to send
    ///   - relatedRequestId: The ID of the request this message relates to
    public func send(_ data: Data, relatedRequestId: RequestId?) async throws {
        var requestId = relatedRequestId

        // For responses, extract the ID from the message
        if requestId == nil {
            requestId = extractResponseId(from: data)
        }

        // If no request ID, send to standalone SSE stream
        if requestId == nil {
            // Generate and store event ID if event store is provided
            var eventId: String?
            if let eventStore = options.eventStore {
                eventId = try await eventStore.storeEvent(streamId: standaloneSseStreamId, message: data)
            }

            if let streamState = streamMapping[standaloneSseStreamId] {
                let sseData = formatSSEEvent(data: data, eventId: eventId)
                streamState.continuation.yield(sseData)
            }
            return
        }

        guard let requestId = requestId else { return }

        // Get the stream for this request
        guard let streamId = requestToStreamMapping[requestId] else {
            logger.debug("No stream found for request \(requestId) - client may have disconnected")
            return
        }

        // Check if using JSON response mode
        if let jsonState = jsonStreamMapping[streamId] {
            // Store the response
            requestResponseMap[requestId] = data
            try await checkBatchCompletion(streamId: streamId, jsonState: jsonState)
            return
        }

        // SSE streaming mode
        if let streamState = streamMapping[streamId] {
            // Generate event ID if event store is provided
            var eventId: String?
            if let eventStore = options.eventStore {
                eventId = try await eventStore.storeEvent(streamId: streamId, message: data)
            }

            let sseData = formatSSEEvent(data: data, eventId: eventId)
            streamState.continuation.yield(sseData)

            // Track response for batch completion
            let isResponse = isJSONRPCResponse(data)
            if isResponse {
                requestResponseMap[requestId] = data
                try await checkStreamCompletion(streamId: streamId)
            }
        }
    }

    /// Returns the stream of messages from HTTP clients.
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return serverStream
    }

    // MARK: - HTTP Request Handling

    /// Handles an incoming HTTP request.
    ///
    /// This method routes the request based on HTTP method:
    /// - POST: Handle JSON-RPC messages
    /// - GET: Establish SSE stream for server-initiated notifications
    /// - DELETE: Terminate the session
    ///
    /// - Parameter request: The incoming HTTP request
    /// - Returns: An HTTP response
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Check if transport has been terminated (applies to all modes)
        // Per spec: server MUST respond to requests after termination with 404 Not Found
        if terminated {
            return createJsonErrorResponse(
                status: 404,
                code: ErrorCode.connectionClosed,
                message: "Session has been terminated"
            )
        }

        // Validate security headers (DNS rebinding protection)
        if let error = validateSecurityHeaders(request) {
            return error
        }

        switch request.method.uppercased() {
        case "POST":
            return await handlePostRequest(request)
        case "GET":
            return await handleGetRequest(request)
        case "DELETE":
            return await handleDeleteRequest(request)
        default:
            return createJsonErrorResponse(
                status: 405,
                code: ErrorCode.connectionClosed,
                message: "Method not allowed",
                extraHeaders: [HTTPHeader.allow: "GET, POST, DELETE"]
            )
        }
    }

    // MARK: - POST Request Handling

    private func handlePostRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Validate Accept header
        // Per spec: Client must accept both application/json and text/event-stream for SSE mode.
        // However, when JSON response mode is enabled, only application/json is required.
        let acceptHeader = request.header(HTTPHeader.accept) ?? ""
        if options.enableJsonResponse {
            // JSON response mode only requires application/json
            guard acceptHeader.contains("application/json") else {
                return createJsonErrorResponse(
                    status: 406,
                    code: ErrorCode.connectionClosed,
                    message: "Not Acceptable: Client must accept application/json"
                )
            }
        } else {
            // SSE mode requires both content types
            guard acceptHeader.contains("application/json") && acceptHeader.contains("text/event-stream") else {
                return createJsonErrorResponse(
                    status: 406,
                    code: ErrorCode.connectionClosed,
                    message: "Not Acceptable: Client must accept both application/json and text/event-stream"
                )
            }
        }

        // Validate Content-Type
        let contentType = request.header(HTTPHeader.contentType) ?? ""
        guard contentType.contains("application/json") else {
            return createJsonErrorResponse(
                status: 415,
                code: ErrorCode.connectionClosed,
                message: "Unsupported Media Type: Content-Type must be application/json"
            )
        }

        // Parse the request body
        guard let body = request.body, !body.isEmpty else {
            return createJsonErrorResponse(
                status: 400,
                code: ErrorCode.parseError,
                message: "Parse error: Empty request body"
            )
        }

        // Try to parse as JSON-RPC message(s)
        let messages: [[String: Any]]
        do {
            if let parsed = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] {
                messages = parsed
            } else if let single = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                messages = [single]
            } else {
                return createJsonErrorResponse(
                    status: 400,
                    code: ErrorCode.parseError,
                    message: "Parse error: Invalid JSON-RPC message"
                )
            }
        } catch {
            return createJsonErrorResponse(
                status: 400,
                code: ErrorCode.parseError,
                message: "Parse error: Invalid JSON"
            )
        }

        // Validate JSON-RPC format - all messages must have "jsonrpc": "2.0"
        for message in messages {
            guard let jsonrpc = message["jsonrpc"] as? String, jsonrpc == "2.0" else {
                return createJsonErrorResponse(
                    status: 400,
                    code: ErrorCode.invalidRequest,
                    message: "Invalid Request: Missing or invalid jsonrpc version"
                )
            }
        }

        // Check for initialization request
        let isInitializationRequest = messages.contains { isInitializeRequest($0) }

        // Check for batch requests (protocol version conditional)
        let isBatchRequest = messages.count > 1

        if isInitializationRequest {
            // Check if already initialized in stateful mode
            if initialized && sessionId != nil {
                return createJsonErrorResponse(
                    status: 400,
                    code: ErrorCode.invalidRequest,
                    message: "Invalid Request: Server already initialized"
                )
            }

            // Only one initialize request allowed
            if isBatchRequest {
                return createJsonErrorResponse(
                    status: 400,
                    code: ErrorCode.invalidRequest,
                    message: "Invalid Request: Only one initialization request is allowed"
                )
            }

            // Extract and store the protocol version from the initialize request
            let clientProtocolVersion = extractProtocolVersionFromInitialize(messages)
            negotiatedProtocolVersion = clientProtocolVersion

            // Generate session ID if in stateful mode
            if let generator = options.sessionIdGenerator {
                let generatedId = generator()

                // Validate session ID per spec: must be visible ASCII (0x21-0x7E)
                if !isValidSessionId(generatedId) {
                    logger.error(
                        "Generated session ID contains invalid characters",
                        metadata: ["sessionId": "\(generatedId)"]
                    )
                    return createJsonErrorResponse(
                        status: 500,
                        code: ErrorCode.connectionClosed,
                        message: "Internal error: Invalid session ID generated"
                    )
                }

                sessionId = generatedId
                initialized = true

                // Fire session initialized callback BEFORE dispatching to server
                if let sessionId, let callback = options.onSessionInitialized {
                    await callback(sessionId)
                }
            } else {
                initialized = true
            }
        } else {
            // Validate session for non-initialization requests
            if let error = validateSession(request) {
                return error
            }

            // Validate protocol version
            if let error = validateProtocolVersion(request) {
                return error
            }

            // Reject batch requests for protocol version >= 2025-06-18
            // Batching was removed from the spec starting with 2025-06-18
            if isBatchRequest {
                let protocolVersion = request.header(HTTPHeader.protocolVersion) ?? Version.defaultNegotiated
                if protocolVersion >= Version.v2025_06_18 {
                    return createJsonErrorResponse(
                        status: 400,
                        code: ErrorCode.invalidRequest,
                        message: "Invalid Request: Batch requests not supported in protocol version \(protocolVersion)"
                    )
                }
            }
        }

        // Check if messages contain any requests (vs just notifications)
        let hasRequests = messages.contains { isJSONRPCRequest($0) }

        if !hasRequests {
            // Only notifications - yield to server and return 202
            serverContinuation.yield(body)
            return HTTPResponse(statusCode: 202, headers: sessionHeaders())
        }

        // Extract request IDs
        let requestIds = extractRequestIds(from: messages)
        let streamId = UUID().uuidString

        // Map request IDs to this stream
        for id in requestIds {
            requestToStreamMapping[id] = streamId
        }

        // Check if using JSON response mode
        if options.enableJsonResponse {
            return await handleJsonResponseMode(streamId: streamId, requestIds: requestIds, body: body)
        }

        // SSE streaming mode
        return await handleSSEStreamingMode(
            streamId: streamId,
            requestIds: requestIds,
            body: body,
            request: request,
            messages: messages
        )
    }

    private func handleJsonResponseMode(
        streamId: String,
        requestIds: [RequestId],
        body: Data
    ) async -> HTTPResponse {
        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<HTTPResponse, Swift.Error>.makeStream()

        let state = JsonStreamState(continuation: continuation)
        jsonStreamMapping[streamId] = state

        // Yield the message to the server
        serverContinuation.yield(body)

        // Wait for response - this is cancellation-aware unlike withCheckedContinuation
        do {
            for try await response in stream {
                return response
            }
        } catch {
            // Stream was finished with error (e.g., transport closed)
            logger.debug("JSON response stream ended with error: \(error)")
        }

        // Stream closed without yielding a response - return error
        return createJsonErrorResponse(
            status: 503,
            code: ErrorCode.connectionClosed,
            message: "Service Unavailable: No response received"
        )
    }

    private func handleSSEStreamingMode(
        streamId: String,
        requestIds: [RequestId],
        body: Data,
        request: HTTPRequest,
        messages: [[String: Any]]
    ) async -> HTTPResponse {
        let (stream, streamContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()

        // Clean up mapping when stream terminates (e.g., client disconnect)
        streamContinuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cleanUpStreamMapping(for: streamId) }
        }

        let cleanup: @Sendable () -> Void = {
            streamContinuation.finish()
        }

        let state = StreamState(
            continuation: streamContinuation,
            cleanup: cleanup
        )

        streamMapping[streamId] = state

        // Use negotiated protocol version if available, otherwise extract from request
        let protocolVersion = negotiatedProtocolVersion ?? extractProtocolVersion(from: messages, request: request)

        // Write priming event if appropriate
        await writePrimingEvent(streamId: streamId, continuation: streamContinuation, protocolVersion: protocolVersion)

        // Yield the message to the server
        serverContinuation.yield(body)

        var headers = sessionHeaders()
        headers[HTTPHeader.contentType] = "text/event-stream"
        headers[HTTPHeader.cacheControl] = "no-cache, no-transform"
        headers[HTTPHeader.connection] = "keep-alive"

        return HTTPResponse(statusCode: 200, headers: headers, stream: stream)
    }

    // MARK: - GET Request Handling

    private func handleGetRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Validate Accept header
        let acceptHeader = request.header(HTTPHeader.accept) ?? ""
        guard acceptHeader.contains("text/event-stream") else {
            return createJsonErrorResponse(
                status: 406,
                code: ErrorCode.connectionClosed,
                message: "Not Acceptable: Client must accept text/event-stream"
            )
        }

        // Validate session
        if let error = validateSession(request) {
            return error
        }

        // Validate protocol version
        if let error = validateProtocolVersion(request) {
            return error
        }

        // Handle resumability
        if let eventStore = options.eventStore,
            let lastEventId = request.header(HTTPHeader.lastEventId)
        {
            return await replayEvents(lastEventId: lastEventId, eventStore: eventStore, request: request)
        }

        // Check if there's already an active standalone SSE stream
        if streamMapping[standaloneSseStreamId] != nil {
            return createJsonErrorResponse(
                status: 409,
                code: ErrorCode.connectionClosed,
                message: "Conflict: Only one SSE stream is allowed per session"
            )
        }

        let (stream, streamContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()

        // Clean up mapping when stream terminates (e.g., client disconnect)
        let streamId = standaloneSseStreamId
        streamContinuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cleanUpStreamMapping(for: streamId) }
        }

        let cleanup: @Sendable () -> Void = {
            streamContinuation.finish()
        }

        streamMapping[standaloneSseStreamId] = StreamState(
            continuation: streamContinuation,
            cleanup: cleanup
        )

        // Write priming event for resumability (use negotiated version or header)
        let protocolVersion = negotiatedProtocolVersion ?? request.header(HTTPHeader.protocolVersion) ?? Version.defaultNegotiated
        await writePrimingEvent(streamId: standaloneSseStreamId, continuation: streamContinuation, protocolVersion: protocolVersion)

        var headers = sessionHeaders()
        headers[HTTPHeader.contentType] = "text/event-stream"
        headers[HTTPHeader.cacheControl] = "no-cache, no-transform"
        headers[HTTPHeader.connection] = "keep-alive"

        return HTTPResponse(statusCode: 200, headers: headers, stream: stream)
    }

    // MARK: - DELETE Request Handling

    private func handleDeleteRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // DELETE is only valid in stateful mode (when session management is enabled)
        // In stateless mode, there's no session to terminate
        guard options.sessionIdGenerator != nil else {
            return createJsonErrorResponse(
                status: 405,
                code: ErrorCode.connectionClosed,
                message: "Method Not Allowed: Session management is not enabled",
                extraHeaders: [HTTPHeader.allow: "GET, POST"]
            )
        }

        // Validate session
        if let error = validateSession(request) {
            return error
        }

        // Validate protocol version
        if let error = validateProtocolVersion(request) {
            return error
        }

        // Fire session closed callback
        if let sessionId, let callback = options.onSessionClosed {
            await callback(sessionId)
        }

        await close()

        return HTTPResponse(statusCode: 200, headers: sessionHeaders())
    }

    // MARK: - Close

    /// Closes the transport and all active streams.
    public func close() async {
        // Mark session as terminated so subsequent requests are rejected with 404
        terminated = true

        // Close all SSE streams and remove mappings synchronously
        for (streamId, state) in streamMapping {
            state.cleanup()
            streamMapping.removeValue(forKey: streamId)
        }

        // Finish all pending JSON response streams.
        // The for-await loop in handleJsonResponseMode will exit and return a 503 error.
        for (streamId, state) in jsonStreamMapping {
            state.continuation.finish()
            jsonStreamMapping.removeValue(forKey: streamId)
        }

        // Clear request mappings
        requestToStreamMapping.removeAll()
        requestResponseMap.removeAll()

        // Finish the server stream
        serverContinuation.finish()

        await onClose?()
    }

    // MARK: - Stream Control

    /// Closes an SSE stream for a specific request, triggering client reconnection.
    ///
    /// Use this to implement polling behavior during long-running operations -
    /// the client will reconnect after the retry interval specified in the priming event.
    ///
    /// - Parameter requestId: The ID of the request whose stream should be closed
    public func closeSSEStream(for requestId: RequestId) {
        guard let streamId = requestToStreamMapping[requestId] else { return }

        if let stream = streamMapping.removeValue(forKey: streamId) {
            stream.cleanup()
        }
    }

    /// Closes the standalone GET SSE stream, triggering client reconnection.
    ///
    /// Use this to implement polling behavior for server-initiated notifications.
    public func closeStandaloneSSEStream() {
        if let stream = streamMapping.removeValue(forKey: standaloneSseStreamId) {
            stream.cleanup()
        }
    }

    /// Removes a stream from the mapping without calling cleanup.
    /// Used by onTermination handlers when the stream has already terminated.
    private func cleanUpStreamMapping(for streamId: String) {
        streamMapping.removeValue(forKey: streamId)
    }

    // MARK: - Helper Methods

    private func sessionHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let sessionId {
            headers[HTTPHeader.sessionId] = sessionId
        }
        return headers
    }

    // MARK: - Security Validation

    /// Validates Host and Origin headers for DNS rebinding protection.
    ///
    /// DNS rebinding attacks allow malicious websites to bypass browser same-origin policy
    /// by manipulating DNS responses. This is particularly dangerous for localhost servers
    /// as browsers may allow requests from attacker-controlled pages to local services.
    private func validateSecurityHeaders(_ request: HTTPRequest) -> HTTPResponse? {
        guard let security = options.security,
            security.enableDnsRebindingProtection
        else {
            return nil
        }

        // Validate Host header (required when protection is enabled)
        let hostHeader = request.header(HTTPHeader.host)
        if hostHeader == nil {
            logger.warning("DNS rebinding protection: Missing Host header")
            // Use 421 Misdirected Request for Host header issues
            return createJsonErrorResponse(
                status: 421,
                code: ErrorCode.connectionClosed,
                message: "Misdirected Request: Missing Host header"
            )
        }

        let hostMatches = security.allowedHosts.contains { pattern in
            matchesHostPattern(hostHeader!, pattern: pattern)
        }

        if !hostMatches {
            logger.warning(
                "DNS rebinding protection: Host header rejected",
                metadata: ["host": "\(hostHeader!)"]
            )
            // Use 421 Misdirected Request for Host header issues
            return createJsonErrorResponse(
                status: 421,
                code: ErrorCode.connectionClosed,
                message: "Misdirected Request: Host header not allowed"
            )
        }

        // Validate Origin header (only if present - non-browser clients won't send it)
        if let originHeader = request.header(HTTPHeader.origin) {
            let originMatches = security.allowedOrigins.contains { pattern in
                matchesOriginPattern(originHeader, pattern: pattern)
            }

            if !originMatches {
                logger.warning(
                    "DNS rebinding protection: Origin header rejected",
                    metadata: ["origin": "\(originHeader)"]
                )
                return createJsonErrorResponse(
                    status: 403,
                    code: ErrorCode.connectionClosed,
                    message: "Forbidden: Origin not allowed"
                )
            }
        }

        return nil
    }

    /// Matches a host value against a pattern that may contain port wildcards.
    ///
    /// Patterns like "localhost:*" match "localhost:8080", "localhost:3000", etc.
    private func matchesHostPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasSuffix(":*") {
            let patternHost = String(pattern.dropLast(2))  // Remove ":*"
            // Host must start with pattern host and have a port
            if host.hasPrefix(patternHost + ":") {
                let portPart = host.dropFirst(patternHost.count + 1)
                // Verify the rest is a valid port (digits only)
                return !portPart.isEmpty && portPart.allSatisfy { $0.isNumber }
            }
            return false
        }
        // Exact match
        return host == pattern
    }

    /// Matches an origin value against a pattern that may contain port wildcards.
    ///
    /// Patterns like "http://localhost:*" match "http://localhost:8080", etc.
    private func matchesOriginPattern(_ origin: String, pattern: String) -> Bool {
        if pattern.hasSuffix(":*") {
            let patternPrefix = String(pattern.dropLast(2))  // Remove ":*"
            // Origin must start with pattern prefix and have a port
            if origin.hasPrefix(patternPrefix + ":") {
                let portPart = origin.dropFirst(patternPrefix.count + 1)
                // Verify the rest is a valid port (digits only, possibly followed by path)
                let portString = portPart.prefix(while: { $0.isNumber })
                return !portString.isEmpty
            }
            return false
        }
        // Exact match or origin is prefix (origin may have trailing path)
        return origin == pattern || origin.hasPrefix(pattern + "/")
    }

    // MARK: - Session Validation

    private func validateSession(_ request: HTTPRequest) -> HTTPResponse? {
        // Check initialization status first - applies to BOTH stateful and stateless modes
        // Per MCP spec, clients should not send requests before initialization
        guard initialized else {
            return createJsonErrorResponse(
                status: 400,
                code: ErrorCode.connectionClosed,
                message: "Bad Request: Server not initialized"
            )
        }

        // If no session ID generator, we're in stateless mode - skip session ID validation
        guard options.sessionIdGenerator != nil else {
            return nil
        }

        // If session was terminated (via DELETE), reject with 404
        if terminated {
            return createJsonErrorResponse(
                status: 404,
                code: ErrorCode.connectionClosed,
                message: "Session has been terminated"
            )
        }

        let requestSessionId = request.header(HTTPHeader.sessionId)

        // Non-initialization requests must include session ID
        guard let requestSessionId else {
            return createJsonErrorResponse(
                status: 400,
                code: ErrorCode.connectionClosed,
                message: "Bad Request: \(HTTPHeader.sessionId) header is required"
            )
        }

        // Session ID must match
        guard requestSessionId == sessionId else {
            return createJsonErrorResponse(
                status: 404,
                code: ErrorCode.connectionClosed,
                message: "Session not found"
            )
        }

        return nil
    }

    /// Supported protocol versions for header validation.
    /// This is more lenient than Version.supported - it accepts headers from clients
    /// even if we don't fully implement all features of that version yet.
    private static let supportedProtocolVersions = [
        Version.v2024_11_05,
        Version.v2025_03_26,
        Version.v2025_06_18,
        Version.v2025_11_25,
    ]

    private func validateProtocolVersion(_ request: HTTPRequest) -> HTTPResponse? {
        let protocolVersion = request.header(HTTPHeader.protocolVersion)

        // If header is present, validate it
        if let version = protocolVersion {
            guard Self.supportedProtocolVersions.contains(version) else {
                return createJsonErrorResponse(
                    status: 400,
                    code: ErrorCode.connectionClosed,
                    message:
                        "Bad Request: Unsupported protocol version: \(version) (supported: \(Self.supportedProtocolVersions.joined(separator: ", ")))"
                )
            }
        }

        return nil
    }

    private func isInitializeRequest(_ message: [String: Any]) -> Bool {
        guard let method = message["method"] as? String else { return false }
        return method == "initialize"
    }

    /// Validates that a session ID contains only visible ASCII characters (0x21-0x7E).
    ///
    /// Per MCP spec: "Session IDs MUST be visible ASCII characters only."
    /// This range includes printable characters from '!' (0x21) to '~' (0x7E),
    /// excluding space (0x20) and control characters.
    private func isValidSessionId(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return sessionId.utf8.allSatisfy { byte in
            byte >= 0x21 && byte <= 0x7E
        }
    }

    /// Extracts the protocol version from an initialize request's params.
    private func extractProtocolVersionFromInitialize(_ messages: [[String: Any]]) -> String {
        for message in messages where isInitializeRequest(message) {
            if let params = message["params"] as? [String: Any],
                let version = params["protocolVersion"] as? String
            {
                return version
            }
        }
        return Version.defaultNegotiated  // Default per spec
    }

    private func isJSONRPCRequest(_ message: [String: Any]) -> Bool {
        return message["method"] != nil && message["id"] != nil
    }

    private func isJSONRPCResponse(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["result"] != nil || json["error"] != nil
    }

    private func extractRequestIds(from messages: [[String: Any]]) -> [RequestId] {
        var ids: [RequestId] = []
        for message in messages {
            guard message["method"] != nil else { continue }
            if let stringId = message["id"] as? String {
                ids.append(.string(stringId))
            } else if let intId = message["id"] as? Int {
                ids.append(.number(intId))
            }
        }
        return ids
    }

    private func extractResponseId(from data: Data) -> RequestId? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Check if it's a response (has result or error)
        guard json["result"] != nil || json["error"] != nil else {
            return nil
        }

        if let stringId = json["id"] as? String {
            return .string(stringId)
        } else if let intId = json["id"] as? Int {
            return .number(intId)
        }
        return nil
    }

    private func extractProtocolVersion(from messages: [[String: Any]], request: HTTPRequest) -> String {
        // For initialize requests, get from request params
        for message in messages where isInitializeRequest(message) {
            if let params = message["params"] as? [String: Any],
                let version = params["protocolVersion"] as? String
            {
                return version
            }
        }

        // For other requests, get from header
        return request.header(HTTPHeader.protocolVersion) ?? Version.defaultNegotiated
    }

    private func formatSSEEvent(data: Data, eventId: String?) -> Data {
        Self.formatSSEEventStatic(data: data, eventId: eventId)
    }

    /// Static version of formatSSEEvent for use in Sendable closures
    private static func formatSSEEventStatic(data: Data, eventId: String?) -> Data {
        var event = "event: message\n"
        if let eventId {
            event += "id: \(eventId)\n"
        }
        if let jsonString = String(data: data, encoding: .utf8) {
            event += "data: \(jsonString)\n\n"
        }
        return Data(event.utf8)
    }

    private func writePrimingEvent(
        streamId: String,
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation,
        protocolVersion: String
    ) async {
        // Only write priming events if event store is configured
        guard let eventStore = options.eventStore else { return }

        // Priming events have empty data which older clients cannot handle
        // Only send to clients with protocol version >= 2025-11-25
        guard protocolVersion >= Version.v2025_11_25 else { return }

        do {
            let primingEventId = try await eventStore.storeEvent(streamId: streamId, message: Data())

            var primingEvent = "id: \(primingEventId)\n"
            if let retryInterval = options.retryInterval {
                primingEvent += "retry: \(retryInterval)\n"
            }
            primingEvent += "data: \n\n"

            continuation.yield(Data(primingEvent.utf8))
        } catch {
            logger.error("Failed to write priming event: \(error)")
        }
    }

    private func replayEvents(lastEventId: String, eventStore: EventStore, request: HTTPRequest) async -> HTTPResponse {
        // Get stream ID for this event
        guard let streamId = await eventStore.streamIdForEventId(lastEventId) else {
            return createJsonErrorResponse(
                status: 400,
                code: ErrorCode.connectionClosed,
                message: "Invalid event ID format"
            )
        }

        // Check for conflict
        if streamMapping[streamId] != nil {
            return createJsonErrorResponse(
                status: 409,
                code: ErrorCode.connectionClosed,
                message: "Conflict: Stream already has an active connection"
            )
        }

        let (stream, streamContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()

        // Capture continuation by value for Sendable closure
        let capturedContinuation = streamContinuation

        do {
            // Replay events - use static method for SSE formatting
            let replayedStreamId = try await eventStore.replayEventsAfter(lastEventId) { eventId, message in
                let sseData = Self.formatSSEEventStatic(data: message, eventId: eventId)
                capturedContinuation.yield(sseData)
            }

            // Clean up mapping when stream terminates (e.g., client disconnect)
            streamContinuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.cleanUpStreamMapping(for: replayedStreamId) }
            }

            let cleanup: @Sendable () -> Void = {
                capturedContinuation.finish()
            }

            streamMapping[replayedStreamId] = StreamState(
                continuation: streamContinuation,
                cleanup: cleanup
            )

            // Write a new priming event after replay so clients can resume again
            // if they disconnect during this stream. Use the replayed stream ID.
            let protocolVersion = negotiatedProtocolVersion ?? request.header(HTTPHeader.protocolVersion) ?? Version.defaultNegotiated
            await writePrimingEvent(streamId: replayedStreamId, continuation: streamContinuation, protocolVersion: protocolVersion)

            var headers = sessionHeaders()
            headers[HTTPHeader.contentType] = "text/event-stream"
            headers[HTTPHeader.cacheControl] = "no-cache, no-transform"
            headers[HTTPHeader.connection] = "keep-alive"

            return HTTPResponse(statusCode: 200, headers: headers, stream: stream)
        } catch {
            logger.error("Error replaying events: \(error)")
            streamContinuation.finish()
            return createJsonErrorResponse(
                status: 500,
                code: ErrorCode.connectionClosed,
                message: "Error replaying events"
            )
        }
    }

    private func checkBatchCompletion(streamId: String, jsonState: JsonStreamState) async throws {
        // Find all request IDs using this stream
        let relatedIds = requestToStreamMapping.filter { $0.value == streamId }.map { $0.key }

        // Check if all requests have responses
        let allComplete = relatedIds.allSatisfy { requestResponseMap[$0] != nil }

        guard allComplete else { return }

        // Gather responses
        let responses = relatedIds.compactMap { requestResponseMap[$0] }

        // Build JSON response
        var responseData: Data
        if responses.count == 1, let singleResponse = responses.first {
            responseData = singleResponse
        } else {
            // Combine into array
            var jsonArray = Data("[".utf8)
            for (index, response) in responses.enumerated() {
                if index > 0 {
                    jsonArray.append(contentsOf: ",".utf8)
                }
                jsonArray.append(response)
            }
            jsonArray.append(contentsOf: "]".utf8)
            responseData = jsonArray
        }

        // Clean up
        for id in relatedIds {
            requestResponseMap.removeValue(forKey: id)
            requestToStreamMapping.removeValue(forKey: id)
        }
        jsonStreamMapping.removeValue(forKey: streamId)

        var headers = sessionHeaders()
        headers[HTTPHeader.contentType] = "application/json"

        // Yield the response to the stream and finish
        jsonState.continuation.yield(HTTPResponse(statusCode: 200, headers: headers, body: responseData))
        jsonState.continuation.finish()
    }

    private func checkStreamCompletion(streamId: String) async throws {
        // Find all request IDs using this stream
        let relatedIds = requestToStreamMapping.filter { $0.value == streamId }.map { $0.key }

        // Check if all requests have responses
        let allComplete = relatedIds.allSatisfy { requestResponseMap[$0] != nil }

        guard allComplete else { return }

        // Close the stream
        if let state = streamMapping[streamId] {
            state.cleanup()
        }

        // Clean up
        for id in relatedIds {
            requestResponseMap.removeValue(forKey: id)
            requestToStreamMapping.removeValue(forKey: id)
        }
        streamMapping.removeValue(forKey: streamId)
    }

    private func createJsonErrorResponse(
        status: Int,
        code: Int,
        message: String,
        extraHeaders: [String: String] = [:]
    ) -> HTTPResponse {
        let error: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ],
            "id": NSNull(),
        ]

        let body = (try? JSONSerialization.data(withJSONObject: error)) ?? Data()

        var headers = sessionHeaders()
        headers[HTTPHeader.contentType] = "application/json"
        for (key, value) in extraHeaders {
            headers[key] = value
        }

        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }
}
