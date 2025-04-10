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
#elseif os(Windows)
    import CRT
    import WinSDK
#endif

#if canImport(Darwin) || canImport(Glibc) || os(Windows)
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
            #elseif os(Windows)
                // Windows non-blocking mode setup
                var mode: UInt32 = 1  // 1 = Non-blocking mode
                let result = ioctlsocket(SOCKET(fileDescriptor.rawValue), FIONBIO, &mode)
                guard result == 0 else {
                    let error = WSAGetLastError()
                    throw MCPError.transportError(POSIXErrorCode(rawValue: CInt(error)))
                }
            #else
                // For platforms where non-blocking operations aren't supported
                throw MCPError.internalError(
                    "Setting non-blocking mode not supported on this platform")
            #endif
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
                            logger.debug(
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

        public func disconnect() async {
            guard isConnected else { return }
            isConnected = false
            messageContinuation.finish()
            logger.info("Transport disconnected")
        }

        public func send(_ message: Data) async throws {
            guard isConnected else {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    throw MCPError.transportError(Errno(rawValue: ENOTCONN))
                #elseif os(Windows)
                    throw MCPError.transportError(POSIXErrorCode(rawValue: WSAENOTCONN))
                #else
                    throw MCPError.internalError("Transport not connected")
                #endif
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
#endif
