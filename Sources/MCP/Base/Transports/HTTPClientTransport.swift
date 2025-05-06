import Foundation
import Logging

#if !os(Linux)
    import EventSource
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

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
/// // Create a streaming HTTP transport
/// let transport = HTTPClientTransport(
///     endpoint: URL(string: "http://localhost:8080")!,
/// )
///
/// // Initialize the client with streaming transport
/// let client = Client(name: "MyApp", version: "1.0.0")
/// try await client.connect(transport: transport)
///
/// // Initialize the connection
/// let result = try await client.initialize()
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
    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// Maximum time to wait for a session ID before proceeding with SSE connection
    public let sseInitializationTimeout: TimeInterval

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var initialSessionIDSignalTask: Task<Void, Never>?
    private var initialSessionIDContinuation: CheckedContinuation<Void, Never>?

    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests
    ///   - streaming: Whether to enable SSE streaming mode (default: true)
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        logger: Logger? = nil
    ) {
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            logger: logger
        )
    }

    internal init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        sseInitializationTimeout: TimeInterval = 10,
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming
        self.sseInitializationTimeout = sseInitializationTimeout

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
                // This task will suspend here until continuation.resume() is called
            }
        }
    }

    // Trigger the initial session ID signal when a session ID is established
    private func triggerInitialSessionIDSignal() {
        if let continuation = self.initialSessionIDContinuation {
            continuation.resume()
            self.initialSessionIDContinuation = nil  // Consume the continuation
            logger.debug("Initial session ID signal triggered for SSE task.")
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
        setupInitialSessionIDSignal()

        if streaming {
            // Start listening to server events
            streamingTask = Task { await startListeningForServerEvents() }
        }

        logger.info("HTTP transport connected")
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

        // Cancel the initial session ID signal task if active
        initialSessionIDSignalTask?.cancel()
        initialSessionIDSignalTask = nil
        // Resume the continuation if it's still pending to avoid leaks
        initialSessionIDContinuation?.resume()
        initialSessionIDContinuation = nil

        logger.info("HTTP clienttransport disconnected")
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
    /// - Parameter data: The JSON-RPC message to send
    /// - Throws: MCPError for transport failures or server errors
    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        // Add session ID if available
        if let sessionID = sessionID {
            request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        #if os(Linux)
            // Linux implementation using data(for:) instead of bytes(for:)
            let (responseData, response) = try await session.data(for: request)
            try await processResponse(response: response, data: responseData)
        #else
            // macOS and other platforms with bytes(for:) support
            let (responseStream, response) = try await session.bytes(for: request)
            try await processResponse(response: response, stream: responseStream)
        #endif
    }

    #if os(Linux)
        // Process response with data payload (Linux)
        private func processResponse(response: URLResponse, data: Data) async throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            // Process the response based on content type and status code
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
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

            // For JSON responses, yield the data
            if contentType.contains("text/event-stream") {
                logger.warning("SSE responses aren't fully supported on Linux")
                messageContinuation.yield(data)
            } else if contentType.contains("application/json") {
                logger.debug("Received JSON response", metadata: ["size": "\(data.count)"])
                messageContinuation.yield(data)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #else
        // Process response with byte stream (macOS, iOS, etc.)
        private func processResponse(response: URLResponse, stream: URLSession.AsyncBytes)
            async throws
        {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            // Process the response based on content type and status code
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
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
                // For SSE, processing happens via the stream
                logger.debug("Received SSE response, processing in streaming task")
                try await self.processSSE(stream)
            } else if contentType.contains("application/json") {
                // For JSON responses, collect and deliver the data
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                }
                logger.debug("Received JSON response", metadata: ["size": "\(buffer.count)"])
                messageContinuation.yield(buffer)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #endif

    // Common HTTP response handling for all platforms
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
            if self.sessionID == nil, let signalTask = self.initialSessionIDSignalTask {
                logger.debug("SSE streaming task waiting for initial sessionID signal...")

                // Race the signalTask against a timeout
                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(self.sseInitializationTimeout))
                    return false
                }

                let signalCompletionTask = Task {
                    await signalTask.value
                    return true  // Indicates signal received
                }

                // Use TaskGroup to race the two tasks
                var signalReceived = false
                do {
                    signalReceived = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            await signalCompletionTask.value
                        }
                        group.addTask {
                            await timeoutTask.value
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

                // Clean up tasks
                timeoutTask.cancel()

                if signalReceived {
                    logger.debug("SSE streaming task proceeding after initial sessionID signal.")
                } else {
                    logger.warning(
                        "Timeout waiting for initial sessionID signal. SSE stream will proceed (sessionID might be nil)."
                    )
                }
            } else if self.sessionID != nil {
                logger.debug(
                    "Initial sessionID already available. Proceeding with SSE streaming task immediately."
                )
            } else {
                logger.info(
                    "Proceeding with SSE connection attempt; sessionID is nil. This might be expected for stateless servers or if initialize hasn't provided one yet."
                )
            }

            // Retry loop for connection drops
            while isConnected && !Task.isCancelled {
                do {
                    try await connectToEventStream()
                } catch {
                    if !Task.isCancelled {
                        logger.error("SSE connection error: \(error)")
                        // Wait before retrying
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        #endif
    }

    #if !os(Linux)
        /// Establishes an SSE connection to the server
        ///
        /// This initiates a GET request to the server endpoint with appropriate
        /// headers to establish an SSE stream according to the MCP specification.
        ///
        /// - Throws: MCPError for connection failures or server errors
        private func connectToEventStream() async throws {
            guard isConnected else { return }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.addValue("no-cache", forHTTPHeaderField: "Cache-Control")

            // Add session ID if available
            if let sessionID = sessionID {
                request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }

            logger.debug("Starting SSE connection")

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
            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    // Trigger signal on first session ID, though this is unlikely to happen here
                    // as GET usually follows a POST that would have already set the session ID
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try await self.processSSE(stream)
        }

        /// Processes an SSE byte stream, extracting events and delivering them
        ///
        /// - Parameter stream: The URLSession.AsyncBytes stream to process
        /// - Throws: Error for stream processing failures
        private func processSSE(_ stream: URLSession.AsyncBytes) async throws {
            do {
                for try await event in stream.events {
                    // Check if task has been cancelled
                    if Task.isCancelled { break }

                    logger.debug(
                        "SSE event received",
                        metadata: [
                            "type": "\(event.event ?? "message")",
                            "id": "\(event.id ?? "none")",
                        ]
                    )

                    // Convert the event data to Data and yield it to the message stream
                    if !event.data.isEmpty, let data = event.data.data(using: .utf8) {
                        messageContinuation.yield(data)
                    }
                }
            } catch {
                logger.error("Error processing SSE events: \(error)")
                throw error
            }
        }
    #endif
}
