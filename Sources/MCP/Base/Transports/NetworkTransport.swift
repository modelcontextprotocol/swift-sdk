import Logging

import struct Foundation.Data

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
                continuation.resume(throwing: MCPError.internalError("Connection cancelled"))
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
                    completion: .contentProcessed { [weak self] error in
                        guard let self = self else { return }

                        Task { @MainActor in
                            if !sendContinuationResumed {
                                sendContinuationResumed = true
                                if let error = error {
                                    self.logger.error("Send error: \(error)")
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

        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return messageStream
        }

        private func receiveLoop() async {
            var buffer = Data()

            while isConnected && !Task.isCancelled {
                do {
                    let newData = try await receiveData()
                    // Check for EOF (empty data)
                    if newData.isEmpty {
                        logger.info("Connection closed by peer (EOF).")
                        break  // Exit loop gracefully
                    }
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
                        messageContinuation.finish(throwing: MCPError.transportError(error))
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
                    continuation.resume(throwing: MCPError.internalError("Transport deallocated"))
                    return
                }

                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    content, _, _, error in
                    Task { @MainActor in
                        if !receiveContinuationResumed {
                            receiveContinuationResumed = true
                            if let error = error {
                                continuation.resume(throwing: MCPError.transportError(error))
                            } else if let content = content {
                                continuation.resume(returning: content)
                            } else {
                                // EOF: Resume with empty data instead of throwing an error
                                continuation.resume(returning: Data())
                            }
                        }
                    }
                }
            }
        }
    }
#endif
