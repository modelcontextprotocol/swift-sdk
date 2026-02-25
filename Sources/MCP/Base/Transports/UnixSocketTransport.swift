import Foundation
import Logging

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

// Import for specific low-level operations not yet in Swift System
#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    /// An implementation of Unix domain socket transport for MCP.
    ///
    /// Unix domain sockets provide high-performance inter-process communication (IPC)
    /// for processes on the same machine. They offer better performance than TCP/IP
    /// for local communication and use file system permissions for security.
    ///
    /// This transport supports both client and server modes:
    /// - **Client mode**: Connects to an existing Unix socket
    /// - **Server mode**: Creates a Unix socket, binds to it, and accepts a single client connection
    ///
    /// The transport uses newline-delimited messages, matching the stdio transport protocol.
    ///
    /// - Important: This transport is available on Apple platforms and Linux distributions with glibc
    ///   (Ubuntu, Debian, Fedora, CentOS, RHEL).
    ///
    /// ## Example Usage (Client)
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Connect to a server socket
    /// let transport = UnixSocketTransport(
    ///     path: "/tmp/mcp.sock",
    ///     mode: .client
    /// )
    /// try await transport.connect()
    /// ```
    ///
    /// ## Example Usage (Server)
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Create a server socket
    /// let transport = UnixSocketTransport(
    ///     path: "/tmp/mcp.sock",
    ///     mode: .server(cleanup: .removeExisting)
    /// )
    /// try await transport.connect()
    /// ```
    public actor UnixSocketTransport: Transport {

        #if canImport(Darwin)
            /// Ref: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h#L79
            public static let socketPathMax: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        #elseif canImport(Glibc)
            /// Ref: https://github.com/torvalds/linux/blob/master/include/uapi/linux/un.h#L7
            public static let socketPathMax: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        #elseif canImport(Musl)
            /// Ref: https://github.com/torvalds/linux/blob/master/include/uapi/linux/un.h#L7
            public static let socketPathMax: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        #endif

        /// Mode of operation (client or server)
        public enum Mode: Sendable {
            /// Client mode: connects to existing Unix socket
            case client

            /// Server mode: creates and binds to Unix socket
            /// - Parameter cleanup: Strategy for handling existing socket files
            case server(cleanup: SocketCleanup)
        }

        /// Strategy for handling existing socket files in server mode
        public enum SocketCleanup: Sendable {
            /// Fail if socket file exists
            case failIfExists

            /// Remove existing socket file before binding
            case removeExisting

            /// Try to reuse if socket is still alive, otherwise remove
            case reuseIfPossible
        }

        private let socketPath: String
        private let mode: Mode
        /// Socket descriptor for listening (server) or connection (client)
        private var socketDescriptor: FileDescriptor?
        /// Client connection descriptor (server mode only)
        private var clientDescriptor: FileDescriptor?

        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        private var isConnected = false
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        /// Creates a new Unix socket transport
        ///
        /// - Parameters:
        ///   - path: File system path for the Unix socket
        ///   - mode: Operation mode (client or server)
        ///   - logger: Optional logger instance for transport events
        public init(path: String, mode: Mode, logger: Logger? = nil) {
            self.socketPath = path
            self.mode = mode
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.unix-socket",
                    factory: { _ in SwiftLogNoOpLogHandler() })

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Establishes connection with the transport
        ///
        /// For client mode, this connects to the existing Unix socket.
        /// For server mode, this creates the socket, binds to it, and waits for a client connection.
        ///
        /// - Throws: Error if the connection cannot be established
        public func connect() async throws {
            guard !isConnected else { return }

            switch mode {
            case .client:
                try await connectClient()
            case .server(let cleanup):
                try await connectServer(cleanup: cleanup)
            }

            isConnected = true
            logger.debug("Transport connected successfully", metadata: ["path": "\(socketPath)"])

            // Start reading loop in background
            Task {
                await readLoop()
            }
        }

        /// Validates that the socket path length is within the sockaddr_un limit
        ///
        /// - Throws: `MCPError.internalError` if the path exceeds platform specific `socketPathMax` bytes
        private func validateSocketPath() throws {
            guard socketPath.utf8.count < UnixSocketTransport.socketPathMax else {
                throw MCPError.internalError(
                    "Socket path too long: \(socketPath.utf8.count) bytes")
            }
        }

        /// Connects to an existing Unix socket (client mode)
        private func connectClient() async throws {
            try validateSocketPath()

            // Create socket
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard sockfd >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                let fd = FileDescriptor(rawValue: sockfd)

                // Build socket address
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)

                let pathBytes = socketPath.utf8CString
                _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    pathBytes.withUnsafeBufferPointer { buffer in
                        memcpy(ptr, buffer.baseAddress, min(buffer.count, UnixSocketTransport.socketPathMax))
                    }
                }

                // Connect to socket
                let connectResult = withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        #if canImport(Darwin)
                            Darwin.connect(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        #elseif canImport(Glibc)
                            Glibc.connect(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        #else
                            Musl.connect(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        #endif
                    }
                }

                guard connectResult >= 0 else {
                    try fd.close()
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                // Set non-blocking mode
                try setNonBlocking(fileDescriptor: fd)

                self.socketDescriptor = fd
                logger.debug("Client connected to Unix socket", metadata: ["path": "\(socketPath)"])
            #else
                throw MCPError.internalError("Unix sockets not supported on this platform")
            #endif
        }

        /// Creates a Unix socket and accepts a client connection (server mode)
        private func connectServer(cleanup: SocketCleanup) async throws {
            try validateSocketPath()

            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                // Handle cleanup strategy
                switch cleanup {
                case .failIfExists:
                    // Check if file exists
                    if access(socketPath, F_OK) == 0 {
                        throw MCPError.transportError(
                            NSError(
                                domain: "mcp.transport.unix_socket",
                                code: Int(EADDRINUSE),
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Socket file already exists: \(socketPath)"
                                ]
                            ))
                    }
                case .removeExisting:
                    // Always remove if exists
                    if access(socketPath, F_OK) == 0 {
                        unlink(socketPath)
                        logger.debug(
                            "Removed existing socket file", metadata: ["path": "\(socketPath)"])
                    }
                case .reuseIfPossible:
                    // Try to connect - if it fails, remove the stale socket
                    if access(socketPath, F_OK) == 0 {
                        let testSock = socket(AF_UNIX, SOCK_STREAM, 0)
                        if testSock >= 0 {
                            var testAddr = sockaddr_un()
                            testAddr.sun_family = sa_family_t(AF_UNIX)
                            let pathBytes = socketPath.utf8CString
                            _ = withUnsafeMutablePointer(to: &testAddr.sun_path) { ptr in
                                pathBytes.withUnsafeBufferPointer { buffer in
                                    memcpy(ptr, buffer.baseAddress, min(buffer.count, UnixSocketTransport.socketPathMax))
                                }
                            }

                            let testResult = withUnsafePointer(to: &testAddr) { addrPtr in
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

                            #if canImport(Darwin)
                                Darwin.close(testSock)
                            #elseif canImport(Glibc)
                                Glibc.close(testSock)
                            #else
                                Musl.close(testSock)
                            #endif

                            if testResult < 0 {
                                // Socket is stale, remove it
                                unlink(socketPath)
                                logger.debug(
                                    "Removed stale socket file", metadata: ["path": "\(socketPath)"]
                                )
                            } else {
                                // Socket is alive, fail
                                throw MCPError.transportError(
                                    NSError(
                                        domain: "mcp.transport.unix_socket",
                                        code: Int(EADDRINUSE),
                                        userInfo: [
                                            NSLocalizedDescriptionKey:
                                                "Socket is already in use: \(socketPath)"
                                        ]
                                    ))
                            }
                        }
                    }
                }

                // Create socket
                let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard sockfd >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                let fd = FileDescriptor(rawValue: sockfd)

                // Build socket address
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)

                let pathBytes = socketPath.utf8CString
                _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    pathBytes.withUnsafeBufferPointer { buffer in
                        memcpy(ptr, buffer.baseAddress, min(buffer.count, UnixSocketTransport.socketPathMax))
                    }
                }

                // Bind socket
                let bindResult = withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        #if canImport(Darwin)
                            Darwin.bind(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        #elseif canImport(Glibc)
                            Glibc.bind(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        #else
                            Musl.bind(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        #endif
                    }
                }

                guard bindResult >= 0 else {
                    try fd.close()
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                // Listen for connections
                let listenResult = listen(sockfd, 1)
                guard listenResult >= 0 else {
                    try fd.close()
                    unlink(socketPath)
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                // Set listening socket to non-blocking so accept() doesn't block
                try setNonBlocking(fileDescriptor: fd)

                logger.debug("Server listening on Unix socket", metadata: ["path": "\(socketPath)"])

                // Accept client connection (with retry loop for non-blocking)
                var clientfd: Int32 = -1
                while clientfd < 0 {
                    clientfd = accept(sockfd, nil, nil)
                    if clientfd < 0 {
                        let error = Errno(rawValue: CInt(errno))
                        if error == .resourceTemporarilyUnavailable {
                            // No client yet, sleep and retry
                            try? await Task.sleep(for: .milliseconds(10))
                            continue
                        } else {
                            // Real error
                            try fd.close()
                            unlink(socketPath)
                            throw MCPError.transportError(error)
                        }
                    }
                }

                let clientFd = FileDescriptor(rawValue: clientfd)

                // Set non-blocking mode on client descriptor
                try setNonBlocking(fileDescriptor: clientFd)

                self.socketDescriptor = fd
                self.clientDescriptor = clientFd
                logger.debug("Server accepted client connection")
            #else
                throw MCPError.internalError("Unix sockets not supported on this platform")
            #endif
        }

        /// Configures a file descriptor for non-blocking I/O
        ///
        /// - Parameter fileDescriptor: The file descriptor to configure
        /// - Throws: Error if the operation fails
        private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                // Get current flags
                let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
                guard flags >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                // Set non-blocking flag
                let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
                guard result >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }
            #else
                // For platforms where non-blocking operations aren't supported
                throw MCPError.internalError(
                    "Setting non-blocking mode not supported on this platform")
            #endif
        }

        /// Continuous loop that reads and processes incoming messages
        ///
        /// This method runs in the background while the transport is connected,
        /// parsing complete messages delimited by newlines and yielding them
        /// to the message stream.
        private func readLoop() async {
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var pendingData = Data()

            // Read from client descriptor (server) or socket descriptor (client)
            let readDescriptor: FileDescriptor? =
                clientDescriptor != nil ? clientDescriptor : socketDescriptor

            guard let descriptor = readDescriptor else {
                messageContinuation.finish()
                return
            }

            while isConnected && !Task.isCancelled {
                do {
                    let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                        try descriptor.read(into: UnsafeMutableRawBufferPointer(pointer))
                    }

                    if bytesRead == 0 {
                        logger.notice("EOF received")
                        break
                    }

                    pendingData.append(Data(buffer[..<bytesRead]))

                    // Process complete messages
                    while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                        let messageData = pendingData[..<newlineIndex]
                        pendingData = pendingData[(newlineIndex + 1)...]

                        if !messageData.isEmpty {
                            logger.trace(
                                "Message received", metadata: ["size": "\(messageData.count)"])
                            messageContinuation.yield(Data(messageData))
                        }
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    if !Task.isCancelled {
                        logger.error("Read error occurred", metadata: ["error": "\(error)"])
                    }
                    break
                }
            }

            messageContinuation.finish()
        }

        /// Disconnects from the transport
        ///
        /// This stops the message reading loop, closes file descriptors,
        /// and removes the socket file (server mode only).
        public func disconnect() async {
            guard isConnected else { return }
            isConnected = false

            // Close client descriptor (server mode)
            if let client = clientDescriptor {
                try? client.close()
                clientDescriptor = nil
            }

            // Close socket descriptor
            if let socket = socketDescriptor {
                try? socket.close()
                socketDescriptor = nil
            }

            // Remove socket file in server mode
            if case .server = mode {
                unlink(socketPath)
                logger.debug("Removed socket file", metadata: ["path": "\(socketPath)"])
            }

            messageContinuation.finish()
            logger.debug("Transport disconnected")
        }

        /// Sends a message over the transport.
        ///
        /// This method supports sending both individual JSON-RPC messages and JSON-RPC batches.
        /// Batches should be encoded as a JSON array containing multiple request/notification objects
        /// according to the JSON-RPC 2.0 specification.
        ///
        /// - Parameter message: The message data to send (without a trailing newline)
        /// - Throws: Error if the message cannot be sent
        public func send(_ message: Data) async throws {
            guard isConnected else {
                throw MCPError.transportError(Errno(rawValue: ENOTCONN))
            }

            // Write to client descriptor (server) or socket descriptor (client)
            let writeDescriptor: FileDescriptor? =
                clientDescriptor != nil ? clientDescriptor : socketDescriptor

            guard let descriptor = writeDescriptor else {
                throw MCPError.transportError(Errno(rawValue: ENOTCONN))
            }

            // Add newline as delimiter
            var messageWithNewline = message
            messageWithNewline.append(UInt8(ascii: "\n"))

            var remaining = messageWithNewline
            while !remaining.isEmpty {
                do {
                    let written = try remaining.withUnsafeBytes { buffer in
                        try descriptor.write(UnsafeRawBufferPointer(buffer))
                    }
                    if written > 0 {
                        remaining = remaining.dropFirst(written)
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    throw MCPError.transportError(error)
                }
            }
        }

        /// Receives messages from the transport.
        ///
        /// Messages may be individual JSON-RPC requests, notifications, responses,
        /// or batches containing multiple requests/notifications encoded as JSON arrays.
        /// Each message is guaranteed to be a complete JSON object or array.
        ///
        /// - Returns: An AsyncThrowingStream of Data objects representing JSON-RPC messages
        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return messageStream
        }
    }
#endif
