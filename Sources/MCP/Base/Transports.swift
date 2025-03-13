import Darwin
import Logging
import SystemPackage

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends a message string
    func send(_ message: String) async throws

    /// Receives message strings as an async sequence
    func receive() -> AsyncThrowingStream<String, Swift.Error>
}

/// Standard input/output transport implementation
public actor StdioTransport: Transport {
    private let input: FileDescriptor
    private let output: FileDescriptor
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncStream<String>
    private let messageContinuation: AsyncStream<String>.Continuation

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
        var continuation: AsyncStream<String>.Continuation!
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

                    if let message = String(data: messageData, encoding: .utf8),
                        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        logger.debug("Message received", metadata: ["message": "\(message)"])
                        messageContinuation.yield(message)
                    }
                }
            } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms backoff
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

    public func send(_ message: String) async throws {
        guard isConnected else {
            throw Error.transportError(Errno.socketNotConnected)
        }

        let message = message + "\n"
        guard let data = message.data(using: .utf8) else {
            throw Error.transportError(Errno.invalidArgument)
        }

        var remaining = data
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer in
                    try output.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                }
            } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                try await Task.sleep(nanoseconds: 10_000_000)  // 10ms backoff
                continue
            } catch {
                throw Error.transportError(error)
            }
        }
    }

    public func receive() -> AsyncThrowingStream<String, Swift.Error> {
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
        private let messageStream: AsyncThrowingStream<String, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<String, Swift.Error>.Continuation

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
            var continuation: AsyncThrowingStream<String, Swift.Error>.Continuation!
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

        public func send(_ message: String) async throws {
            guard isConnected else {
                throw MCP.Error.internalError("Transport not connected")
            }

            guard let data = (message + "\n").data(using: .utf8) else {
                throw MCP.Error.internalError("Failed to encode message")
            }

            // Use a local actor-isolated variable to track continuation state
            var sendContinuationResumed = false

            try await withCheckedThrowingContinuation {
                [weak self] (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard let self = self else {
                    continuation.resume(throwing: MCP.Error.internalError("Transport deallocated"))
                    return
                }

                connection.send(
                    content: data,
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

        public func receive() -> AsyncThrowingStream<String, Swift.Error> {
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

                        if let message = String(data: messageData, encoding: .utf8),
                            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            logger.debug("Message received", metadata: ["message": "\(message)"])
                            messageContinuation.yield(message)
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
