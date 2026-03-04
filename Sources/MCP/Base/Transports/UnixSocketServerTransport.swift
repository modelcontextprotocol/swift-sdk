import Foundation
import Logging
import NIOCore
import NIOPosix

#if canImport(Darwin)
        import Darwin.POSIX
#elseif canImport(Glibc)
        import Glibc
#elseif canImport(Musl)
        import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        /// Unix domain socket transport for MCP servers using SwiftNIO.
        ///
        /// Creates a Unix domain socket, binds to it, and accepts multiple client connections sequentially.
        /// The transport uses newline-delimited messages and handles reconnections automatically.
        ///
        /// ## Usage
        ///
        /// ```swift
        /// let transport = UnixSocketServerTransport(
        ///     path: "/tmp/mcp.sock",
        ///     cleanup: .removeExisting
        /// )
        /// try await transport.connect()  // Starts accepting clients
        ///
        /// // Use with MCP server
        /// try await server.start(transport: transport)
        /// ```
        ///
        /// ## When to Use
        ///
        /// Use this transport when you need:
        /// - Local-only communication (same machine)
        /// - High-performance IPC
        /// - File system permission-based security
        /// - Multiple sequential client connections
        ///
        public actor UnixSocketServerTransport: Transport {
                /// Maximum socket path length in bytes
                ///
                /// - SeeAlso: https://github.com/torvalds/linux/blob/master/include/uapi/linux/un.h#L7
                /// - SeeAlso: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h#L79
                /// - SeeAlso: https://github.com/kraj/musl/blob/kraj/master/include/sys/un.h#L19
                ///
                public static let socketPathMax: Int =
                        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

                /// Strategy for handling existing socket files
                public enum SocketCleanup: Sendable {
                        /// Fail if socket file exists
                        case failIfExists
                        /// Remove existing socket file before binding
                        case removeExisting
                        /// Try to reuse if socket is stale, otherwise fail
                        case reuseIfPossible
                }

                public nonisolated let logger: Logger

                // MARK: - Configuration
                private let socketPath: String
                private let cleanup: SocketCleanup

                // MARK: - State
                private var terminated = false
                private var started = false

                // MARK: - NIO Components
                private var eventLoopGroup: MultiThreadedEventLoopGroup?
                private var serverChannel: Channel?

                // MARK: - Async Streams
                private var messageStream: AsyncThrowingStream<Data, Swift.Error>?
                private var messageContinuation:
                        AsyncThrowingStream<Data, Swift.Error>.Continuation?

                // MARK: - Current Client
                private var currentChannel: Channel?

                // MARK: - Response Waiters
                /// Maps request ID → continuation waiting for a response.
                /// When the server calls `send()` with a response, the matching continuation is resumed.
                private var responseWaiters: [String: CheckedContinuation<Data, any Error>] = [:]

                // MARK: - Init

                /// Creates a new Unix socket server transport
                ///
                /// - Parameters:
                ///   - path: File system path for the Unix socket
                ///   - cleanup: Strategy for handling existing socket files
                ///   - logger: Optional logger instance
                public init(path: String, cleanup: SocketCleanup, logger: Logger? = nil) {
                        self.socketPath = path
                        self.cleanup = cleanup
                        self.logger =
                                logger
                                ?? Logger(
                                        label: "mcp.transport.unix-socket.server",
                                        factory: { _ in SwiftLogNoOpLogHandler() })
                }

                // MARK: - Transport Conformance

                /// Starts the server (creates socket, binds, listens, accepts clients)
                ///
                /// This method starts accepting clients continuously until disconnect() is called.
                ///
                /// - Throws: `MCPError.transportError` if socket creation fails
                public func connect() async throws {
                        guard !started else {
                                // Idempotent: already started
                                return
                        }
                        guard !terminated else {
                                throw MCPError.connectionClosed
                        }

                        try validateSocketPath()
                        try handleCleanup()

                        // Create event loop group
                        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                        self.eventLoopGroup = group

                        // Create message stream
                        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
                        self.messageStream = AsyncThrowingStream { continuation = $0 }
                        self.messageContinuation = continuation

                        // Create server bootstrap
                        let bootstrap = ServerBootstrap(group: group)
                                .serverChannelOption(
                                        ChannelOptions.socketOption(.so_reuseaddr), value: 1
                                )
                                .childChannelInitializer { [weak self] channel in
                                        guard let self = self else {
                                                return channel.eventLoop.makeSucceededVoidFuture()
                                        }
                                        return channel.pipeline.addHandlers([
                                                ByteToMessageHandler(NewlineFrameDecoder()),
                                                MessageToByteHandler(NewlineFrameEncoder()),
                                                UnixSocketServerHandler(transport: self),
                                        ])
                                }

                        do {
                                let channel = try await bootstrap.bind(
                                        unixDomainSocketPath: socketPath
                                ).get()
                                self.serverChannel = channel
                                started = true

                                logger.info("Server listening", metadata: ["path": "\(socketPath)"])
                        } catch {
                                try? await group.shutdownGracefully()
                                self.eventLoopGroup = nil
                                throw MCPError.transportError(error)
                        }
                }

                /// Stops the server and cleans up the socket file
                public func disconnect() async {
                        await terminate()
                }

                /// Sends data to the current client or routes to a waiting continuation.
                ///
                /// - Responses are matched by JSON-RPC ID to waiting continuations.
                /// - If no waiter exists, the response is sent directly to the client.
                /// - Notifications and requests are always sent directly to the client.
                ///
                /// - Parameter data: Data to send
                /// - Throws: `MCPError.transportError` if not connected or write fails
                public func send(_ data: Data) async throws {
                        guard !terminated else {
                                throw MCPError.connectionClosed
                        }

                        // Classify the message for routing
                        if let kind = JSONRPCMessageKind(data: data) {
                                switch kind {
                                case .response(let id):
                                        // Check if there's a waiter for this response
                                        if let continuation = responseWaiters.removeValue(
                                                forKey: id)
                                        {
                                                continuation.resume(returning: data)
                                                return
                                        }
                                // No waiter, fall through to send to socket

                                case .notification, .request:
                                        // Always send to socket
                                        break
                                }
                        }

                        // Send to client via socket
                        guard let channel = currentChannel else {
                                throw MCPError.transportError(
                                        NSError(
                                                domain: "mcp.unix-socket", code: Int(ENOTCONN),
                                                userInfo: [
                                                        NSLocalizedDescriptionKey:
                                                                "No client connected"
                                                ]))
                        }

                        var buffer = channel.allocator.buffer(capacity: data.count)
                        buffer.writeBytes(data)

                        try await channel.writeAndFlush(buffer)
                }

                /// Receives data from clients
                ///
                /// Returns a stream of newline-delimited messages.
                ///
                /// - Returns: Async stream of received data
                public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
                        guard let stream = messageStream else {
                                return AsyncThrowingStream { $0.finish() }
                        }
                        return stream
                }

                // MARK: - Internal Methods (called from handler)

                /// JSON-RPC notification sent when a new client connects.
                /// MCP Server can handle this to reset initialization state.
                public static let newConnectionNotification = Data(
                        #"{"jsonrpc":"2.0","method":"$/connection/didOpen"}"#.utf8)

                func handleNewClient(_ channel: Channel) {
                        self.currentChannel = channel
                        // Signal new connection to the MCP Server so it can reset state
                        messageContinuation?.yield(Self.newConnectionNotification)
                        logger.info("Client connected")
                }

                func handleClientDisconnected() {
                        self.currentChannel = nil
                        // Note: We do NOT finish the message stream here.
                        // The stream lives for the lifetime of the server, not per client.
                        // This allows the MCP server layer to keep receiving from the same stream
                        // as clients connect and disconnect.
                        logger.info("Client disconnected")
                }

                func handleIncomingData(_ data: Data) {
                        // Filter out empty messages
                        guard !data.isEmpty else { return }
                        messageContinuation?.yield(data)
                }

                // MARK: - Private Implementation

                private func validateSocketPath() throws {
                        guard socketPath.utf8.count < UnixSocketServerTransport.socketPathMax else {
                                throw MCPError.internalError(
                                        "Socket path too long: \(socketPath.utf8.count) bytes (max: \(UnixSocketServerTransport.socketPathMax))"
                                )
                        }
                }

                private func handleCleanup() throws {
                        switch cleanup {
                        case .failIfExists:
                                if access(socketPath, F_OK) == 0 {
                                        throw MCPError.transportError(
                                                NSError(
                                                        domain: "mcp.unix-socket",
                                                        code: Int(EADDRINUSE),
                                                        userInfo: [
                                                                NSLocalizedDescriptionKey:
                                                                        "Socket already exists: \(socketPath)"
                                                        ]))
                                }
                        case .removeExisting:
                                if access(socketPath, F_OK) == 0 {
                                        unlink(socketPath)
                                }
                        case .reuseIfPossible:
                                if access(socketPath, F_OK) == 0 {
                                        // Try to connect to see if socket is alive
                                        let testResult = testSocketConnection()
                                        if testResult {
                                                throw MCPError.transportError(
                                                        NSError(
                                                                domain: "mcp.unix-socket",
                                                                code: Int(EADDRINUSE),
                                                                userInfo: [
                                                                        NSLocalizedDescriptionKey:
                                                                                "Socket is in use: \(socketPath)"
                                                                ]))
                                        } else {
                                                // Stale socket, remove it
                                                unlink(socketPath)
                                        }
                                }
                        }
                }

                private func testSocketConnection() -> Bool {
                        let testSock = socket(AF_UNIX, SOCK_STREAM, 0)
                        guard testSock >= 0 else { return false }

                        defer {
                                #if canImport(Darwin)
                                        Darwin.close(testSock)
                                #elseif canImport(Glibc)
                                        Glibc.close(testSock)
                                #else
                                        Musl.close(testSock)
                                #endif
                        }

                        var addr = sockaddr_un()
                        addr.sun_family = sa_family_t(AF_UNIX)
                        let pathBytes = socketPath.utf8CString
                        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                                pathBytes.withUnsafeBufferPointer { buffer in
                                        memcpy(
                                                ptr, buffer.baseAddress,
                                                min(
                                                        buffer.count,
                                                        UnixSocketServerTransport.socketPathMax))
                                }
                        }

                        let result = withUnsafePointer(to: &addr) { addrPtr in
                                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                        sockaddrPtr in
                                        #if canImport(Darwin)
                                                Darwin.connect(
                                                        testSock, sockaddrPtr,
                                                        socklen_t(MemoryLayout<sockaddr_un>.size))
                                        #elseif canImport(Glibc)
                                                Glibc.connect(
                                                        testSock, sockaddrPtr,
                                                        socklen_t(MemoryLayout<sockaddr_un>.size))
                                        #else
                                                Musl.connect(
                                                        testSock, sockaddrPtr,
                                                        socklen_t(MemoryLayout<sockaddr_un>.size))
                                        #endif
                                }
                        }

                        return result >= 0
                }

                private func terminate() async {
                        guard !terminated else { return }
                        terminated = true
                        started = false

                        // Cancel all waiting continuations
                        for (id, continuation) in responseWaiters {
                                continuation.resume(throwing: MCPError.connectionClosed)
                                logger.debug(
                                        "Cancelled waiter for request",
                                        metadata: ["requestID": "\(id)"])
                        }
                        responseWaiters.removeAll()

                        // Close server channel
                        if let channel = serverChannel {
                                try? await channel.close()
                                self.serverChannel = nil
                        }

                        // Shutdown event loop group
                        if let group = eventLoopGroup {
                                try? await group.shutdownGracefully()
                                self.eventLoopGroup = nil
                        }

                        // Clean up socket file
                        unlink(socketPath)

                        messageContinuation?.finish()
                        messageContinuation = nil
                        messageStream = nil
                        currentChannel = nil

                        logger.info("Server stopped", metadata: ["path": "\(socketPath)"])
                }
        }

        // MARK: - NIO Channel Handlers

        /// Decodes newline-delimited frames
        private final class NewlineFrameDecoder: ByteToMessageDecoder, @unchecked Sendable {
                typealias InboundOut = ByteBuffer

                func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws
                        -> DecodingState
                {
                        guard
                                let newlineIndex = buffer.readableBytesView.firstIndex(
                                        of: UInt8(ascii: "\n"))
                        else {
                                return .needMoreData
                        }

                        let length = newlineIndex - buffer.readerIndex
                        guard let frame = buffer.readSlice(length: length) else {
                                return .needMoreData
                        }

                        // Skip the newline
                        buffer.moveReaderIndex(forwardBy: 1)

                        context.fireChannelRead(self.wrapInboundOut(frame))
                        return .continue
                }

                func decodeLast(
                        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
                ) throws -> DecodingState {
                        // Process any remaining data
                        if buffer.readableBytes > 0 {
                                let frame = buffer.readSlice(length: buffer.readableBytes)!
                                context.fireChannelRead(self.wrapInboundOut(frame))
                        }
                        return .needMoreData
                }
        }

        /// Encodes frames with newline delimiter
        private final class NewlineFrameEncoder: MessageToByteEncoder, @unchecked Sendable {
                typealias OutboundIn = ByteBuffer

                func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
                        out.writeImmutableBuffer(data)
                        out.writeInteger(UInt8(ascii: "\n"))
                }
        }

        /// Handles client connections and data
        private final class UnixSocketServerHandler: ChannelInboundHandler, @unchecked Sendable {
                typealias InboundIn = ByteBuffer

                private let transport: UnixSocketServerTransport

                init(transport: UnixSocketServerTransport) {
                        self.transport = transport
                }

                func channelActive(context: ChannelHandlerContext) {
                        let channel = context.channel
                        Task.detached {
                                await self.transport.handleNewClient(channel)
                        }
                }

                func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                        var buffer = self.unwrapInboundIn(data)
                        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
                                return
                        }

                        let data = Data(bytes)
                        Task.detached {
                                await self.transport.handleIncomingData(data)
                        }
                }

                func channelInactive(context: ChannelHandlerContext) {
                        Task.detached {
                                await self.transport.handleClientDisconnected()
                        }
                }

                func errorCaught(context: ChannelHandlerContext, error: Error) {
                        // Log error and close channel
                        context.close(promise: nil)
                }
        }
#endif
