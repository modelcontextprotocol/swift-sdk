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
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var initialSessionIDSignalTask: Task<Void, Never>?
    private var initialSessionIDContinuation: CheckedContinuation<Void, Never>?

    /// The last event ID received from the server for SSE stream resumability
    private var lastEventID: String?

    /// The retry interval (in milliseconds) from the server's SSE `retry:` field
    private var retryInterval: Int = 3000  // Default 3000ms per SSE spec

    /// The underlying URLSession task for the active GET SSE stream.
    /// Used to trigger reconnection when a POST SSE stream closes without delivering data.
    private var activeGETSessionTask: URLSessionDataTask?

    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests
    ///   - streaming: Whether to enable SSE streaming mode (default: true)
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - protocolVersion: The MCP protocol version to use (default: "2025-11-25")
    ///   - authorizer: Optional ``HTTPClientAuthorizer`` for automatic Bearer token acquisition and retries.
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification)
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latest,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
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
        self.initialSessionIDSignalTask = Task {
            await withCheckedContinuation { continuation in
                self.initialSessionIDContinuation = continuation
            }
        }
    }

    // Trigger the initial session ID signal when a session ID is established
    private func triggerInitialSessionIDSignal() {
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

        session.invalidateAndCancel()
        messageContinuation.finish()

        initialSessionIDSignalTask?.cancel()
        initialSessionIDSignalTask = nil
        initialSessionIDContinuation?.resume()
        initialSessionIDContinuation = nil

        logger.debug("HTTP clienttransport disconnected")
    }

    /// Updates the protocol version used for `MCP-Protocol-Version` headers on subsequent requests.
    public func updateNegotiatedProtocolVersion(_ version: String) {
        self.protocolVersion = version
    }

    /// Sends data through an HTTP POST request
    public func send(_ data: Data) async throws {
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
        let operationKey = jsonRPCOperationKey(from: data)

        while true {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue(
                "\(ContentType.json), \(ContentType.sse)",
                forHTTPHeaderField: HTTPHeaderName.accept
            )
            request.addValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.contentType)
            request.httpBody = data

            if let protocolVersion = protocolVersion {
                request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
            }

            if let sessionID = sessionID {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            }

            if let authValue = authorizer?.authorizationHeader(for: endpoint) {
                request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
            }

            request = requestModifier(request)

            do {
                #if os(Linux)
                    let (responseData, response) = try await session.data(for: request)
                    try await processResponse(response: response, data: responseData)
                #else
                    let (responseStream, response) = try await session.bytes(for: request)
                    try await processResponse(response: response, stream: responseStream)
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
        private func processResponse(response: URLResponse, data: Data) async throws {
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
        private func processResponse(response: URLResponse, stream: URLSession.AsyncBytes)
            async throws
        {
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

            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains(ContentType.sse) {
                logger.trace("Received SSE response, processing in streaming task")
                let hadData = try await self.processSSE(stream)

                if !hadData {
                    logger.debug("POST SSE stream closed without data, triggering GET reconnection")
                    self.activeGETSessionTask?.cancel()
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
            throw MCPError.internalError("Bad request")

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
            throw MCPError.internalError("Endpoint not found")

        case 405:
            if streaming {
                self.streamingTask?.cancel()
                throw MCPError.internalError("Server does not support streaming")
            }
            throw MCPError.internalError("Method not allowed")

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

    private func jsonRPCOperationKey(from data: Data) -> String? {
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = jsonObject["method"] as? String
        else {
            return nil
        }

        let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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
                do {
                    try await withThrowingTaskGroup { group in
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeout))
                        }

                        group.addTask {
                            await signalTask.value
                        }

                        if let firstResult = try await group.next() {
                            group.cancelAll()
                            return firstResult
                        }
                    }
                } catch {
                    logger.warning("⏱️ Timeout waiting for session ID (\(timeout)s). SSE stream will proceed anyway.")
                }

                if self.sessionID != nil {
                    let elapsed = Date().timeIntervalSince(startTime)
                    logger.debug("✓ Session ID received after \(Int(elapsed * 1000))ms, proceeding with SSE connection")
                }
            } else {
                logger.debug("✓ Session ID already available, proceeding with SSE connection immediately")
            }

            var isFirstAttempt = true
            var attemptCount = 0

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
                        let delayMs = self.retryInterval
                        logger.debug("⏳ Waiting before SSE reconnection", metadata: ["retryMs": "\(delayMs)"])
                        try await Task.sleep(for: .milliseconds(delayMs))
                        logger.debug("✓ Wait complete, reconnecting now")
                    }
                    isFirstAttempt = false

                    logger.debug("📡 Calling connectToEventStream (attempt #\(attemptCount))")

                    try await self.connectToEventStream()

                    logger.info("🔌 SSE stream closed gracefully, will reconnect", metadata: [
                        "attempt": "\(attemptCount)",
                        "willRetryAfter": "\(self.retryInterval)ms"
                    ])
                } catch {
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
        private func connectToEventStream() async throws {
            guard isConnected else {
                logger.debug("⚠️ Skipping connectToEventStream - transport not connected")
                return
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

            logger.debug("🔌 Preparing SSE connection request")

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.addValue(ContentType.sse, forHTTPHeaderField: HTTPHeaderName.accept)
            request.addValue("no-cache", forHTTPHeaderField: HTTPHeaderName.cacheControl)

            if let protocolVersion = protocolVersion {
                request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
            }

            if let sessionID = sessionID {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            }

            if let lastEventID = lastEventID {
                request.addValue(lastEventID, forHTTPHeaderField: HTTPHeaderName.lastEventID)
                logger.info("→ Resuming SSE stream with Last-Event-ID", metadata: ["lastEventID": "\(lastEventID)"])
            } else {
                logger.info("→ Connecting to SSE stream (no last event ID to resume from)")
            }

            if let authValue = authorizer?.authorizationHeader(for: endpoint) {
                request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
            }

            request = requestModifier(request)

            logger.debug("Starting SSE connection")

            let (stream, response) = try await session.bytes(for: request)
            self.activeGETSessionTask = stream.task

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 405 {
                    self.streamingTask?.cancel()
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

            defer { self.activeGETSessionTask = nil }
            try await self.processSSE(stream)
        }

        @discardableResult
        private func processSSE(_ stream: URLSession.AsyncBytes) async throws -> Bool {
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
                    self.lastEventID = eventID
                    logger.debug("Stored event ID for resumability", metadata: ["eventID": "\(eventID)"])
                }

                if let retry = event.retry {
                    self.retryInterval = retry
                    logger.debug("SSE retry interval updated", metadata: ["retryMs": "\(retry)"])
                }

                if !event.data.isEmpty, let data = event.data.data(using: .utf8) {
                    hadDataEvent = true
                    messageContinuation.yield(data)
                }
            }

            logger.debug("✓ SSE event stream completed", metadata: ["eventsProcessed": "\(eventCount)", "hadData": "\(hadDataEvent)"])
            return hadDataEvent
        }
    #endif
}
