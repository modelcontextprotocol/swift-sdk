import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public actor HTTPClientTransport: Actor, Transport {
    public let endpoint: URL
    private let session: URLSession
    public private(set) var sessionID: String?
    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?
    private var lastEventID: String?
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = false,
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

        let (responseData, response) = try await session.data(for: request)

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

        // Handle different response types
        switch httpResponse.statusCode {
        case 200, 201, 202:
            // For SSE, the processing happens in the streaming task
            if contentType.contains("text/event-stream") {
                logger.debug("Received SSE response, processing in streaming task")
                // The streaming is handled by the SSE task if active
                return
            }

            // For JSON responses, deliver the data directly
            if contentType.contains("application/json") && !responseData.isEmpty {
                logger.debug("Received JSON response", metadata: ["size": "\(responseData.count)"])
                messageContinuation.yield(responseData)
            }
        case 404:
            // If we get a 404 with a session ID, it means our session is invalid
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError("Endpoint not found")
        default:
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return AsyncThrowingStream { continuation in
            Task {
                for try await message in messageStream {
                    continuation.yield(message)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - SSE

    /// Starts listening for server events using SSE
    private func startListeningForServerEvents() async {
        guard isConnected else { return }

        // Retry loop for connection drops
        while isConnected && !Task.isCancelled {
            do {
                try await connectToEventStream()
            } catch {
                if !Task.isCancelled {
                    logger.error("SSE connection error: \(error)")
                    // Wait before retrying
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                }
            }
        }
    }

    #if canImport(FoundationNetworking)
        private func connectToEventStream() async throws {
            logger.warning("SSE is not supported on this platform")
        }
    #else
        /// Establishes an SSE connection to the server
        private func connectToEventStream() async throws {
            guard isConnected else { return }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.addValue("text/event-stream", forHTTPHeaderField: "Accept")

            // Add session ID if available
            if let sessionID = sessionID {
                request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }

            // Add Last-Event-ID header for resumability if available
            if let lastEventID = lastEventID {
                request.addValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
            }

            logger.debug("Starting SSE connection")

            // Create URLSession task for SSE
            let (stream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            // Check response status
            guard httpResponse.statusCode == 200 else {
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
                self.sessionID = newSessionID
            }

            // Process the SSE stream
            var buffer = ""
            var eventType = ""
            var eventID: String?
            var eventData = ""

            for try await byte in stream {
                if Task.isCancelled { break }

                guard let char = String(bytes: [byte], encoding: .utf8) else { continue }
                buffer.append(char)

                // Process complete lines
                while let newlineIndex = buffer.firstIndex(of: "\n") {
                    let line = buffer[..<newlineIndex]
                    buffer = String(buffer[buffer.index(after: newlineIndex)...])

                    // Empty line marks the end of an event
                    if line.isEmpty || line == "\r" || line == "\n" || line == "\r\n" {
                        if !eventData.isEmpty {
                            // Process the event
                            if eventType == "id" {
                                lastEventID = eventID
                            } else {
                                // Default event type is "message" if not specified
                                if let data = eventData.data(using: .utf8) {
                                    logger.debug(
                                        "SSE event received",
                                        metadata: [
                                            "type": "\(eventType.isEmpty ? "message" : eventType)",
                                            "id": "\(eventID ?? "none")",
                                        ])
                                    messageContinuation.yield(data)
                                }
                            }

                            // Reset for next event
                            eventType = ""
                            eventData = ""
                        }
                        continue
                    }

                    // Lines starting with ":" are comments
                    if line.hasPrefix(":") { continue }

                    // Parse field: value format
                    if let colonIndex = line.firstIndex(of: ":") {
                        let field = String(line[..<colonIndex])
                        var value = String(line[line.index(after: colonIndex)...])

                        // Trim leading space
                        if value.hasPrefix(" ") {
                            value = String(value.dropFirst())
                        }

                        // Process based on field
                        switch field {
                        case "event":
                            eventType = value
                        case "data":
                            if !eventData.isEmpty {
                                eventData.append("\n")
                            }
                            eventData.append(value)
                        case "id":
                            if !value.contains("\0") {  // ID must not contain NULL
                                eventID = value
                                lastEventID = value
                            }
                        case "retry":
                            // Retry timing not implemented
                            break
                        default:
                            // Unknown fields are ignored per SSE spec
                            break
                        }
                    }
                }
            }
        }
    #endif
}
