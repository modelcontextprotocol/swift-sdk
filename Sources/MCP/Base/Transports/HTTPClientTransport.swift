import Foundation
import Logging

#if !os(Linux)
    import EventSource
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Configuration options for reconnection behavior of the HTTPClientTransport.
///
/// These options control how the transport handles SSE stream disconnections
/// and reconnection attempts.
public struct HTTPReconnectionOptions: Sendable {
    /// Initial delay between reconnection attempts in seconds.
    /// Default is 1.0 second.
    public var initialReconnectionDelay: TimeInterval

    /// Maximum delay between reconnection attempts in seconds.
    /// Default is 30.0 seconds.
    public var maxReconnectionDelay: TimeInterval

    /// Factor by which the reconnection delay increases after each attempt.
    /// Default is 1.5.
    public var reconnectionDelayGrowFactor: Double

    /// Maximum number of reconnection attempts before giving up.
    /// Default is 2.
    public var maxRetries: Int

    /// Creates reconnection options with default values.
    public init(
        initialReconnectionDelay: TimeInterval = 1.0,
        maxReconnectionDelay: TimeInterval = 30.0,
        reconnectionDelayGrowFactor: Double = 1.5,
        maxRetries: Int = 2
    ) {
        self.initialReconnectionDelay = initialReconnectionDelay
        self.maxReconnectionDelay = maxReconnectionDelay
        self.reconnectionDelayGrowFactor = reconnectionDelayGrowFactor
        self.maxRetries = maxRetries
    }

    /// Default reconnection options.
    public static let `default` = HTTPReconnectionOptions()
}

/// An implementation of the MCP Streamable HTTP transport protocol for clients.
///
/// This transport implements the [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http)
/// specification from the Model Context Protocol.
///
/// It supports:
/// - Sending JSON-RPC messages via HTTP POST requests
/// - Receiving responses via both direct JSON responses and SSE streams
/// - Session management using the `Mcp-Session-Id` header
/// - Automatic reconnection for dropped SSE streams
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

    /// The negotiated protocol version, set after initialization
    public private(set) var protocolVersion: String?
    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// Maximum time to wait for a session ID before proceeding with SSE connection
    public let sseInitializationTimeout: TimeInterval

    /// Configuration for reconnection behavior
    public nonisolated let reconnectionOptions: HTTPReconnectionOptions

    /// Closure to modify requests before they are sent
    private let requestModifier: (URLRequest) -> URLRequest

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Stream for signaling when session ID is set
    private var sessionIDSignalStream: AsyncStream<Void>?
    private var sessionIDSignalContinuation: AsyncStream<Void>.Continuation?

    // MARK: - Reconnection State

    /// The last event ID received from the server, used for resumability
    private var lastEventId: String?

    /// Server-provided retry delay in seconds (from SSE retry: field)
    private var serverRetryDelay: TimeInterval?

    /// Current reconnection attempt count
    private var reconnectionAttempt: Int = 0

    /// Callback invoked when a new resumption token (event ID) is received
    public var onResumptionToken: ((String) -> Void)?

    /// Sets the callback invoked when a new resumption token (event ID) is received.
    ///
    /// - Parameter callback: The callback to invoke with the event ID
    public func setOnResumptionToken(_ callback: ((String) -> Void)?) {
        onResumptionToken = callback
    }

    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests
    ///   - streaming: Whether to enable SSE streaming mode (default: true)
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - reconnectionOptions: Configuration for reconnection behavior (default: .default)
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification)
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        reconnectionOptions: HTTPReconnectionOptions = .default,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            reconnectionOptions: reconnectionOptions,
            requestModifier: requestModifier,
            logger: logger
        )
    }

    internal init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        sseInitializationTimeout: TimeInterval = 10,
        reconnectionOptions: HTTPReconnectionOptions = .default,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming
        self.sseInitializationTimeout = sseInitializationTimeout
        self.reconnectionOptions = reconnectionOptions
        self.requestModifier = requestModifier

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

    // Setup the initial session ID signal stream
    private func setUpInitialSessionIDSignal() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.sessionIDSignalStream = stream
        self.sessionIDSignalContinuation = continuation
    }

    // Trigger the initial session ID signal when a session ID is established
    private func triggerInitialSessionIDSignal() {
        if let continuation = self.sessionIDSignalContinuation {
            continuation.yield(())
            continuation.finish()
            self.sessionIDSignalContinuation = nil  // Consume the continuation
            logger.trace("Initial session ID signal triggered for SSE task.")
        }
    }

    /// Establishes connection with the transport
    ///
    /// This prepares the transport for communication and sets up SSE streaming
    /// if streaming mode is enabled. The actual HTTP connection happens with the
    /// first message sent.
    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        // Setup initial session ID signal
        setUpInitialSessionIDSignal()

        if streaming {
            // Start listening to server events
            streamingTask = Task { await startListeningForServerEvents() }
        }

        logger.debug("HTTP transport connected")
    }

    /// Disconnects from the transport
    ///
    /// This terminates any active connections, cancels the streaming task,
    /// and releases any resources being used by the transport.
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        // Cancel streaming task if active
        streamingTask?.cancel()
        streamingTask = nil

        // Cancel any in-progress requests
        session.invalidateAndCancel()

        // Clean up message stream
        messageContinuation.finish()

        // Finish the session ID signal stream if it's still pending
        sessionIDSignalContinuation?.finish()
        sessionIDSignalContinuation = nil
        sessionIDSignalStream = nil

        logger.debug("HTTP clienttransport disconnected")
    }

    /// Terminates the current session by sending a DELETE request to the server.
    ///
    /// Clients that no longer need a particular session (e.g., because the user is
    /// leaving the client application) SHOULD send an HTTP DELETE to the MCP endpoint
    /// with the `Mcp-Session-Id` header to explicitly terminate the session.
    ///
    /// This allows the server to clean up any resources associated with the session.
    ///
    /// - Note: The server MAY respond with HTTP 405 Method Not Allowed, indicating
    ///   that the server does not allow clients to terminate sessions. This is handled
    ///   gracefully and does not throw an error.
    ///
    /// - Throws: MCPError if the DELETE request fails for reasons other than 405.
    public func terminateSession() async throws {
        guard let sessionID else {
            // No session to terminate
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"

        // Add session ID header
        request.addValue(sessionID, forHTTPHeaderField: HTTPHeader.sessionId)

        // Add protocol version if available
        if let protocolVersion {
            request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)
        }

        // Apply request modifier (for auth headers, etc.)
        request = requestModifier(request)

        logger.debug("Terminating session", metadata: ["sessionID": "\(sessionID)"])

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 204:
            // Success - session terminated
            self.sessionID = nil
            logger.debug("Session terminated successfully")

        case 405:
            // Server does not support session termination - this is OK per spec
            logger.debug("Server does not support session termination (405)")

        case 404:
            // Session already expired or doesn't exist
            self.sessionID = nil
            logger.debug("Session not found (already expired)")

        default:
            throw MCPError.internalError(
                "Failed to terminate session: HTTP \(httpResponse.statusCode)")
        }
    }

    /// Sends data through an HTTP POST request
    ///
    /// This sends a JSON-RPC message to the server via HTTP POST and processes
    /// the response according to the MCP Streamable HTTP specification. It handles:
    ///
    /// - Adding appropriate Accept headers for both JSON and SSE
    /// - Including the session ID in requests if one has been established
    /// - Processing different response types (JSON vs SSE)
    /// - Handling HTTP error codes according to the specification
    ///
    /// ## Implementation Note
    ///
    /// This method signature differs from TypeScript and Python SDKs which receive
    /// typed `JSONRPCMessage` objects instead of raw `Data`. Swift parses the JSON
    /// internally to determine message type (request vs notification) for proper
    /// content-type validation per the MCP spec.
    ///
    /// This design avoids breaking changes to the `Transport` protocol. A future
    /// revision could consider changing the protocol to receive typed messages
    /// for better alignment with other SDKs.
    ///
    /// - Parameter data: The JSON-RPC message to send
    /// - Throws: MCPError for transport failures or server errors
    public func send(_ data: Data) async throws {
        // Determine if message is a request (has both "method" and "id")
        // Per MCP spec, only requests require content-type validation
        let expectsContentType = isRequest(data)
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: HTTPHeader.accept)
        request.addValue("application/json", forHTTPHeaderField: HTTPHeader.contentType)
        request.httpBody = data

        // Add session ID if available
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: HTTPHeader.sessionId)
        }

        // Add protocol version if available (required after initialization)
        if let protocolVersion {
            request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)
        }

        // Apply request modifier
        request = requestModifier(request)

        #if os(Linux)
            // Linux implementation using data(for:) instead of bytes(for:)
            let (responseData, response) = try await session.data(for: request)
            try await processResponse(response: response, data: responseData, expectsContentType: expectsContentType)
        #else
            // macOS and other platforms with bytes(for:) support
            let (responseStream, response) = try await session.bytes(for: request)
            try await processResponse(response: response, stream: responseStream, expectsContentType: expectsContentType)
        #endif
    }

    /// Checks if the given data represents a JSON-RPC request.
    ///
    /// Per JSON-RPC 2.0 spec, a request has both "method" and "id" fields.
    /// Notifications have "method" but no "id". Responses have "id" but no "method".
    ///
    /// This is used to determine content-type validation behavior per MCP spec:
    /// - Requests: Server MUST return `application/json` or `text/event-stream`
    /// - Notifications: Server MUST return 202 Accepted with no body
    private func isRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // A request has both "method" and "id" fields
        return json["method"] != nil && json["id"] != nil
    }

    /// Result of processing a JSON-RPC message for response detection and optional ID remapping.
    private struct ProcessedMessage {
        /// Whether the message is a JSON-RPC response (success or error)
        let isResponse: Bool
        /// The message data, potentially with ID remapped
        let data: Data
    }

    /// Processes a JSON-RPC message, detecting if it's a response and optionally remapping its ID.
    ///
    /// Per JSON-RPC 2.0 spec:
    /// - A successful response has "id" and "result" fields, but no "method"
    /// - An error response has "id" and "error" fields, but no "method"
    ///
    /// This combines response detection with ID remapping for efficiency (single parse).
    /// ID remapping is used during stream resumption to ensure responses match the
    /// original pending request, aligning with Python SDK behavior.
    ///
    /// Note: This implementation handles both success AND error responses, which aligns
    /// with Python SDK but is more complete than TypeScript SDK. TypeScript's streamableHttp.ts
    /// only checks `isJSONRPCResultResponse` (success only), missing error response handling.
    /// TODO: File PR to fix TypeScript SDK - streamableHttp.ts line 364 should also handle
    /// `isJSONRPCErrorResponse` for both `receivedResponse` flag and ID remapping.
    ///
    /// - Parameters:
    ///   - data: The raw JSON-RPC message data
    ///   - originalRequestId: Optional ID to remap response IDs to (for stream resumption)
    /// - Returns: ProcessedMessage with isResponse flag and potentially remapped data
    private func processJSONRPCMessage(_ data: Data, originalRequestId: RequestId?) -> ProcessedMessage {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProcessedMessage(isResponse: false, data: data)
        }

        // Check if it's a response (has id + result/error, no method)
        let hasId = json["id"] != nil
        let hasResult = json["result"] != nil
        let hasError = json["error"] != nil
        let hasMethod = json["method"] != nil
        let isResponse = hasId && (hasResult || hasError) && !hasMethod

        // If it's a response and we have an original request ID, remap the ID
        if isResponse, let originalId = originalRequestId {
            switch originalId {
            case .string(let s): json["id"] = s
            case .number(let n): json["id"] = n
            }

            // Re-encode with remapped ID
            if let remappedData = try? JSONSerialization.data(withJSONObject: json) {
                return ProcessedMessage(isResponse: true, data: remappedData)
            }
        }

        return ProcessedMessage(isResponse: isResponse, data: data)
    }

    #if os(Linux)
        // Process response with data payload (Linux)
        private func processResponse(response: URLResponse, data: Data, expectsContentType: Bool) async throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            // Process the response based on content type and status code
            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeader.contentType) ?? ""

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeader.sessionId) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    // Trigger signal on first session ID
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            // Process response based on content type
            if contentType.contains("text/event-stream") {
                logger.warning("SSE responses aren't fully supported on Linux")
                messageContinuation.yield(data)
            } else if contentType.contains("application/json") {
                logger.trace("Received JSON response", metadata: ["size": "\(data.count)"])
                messageContinuation.yield(data)
            } else if expectsContentType && !data.isEmpty {
                // Per MCP spec: requests MUST receive application/json or text/event-stream
                // Notifications expect 202 Accepted with no body, so unexpected content-type is ignored
                throw MCPError.internalError("Unexpected content type: \(contentType)")
            }
        }
    #else
        // Process response with byte stream (macOS, iOS, etc.)
        private func processResponse(response: URLResponse, stream: URLSession.AsyncBytes, expectsContentType: Bool)
            async throws
        {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            // Process the response based on content type and status code
            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeader.contentType) ?? ""

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeader.sessionId) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    // Trigger signal on first session ID
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains("text/event-stream") {
                // For SSE response from POST, isReconnectable is false initially
                // but can become reconnectable after receiving a priming event
                logger.trace("Received SSE response, processing in streaming task")
                try await self.processSSE(stream, isReconnectable: false)
            } else if contentType.contains("application/json") {
                // For JSON responses, collect and deliver the data
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                }
                logger.trace("Received JSON response", metadata: ["size": "\(buffer.count)"])
                messageContinuation.yield(buffer)
            } else {
                // Collect data to check if response has content
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                }
                // Per MCP spec: requests MUST receive application/json or text/event-stream
                // Notifications expect 202 Accepted with no body, so unexpected content-type is ignored
                if expectsContentType && !buffer.isEmpty {
                    throw MCPError.internalError("Unexpected content type: \(contentType)")
                }
            }
        }
    #endif

    // Common HTTP response handling for all platforms
    //
    // Note: The MCP spec recommends auto-detecting legacy SSE servers by falling back
    // to GET on 400/404/405 errors. We don't implement this, consistent with the
    // TypeScript and Python SDKs which provide separate transports instead.
    private func processHTTPResponse(_ response: HTTPURLResponse, contentType: String) throws {
        // Handle status codes according to HTTP semantics
        switch response.statusCode {
        case 200..<300:
            // Success range - these are handled by the platform-specific code
            return

        case 400:
            throw MCPError.internalError("Bad request")

        case 401:
            throw MCPError.internalError("Authentication required")

        case 403:
            throw MCPError.internalError("Access forbidden")

        case 404:
            // If we get a 404 with a session ID, it means our session is invalid
            // TODO: Consider Python's approach - send JSON-RPC error through stream
            // with request ID (code -32600) before throwing. This gives pending requests
            // proper error responses. Options: (1) catch in send() and yield error,
            // (2) use RequestContext pattern like Python. Both are spec-compliant.
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError("Endpoint not found")

        case 405:
            // If we get a 405, it means the server does not support the requested method
            // If streaming was requested, we should cancel the streaming task
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
            // Server error range
            throw MCPError.internalError("Server error: \(response.statusCode)")

        default:
            throw MCPError.internalError(
                "Unexpected HTTP response: \(response.statusCode) (\(contentType))")
        }
    }

    /// Receives data in an async sequence
    ///
    /// This returns an AsyncThrowingStream that emits Data objects representing
    /// each JSON-RPC message received from the server. This includes:
    ///
    /// - Direct responses to client requests
    /// - Server-initiated messages delivered via SSE streams
    ///
    /// - Returns: An AsyncThrowingStream of Data objects
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    /// Sets the protocol version to include in request headers.
    ///
    /// This should be called after initialization when the protocol version is negotiated.
    /// HTTP transports must include the `Mcp-Protocol-Version` header in all requests
    /// after initialization.
    ///
    /// - Parameter version: The negotiated protocol version (e.g., "2024-11-05")
    public func setProtocolVersion(_ version: String) {
        self.protocolVersion = version
        logger.debug("Protocol version set", metadata: ["version": "\(version)"])
    }

    // MARK: - SSE

    /// Starts listening for server events using SSE
    ///
    /// This establishes a long-lived HTTP connection using Server-Sent Events (SSE)
    /// to enable server-to-client push messaging. It handles:
    ///
    /// - Waiting for session ID if needed
    /// - Opening the SSE connection
    /// - Automatic reconnection on connection drops
    /// - Processing received events
    private func startListeningForServerEvents() async {
        #if os(Linux)
            // SSE is not fully supported on Linux
            if streaming {
                logger.warning(
                    "SSE streaming was requested but is not fully supported on Linux. SSE connection will not be attempted."
                )
            }
        #else
            // This is the original code for platforms that support SSE
            guard isConnected else { return }

            // Wait for the initial session ID signal, but only if sessionID isn't already set
            if self.sessionID == nil, let signalStream = self.sessionIDSignalStream {
                logger.trace("SSE streaming task waiting for initial sessionID signal...")

                // Race the stream against a timeout using TaskGroup
                var signalReceived = false
                do {
                    signalReceived = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            // Wait for signal from stream
                            for await _ in signalStream {
                                return true
                            }
                            return false  // Stream finished without yielding
                        }
                        group.addTask {
                            // Timeout task
                            try await Task.sleep(for: .seconds(self.sseInitializationTimeout))
                            return false
                        }

                        // Take the first result and cancel the other task
                        if let firstResult = try await group.next() {
                            group.cancelAll()
                            return firstResult
                        }
                        return false
                    }
                } catch {
                    logger.error("Error while waiting for session ID signal: \(error)")
                }

                if signalReceived {
                    logger.trace("SSE streaming task proceeding after initial sessionID signal.")
                } else {
                    logger.warning(
                        "Timeout waiting for initial sessionID signal. SSE stream will proceed (sessionID might be nil)."
                    )
                }
            } else if self.sessionID != nil {
                logger.trace(
                    "Initial sessionID already available. Proceeding with SSE streaming task immediately."
                )
            } else {
                logger.trace(
                    "Proceeding with SSE connection attempt; sessionID is nil. This might be expected for stateless servers or if initialize hasn't provided one yet."
                )
            }

            // Retry loop for connection drops with exponential backoff
            while isConnected && !Task.isCancelled {
                do {
                    try await connectToEventStream()
                    // Reset attempt counter on successful connection
                    reconnectionAttempt = 0
                } catch {
                    if !Task.isCancelled {
                        logger.error("SSE connection error: \(error)")

                        // Check if we've exceeded max retries
                        if reconnectionAttempt >= reconnectionOptions.maxRetries {
                            logger.error(
                                "Maximum reconnection attempts exceeded",
                                metadata: ["maxRetries": "\(reconnectionOptions.maxRetries)"]
                            )
                            break
                        }

                        // Calculate delay with exponential backoff
                        let delay = getNextReconnectionDelay()
                        reconnectionAttempt += 1

                        logger.debug(
                            "Scheduling reconnection",
                            metadata: [
                                "attempt": "\(reconnectionAttempt)",
                                "delay": "\(delay)s",
                            ]
                        )

                        try? await Task.sleep(for: .seconds(delay))
                    }
                }
            }
        #endif
    }

    /// Calculates the next reconnection delay using exponential backoff
    ///
    /// Uses server-provided retry value if available, otherwise falls back
    /// to exponential backoff based on current attempt count.
    ///
    /// - Returns: Time to wait in seconds before next reconnection attempt
    private func getNextReconnectionDelay() -> TimeInterval {
        // Use server-provided retry value if available
        if let serverDelay = serverRetryDelay {
            return serverDelay
        }

        // Fall back to exponential backoff
        let initialDelay = reconnectionOptions.initialReconnectionDelay
        let growFactor = reconnectionOptions.reconnectionDelayGrowFactor
        let maxDelay = reconnectionOptions.maxReconnectionDelay

        // Calculate delay with exponential growth, capped at maximum
        let delay = initialDelay * pow(growFactor, Double(reconnectionAttempt))
        return min(delay, maxDelay)
    }

    #if !os(Linux)
        /// Establishes an SSE connection to the server
        ///
        /// This initiates a GET request to the server endpoint with appropriate
        /// headers to establish an SSE stream according to the MCP specification.
        ///
        /// - Parameters:
        ///   - resumptionToken: Optional event ID to resume from (sent as Last-Event-ID header)
        ///   - originalRequestId: Optional request ID to remap response IDs to (for stream resumption)
        /// - Throws: MCPError for connection failures or server errors
        private func connectToEventStream(
            resumptionToken: String? = nil,
            originalRequestId: RequestId? = nil
        ) async throws {
            guard isConnected else { return }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.addValue("text/event-stream", forHTTPHeaderField: HTTPHeader.accept)
            request.addValue("no-cache", forHTTPHeaderField: HTTPHeader.cacheControl)

            // Add session ID if available
            if let sessionID {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeader.sessionId)
            }

            // Add protocol version if available
            if let protocolVersion {
                request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)
            }

            // Add Last-Event-ID for resumability (use provided token or stored lastEventId)
            let eventIdToSend = resumptionToken ?? lastEventId
            if let eventId = eventIdToSend {
                request.addValue(eventId, forHTTPHeaderField: HTTPHeader.lastEventId)
                logger.debug("Resuming SSE stream", metadata: ["lastEventId": "\(eventId)"])
            }

            // Apply request modifier
            request = requestModifier(request)

            logger.debug("Starting SSE connection")

            // Reset reconnection attempt on new connection
            reconnectionAttempt = 0

            // Create URLSession task for SSE
            let (stream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            // Check response status
            guard httpResponse.statusCode == 200 else {
                // If the server returns 405 Method Not Allowed,
                // it indicates that the server doesn't support SSE streaming.
                // We should cancel the task instead of retrying the connection.
                if httpResponse.statusCode == 405 {
                    self.streamingTask?.cancel()
                }
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeader.sessionId) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    // Trigger signal on first session ID, though this is unlikely to happen here
                    // as GET usually follows a POST that would have already set the session ID
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try await self.processSSE(stream, isReconnectable: true, originalRequestId: originalRequestId)
        }

        /// Processes an SSE byte stream, extracting events and delivering them
        ///
        /// This method tracks event IDs for resumability and handles the retry directive
        /// from the server to adjust reconnection timing.
        ///
        /// - Parameters:
        ///   - stream: The URLSession.AsyncBytes stream to process
        ///   - isReconnectable: Whether this stream should automatically reconnect on disconnect
        ///   - originalRequestId: Optional request ID to remap response IDs to (for stream resumption)
        /// - Throws: Error for stream processing failures
        private func processSSE(
            _ stream: URLSession.AsyncBytes,
            isReconnectable: Bool,
            originalRequestId: RequestId? = nil
        ) async throws {
            // Track whether we've received a priming event (event with ID)
            // Per spec, server SHOULD send a priming event with ID before closing
            var hasPrimingEvent = false

            // Track whether we've received a response - if so, no need to reconnect
            // Reconnection is for when server disconnects BEFORE sending response
            var receivedResponse = false

            do {
                for try await event in stream.events {
                    // Check if task has been cancelled
                    if Task.isCancelled { break }

                    logger.trace(
                        "SSE event received",
                        metadata: [
                            "type": "\(event.event ?? "message")",
                            "id": "\(event.id ?? "none")",
                            "retry": "\(event.retry.map(String.init) ?? "none")",
                        ]
                    )

                    // Update last event ID if provided
                    if let eventId = event.id {
                        lastEventId = eventId
                        // Mark that we've received a priming event - stream is now resumable
                        hasPrimingEvent = true
                        // Notify callback
                        onResumptionToken?(eventId)
                    }

                    // Handle server-provided retry directive (in milliseconds, convert to seconds)
                    if let retryMs = event.retry {
                        serverRetryDelay = TimeInterval(retryMs) / 1000.0
                        logger.debug(
                            "Server retry directive received",
                            metadata: ["retryMs": "\(retryMs)"]
                        )
                    }

                    // Skip events with no data (priming events, keep-alives)
                    if event.data.isEmpty {
                        continue
                    }

                    // Convert the event data to Data and yield it to the message stream
                    if let data = event.data.data(using: .utf8) {
                        // Process the message: detect if it's a response and optionally remap ID
                        // Per MCP spec, reconnection should only stop after receiving
                        // the response to the original request
                        let processed = processJSONRPCMessage(data, originalRequestId: originalRequestId)
                        if processed.isResponse {
                            receivedResponse = true
                        }
                        messageContinuation.yield(processed.data)
                    }
                }

                // Stream ended gracefully - check if we need to reconnect
                // Reconnect if: already reconnectable (GET stream) OR received a priming event
                // BUT don't reconnect if we already received a response - the request is complete
                let canResume = isReconnectable || hasPrimingEvent
                let needsReconnect = canResume && !receivedResponse

                if needsReconnect && isConnected && !Task.isCancelled {
                    logger.debug(
                        "SSE stream ended gracefully, will reconnect",
                        metadata: ["lastEventId": "\(lastEventId ?? "none")"]
                    )

                    // For GET streams (isReconnectable=true), the outer loop in
                    // startListeningForServerEvents handles reconnection.
                    // For POST SSE responses that received a priming event, we need to
                    // schedule reconnection via GET (per MCP spec: "Resumption is always via HTTP GET").
                    if !isReconnectable && hasPrimingEvent {
                        schedulePostSSEReconnection()
                    }
                }
            } catch {
                logger.error("Error processing SSE events: \(error)")

                // For GET streams, the outer loop will handle reconnection with exponential backoff.
                // For POST SSE responses with a priming event, schedule reconnection via GET.
                if !isReconnectable && hasPrimingEvent && !receivedResponse && isConnected
                    && !Task.isCancelled
                {
                    schedulePostSSEReconnection()
                } else {
                    throw error
                }
            }
        }

        /// Schedules reconnection for a POST SSE response that was interrupted.
        ///
        /// Per MCP spec, resumption is always via HTTP GET with Last-Event-ID header.
        /// This method spawns a task that handles reconnection with exponential backoff.
        private func schedulePostSSEReconnection() {
            guard let eventId = lastEventId else {
                logger.warning("Cannot schedule POST SSE reconnection without lastEventId")
                return
            }

            // Reset reconnection attempt counter for this new reconnection sequence
            reconnectionAttempt = 0

            Task { [weak self] in
                guard let self else { return }

                let maxRetries = self.reconnectionOptions.maxRetries

                while await self.isConnected && !Task.isCancelled {
                    let attempt = await self.reconnectionAttempt

                    if attempt >= maxRetries {
                        self.logger.error(
                            "POST SSE reconnection: max attempts exceeded",
                            metadata: ["maxRetries": "\(maxRetries)"]
                        )
                        return
                    }

                    // Calculate delay with exponential backoff
                    let delay = await self.getNextReconnectionDelay()
                    await self.incrementReconnectionAttempt()

                    self.logger.debug(
                        "POST SSE reconnection: scheduling attempt",
                        metadata: [
                            "attempt": "\(attempt + 1)",
                            "delay": "\(delay)s",
                            "lastEventId": "\(eventId)",
                        ]
                    )

                    try? await Task.sleep(for: .seconds(delay))

                    // Check again after sleep
                    guard await self.isConnected && !Task.isCancelled else { return }

                    do {
                        try await self.connectToEventStream(resumptionToken: eventId)
                        // Success - connectToEventStream handles SSE processing
                        // Reset attempt counter on success
                        await self.resetReconnectionAttempt()
                        return
                    } catch {
                        self.logger.error(
                            "POST SSE reconnection failed: \(error)",
                            metadata: ["attempt": "\(attempt + 1)"]
                        )
                        // Continue to next iteration for retry
                    }
                }
            }
        }

        /// Increments the reconnection attempt counter.
        private func incrementReconnectionAttempt() {
            reconnectionAttempt += 1
        }

        /// Resets the reconnection attempt counter.
        private func resetReconnectionAttempt() {
            reconnectionAttempt = 0
        }
    #endif

    // MARK: - Public Resumption API

    /// Resumes an SSE stream from a previous event ID.
    ///
    /// Opens a GET SSE connection with the Last-Event-ID header to replay missed events.
    /// This is useful for clients that need to reconnect after a disconnection and want
    /// to resume from where they left off.
    ///
    /// When `originalRequestId` is provided, any JSON-RPC response received on the
    /// resumed stream will have its ID remapped to match the original request. This
    /// ensures the response is correctly matched to the pending request in the client,
    /// even if the server sends a different ID during replay. This behavior aligns
    /// with the TypeScript and Python MCP SDK implementations.
    ///
    /// - Parameters:
    ///   - lastEventId: The event ID to resume from (sent as Last-Event-ID header)
    ///   - originalRequestId: Optional request ID to remap response IDs to
    /// - Throws: MCPError if the connection fails
    public func resumeStream(from lastEventId: String, forRequestId originalRequestId: RequestId? = nil) async throws {
        #if os(Linux)
            logger.warning("resumeStream is not supported on Linux (SSE not available)")
        #else
            try await connectToEventStream(resumptionToken: lastEventId, originalRequestId: originalRequestId)
        #endif
    }

    /// The last event ID received from the server.
    ///
    /// This can be used to persist the event ID and resume the stream later
    /// using `resumeStream(from:)`.
    public var lastReceivedEventId: String? {
        lastEventId
    }
}
