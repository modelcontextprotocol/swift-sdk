import Foundation
import Logging

#if canImport(System)
        import System
#else
        @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
        import Darwin.POSIX
#elseif canImport(Glibc)
        import Glibc
#elseif canImport(Musl)
        import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        /// Unix domain socket transport for MCP clients.
        ///
        /// Connects to an existing Unix domain socket and provides
        /// communication for local connections.
        ///
        /// The transport uses newline-delimited messages and supports reconnection cycles.
        ///
        /// ## Usage
        ///
        /// ```swift
        /// let transport = UnixSocketClientTransport(
        ///     path: "/tmp/mcp.sock"
        /// )
        ///
        /// // Start MCP server
        /// try await server.start(transport: transport)
        ///
        /// ```
        ///
        /// ## When to Use
        ///
        /// Use this transport when local only commincation is prefered.
        ///
        public actor UnixSocketClientTransport: Transport {
                /// Maximum socket path length in bytes
                ///
                /// - SeeAlso: https://github.com/torvalds/linux/blob/master/include/uapi/linux/un.h#L7
                /// - SeeAlso: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h#L79
                /// - SeeAlso: https://github.com/kraj/musl/blob/kraj/master/include/sys/un.h#L19
                ///
                public static let socketPathMax: Int =
                        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

                public nonisolated let logger: Logger

                // MARK: - State
                private var terminated = false
                private var started = false

                /// MARK: - Socket
                private var socketDescriptor: FileDescriptor?
                private let socketPath: String

                // MARK: - ASync
                private var isConnected = false
                private var messageStream: AsyncThrowingStream<Data, Swift.Error>?
                private var messageContinuation:
                        AsyncThrowingStream<Data, Swift.Error>.Continuation?

                private var readLoopTask: Task<Void, Never>?

                /// Creates a new Unix socket client transport
                ///
                /// - Parameters:
                ///   - path: File system path for the Unix socket
                ///   - logger: Optional logger instance
                public init(path: String, logger: Logger? = nil) {
                        self.socketPath = path
                        self.logger =
                                logger
                                ?? Logger(
                                        label: "mcp.transport.unix-socket.client",
                                        factory: { _ in SwiftLogNoOpLogHandler() })

                        // TODO: verify closure
                        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!

                        self.messageStream = AsyncThrowingStream { continuation = $0 }
                        self.messageContinuation = continuation

                }

                // MARK: `Transport` comformance

                /// Connects to the Unix socket
                ///
                /// This method can be called multiple times to support reconnection cycles.
                /// Each call recreates the message stream.
                ///
                /// - Throws: `MCPError.transportError` if connection fails
                public func connect() async throws {
                        guard !isConnected else { return }
                        isConnected = true

                        try validateSocketPath()

                        let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
                        guard sockfd >= 0 else {
                                throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                        }

                        let fd = FileDescriptor(rawValue: sockfd)

                        var addr = sockaddr_un()
                        addr.sun_family = sa_family_t(AF_UNIX)
                        let pathBytes = socketPath.utf8CString
                        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                                pathBytes.withUnsafeBufferPointer { buffer in
                                        memcpy(
                                                ptr, buffer.baseAddress,
                                                min(
                                                        buffer.count,
                                                        UnixSocketClientTransport.socketPathMax))
                                }
                        }

                        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
                                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                        sockaddrPtr in
                                        #if canImport(Darwin)
                                                Darwin.connect(
                                                        sockfd, sockaddrPtr,
                                                        socklen_t(MemoryLayout<sockaddr_un>.size))
                                        #elseif canImport(Glibc)
                                                Glibc.connect(
                                                        sockfd, sockaddrPtr,
                                                        socklen_t(MemoryLayout<sockaddr_un>.size))
                                        #else
                                                Musl.connect(
                                                        sockfd, sockaddrPtr,
                                                        socklen_t(MemoryLayout<sockaddr_un>.size))
                                        #endif
                                }
                        }

                        guard connectResult >= 0 else {
                                try fd.close()
                                throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                        }

                        try setNonBlocking(fd)
                        self.socketDescriptor = fd

                        // Create new stream for this connection (supports reconnection)
                        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
                        self.messageStream = AsyncThrowingStream { continuation = $0 }
                        self.messageContinuation = continuation

                        // isConnected = true
                        readLoopTask = Task { await readLoop() }
                        logger.debug("Connected", metadata: ["path": "\(socketPath)"])
                }

                /// Disconnects from the Unix socket
                public func disconnect() async {
                        guard isConnected else { return }
                        isConnected = false

                        readLoopTask?.cancel()
                        await readLoopTask?.value
                        readLoopTask = nil

                        if let socket = socketDescriptor {
                                try? socket.close()
                                socketDescriptor = nil
                        }

                        messageContinuation?.finish()
                        messageContinuation = nil
                        messageStream = nil

                        logger.debug("Disconnected")
                }

                /// Sends data to the server
                ///
                /// - Parameter data: Data to send (newline will be appended automatically)
                /// - Throws: `MCPError.transportError` if not connected or write fails
                public func send(_ data: Data) async throws {
                        guard isConnected, let socket = socketDescriptor else {
                                throw MCPError.transportError(Errno(rawValue: ENOTCONN))
                        }

                        var messageWithNewline = data
                        messageWithNewline.append(UInt8(ascii: "\n"))

                        var remaining = messageWithNewline
                        while !remaining.isEmpty {
                                do {
                                        let written = try remaining.withUnsafeBytes { buffer in
                                                try socket.write(UnsafeRawBufferPointer(buffer))
                                        }
                                        if written > 0 {
                                                remaining = remaining.dropFirst(written)
                                        }
                                } catch let error
                                        where MCPError.isResourceTemporarilyUnavailable(error)
                                {
                                        try await Task.sleep(for: .milliseconds(10))
                                        continue
                                } catch {
                                        throw MCPError.transportError(error)
                                }
                        }
                }

                /// Receives data from the server
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

                // MARK: - Private Implementation

                private func readLoop() async {
                        let bufferSize = 4096
                        var buffer = [UInt8](repeating: 0, count: bufferSize)
                        var pendingData = Data()

                        guard let descriptor = socketDescriptor,
                                let continuation = messageContinuation
                        else {
                                return
                        }

                        while isConnected && !Task.isCancelled {
                                do {
                                        let bytesRead = try buffer.withUnsafeMutableBufferPointer {
                                                pointer in
                                                try descriptor.read(
                                                        into: UnsafeMutableRawBufferPointer(pointer)
                                                )
                                        }

                                        if bytesRead == 0 {
                                                logger.notice("Server closed connection")
                                                break
                                        }

                                        pendingData.append(Data(buffer[..<bytesRead]))

                                        // Parse newline-delimited messages
                                        while let newlineIndex = pendingData.firstIndex(
                                                of: UInt8(ascii: "\n"))
                                        {
                                                let messageData = pendingData[..<newlineIndex]
                                                pendingData = pendingData[(newlineIndex + 1)...]

                                                if !messageData.isEmpty {
                                                        continuation.yield(Data(messageData))
                                                }
                                        }
                                } catch let error
                                        where MCPError.isResourceTemporarilyUnavailable(error)
                                {
                                        try? await Task.sleep(for: .milliseconds(10))
                                        continue
                                } catch {
                                        if !Task.isCancelled {
                                                logger.error(
                                                        "Read error",
                                                        metadata: ["error": "\(error)"])
                                        }
                                        break
                                }
                        }

                        continuation.finish()
                }

                private func validateSocketPath() throws {
                        guard socketPath.utf8.count < UnixSocketClientTransport.socketPathMax else {
                                throw MCPError.internalError(
                                        "Socket path too long: \(socketPath.utf8.count) bytes (max: \(UnixSocketClientTransport.socketPathMax))"
                                )
                        }
                }

                private func setNonBlocking(_ fd: FileDescriptor) throws {
                        let flags = fcntl(fd.rawValue, F_GETFL)
                        guard flags >= 0 else {
                                throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                        }

                        let result = fcntl(fd.rawValue, F_SETFL, flags | O_NONBLOCK)
                        guard result >= 0 else {
                                throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                        }
                }
        }
#endif
