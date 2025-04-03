import Darwin
import Logging

import struct Foundation.Data

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends data
    func send(_ data: Data) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

/// Standard input/output transport implementation
public actor StdioTransport: Transport {
    private let input: FileDescriptor
    private let output: FileDescriptor
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncStream<Data>
    private let messageContinuation: AsyncStream<Data>.Continuation

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
        var continuation: AsyncStream<Data>.Continuation!
        self.messageStream = AsyncStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    public func connect() async throws {
        guard !isConnected else { return }

        // Set non-blocking mode
        try setNonBlocking(fileDescriptor: input)
        try setNonBlocking(fileDescriptor: output)

        isConnected = true
        logger.info("Transport connected successfully")

        // Start reading loop in background
        Task {
            await readLoop()
        }
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw Error.transportError(Errno.badFileDescriptor)
        }
        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw Error.transportError(Errno.badFileDescriptor)
        }
    }

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
                        logger.debug("Message received", metadata: ["size": "\(messageData.count)"])
                        messageContinuation.yield(Data(messageData))
                    }
                }
            } catch let error where Error.isResourceTemporarilyUnavailable(error) {
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

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
        logger.info("Transport disconnected")
    }

    public func send(_ message: Data) async throws {
        guard isConnected else {
            throw Error.transportError(Errno.socketNotConnected)
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
            } catch let error where Error.isResourceTemporarilyUnavailable(error) {
                try await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                throw Error.transportError(error)
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return AsyncThrowingStream { continuation in
            Task {
                for await message in messageStream {
                    continuation.yield(message)
                }
                continuation.finish()
            }
        }
    }
}

#if canImport(Network)
    import Network

    /// Network connection based transport implementation
    public actor NetworkTransport: Transport {
        private let connection: NWConnection
        public nonisolated let logger: Logger

        private var isConnected = false
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        // Track connection state for continuations
        private var connectionContinuationResumed = false

        public init(connection: NWConnection, logger: Logger? = nil) {
            self.connection = connection
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.network",
                    factory: { _ in SwiftLogNoOpLogHandler() }
                )

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Connects to the network transport
        public func connect() async throws {
            guard !isConnected else { return }

            // Reset continuation state
            connectionContinuationResumed = false

            // Wait for connection to be ready
            try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCP.Error.internalError("Transport deallocated"))
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
                        default:
                            // Wait for ready or failed state
                            break
                        }
                    }
                }

                // Start the connection if it's not already started
                if connection.state != .ready {
                    connection.start(queue: .main)
                } else {
                    Task { @MainActor in
                        await self.handleConnectionReady(continuation: continuation)
                    }
                }
            }
        }

        private func handleConnectionReady(continuation: CheckedContinuation<Void, Swift.Error>)
            async
        {
            if !connectionContinuationResumed {
                connectionContinuationResumed = true
                isConnected = true
                logger.info("Network transport connected successfully")
                continuation.resume()
                // Start the receive loop after connection is established
                Task { await self.receiveLoop() }
            }
        }

        private func handleConnectionFailed(
            error: Swift.Error, continuation: CheckedContinuation<Void, Swift.Error>
        ) async {
            if !connectionContinuationResumed {
                connectionContinuationResumed = true
                logger.error("Connection failed: \(error)")
                continuation.resume(throwing: error)
            }
        }

        private func handleConnectionCancelled(continuation: CheckedContinuation<Void, Swift.Error>)
            async
        {
            if !connectionContinuationResumed {
                connectionContinuationResumed = true
                logger.warning("Connection cancelled")
                continuation.resume(throwing: MCP.Error.internalError("Connection cancelled"))
            }
        }

        public func disconnect() async {
            guard isConnected else { return }
            isConnected = false
            connection.cancel()
            messageContinuation.finish()
            logger.info("Network transport disconnected")
        }

        public func send(_ message: Data) async throws {
            guard isConnected else {
                throw MCP.Error.internalError("Transport not connected")
            }

            // Add newline as delimiter
            var messageWithNewline = message
            messageWithNewline.append(UInt8(ascii: "\n"))

            // Use a local actor-isolated variable to track continuation state
            var sendContinuationResumed = false

            try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCP.Error.internalError("Transport deallocated"))
                    return
                }

                connection.send(
                    content: messageWithNewline,
                    completion: .contentProcessed { [weak self] error in
                        guard let self = self else { return }

                        Task { @MainActor in
                            if !sendContinuationResumed {
                                sendContinuationResumed = true
                                if let error = error {
                                    self.logger.error("Send error: \(error)")
                                    continuation.resume(
                                        throwing: MCP.Error.internalError("Send error: \(error)"))
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                    })
            }
        }

        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await message in messageStream {
                            continuation.yield(message)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        private func receiveLoop() async {
            var buffer = Data()

            while isConnected && !Task.isCancelled {
                do {
                    let newData = try await receiveData()
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
                    if !Task.isCancelled {
                        logger.error("Network error occurred", metadata: ["error": "\(error)"])
                        messageContinuation.finish(throwing: MCP.Error.transportError(error))
                    }
                    break
                } catch {
                    if !Task.isCancelled {
                        logger.error("Receive error: \(error)")
                        messageContinuation.finish(throwing: error)
                    }
                    break
                }
            }

            messageContinuation.finish()
        }

        private func receiveData() async throws -> Data {
            var receiveContinuationResumed = false

            return try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Data, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCP.Error.internalError("Transport deallocated"))
                    return
                }

                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    content, _, _, error in
                    Task { @MainActor in
                        if !receiveContinuationResumed {
                            receiveContinuationResumed = true
                            if let error = error {
                                continuation.resume(throwing: MCP.Error.transportError(error))
                            } else if let content = content {
                                continuation.resume(returning: content)
                            } else {
                                continuation.resume(
                                    throwing: MCP.Error.internalError("No data received"))
                            }
                        }
                    }
                }
            }
        }
    }
#endif
