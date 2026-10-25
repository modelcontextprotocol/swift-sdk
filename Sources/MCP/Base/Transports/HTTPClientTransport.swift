import Foundation
import Logging

#if !os(Linux)
    import EventSource
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Timeout Helpers

/// Error thrown when an operation times out
/// An implementation of the MCP Streamable HTTP transport protocol for clients.
///
/// This transport implements the [Streamable HTTP transport](https://spec.modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http)
/// specification from the Model Context Protocol (version 2025-11-25).
///
/// It supports:
/// - Sending JSON-RPC messages via HTTP POST requests
/// - Receiving responses via both direct JSON responses and SSE streams
/// - Session management using the `MCP-Session-Id` header
/// - Protocol version negotiation via `MCP-Protocol-Version` header
/// - Automatic reconnection for dropped SSE streams with resumability support
/// - Platform-specific optimizations for different operating systems
///
/// The transport supports two modes:
/// - Regular HTTP (`streaming=false`): Simple request/response pattern
/// - Streaming HTTP with SSE (`streaming=true`): Enables server-to-client push messages
///
/// - Important: Server-Sent Events (SSE) functionality is not supported on Linux platforms.
///
/// ## Example Usage
///
/// ```swift
/// import MCP
///
/// // Create a streaming HTTP transport with bearer token authentication
/// let transport = HTTPClientTransport(
///     endpoint: URL(string: "https://api.example.com/mcp")!,
///     requestModifier: { request in
///         var modifiedRequest = request
///         modifiedRequest.addValue("Bearer your-token-here", forHTTPHeaderField: "Authorization")
///         return modifiedRequest
///     }
/// )
///
/// // Initialize the client with streaming transport
/// let client = Client(name: "MyApp", version: "1.0.0")
/// try await client.connect(transport: transport)
///
/// // The transport will automatically handle SSE events
/// // and deliver them through the client's notification handlers
/// ```
public actor HTTPClientTransport: Transport {
    /// The server endpoint URL to connect to
    public let endpoint: URL
    private let session: URLSession

    /// The session ID assigned by the server, used for maintaining state across requests
    public private(set) var sessionID: String?

    /// The negotiated protocol version to send in MCP-Protocol-Version header
    public var protocolVersion: String?

    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// Maximum time to wait for a session ID before proceeding with SSE connection
    public let sseInitializationTimeout: TimeInterval

    /// Closure to modify requests before they are sent
    private let requestModifier: (URLRequest) -> URLRequest

    /// Optional OAuth 2.1 authorizer.
    private let authorizer: (any HTTPClientAuthorizer)?

    private var isConnected = false
    /// Whether the connection uses a stateless revision.
    private var isStateless = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var initialSessionIDSignalTask: Task<Void, Never>?
    private var initialSessionIDContinuation: CheckedContinuation<Void, Never>?
    /// Whether the initial session ID signal fired (a session ID, a timeout or disconnect).
    private var initialSessionIDSignalled = false

    /// The last event ID received from the server for SSE stream resumability
    private var lastEventID: String?

    /// The retry interval (in milliseconds) from the server's SSE `retry:` field,
    /// clamped to ``retryIntervalBounds``.
    private var retryInterval: Int = 3000  // Default 3000ms per SSE spec

    /// The POSTs of requests in flight, by JSON-RPC ID. Cancelled by
    /// ``disconnect()`` and by an outgoing `notifications/cancelled`.
    private var inFlightPosts: [String: Task<Void, Swift.Error>] = [:]

    /// The bounds applied to a server's SSE `retry:` value, in milliseconds.
    static let retryIntervalBounds = 10...60_000

    /// The longest wait before reconnecting the GET stream after repeated failures,
    /// in milliseconds.
    static let maxReconnectDelay = 60_000

    /// A server's SSE `retry:` value, clamped to ``retryIntervalBounds``.
    static func clampedRetryInterval(_ milliseconds: Int) -> Int {
        min(max(milliseconds, retryIntervalBounds.lowerBound), retryIntervalBounds.upperBound)
    }

    /// The wait before the next GET stream connection: the retry interval,
    /// doubled for each consecutive failure after the first, up to
    /// ``maxReconnectDelay``.
    static func reconnectDelay(retryInterval: Int, consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 1 else { return retryInterval }
        let doublings = min(consecutiveFailures - 1, 16)
        return min(retryInterval * (1 << doublings), maxReconnectDelay)
    }

    /// The per-host connection limit of ``defaultConfiguration``.
    public static let defaultMaximumConnectionsPerHost = 64

    /// `URLSessionConfiguration.default`'s per-host limit on Apple platforms.
    static let platformDefaultMaximumConnectionsPerHost = 6

    /// The default URLSession configuration: `URLSessionConfiguration.default`
    /// with `httpMaximumConnectionsPerHost` raised to
    /// ``defaultMaximumConnectionsPerHost``.
    ///
    /// Over HTTP/1.1 every request in flight holds a connection until its
    /// response ends, and the GET stream holds one more. A server-to-client
    /// request (sampling, elicitation, roots) arrives on such a stream, and
    /// the reply needs a connection of its own: with
    /// `URLSessionConfiguration.default` (6 per host on Apple platforms), five
    /// concurrent calls that each wait for a reply deadlock.
    public static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = defaultMaximumConnectionsPerHost
        return configuration
    }

    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests. Defaults to
    ///     ``defaultConfiguration``. A custom configuration needs an
    ///     `httpMaximumConnectionsPerHost` above the number of concurrent requests plus one;
    ///     the transport logs a warning when it is at the platform default of 6 or lower.
    ///   - streaming: Whether to enable SSE streaming mode (default: true)
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - protocolVersion: The MCP protocol version to use (default: "2025-11-25")
    ///   - authorizer: Optional ``HTTPClientAuthorizer`` for automatic Bearer token acquisition and retries.
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification)
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = HTTPClientTransport.defaultConfiguration,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latest,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        if configuration.httpMaximumConnectionsPerHost <= Self.platformDefaultMaximumConnectionsPerHost {
            logger?.warning(
                "URLSessionConfiguration allows \(configuration.httpMaximumConnectionsPerHost) connections per host; concurrent requests that wait for a server-to-client reply can deadlock. Raise httpMaximumConnectionsPerHost, or use HTTPClientTransport.defaultConfiguration."
            )
        }
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            protocolVersion: protocolVersion,
            authorizer: authorizer,
            requestModifier: requestModifier,
            logger: logger
        )
    }

    internal init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latest,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming
        self.sseInitializationTimeout = sseInitializationTimeout
        self.protocolVersion = protocolVersion
        self.requestModifier = requestModifier
        self.authorizer = authorizer

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation

        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.http.client",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    // Setup the initial session ID signal
    private func setupInitialSessionIDSignal() {
        initialSessionIDSignalled = false
        self.initialSessionIDSignalTask = Task {
            await withCheckedContinuation { continuation in
                // The signal may fire before this task runs.
                if self.initialSessionIDSignalled {
                    continuation.resume()
                } else {
                    self.initialSessionIDContinuation = continuation
                }
            }
        }
    }

    private func sessionIDWaitTimedOut(after timeout: TimeInterval) {
        guard !initialSessionIDSignalled else { return }
        logger.warning("⏱️ Timeout waiting for session ID (\(timeout)s). SSE stream will proceed anyway.")
        triggerInitialSessionIDSignal()
    }

    // Trigger the initial session ID signal when a session ID is established
    private func triggerInitialSessionIDSignal() {
        initialSessionIDSignalled = true
        if let continuation = self.initialSessionIDContinuation {
            continuation.resume()
            self.initialSessionIDContinuation = nil
            logger.debug("✓ Initial session ID signal triggered for SSE task")
        } else {
            logger.debug("✗ No continuation to trigger - signal already consumed or SSE task not waiting")
        }
    }

    /// Establishes connection with the transport
    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        setupInitialSessionIDSignal()

        if streaming {
            streamingTask = Task { await startListeningForServerEvents() }
        }

        logger.debug("HTTP transport connected")
    }

    /// Disconnects from the transport
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        streamingTask?.cancel()
        streamingTask = nil

        // POSTs still in flight, including response streams waiting to
        // resume, end now instead of sleeping on a server-chosen delay.
        for task in inFlightPosts.values { task.cancel() }
        inFlightPosts.removeAll()

        session.invalidateAndCancel()
        messageContinuation.finish()

        initialSessionIDSignalTask?.cancel()
        initialSessionIDSignalTask = nil
        initialSessionIDSignalled = true
        initialSessionIDContinuation?.resume()
        initialSessionIDContinuation = nil

        logger.debug("HTTP clienttransport disconnected")
    }

    /// Updates the protocol version used for `MCP-Protocol-Version` headers on subsequent requests.
    public func updateNegotiatedProtocolVersion(_ version: String) {
        self.protocolVersion = version
    }

    /// Switches the transport to a stateless revision (2026-07-28 and later):
    /// no session ID and no standalone GET stream.
    public func useStatelessProtocol(_ version: String) {
        protocolVersion = version
        isStateless = true
        sessionID = nil
        streamingTask?.cancel()
        streamingTask = nil
        initialSessionIDSignalled = true
        initialSessionIDContinuation?.resume()
        initialSessionIDContinuation = nil
    }

    /// Sends data through an HTTP POST request.
    ///
    /// A request's POST, including the resumption of its response stream,
    /// runs until its response arrives, ``disconnect()`` is called, or the
    /// client sends `notifications/cancelled` for it.
    public func send(_ data: Data) async throws {
        let message = OutgoingMessage(data)
        if let id = message.requestID {
            let task = Task { try await self.post(message) }
            inFlightPosts[id] = task
            defer { inFlightPosts[id] = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return
        }
        // The client ignores a cancelled request's response: stop reading
        // and resuming its stream.
        if let cancelled = message.cancelledRequestID {
            inFlightPosts[cancelled]?.cancel()
        }
        try await post(message)
    }

    private func post(_ message: OutgoingMessage) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        if let authorizer {
            do {
                try authorizer.validateEndpointSecurity(for: endpoint)
            } catch {
                throw MCPError.internalError(
                    "Authorization flow failed: \(error.localizedDescription)"
                )
            }
        }

        if let authorizer {
            try? await authorizer.prepareAuthorization(for: endpoint, session: session)
        }

        var attempts = 0
        let operationKey = message.method
        // A stateless request names its version in `_meta`; the header must match.
        let version = message.protocolVersion ?? protocolVersion

        while true {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue(
                "\(ContentType.json), \(ContentType.sse)",
                forHTTPHeaderField: HTTPHeaderName.accept
            )
            request.addValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.contentType)
            request.httpBody = message.data

            if let version {
                request.addValue(version, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
            }

            if let sessionID = sessionID, !isStateless {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            }

            if let authValue = authorizer?.authorizationHeader(for: endpoint) {
                request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
            }

            request = requestModifier(request)

            do {
                #if os(Linux)
                    let (responseData, response) = try await session.data(for: request)
                    try await processResponse(response: response, data: responseData, request: message)
                #else
                    let (responseStream, response) = try await session.bytes(for: request)
                    try await processResponse(response: response, stream: responseStream, request: message)
                #endif
                return
            } catch let authError as HTTPAuthenticationChallengeError {
                guard let authorizer else {
                    throw mapAuthenticationChallengeError(authError)
                }

                let handled: Bool
                do {
                    handled = try await authorizer.handleChallenge(
                        statusCode: authError.statusCode,
                        headers: authError.headers,
                        endpoint: endpoint,
                        operationKey: operationKey,
                        session: session
                    )
                } catch {
                    throw MCPError.internalError(
                        "Authorization flow failed: \(error.localizedDescription)")
                }

                attempts += 1

                if handled, attempts < authorizer.maxAuthorizationAttempts {
                    continue
                }

                throw mapAuthenticationChallengeError(authError)
            }
        }
    }

    #if os(Linux)
        private func processResponse(
            response: URLResponse, data: Data, request message: OutgoingMessage
        ) async throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            if !(200..<300).contains(httpResponse.statusCode), ![401, 403].contains(httpResponse.statusCode),
                deliverErrorResponse(data, contentType: contentType, status: httpResponse.statusCode, request: message)
            {
                return
            }
            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains(ContentType.sse) {
                logger.warning("SSE responses aren't fully supported on Linux")
                messageContinuation.yield(data)
            } else if contentType.contains(ContentType.json) {
                logger.trace("Received JSON response", metadata: ["size": "\(data.count)"])
                messageContinuation.yield(data)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #else
        private func processResponse(
            response: URLResponse, stream: URLSession.AsyncBytes, request message: OutgoingMessage
        ) async throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            if !(200..<300).contains(httpResponse.statusCode), ![401, 403].contains(httpResponse.statusCode),
                contentType.contains(ContentType.json)
            {
                var body = Data()
                for try await byte in stream {
                    body.append(byte)
                    if body.count > 1 << 20 { break }
                }
                if deliverErrorResponse(body, contentType: contentType, status: httpResponse.statusCode, request: message) {
                    return
                }
            }
            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains(ContentType.sse) {
                logger.trace("Received SSE response, processing in streaming task")
                // The response this stream owes, if the POST carried a request.
                let awaited = message.requestID
                var lastEventID: String?
                var retry: Int?
                var responded = false
                do {
                    try await processSSE(
                        stream, until: awaited,
                        onEventID: { lastEventID = $0 }, onRetry: { retry = Self.clampedRetryInterval($0) },
                        onResponse: { if $0 == awaited { responded = true } })
                } catch where awaited != nil && lastEventID != nil && !Task.isCancelled {
                    logger.debug("POST SSE stream failed before its response", metadata: ["error": "\(error)"])
                }
                if let awaited, !responded, !Task.isCancelled {
                    try await resumeResponseStream(
                        after: lastEventID, retry: retry, awaiting: awaited, request: message)
                }
            } else if contentType.contains(ContentType.json) {
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                }
                logger.trace("Received JSON response", metadata: ["size": "\(buffer.count)"])
                messageContinuation.yield(buffer)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #endif

    private func processHTTPResponse(_ response: HTTPURLResponse, contentType: String) throws {
        switch response.statusCode {
        case 200..<300:
            return

        case 400:
            throw MCPError.internalError(StatusMessage.badRequest)

        case 401:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 403:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 404:
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError(StatusMessage.notFound)

        case 405:
            if streaming {
                self.streamingTask?.cancel()
                throw MCPError.internalError(StatusMessage.streamingUnsupported)
            }
            throw MCPError.internalError(StatusMessage.methodNotAllowed)

        case 408:
            throw MCPError.internalError("Request timeout")

        case 429:
            throw MCPError.internalError("Too many requests")

        case 500..<600:
            throw MCPError.internalError("Server error: \(response.statusCode)")

        default:
            throw MCPError.internalError(
                "Unexpected HTTP response: \(response.statusCode) (\(contentType))")
        }
    }

    private func mapAuthenticationChallengeError(_ error: HTTPAuthenticationChallengeError) -> MCPError {
        switch error.statusCode {
        case 401:
            return MCPError.internalError("Authentication required")
        case 403:
            return MCPError.internalError("Access forbidden")
        default:
            return MCPError.internalError("HTTP authorization error: \(error.statusCode)")
        }
    }

    private func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return headers
    }

    /// Delivers the JSON-RPC error a non-2xx reply carries for the POSTed request.
    ///
    /// Servers at 2026-07-28 answer protocol errors with HTTP 4xx and a
    /// JSON-RPC body. Only an `error` whose ID is the request's ID is
    /// delivered: any other body (a `result`, a placeholder or foreign ID, a
    /// batch) leaves the request to fail with the status error. Returns
    /// `true` when the error was delivered.
    private func deliverErrorResponse(
        _ body: Data, contentType: String, status: Int, request message: OutgoingMessage
    ) -> Bool {
        guard contentType.contains(ContentType.json),
            let requestID = message.requestID,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            json["error"] is [String: Any], json["result"] == nil,
            JSONRPCMessageKind.extractID(from: json) == requestID
        else { return false }
        if status == 404, sessionID != nil {
            logger.warning("Session has expired")
            sessionID = nil
        }
        messageContinuation.yield(body)
        return true
    }

    /// Whether `error` reports a 400, 404 or 405 reply without a JSON-RPC
    /// answer for the request: how a server that serves only the handshake
    /// refuses a request without a session.
    package static func isSessionlessRefusal(_ error: Swift.Error) -> Bool {
        guard case .internalError(let detail?) = error as? MCPError else { return false }
        return [StatusMessage.badRequest, StatusMessage.notFound, StatusMessage.methodNotAllowed,
            StatusMessage.streamingUnsupported].contains(detail)
    }

    /// Error details for HTTP status replies.
    enum StatusMessage {
        static let badRequest = "Bad request"
        static let notFound = "Endpoint not found"
        static let methodNotAllowed = "Method not allowed"
        static let streamingUnsupported = "Server does not support streaming"
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - SSE

    private func startListeningForServerEvents() async {
        #if os(Linux)
            if streaming {
                logger.warning(
                    "SSE streaming was requested but is not fully supported on Linux. SSE connection will not be attempted."
                )
            }
        #else
            guard isConnected else { return }

            if self.sessionID == nil, let signalTask = self.initialSessionIDSignalTask {
                logger.debug("⏳ Waiting for session ID to be set (timeout: \(self.sseInitializationTimeout)s)...")

                let startTime = Date()
                let timeout = self.sseInitializationTimeout
                // The signal task waits on a continuation that only a session
                // ID (or disconnect) resumes, so the timeout resumes it too.
                let timer = Task { [weak self] in
                    try await Task.sleep(for: .seconds(timeout))
                    await self?.sessionIDWaitTimedOut(after: timeout)
                }
                await signalTask.value
                timer.cancel()

                if self.sessionID != nil {
                    let elapsed = Date().timeIntervalSince(startTime)
                    logger.debug("✓ Session ID received after \(Int(elapsed * 1000))ms, proceeding with SSE connection")
                }
            } else {
                logger.debug("✓ Session ID already available, proceeding with SSE connection immediately")
            }

            var isFirstAttempt = true
            var attemptCount = 0
            // Failed connections and streams that close without an event in a
            // row; each one after the first doubles the wait.
            var consecutiveFailures = 0

            logger.debug("🔄 Starting SSE retry loop", metadata: [
                "isConnected": "\(isConnected)",
                "isCancelled": "\(Task.isCancelled)"
            ])

            while isConnected && !Task.isCancelled {
                attemptCount += 1
                logger.debug("🔄 SSE retry loop iteration", metadata: [
                    "attempt": "\(attemptCount)",
                    "isFirstAttempt": "\(isFirstAttempt)"
                ])

                do {
                    if !isFirstAttempt {
                        let delayMs = Self.reconnectDelay(
                            retryInterval: self.retryInterval, consecutiveFailures: consecutiveFailures)
                        logger.debug("⏳ Waiting before SSE reconnection", metadata: ["retryMs": "\(delayMs)"])
                        try await Task.sleep(for: .milliseconds(delayMs))
                        logger.debug("✓ Wait complete, reconnecting now")
                    }
                    isFirstAttempt = false

                    logger.debug("📡 Calling connectToEventStream (attempt #\(attemptCount))")

                    let receivedEvents = try await self.connectToEventStream()
                    consecutiveFailures = receivedEvents ? 0 : consecutiveFailures + 1

                    logger.info("🔌 SSE stream closed gracefully, will reconnect", metadata: [
                        "attempt": "\(attemptCount)",
                        "willRetryAfter": "\(self.retryInterval)ms"
                    ])
                } catch {
                    consecutiveFailures += 1
                    if !Task.isCancelled {
                        logger.error("❌ SSE connection error (attempt #\(attemptCount)): \(error)")
                    } else {
                        logger.debug("⏹️ SSE task cancelled")
                    }
                }

                logger.debug("🔄 End of retry loop iteration", metadata: [
                    "isConnected": "\(isConnected)",
                    "isCancelled": "\(Task.isCancelled)",
                    "willContinue": "\(isConnected && !Task.isCancelled)"
                ])
            }

            logger.debug("⏹️ SSE retry loop exited", metadata: [
                "isConnected": "\(isConnected)",
                "isCancelled": "\(Task.isCancelled)",
                "totalAttempts": "\(attemptCount)"
            ])
        #endif
    }

    #if !os(Linux)
        /// Opens the standalone GET stream and reads it until it ends.
        /// Returns whether any event arrived.
        private func connectToEventStream() async throws -> Bool {
            guard isConnected else {
                logger.debug("⚠️ Skipping connectToEventStream - transport not connected")
                return false
            }

            if let authorizer {
                do {
                    try authorizer.validateEndpointSecurity(for: endpoint)
                } catch {
                    throw MCPError.internalError(
                        "Authorization flow failed: \(error.localizedDescription)"
                    )
                }
            }

            if let lastEventID = lastEventID {
                logger.info("→ Resuming SSE stream with Last-Event-ID", metadata: ["lastEventID": "\(lastEventID)"])
            } else {
                logger.info("→ Connecting to SSE stream (no last event ID to resume from)")
            }

            let (stream, httpResponse) = try await openEventStream(
                lastEventID: lastEventID, protocolVersion: protocolVersion)

            guard httpResponse.statusCode == 200 else {
                stream.task.cancel()
                if httpResponse.statusCode == 405 {
                    self.streamingTask?.cancel()
                }
                // The server no longer has the event to resume from: the next
                // connection opens a fresh stream instead of repeating the ID.
                if httpResponse.statusCode == 400, lastEventID != nil {
                    lastEventID = nil
                }
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            return try await self.processSSE(
                stream, onEventID: { self.lastEventID = $0 },
                onRetry: { self.retryInterval = Self.clampedRetryInterval($0) })
        }

        /// Sends a GET for an SSE stream, resuming after `lastEventID` when
        /// given. A 401 or 403 goes to the authorizer, as for a POST, and the
        /// GET is retried while it handles the challenge.
        private func openEventStream(
            lastEventID: String?, protocolVersion: String?
        ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            if let authorizer {
                try? await authorizer.prepareAuthorization(for: endpoint, session: session)
            }
            var attempts = 0
            while true {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "GET"
                request.addValue(ContentType.sse, forHTTPHeaderField: HTTPHeaderName.accept)
                request.addValue("no-cache", forHTTPHeaderField: HTTPHeaderName.cacheControl)
                if let protocolVersion {
                    request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
                }
                if let sessionID {
                    request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
                }
                if let lastEventID {
                    request.addValue(lastEventID, forHTTPHeaderField: HTTPHeaderName.lastEventID)
                }
                if let authValue = authorizer?.authorizationHeader(for: endpoint) {
                    request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
                }
                request = requestModifier(request)

                let (stream, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    stream.task.cancel()
                    throw MCPError.internalError("Invalid HTTP response")
                }
                guard let authorizer, httpResponse.statusCode == 401 || httpResponse.statusCode == 403 else {
                    return (stream, httpResponse)
                }
                stream.task.cancel()
                let handled: Bool
                do {
                    handled = try await authorizer.handleChallenge(
                        statusCode: httpResponse.statusCode,
                        headers: responseHeaders(from: httpResponse),
                        endpoint: endpoint,
                        operationKey: nil,
                        session: session
                    )
                } catch {
                    throw MCPError.internalError("Authorization flow failed: \(error.localizedDescription)")
                }
                attempts += 1
                guard handled, attempts < authorizer.maxAuthorizationAttempts else {
                    throw mapAuthenticationChallengeError(
                        HTTPAuthenticationChallengeError(
                            statusCode: httpResponse.statusCode, headers: responseHeaders(from: httpResponse)))
                }
            }
        }

        /// The most GET resumptions of one POST stream before its request fails.
        static let maxStreamResumptions = 10

        /// Resumes a POST stream that ended before its response (2025-11-25
        /// resumability, SEP-1699): a GET with the stream's own last event ID,
        /// repeated while the server closes the stream again. Without an event
        /// ID, or when the server refuses the GET, the request fails with an
        /// error instead of waiting forever. Revisions without sessions
        /// (2026-07-28) have no resumability: the request fails at once.
        private func resumeResponseStream(
            after eventID: String?, retry: Int?, awaiting id: String, request message: OutgoingMessage
        ) async throws {
            let requestData = message.data
            let version = message.protocolVersion ?? protocolVersion
            guard !isStateless, version.map({ Version.profile(for: $0).usesSessions }) ?? true else {
                deliverStreamLoss(for: requestData, reason: "The server closed the response stream without a response")
                return
            }
            var lastEventID = eventID
            var retry = retry
            var attempts = 0
            while let resumeFrom = lastEventID, attempts < Self.maxStreamResumptions {
                guard isConnected, !Task.isCancelled else { return }
                attempts += 1
                try await Task.sleep(for: .milliseconds(retry ?? retryInterval))
                logger.debug(
                    "Resuming a response stream", metadata: ["lastEventID": "\(resumeFrom)", "attempt": "\(attempts)"])

                let (stream, httpResponse) = try await openEventStream(
                    lastEventID: resumeFrom, protocolVersion: version)
                guard httpResponse.statusCode == 200 else {
                    stream.task.cancel()
                    logger.warning(
                        "The server refused to resume a response stream",
                        metadata: ["status": "\(httpResponse.statusCode)"])
                    break
                }
                var responded = false
                do {
                    try await processSSE(
                        stream, until: id,
                        onEventID: { lastEventID = $0 }, onRetry: { retry = Self.clampedRetryInterval($0) },
                        onResponse: { if $0 == id { responded = true } })
                } catch {
                    if Task.isCancelled { return }
                    logger.debug("Resumed response stream failed", metadata: ["error": "\(error)"])
                }
                if responded { return }
            }
            // A cancelled read can end the last attempt's stream without an
            // error: a cancelled request or a closed transport is no loss.
            guard isConnected, !Task.isCancelled else { return }
            deliverStreamLoss(
                for: requestData,
                reason: eventID != nil
                    ? "The response stream could not be resumed"
                    : "The server closed the response stream without a response or an event ID to resume from")
        }

        /// Fails the request of a response stream that cannot be resumed.
        private func deliverStreamLoss(for requestData: Data, reason: String) {
            guard let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                let id = request["id"]
            else { return }
            let error: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "error": ["code": MCPError.internalError(nil).code, "message": reason],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: error) else { return }
            logger.warning("\(reason)")
            messageContinuation.yield(data)
        }

        /// Reads SSE events and yields their messages. `onEventID` and
        /// `onRetry` see each event's `id` and `retry`, `onResponse` the ID of
        /// each response. With `until`, reading stops once that response is
        /// delivered. Messages are only parsed for their ID when `until` or
        /// `onResponse` needs it. Returns whether any event arrived.
        @discardableResult
        private func processSSE(
            _ stream: URLSession.AsyncBytes,
            until responseID: String? = nil,
            onEventID: (String) -> Void = { _ in },
            onRetry: (Int) -> Void = { _ in },
            onResponse: ((String) -> Void)? = nil
        ) async throws -> Bool {
            logger.debug("📥 Starting SSE event processing")
            var eventCount = 0
            var hadDataEvent = false

            for try await event in stream.events {
                eventCount += 1

                if Task.isCancelled {
                    logger.debug("⏹️ SSE processing cancelled", metadata: ["eventsProcessed": "\(eventCount)"])
                    break
                }

                logger.trace(
                    "SSE event received",
                    metadata: [
                        "type": "\(event.event ?? "message")",
                        "id": "\(event.id ?? "none")",
                    ]
                )

                if let eventID = event.id, !eventID.isEmpty {
                    onEventID(eventID)
                    logger.debug("Stored event ID for resumability", metadata: ["eventID": "\(eventID)"])
                }

                if let retry = event.retry {
                    onRetry(retry)
                    logger.debug("SSE retry interval updated", metadata: ["retryMs": "\(retry)"])
                }

                if !event.data.isEmpty, let data = event.data.data(using: .utf8) {
                    hadDataEvent = true
                    var delivered: String?
                    if responseID != nil || onResponse != nil,
                        case .response(let id) = JSONRPCMessageKind(data: data)
                    {
                        onResponse?(id)
                        delivered = id
                    }
                    messageContinuation.yield(data)
                    if let responseID, delivered == responseID {
                        stream.task.cancel()
                        break
                    }
                }
            }

            logger.debug("✓ SSE event stream completed", metadata: ["eventsProcessed": "\(eventCount)", "hadData": "\(hadDataEvent)"])
            return eventCount > 0
        }
    #endif
}

/// The parts of an outgoing JSON-RPC message the transport reads, parsed
/// once per send.
struct OutgoingMessage: Sendable {
    let data: Data
    /// A request's ID, rendered like ``JSONRPCMessageKind`` IDs; `nil` for
    /// notifications, responses and batches.
    let requestID: String?
    /// The trimmed method name; the operation key for authorization.
    let method: String?
    /// `params._meta["io.modelcontextprotocol/protocolVersion"]`.
    let protocolVersion: String?
    /// The `requestId` of a `notifications/cancelled` message.
    let cancelledRequestID: String?

    init(_ data: Data) {
        self.data = data
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let method = (json?["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = json?["params"] as? [String: Any]
        self.method = method?.isEmpty == false ? method : nil
        self.requestID = json.flatMap { json in
            json["method"] is String ? JSONRPCMessageKind.extractID(from: json) : nil
        }
        self.protocolVersion = (params?["_meta"] as? [String: Any])?[MetaKey.protocolVersion] as? String
        self.cancelledRequestID =
            method == CancelledNotification.name && json?["id"] == nil
            ? JSONRPCMessageKind.extractID(from: ["id": params?["requestId"] as Any]) : nil
    }
}
