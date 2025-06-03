import Foundation
import Logging

#if !os(Linux)
    import EventSource

    /// An implementation of the MCP HTTP with SSE transport protocol.
    ///
    /// This transport implements the [HTTP with SSE transport](https://modelcontextprotocol.io/specification/2024-11-05/basic/transports#http-with-sse)
    /// specification from the Model Context Protocol.
    ///
    /// It supports:
    /// - Sending JSON-RPC messages via HTTP POST requests
    /// - Receiving responses via SSE events
    /// - Automatic handling of endpoint discovery
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Create an SSE transport with the server endpoint
    /// let transport = SSETransport(
    ///     endpoint: URL(string: "http://localhost:8080")!,
    ///     token: "your-auth-token" // Optional
    /// )
    ///
    /// // Initialize the client with the transport
    /// let client = Client(name: "MyApp", version: "1.0.0")
    /// try await client.connect(transport: transport)
    ///
    /// // The transport will automatically handle SSE events
    /// // and deliver them through the client's notification handlers
    /// ```
    public actor SSEClientTransport: Transport {
        /// The server endpoint URL to connect to
        public let endpoint: URL

        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        /// Whether the transport is currently connected
        public private(set) var isConnected: Bool = false

        /// The URL to send messages to, provided by the server in the 'endpoint' event
        private var messageURL: URL?

        /// Authentication token for requests (if required)
        private let token: String?

        /// The URLSession for network requests
        private let session: URLSession

        /// Task for SSE streaming connection
        private var streamingTask: Task<Void, Never>?

        /// Used for async/await in connect()
        private var connectionContinuation: CheckedContinuation<Void, Swift.Error>?

        /// Stream for receiving messages
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        /// Creates a new SSE transport with the specified endpoint
        ///
        /// - Parameters:
        ///   - endpoint: The server URL to connect to
        ///   - token: Optional authentication token
        ///   - configuration: URLSession configuration to use (default: .default)
        ///   - logger: Optional logger instance for transport events
        public init(
            endpoint: URL,
            token: String? = nil,
            configuration: URLSessionConfiguration = .default,
            logger: Logger? = nil
        ) {
            self.endpoint = endpoint
            self.token = token
            self.session = URLSession(configuration: configuration)

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream<Data, Swift.Error> { continuation = $0 }
            self.messageContinuation = continuation

            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.sse",
                    factory: { _ in SwiftLogNoOpLogHandler() }
                )
        }

        /// Establishes connection with the transport
        ///
        /// This creates an SSE connection to the server and waits for the 'endpoint'
        /// event to receive the URL for sending messages.
        public func connect() async throws {
            guard !isConnected else { return }

            logger.info("Connecting to SSE endpoint: \(endpoint)")

            // Start listening for server events
            streamingTask = Task { await listenForServerEvents() }

            // Wait for the endpoint URL to be received with a timeout
            return try await withThrowingTaskGroup(of: Void.self) { group in
                // Add the connection task
                group.addTask {
                    try await self.waitForConnection()
                }

                // Add the timeout task
                group.addTask {
                    try await Task.sleep(for: .seconds(5))  // 5 second timeout
                    throw MCPError.internalError("Connection timeout waiting for endpoint URL")
                }

                // Take the first result and cancel the other task
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                throw MCPError.internalError("Connection failed")
            }
        }

        /// Waits for the connection to be established
        private func waitForConnection() async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.connectionContinuation = continuation
            }
        }

        /// Disconnects from the transport
        ///
        /// This terminates the SSE connection and releases resources.
        public func disconnect() async {
            guard isConnected else { return }

            logger.info("Disconnecting from SSE endpoint")

            // Cancel the streaming task
            streamingTask?.cancel()
            streamingTask = nil

            // Clean up
            isConnected = false
            messageContinuation.finish()

            // If there's a pending connection continuation, fail it
            if let continuation = connectionContinuation {
                continuation.resume(throwing: MCPError.internalError("Connection closed"))
                connectionContinuation = nil
            }

            // Cancel any in-progress requests
            session.invalidateAndCancel()
        }

        /// Sends a JSON-RPC message to the server
        ///
        /// This sends data to the message endpoint provided by the server
        /// during connection setup.
        ///
        /// - Parameter data: The JSON-RPC message to send
        /// - Throws: MCPError if there's no message URL or if the request fails
        public func send(_ data: Data) async throws {
            guard isConnected else {
                throw MCPError.internalError("Transport not connected")
            }

            guard let messageURL = messageURL else {
                throw MCPError.internalError("No message URL provided by server")
            }

            logger.debug("Sending message", metadata: ["size": "\(data.count)"])

            var request = URLRequest(url: messageURL)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Add authorization if token is provided
            if let token = token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }
        }

        /// Receives data in an async sequence
        ///
        /// This returns an AsyncThrowingStream that emits Data objects representing
        /// each JSON-RPC message received from the server via SSE.
        ///
        /// - Returns: An AsyncThrowingStream of Data objects
        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return messageStream
        }

        // MARK: - Private Methods

        /// Main task that listens for server-sent events
        private func listenForServerEvents() async {
            let maxAttempts = 3
            var currentAttempt = 0
            var lastErrorEncountered: Swift.Error?

            while !Task.isCancelled && currentAttempt < maxAttempts {
                currentAttempt += 1
                do {
                    logger.info(
                        "Attempting SSE connection (attempt \(currentAttempt)/\(maxAttempts)) to \(endpoint)"
                    )
                    try await connectToSSEStream()
                    // If connectToSSEStream() returns without throwing, it means the stream of events finished.
                    // If connectionContinuation is still set at this point, it means we never got the 'endpoint' event.
                    if let continuation = self.connectionContinuation {
                        logger.error(
                            "SSE stream ended before 'endpoint' event was received during initial connection phase."
                        )
                        let streamEndedError = MCPError.internalError(
                            "SSE stream ended before 'endpoint' event was received.")
                        continuation.resume(throwing: streamEndedError)
                        self.connectionContinuation = nil  // Mark as handled
                    }
                    // If stream ended (either successfully resolving continuation or not), exit listenForServerEvents.
                    logger.debug(
                        "SSE stream processing completed or stream ended. Connection active: \(isConnected)"
                    )
                    return
                } catch {
                    // Check for cancellation immediately after an error.
                    if Task.isCancelled {
                        logger.info(
                            "SSE connection task cancelled after an error during attempt \(currentAttempt)."
                        )
                        lastErrorEncountered = error  // Store error that occurred before cancellation
                        break  // Exit the retry loop; cancellation will be handled after the loop.
                    }

                    lastErrorEncountered = error  // Store the error from this attempt.
                    logger.warning(
                        "SSE connection attempt \(currentAttempt)/\(maxAttempts) failed: \(error.localizedDescription)"
                    )

                    if currentAttempt < maxAttempts && !Task.isCancelled {  // If there are more attempts left
                        do {
                            let delay: TimeInterval
                            if currentAttempt == 1 {
                                delay = 0.5
                            }  // After 1st attempt fails
                            else {
                                delay = 1.0
                            }  // After 2nd attempt fails

                            logger.info(
                                "Waiting \(delay) seconds before next SSE connection attempt (attempt \(currentAttempt + 1))."
                            )
                            try await Task.sleep(for: .seconds(delay))
                        } catch {  // Catch cancellation of sleep
                            logger.info("SSE connection retry sleep was cancelled.")
                            // lastErrorEncountered is already set from the connection attempt.
                            // Task.isCancelled will be true, so the loop condition or post-loop check will handle it.
                            break  // Exit the retry loop.
                        }
                    }
                }
            }  // End of while loop

            // After the loop (due to Task.isCancelled or currentAttempt >= maxAttempts)
            if let continuation = self.connectionContinuation {
                // This continuation is still pending; means connection never established successfully.
                if Task.isCancelled {
                    logger.info(
                        "SSE connection attempt was cancelled. Failing pending connection continuation."
                    )
                    // Use lastErrorEncountered if cancellation happened after an error, otherwise a generic cancellation error.
                    let cancelError =
                        lastErrorEncountered
                        ?? MCPError.internalError("Connection attempt cancelled.")
                    continuation.resume(throwing: cancelError)
                } else if currentAttempt >= maxAttempts {  // This implies !Task.isCancelled
                    logger.error(
                        "All \(maxAttempts) SSE connection attempts failed. Failing pending connection continuation with last error: \(lastErrorEncountered?.localizedDescription ?? "N/A")"
                    )
                    let finalError =
                        lastErrorEncountered
                        ?? MCPError.internalError(
                            "All SSE connection attempts failed after unknown error.")
                    continuation.resume(throwing: finalError)
                }
                self.connectionContinuation = nil  // Ensure it's nilled after use.
            }
            logger.debug(
                "listenForServerEvents task finished. Final connection state: \(isConnected). Message URL: \(String(describing: self.messageURL))"
            )
        }

        /// Establishes the SSE stream connection
        private func connectToSSEStream() async throws {
            logger.debug("Starting SSE connection")

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            // Add authorization if token is provided
            if let token = token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            // On supported platforms, we use the EventSource implementation
            let (byteStream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            guard httpResponse.statusCode == 200 else {
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            guard let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                contentType.contains("text/event-stream")
            else {
                throw MCPError.internalError("Invalid content type for SSE stream")
            }

            logger.debug("SSE connection established")

            // Process the SSE stream
            for try await event in byteStream.events {
                // Check if task has been cancelled
                if Task.isCancelled { break }

                processServerSentEvent(event)
            }
        }

        /// Processes a server-sent event
        private func processServerSentEvent(_ event: SSE) {
            // Process event based on type
            switch event.event {
            case "endpoint":
                if !event.data.isEmpty {
                    processEndpointURL(event.data)
                } else {
                    logger.error("Received empty endpoint data")
                }

            case "message", nil:  // Default event type is "message" per SSE spec
                if !event.data.isEmpty,
                    let messageData = event.data.data(using: .utf8)
                {
                    messageContinuation.yield(messageData)
                } else {
                    logger.warning("Received empty message data")
                }

            default:
                logger.warning("Received unknown event type: \(event.event ?? "nil")")
            }
        }

        /// Processes an endpoint URL string received from the server
        private func processEndpointURL(_ endpoint: String) {
            logger.debug("Received endpoint path: \(endpoint)")

            // Construct the full URL for sending messages
            if let url = constructMessageURL(from: endpoint) {
                messageURL = url
                logger.info("Message URL set to: \(url)")

                // Mark as connected
                isConnected = true

                // Resume the connection continuation if it exists
                if let continuation = connectionContinuation {
                    continuation.resume()
                    connectionContinuation = nil
                }
            } else {
                logger.error("Failed to construct message URL from path: \(endpoint)")

                // Fail the connection if we have a continuation
                if let continuation = connectionContinuation {
                    continuation.resume(throwing: MCPError.internalError("Invalid endpoint URL"))
                    connectionContinuation = nil
                }
            }
        }

        /// Constructs a message URL from a path or absolute URL
        private func constructMessageURL(from path: String) -> URL? {
            // Handle absolute URLs
            if path.starts(with: "http://") || path.starts(with: "https://") {
                return URL(string: path)
            }

            // Handle relative paths
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true)
            else {
                return nil
            }

            // For relative paths, preserve the scheme, host, and port
            let pathToUse = path.starts(with: "/") ? path : "/\(path)"
            components.path = pathToUse
            return components.url
        }
    }
#endif
