import Foundation
import Logging

/// An in-memory transport implementation for direct communication within the same process.
///
/// - Example:
///   ```swift
///   // Create a connected pair of transports
///   let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
///
///   // Use with client and server
///   let client = Client(name: "MyApp", version: "1.0.0")
///   let server = Server(name: "MyServer", version: "1.0.0")
///
///   try await client.connect(transport: clientTransport)
///   try await server.connect(transport: serverTransport)
///   ```
public actor InMemoryTransport: Transport {
    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    private var isConnected = false
    private var pairedTransport: InMemoryTransport?

    // Message queues
    private var incomingMessages: [Data] = []
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?

    /// Creates a new in-memory transport
    ///
    /// - Parameter logger: Optional logger instance for transport events
    public init(logger: Logger? = nil) {
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.in-memory",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    /// Creates a connected pair of in-memory transports
    ///
    /// This is the recommended way to create transports for client-server communication
    /// within the same process. The returned transports are already paired and ready
    /// to be connected.
    ///
    /// - Parameter logger: Optional logger instance shared by both transports
    /// - Returns: A tuple of (clientTransport, serverTransport) ready for use
    public static func createConnectedPair(
        logger: Logger? = nil
    ) async -> (client: InMemoryTransport, server: InMemoryTransport) {
        let clientLogger: Logger
        let serverLogger: Logger

        if let providedLogger = logger {
            // If a logger is provided, use it directly for both transports
            clientLogger = providedLogger
            serverLogger = providedLogger
        } else {
            // Create default loggers with appropriate labels
            clientLogger = Logger(
                label: "mcp.transport.in-memory.client",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
            serverLogger = Logger(
                label: "mcp.transport.in-memory.server",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
        }

        let clientTransport = InMemoryTransport(logger: clientLogger)
        let serverTransport = InMemoryTransport(logger: serverLogger)

        // Perform pairing
        await clientTransport.pair(with: serverTransport)
        await serverTransport.pair(with: clientTransport)

        return (clientTransport, serverTransport)
    }

    /// Pairs this transport with another for bidirectional communication
    ///
    /// - Parameter other: The transport to pair with
    /// - Important: This method should typically not be called directly.
    ///   Use `createConnectedPair()` instead.
    private func pair(with other: InMemoryTransport) {
        self.pairedTransport = other
    }

    /// Establishes connection with the transport
    ///
    /// For in-memory transports, this validates that the transport is properly
    /// paired and sets up the message stream.
    ///
    /// - Throws: MCPError.internalError if the transport is not paired
    public func connect() async throws {
        guard !isConnected else {
            logger.debug("Transport already connected")
            return
        }

        guard pairedTransport != nil else {
            throw MCPError.internalError(
                "Transport not paired. Use createConnectedPair() to create paired transports.")
        }

        isConnected = true
        logger.info("Transport connected successfully")
    }

    /// Disconnects from the transport
    ///
    /// This closes the message stream and marks the transport as disconnected.
    public func disconnect() async {
        guard isConnected else { return }

        isConnected = false
        messageContinuation?.finish()
        messageContinuation = nil

        // Notify paired transport of disconnection
        if let paired = pairedTransport {
            await paired.handlePeerDisconnection()
        }

        logger.info("Transport disconnected")
    }

    /// Handles disconnection from the paired transport
    private func handlePeerDisconnection() {
        if isConnected {
            messageContinuation?.finish(throwing: MCPError.connectionClosed)
            messageContinuation = nil
            isConnected = false
            logger.info("Peer transport disconnected")
        }
    }

    /// Sends a message to the paired transport
    ///
    /// Messages are delivered directly to the paired transport's receive queue
    /// without any additional encoding or framing.
    ///
    /// - Parameter data: The message data to send
    /// - Throws: MCPError.internalError if not connected or no paired transport
    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        guard let paired = pairedTransport else {
            throw MCPError.internalError("No paired transport")
        }

        logger.debug("Sending message", metadata: ["size": "\(data.count)"])

        // Deliver message to paired transport
        await paired.deliverMessage(data)
    }

    /// Delivers a message from the paired transport
    private func deliverMessage(_ data: Data) {
        guard isConnected else {
            logger.warning("Received message while disconnected")
            return
        }

        logger.debug("Message received", metadata: ["size": "\(data.count)"])

        if let continuation = messageContinuation {
            continuation.yield(data)
        } else {
            // Queue message if stream not yet created
            incomingMessages.append(data)
        }
    }

    /// Receives messages from the paired transport
    ///
    /// - Returns: An AsyncThrowingStream of Data objects representing messages
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return AsyncThrowingStream<Data, Swift.Error> { continuation in
            self.messageContinuation = continuation

            // Deliver any queued messages
            for message in self.incomingMessages {
                continuation.yield(message)
            }
            self.incomingMessages.removeAll()

            // Check if already disconnected
            if !self.isConnected {
                continuation.finish()
            }
        }
    }
}
