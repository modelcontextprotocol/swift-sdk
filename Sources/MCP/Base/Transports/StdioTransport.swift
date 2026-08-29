import Logging

import struct Foundation.Data

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

#if os(Windows)
    import class Foundation.FileHandle
    import class Foundation.Thread
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    /// An implementation of the MCP stdio transport protocol.
    ///
    /// This transport implements the [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio)
    /// specification from the Model Context Protocol.
    ///
    /// The stdio transport works by:
    /// - Reading JSON-RPC messages from standard input
    /// - Writing JSON-RPC messages to standard output
    /// - Using newline characters as message delimiters
    /// - Supporting non-blocking I/O operations
    ///
    /// This transport is the recommended option for most MCP applications due to its
    /// simplicity and broad platform support.
    ///
    /// - Important: This transport is available on Apple platforms and Linux distributions with glibc
    ///   (Ubuntu, Debian, Fedora, CentOS, RHEL).
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Initialize the client
    /// let client = Client(name: "MyApp", version: "1.0.0")
    ///
    /// // Create a transport and connect
    /// let transport = StdioTransport()
    /// try await client.connect(transport: transport)
    /// ```
    public actor StdioTransport: Transport {
        private let input: FileDescriptor
        private let output: FileDescriptor
        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        private var isConnected = false
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        /// Creates a new stdio transport with the specified file descriptors
        ///
        /// - Parameters:
        ///   - input: File descriptor for reading (defaults to standard input)
        ///   - output: File descriptor for writing (defaults to standard output)
        ///   - logger: Optional logger instance for transport events
        public init(
            input: FileDescriptor = FileDescriptor.standardInput,
            output: FileDescriptor = FileDescriptor.standardOutput,
            logger: Logger? = nil
        ) {
            self.input = input
            self.output = output
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.stdio",
                    factory: { _ in SwiftLogNoOpLogHandler() })

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Establishes connection with the transport
        ///
        /// This method configures the file descriptors for non-blocking I/O
        /// and starts the background message reading loop.
        ///
        /// - Throws: Error if the file descriptors cannot be configured
        public func connect() async throws {
            guard !isConnected else { return }

            // Set non-blocking mode
            try setNonBlocking(fileDescriptor: input)
            try setNonBlocking(fileDescriptor: output)

            isConnected = true
            logger.debug("Transport connected successfully")

            // Start reading loop in background
            Task {
                await readLoop()
            }
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

            while isConnected && !Task.isCancelled {
                do {
                    let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                        try input.read(into: UnsafeMutableRawBufferPointer(pointer))
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
        /// This stops the message reading loop and releases associated resources.
        public func disconnect() async {
            guard isConnected else { return }
            isConnected = false
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

            // Add newline as delimiter
            var messageWithNewline = message
            messageWithNewline.append(UInt8(ascii: "\n"))

            var remaining = messageWithNewline
            while !remaining.isEmpty {
                do {
                    let written = try remaining.withUnsafeBytes { buffer in
                        try output.write(UnsafeRawBufferPointer(buffer))
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
#elseif os(Windows)
    /// An implementation of the MCP stdio transport protocol for Windows.
    ///
    /// This transport implements the [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio)
    /// specification from the Model Context Protocol.
    ///
    /// Windows has no POSIX non-blocking file-descriptor I/O, so this
    /// implementation speaks the same wire contract — newline-delimited
    /// JSON-RPC messages on standard input/output — over Foundation's
    /// `FileHandle`. Reads run on a dedicated thread so that a blocking
    /// stdin read never parks a thread of the cooperative pool.
    ///
    /// A trailing carriage return is stripped from each received line in
    /// case a Windows-side client writes CRLF line endings.
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Initialize the client
    /// let client = Client(name: "MyApp", version: "1.0.0")
    ///
    /// // Create a transport and connect
    /// let transport = StdioTransport()
    /// try await client.connect(transport: transport)
    /// ```
    public actor StdioTransport: Transport {
        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        private var isConnected = false
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        /// Creates a new stdio transport over standard input/output
        ///
        /// - Parameter logger: Optional logger instance for transport events
        public init(logger: Logger? = nil) {
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.stdio",
                    factory: { _ in SwiftLogNoOpLogHandler() })

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Establishes connection with the transport
        ///
        /// This starts the background message reading thread.
        public func connect() async throws {
            guard !isConnected else { return }
            isConnected = true
            logger.debug("Transport connected successfully")

            let continuation = messageContinuation
            let logger = logger
            Thread.detachNewThread {
                let standardInput = FileHandle.standardInput
                var pendingData = Data()
                while true {
                    let chunk = standardInput.availableData
                    if chunk.isEmpty {
                        // EOF — the client closed our standard input
                        logger.notice("EOF received")
                        continuation.finish()
                        return
                    }
                    pendingData.append(chunk)

                    // Process complete messages
                    while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                        var messageData = pendingData[pendingData.startIndex..<newlineIndex]
                        if messageData.last == UInt8(ascii: "\r") {
                            messageData = messageData.dropLast()
                        }
                        if !messageData.isEmpty {
                            logger.trace(
                                "Message received", metadata: ["size": "\(messageData.count)"])
                            continuation.yield(Data(messageData))
                        }
                        pendingData.removeSubrange(pendingData.startIndex...newlineIndex)
                    }
                }
            }
        }

        /// Disconnects from the transport
        ///
        /// This finishes the message stream. The reading thread exits when
        /// standard input reaches EOF.
        public func disconnect() async {
            guard isConnected else { return }
            isConnected = false
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
                throw MCPError.internalError("Transport not connected")
            }

            // Add newline as delimiter
            var messageWithNewline = message
            messageWithNewline.append(UInt8(ascii: "\n"))
            do {
                try FileHandle.standardOutput.write(contentsOf: messageWithNewline)
            } catch {
                throw MCPError.transportError(error)
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
