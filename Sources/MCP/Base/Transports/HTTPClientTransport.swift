import Foundation
import Logging

#if !os(Linux)
    import EventSource
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public actor HTTPClientTransport: Actor, Transport {
    public let endpoint: URL
    private let session: URLSession
    public private(set) var sessionID: String?
    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        logger: Logger? = nil
    ) {
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            logger: logger
        )
    }

    internal init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming

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

    /// Establishes connection with the transport
    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        if streaming {
            // Start listening to server events
            streamingTask = Task { await startListeningForServerEvents() }
        }

        logger.info("HTTP transport connected")
    }

    /// Disconnects from the transport
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

        logger.info("HTTP clienttransport disconnected")
    }

    /// Sends data through an HTTP POST request
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
                self.sessionID = newSessionID
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
                self.sessionID = newSessionID
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
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - SSE

    /// Starts listening for server events using SSE
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
                self.sessionID = newSessionID
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try await self.processSSE(stream)
        }

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
