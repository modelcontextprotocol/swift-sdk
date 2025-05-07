import Foundation
import Logging

#if canImport(Network)
    import Network

    /// Protocol that abstracts the Network.NWConnection functionality needed for NetworkTransport
    @preconcurrency protocol NetworkConnectionProtocol {
        var state: NWConnection.State { get }
        var stateUpdateHandler: ((@Sendable (NWConnection.State) -> Void))? { get set }

        func start(queue: DispatchQueue)
        func cancel()
        func send(
            content: Data?, contentContext: NWConnection.ContentContext, isComplete: Bool,
            completion: NWConnection.SendCompletion)
        func receive(
            minimumIncompleteLength: Int, maximumLength: Int,
            completion: @escaping @Sendable (
                Data?, NWConnection.ContentContext?, Bool, NWError?
            ) -> Void)
    }

    /// Extension to conform NWConnection to internal NetworkConnectionProtocol
    extension NWConnection: NetworkConnectionProtocol {}

    /// An implementation of a custom MCP transport using Apple's Network framework.
    ///
    /// This transport allows MCP clients and servers to communicate over TCP/UDP connections
    /// using Apple's Network framework.
    ///
    /// - Important: This transport is available exclusively on Apple platforms
    ///   (macOS, iOS, watchOS, tvOS, visionOS) as it depends on the Network framework.
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// import MCP
    /// import Network
    ///
    /// // Create a TCP connection to a server
    /// let connection = NWConnection(
    ///     host: NWEndpoint.Host("localhost"),
    ///     port: NWEndpoint.Port(8080)!,
    ///     using: .tcp
    /// )
    ///
    /// // Initialize the transport with the connection
    /// let transport = NetworkTransport(connection: connection)
    ///
    /// // Use the transport with an MCP client
    /// let client = Client(name: "MyApp", version: "1.0.0")
    /// try await client.connect(transport: transport)
    ///
    /// // Initialize the connection
    /// let result = try await client.initialize()
    /// ```
    public actor NetworkTransport: Transport {
        /// Represents a heartbeat message for connection health monitoring.
        public struct Heartbeat: RawRepresentable, Hashable, Sendable {
            /// Magic bytes used to identify a heartbeat message.
            private static let magicBytes: [UInt8] = [0xF0, 0x9F, 0x92, 0x93]

            /// The timestamp of when the heartbeat was created.
            public let timestamp: Date

            /// Creates a new heartbeat with the current timestamp.
            public init() {
                self.timestamp = Date()
            }

            /// Creates a heartbeat with a specific timestamp.
            ///
            /// - Parameter timestamp: The timestamp for the heartbeat.
            public init(timestamp: Date) {
                self.timestamp = timestamp
            }

            // MARK: - RawRepresentable

            public typealias RawValue = [UInt8]

            /// Creates a heartbeat from its raw representation.
            ///
            /// - Parameter rawValue: The raw bytes of the heartbeat message.
            /// - Returns: A heartbeat if the raw value is valid, nil otherwise.
            public init?(rawValue: [UInt8]) {
                // Check if the data has the correct format (magic bytes + timestamp)
                guard rawValue.count >= 12,
                    rawValue.prefix(4).elementsEqual(Self.magicBytes)
                else {
                    return nil
                }

                // Extract the timestamp
                let timestampData = Data(rawValue[4..<12])
                let timestamp = timestampData.withUnsafeBytes {
                    $0.load(as: UInt64.self)
                }

                self.timestamp = Date(
                    timeIntervalSinceReferenceDate: TimeInterval(timestamp) / 1000.0)
            }

            /// Converts the heartbeat to its raw representation.
            public var rawValue: [UInt8] {
                var result = Data(Self.magicBytes)

                // Add timestamp (milliseconds since reference date)
                let timestamp = UInt64(self.timestamp.timeIntervalSinceReferenceDate * 1000)
                withUnsafeBytes(of: timestamp) { buffer in
                    result.append(contentsOf: buffer)
                }

                return Array(result)
            }

            /// Converts the heartbeat to Data.
            public var data: Data {
                return Data(self.rawValue)
            }

            /// Checks if the given data represents a heartbeat message.
            ///
            /// - Parameter data: The data to check.
            /// - Returns: true if the data is a heartbeat message, false otherwise.
            public static func isHeartbeat(_ data: Data) -> Bool {
                guard data.count >= 4 else {
                    return false
                }

                return data.prefix(4).elementsEqual(Self.magicBytes)
            }

            /// Attempts to parse a heartbeat from the given data.
            ///
            /// - Parameter data: The data to parse.
            /// - Returns: A heartbeat if the data is valid, nil otherwise.
            public static func from(data: Data) -> Heartbeat? {
                guard data.count >= 12 else {
                    return nil
                }

                return Heartbeat(rawValue: Array(data))
            }
        }

        /// Configuration for heartbeat behavior.
        public struct HeartbeatConfiguration: Hashable, Sendable {
            /// Whether heartbeats are enabled.
            public let enabled: Bool
            /// Interval between heartbeats in seconds.
            public let interval: TimeInterval

            /// Creates a new heartbeat configuration.
            ///
            /// - Parameters:
            ///   - enabled: Whether heartbeats are enabled (default: true)
            ///   - interval: Interval in seconds between heartbeats (default: 15.0)
            public init(enabled: Bool = true, interval: TimeInterval = 15.0) {
                self.enabled = enabled
                self.interval = interval
            }

            /// Default heartbeat configuration.
            public static let `default` = HeartbeatConfiguration()

            /// Configuration with heartbeats disabled.
            public static let disabled = HeartbeatConfiguration(enabled: false)
        }

        /// Configuration for connection retry behavior.
        public struct ReconnectionConfiguration: Hashable, Sendable {
            /// Whether the transport should attempt to reconnect on failure.
            public let enabled: Bool
            /// Maximum number of reconnection attempts.
            public let maxAttempts: Int
            /// Multiplier for exponential backoff on reconnect.
            public let backoffMultiplier: Double

            /// Creates a new reconnection configuration.
            ///
            /// - Parameters:
            ///   - enabled: Whether reconnection should be attempted on failure (default: true)
            ///   - maxAttempts: Maximum number of reconnection attempts (default: 5)
            ///   - backoffMultiplier: Multiplier for exponential backoff on reconnect (default: 1.5)
            public init(
                enabled: Bool = true,
                maxAttempts: Int = 5,
                backoffMultiplier: Double = 1.5
            ) {
                self.enabled = enabled
                self.maxAttempts = maxAttempts
                self.backoffMultiplier = backoffMultiplier
            }

            /// Default reconnection configuration.
            public static let `default` = ReconnectionConfiguration()

            /// Configuration with reconnection disabled.
            public static let disabled = ReconnectionConfiguration(enabled: false)

            /// Calculates the backoff delay for a given attempt number.
            ///
            /// - Parameter attempt: The current attempt number (1-based)
            /// - Returns: The delay in seconds before the next attempt
            public func backoffDelay(for attempt: Int) -> TimeInterval {
                let baseDelay = 0.5  // 500ms
                return baseDelay * pow(backoffMultiplier, Double(attempt - 1))
            }
        }

        // State tracking
        private var isConnected = false
        private var isStopping = false
        private var reconnectAttempt = 0
        private var heartbeatTask: Task<Void, Never>?
        private var lastHeartbeatTime: Date?
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        // Track connection state for continuations
        private var connectionContinuationResumed = false

        // Connection is marked nonisolated(unsafe) to allow access from closures
        private nonisolated(unsafe) var connection: NetworkConnectionProtocol

        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        // Configuration
        private let heartbeatConfig: HeartbeatConfiguration
        private let reconnectionConfig: ReconnectionConfiguration

        /// Creates a new NetworkTransport with the specified NWConnection
        ///
        /// - Parameters:
        ///   - connection: The NWConnection to use for communication
        ///   - logger: Optional logger instance for transport events
        ///   - reconnectionConfig: Configuration for reconnection behavior (default: .default)
        ///   - heartbeatConfig: Configuration for heartbeat behavior (default: .default)
        public init(
            connection: NWConnection,
            logger: Logger? = nil,
            heartbeatConfig: HeartbeatConfiguration = .default,
            reconnectionConfig: ReconnectionConfiguration = .default
        ) {
            self.init(
                connection,
                logger: logger,
                heartbeatConfig: heartbeatConfig,
                reconnectionConfig: reconnectionConfig
            )
        }

        init(
            _ connection: NetworkConnectionProtocol,
            logger: Logger? = nil,
            heartbeatConfig: HeartbeatConfiguration = .default,
            reconnectionConfig: ReconnectionConfiguration = .default
        ) {
            self.connection = connection
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.network",
                    factory: { _ in SwiftLogNoOpLogHandler() }
                )
            self.reconnectionConfig = reconnectionConfig
            self.heartbeatConfig = heartbeatConfig

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Establishes connection with the transport
        ///
        /// This initiates the NWConnection and waits for it to become ready.
        /// Once the connection is established, it starts the message receiving loop.
        ///
        /// - Throws: Error if the connection fails to establish
        public func connect() async throws {
            guard !isConnected else { return }

            // Reset state for fresh connection
            isStopping = false
            reconnectAttempt = 0

            // Reset continuation state
            connectionContinuationResumed = false

            // Wait for connection to be ready
            try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCPError.internalError("Transport deallocated"))
                    return
                }

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }

                    Task { @MainActor in
                        switch state {
                        case .ready:
                            await self.handleConnectionReady(continuation: continuation)
                        case .failed(let error):
                            await self.handleConnectionFailed(
                                error: error, continuation: continuation)
                        case .cancelled:
                            await self.handleConnectionCancelled(continuation: continuation)
                        case .waiting(let error):
                            self.logger.debug("Connection waiting: \(error)")
                        case .preparing:
                            self.logger.debug("Connection preparing...")
                        case .setup:
                            self.logger.debug("Connection setup...")
                        @unknown default:
                            self.logger.warning("Unknown connection state")
                        }
                    }
                }

                connection.start(queue: .main)
            }
        }

        /// Handles when the connection reaches the ready state
        ///
        /// - Parameter continuation: The continuation to resume when connection is ready
        private func handleConnectionReady(continuation: CheckedContinuation<Void, Swift.Error>)
            async
        {
            if !connectionContinuationResumed {
                connectionContinuationResumed = true
                isConnected = true

                // Reset reconnect attempt counter on successful connection
                reconnectAttempt = 0
                logger.info("Network transport connected successfully")
                continuation.resume()

                // Start the receive loop after connection is established
                Task { await self.receiveLoop() }

                // Start heartbeat task if enabled
                if heartbeatConfig.enabled {
                    startHeartbeat()
                }
            }
        }

        /// Starts a task to periodically send heartbeats to check connection health
        private func startHeartbeat() {
            // Cancel any existing heartbeat task
            heartbeatTask?.cancel()

            // Start a new heartbeat task
            heartbeatTask = Task { [weak self] in
                guard let self = self else { return }

                // Initial delay before starting heartbeats
                try? await Task.sleep(for: .seconds(1))

                while !Task.isCancelled {
                    do {
                        // Check actor-isolated properties first
                        let isStopping = await self.isStopping
                        let isConnected = await self.isConnected

                        guard !isStopping && isConnected else { break }

                        try await self.sendHeartbeat()
                        try await Task.sleep(for: .seconds(self.heartbeatConfig.interval))
                    } catch {
                        // If heartbeat fails, log and retry after a shorter interval
                        self.logger.warning("Heartbeat failed: \(error)")
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        }

        /// Sends a heartbeat message to verify connection health
        private func sendHeartbeat() async throws {
            guard isConnected && !isStopping else { return }

            // Try to send the heartbeat (without the newline delimiter used for normal messages)
            try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCPError.internalError("Transport deallocated"))
                    return
                }

                connection.send(
                    content: Heartbeat().data,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            Task { [weak self] in
                                await self?.setLastHeartbeatTime(Date())
                            }
                            continuation.resume()
                        }
                    })
            }

            logger.debug("Heartbeat sent")
        }

        /// Handles connection failure
        ///
        /// - Parameters:
        ///   - error: The error that caused the connection to fail
        ///   - continuation: The continuation to resume with the error
        private func handleConnectionFailed(
            error: Swift.Error, continuation: CheckedContinuation<Void, Swift.Error>
        ) async {
            if !connectionContinuationResumed {
                connectionContinuationResumed = true
                logger.error("Connection failed: \(error)")

                await handleReconnection(
                    error: error,
                    continuation: continuation,
                    context: "failure"
                )
            }
        }

        /// Handles connection cancellation
        ///
        /// - Parameter continuation: The continuation to resume with cancellation error
        private func handleConnectionCancelled(continuation: CheckedContinuation<Void, Swift.Error>)
            async
        {
            if !connectionContinuationResumed {
                connectionContinuationResumed = true
                logger.warning("Connection cancelled")

                await handleReconnection(
                    error: MCPError.internalError("Connection cancelled"),
                    continuation: continuation,
                    context: "cancellation"
                )
            }
        }

        /// Common reconnection handling logic
        ///
        /// - Parameters:
        ///   - error: The error that triggered the reconnection
        ///   - continuation: The continuation to resume with the error
        ///   - context: The context of the reconnection (for logging)
        private func handleReconnection(
            error: Swift.Error,
            continuation: CheckedContinuation<Void, Swift.Error>,
            context: String
        ) async {
            if !isStopping,
                reconnectionConfig.enabled,
                reconnectAttempt < reconnectionConfig.maxAttempts
            {
                // Try to reconnect with exponential backoff
                reconnectAttempt += 1
                logger.info(
                    "Attempting reconnection after \(context) (\(reconnectAttempt)/\(reconnectionConfig.maxAttempts))..."
                )

                // Calculate backoff delay
                let delay = reconnectionConfig.backoffDelay(for: reconnectAttempt)

                // Schedule reconnection attempt after delay
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    if !isStopping {
                        // Cancel the current connection before attempting to reconnect.
                        self.connection.cancel()
                        // Resume original continuation with error; outer logic or a new call to connect() will handle retry.
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: error)  // Stopping, so fail.
                    }
                }
            } else {
                // Not configured to reconnect, exceeded max attempts, or stopping
                self.connection.cancel()  // Ensure connection is cancelled
                continuation.resume(throwing: error)
            }
        }

        /// Disconnects from the transport
        ///
        /// This cancels the NWConnection, finalizes the message stream,
        /// and releases associated resources.
        public func disconnect() async {
            guard isConnected else { return }

            // Mark as stopping to prevent reconnection attempts during disconnect
            isStopping = true
            isConnected = false

            // Cancel heartbeat task if it exists
            heartbeatTask?.cancel()
            heartbeatTask = nil

            connection.cancel()
            messageContinuation.finish()
            logger.info("Network transport disconnected")
        }

        /// Sends data through the network connection
        ///
        /// This sends a JSON-RPC message through the NWConnection, adding a newline
        /// delimiter to mark the end of the message.
        ///
        /// - Parameter message: The JSON-RPC message to send
        /// - Throws: MCPError for transport failures or connection issues
        public func send(_ message: Data) async throws {
            guard isConnected else {
                throw MCPError.internalError("Transport not connected")
            }

            // Add newline as delimiter
            var messageWithNewline = message
            messageWithNewline.append(UInt8(ascii: "\n"))

            // Use a local actor-isolated variable to track continuation state
            var sendContinuationResumed = false

            try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCPError.internalError("Transport deallocated"))
                    return
                }

                connection.send(
                    content: messageWithNewline,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        guard let self = self else { return }

                        Task { @MainActor in
                            if !sendContinuationResumed {
                                sendContinuationResumed = true
                                if let error = error {
                                    self.logger.error("Send error: \(error)")

                                    // Check if we should attempt to reconnect on send failure
                                    let isStopping = await self.isStopping  // Await actor-isolated property
                                    if !isStopping && self.reconnectionConfig.enabled {
                                        let isConnected = await self.isConnected
                                        if isConnected {
                                            if error.isConnectionLost {
                                                self.logger.warning(
                                                    "Connection appears broken, will attempt to reconnect..."
                                                )

                                                // Schedule connection restart
                                                Task { [weak self] in  // Operate on self's executor
                                                    guard let self = self else { return }

                                                    await self.setIsConnected(false)

                                                    try? await Task.sleep(for: .milliseconds(500))

                                                    let currentIsStopping = await self.isStopping
                                                    if !currentIsStopping {
                                                        // Cancel the connection, then attempt to reconnect fully.
                                                        self.connection.cancel()
                                                        try? await self.connect()
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    continuation.resume(
                                        throwing: MCPError.internalError("Send error: \(error)"))
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                    })
            }
        }

        /// Receives data in an async sequence
        ///
        /// This returns an AsyncThrowingStream that emits Data objects representing
        /// each JSON-RPC message received from the network connection.
        ///
        /// - Returns: An AsyncThrowingStream of Data objects
        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return messageStream
        }

        /// Continuous loop to receive and process incoming messages
        ///
        /// This method runs continuously while the connection is active,
        /// receiving data and yielding complete messages to the message stream.
        /// Messages are delimited by newline characters.
        private func receiveLoop() async {
            var buffer = Data()
            var consecutiveEmptyReads = 0
            let maxConsecutiveEmptyReads = 5

            while isConnected && !Task.isCancelled && !isStopping {
                do {
                    let newData = try await receiveData()

                    // Check for EOF or empty data
                    if newData.isEmpty {
                        consecutiveEmptyReads += 1

                        if consecutiveEmptyReads >= maxConsecutiveEmptyReads {
                            logger.warning(
                                "Multiple consecutive empty reads (\(consecutiveEmptyReads)), possible connection issue"
                            )

                            // Check connection state
                            if connection.state != .ready {
                                logger.info("Connection no longer ready, exiting receive loop")
                                break
                            }
                        }

                        // Brief pause before retry
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }

                    // Check if this is a heartbeat message
                    if Heartbeat.isHeartbeat(newData) {
                        logger.debug("Received heartbeat from peer")

                        // Extract timestamp if available
                        if let heartbeat = Heartbeat.from(data: newData) {
                            logger.debug("Heartbeat timestamp: \(heartbeat.timestamp)")
                        }

                        // Reset the counter since we got valid data
                        consecutiveEmptyReads = 0
                        continue  // Skip regular message processing for heartbeats
                    }

                    // Reset counter on successful data read
                    consecutiveEmptyReads = 0
                    buffer.append(newData)

                    // Process complete messages
                    while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let messageData = buffer[..<newlineIndex]
                        buffer = buffer[(newlineIndex + 1)...]

                        if !messageData.isEmpty {
                            logger.debug(
                                "Message received", metadata: ["size": "\(messageData.count)"])
                            messageContinuation.yield(Data(messageData))
                        }
                    }
                } catch let error as NWError {
                    if !Task.isCancelled && !isStopping {
                        logger.error("Network error occurred", metadata: ["error": "\(error)"])

                        // Check for specific connection-related errors
                        if error.isConnectionLost {
                            // If we should reconnect, don't finish the message stream yet
                            if reconnectionConfig.enabled
                                && reconnectAttempt < reconnectionConfig.maxAttempts
                            {
                                reconnectAttempt += 1
                                logger.info(
                                    "Network connection lost, attempting reconnection (\(reconnectAttempt)/\(reconnectionConfig.maxAttempts))..."
                                )

                                // Mark as not connected while attempting reconnection
                                isConnected = false

                                // Schedule reconnection attempt
                                Task {
                                    let delay = reconnectionConfig.backoffDelay(
                                        for: reconnectAttempt)
                                    try? await Task.sleep(for: .seconds(delay))

                                    if !isStopping {
                                        // Cancel the connection, then attempt to reconnect fully.
                                        self.connection.cancel()
                                        try? await self.connect()

                                        // If connect succeeded, a new receive loop will be started
                                    }
                                }

                                // Exit this receive loop since we're starting a new one after reconnect
                                break
                            } else {
                                // We're not reconnecting, finish the message stream with error
                                messageContinuation.finish(
                                    throwing: MCPError.transportError(error))
                                break
                            }
                        } else {
                            // For other network errors, log but continue trying
                            do {
                                try await Task.sleep(for: .milliseconds(100))  // 100ms pause
                                continue
                            } catch {
                                logger.error("Failed to sleep after network error: \(error)")
                                break
                            }
                        }
                    }
                    break
                } catch {
                    if !Task.isCancelled && !isStopping {
                        logger.error("Receive error: \(error)")

                        if reconnectionConfig.enabled
                            && reconnectAttempt < reconnectionConfig.maxAttempts
                        {
                            // Similar reconnection logic for other errors
                            reconnectAttempt += 1
                            logger.info(
                                "Error during receive, attempting reconnection (\(reconnectAttempt)/\(reconnectionConfig.maxAttempts))..."
                            )

                            isConnected = false

                            Task {
                                let delay = reconnectionConfig.backoffDelay(for: reconnectAttempt)
                                try? await Task.sleep(for: .seconds(delay))

                                if !isStopping {
                                    self.connection.cancel()
                                    try? await connect()
                                }
                            }

                            break
                        } else {
                            messageContinuation.finish(throwing: error)
                        }
                    }
                    break
                }
            }

            // If stopping normally, finish the stream without error
            if isStopping {
                logger.debug("Receive loop stopping normally")
                messageContinuation.finish()
            }
        }

        /// Receives a chunk of data from the network connection
        ///
        /// - Returns: The received data chunk
        /// - Throws: Network errors or transport failures
        private func receiveData() async throws -> Data {
            var receiveContinuationResumed = false

            return try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Data, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCPError.internalError("Transport deallocated"))
                    return
                }

                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    content, _, isComplete, error in
                    Task { @MainActor in
                        if !receiveContinuationResumed {
                            receiveContinuationResumed = true
                            if let error = error {
                                continuation.resume(throwing: MCPError.transportError(error))
                            } else if let content = content {
                                continuation.resume(returning: content)
                            } else if isComplete {
                                self.logger.debug("Connection completed by peer")
                                continuation.resume(throwing: MCPError.connectionClosed)
                            } else {
                                // EOF: Resume with empty data instead of throwing an error
                                continuation.resume(returning: Data())
                            }
                        }
                    }
                }
            }
        }

        private func setLastHeartbeatTime(_ time: Date) {
            self.lastHeartbeatTime = time
        }

        private func setIsConnected(_ connected: Bool) {
            self.isConnected = connected
        }
    }

    extension NWError {
        /// Whether this error indicates a connection has been lost or reset.
        fileprivate var isConnectionLost: Bool {
            let nsError = self as NSError
            return nsError.code == 57  // Socket is not connected (EHOSTUNREACH or ENOTCONN)
                || nsError.code == 54  // Connection reset by peer (ECONNRESET)
        }
    }
#endif
