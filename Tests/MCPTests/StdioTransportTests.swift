import Foundation
import Testing

#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@Suite("Stdio Transport Tests")
struct StdioTransportTests {
    @Test("Connection")
    func testStdioTransportConnection() async throws {
        let (input, _) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()
        await transport.disconnect()
    }

    @Test("Disconnect restores file descriptor blocking mode")
    func testDisconnectRestoresBlockingMode() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
            try? output.close()
        }

        let inputFlags = fcntl(input.rawValue, F_GETFL)
        let outputFlags = fcntl(output.rawValue, F_GETFL)
        #expect(inputFlags & O_NONBLOCK == 0)
        #expect(outputFlags & O_NONBLOCK == 0)

        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()
        #expect(fcntl(input.rawValue, F_GETFL) & O_NONBLOCK != 0)
        #expect(fcntl(output.rawValue, F_GETFL) & O_NONBLOCK != 0)

        await transport.disconnect()
        #expect(fcntl(input.rawValue, F_GETFL) & O_NONBLOCK == 0)
        #expect(fcntl(output.rawValue, F_GETFL) & O_NONBLOCK == 0)
    }

    @Test("Disconnect cancels a backpressured send before restoring descriptor flags")
    func testDisconnectDuringBackpressuredSend() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
            try? output.close()
        }

        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()
        let send = Task { try await transport.send(Data(repeating: 65, count: 512 * 1024)) }
        try await Task.sleep(for: .milliseconds(50))

        await transport.disconnect()
        do {
            try await send.value
            Issue.record("Expected the incomplete send to fail on disconnect")
        } catch {
            // The caller must be released before the descriptor becomes blocking.
        }
        #expect(fcntl(output.rawValue, F_GETFL) & O_NONBLOCK == 0)
    }

    /// A frame larger than a pipe's buffer (64 KiB on Linux and macOS), padded with the
    /// `index`th letter.
    private static func largeFrame(_ index: Int) -> Data {
        let letter = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(index)))
        let padding = String(repeating: letter, count: 512 * 1024)
        return Data(#"{"index":\#(index),"padding":"\#(padding)"}"#.utf8)
    }

    private struct Frame: Decodable {
        let index: Int
        let padding: String
    }

    /// Reads `reader` until it has `count` bytes or reaches end of file, off the cooperative pool.
    private static func read(_ reader: FileDescriptor, upTo count: Int = .max) async throws -> Data {
        try await offThreadPool {
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while received.count < count {
                let read = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try reader.read(into: UnsafeMutableRawBufferPointer(pointer))
                }
                if read == 0 { break }
                received.append(contentsOf: buffer[..<read])
            }
            return received
        }
    }

    @Test("Concurrent backpressured sends write whole frames in call order")
    func testConcurrentSendsDoNotInterleave() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
        }
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Nothing reads yet, so the first send fills the pipe and suspends mid-frame, and
        // each later one starts while it is.
        let frames = (0..<3).map(Self.largeFrame)
        var sends: [Task<Void, Swift.Error>] = []
        for frame in frames {
            sends.append(Task { try await transport.send(frame) })
            let count = sends.count
            #expect(await eventually { await transport.activeSends == count })
        }

        let received = Task { try await Self.read(reader) }
        let sent = await outcome(within: .seconds(30)) { [sends] in
            for send in sends { try await send.value }
        }
        #expect(!sent.didTimeOut)
        #expect(sent.error == nil)
        await transport.disconnect()
        // The reader returns at end of file.
        try output.close()

        let lines = try await received.value.split(
            separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        #expect(lines.count == frames.count + 1)
        #expect(lines.last?.isEmpty == true)
        for (index, frame) in frames.enumerated() where index < lines.count {
            #expect(lines[index] == frame, "Frame \(index) arrived torn or out of order")
            let decoded = try? JSONDecoder().decode(Frame.self, from: Data(lines[index]))
            #expect(decoded?.index == index)
        }
    }

    @Test("A send cancelled while it waits for its turn throws, and later sends still go out")
    func testCancelledWaitingSend() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
            try? output.close()
        }
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        let first = Task { try await transport.send(Self.largeFrame(0)) }
        #expect(await eventually { await transport.activeSends == 1 })
        let cancelled = Task { try await transport.send(Self.largeFrame(1)) }
        #expect(await eventually { await transport.activeSends == 2 })
        // The first send still holds the output, so this one is released by cancellation.
        cancelled.cancel()
        let result = await outcome(within: .seconds(30)) { try await cancelled.value }
        #expect(result.error is CancellationError)

        let last = Data(#"{"index":2}"#.utf8)
        let third = Task { try await transport.send(last) }
        let expected = Self.largeFrame(0) + Data("\n".utf8) + last + Data("\n".utf8)
        let received = try await Self.read(reader, upTo: expected.count)
        try await first.value
        try await third.value
        #expect(received == expected)
        await transport.disconnect()
    }

    @Test("Disconnect releases sends waiting for their turn")
    func testDisconnectReleasesWaitingSends() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
            try? output.close()
        }
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        var sends: [Task<Void, Swift.Error>] = []
        for index in 0..<3 {
            sends.append(Task { try await transport.send(Self.largeFrame(index)) })
            let count = sends.count
            #expect(await eventually { await transport.activeSends == count })
        }

        let disconnected = await outcome(within: .seconds(30)) { await transport.disconnect() }
        #expect(!disconnected.didTimeOut)
        // Nothing reads, so no frame finishes: the first send stops mid-frame and the
        // others never start writing.
        for (index, send) in sends.enumerated() {
            let result = await outcome(within: .seconds(30)) { try await send.value }
            guard case .transportError(let underlying) = result.mcpError else {
                Issue.record("Expected send \(index) to fail with a transport error, got \(result)")
                continue
            }
            #expect(underlying as? Errno == Errno(rawValue: ENOTCONN), "Send \(index)")
        }
        #expect(await transport.activeSends == 0)
    }

    @Test("Disconnect preserves an already nonblocking descriptor")
    func testDisconnectPreservesNonblockingMode() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
            try? output.close()
        }
        let flags = fcntl(output.rawValue, F_GETFL)
        #expect(fcntl(output.rawValue, F_SETFL, flags | O_NONBLOCK) == 0)

        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()
        await transport.disconnect()
        #expect(fcntl(input.rawValue, F_GETFL) & O_NONBLOCK == 0)
        #expect(fcntl(output.rawValue, F_GETFL) & O_NONBLOCK != 0)
    }

    @Test("Disconnect leaves a reused output descriptor unchanged")
    func testDisconnectDoesNotChangeReusedOutputDescriptor() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        let (replacementReader, replacementWriter) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
            try? replacementReader.close()
            try? replacementWriter.close()
        }

        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()
        let replacementFlags = fcntl(replacementWriter.rawValue, F_GETFL)
        #expect(fcntl(replacementWriter.rawValue, F_SETFL, replacementFlags | O_NONBLOCK) == 0)

        // dup2 closes `output` and reuses its number in one step, so a test running in
        // parallel cannot be given that number in between.
        #expect(dup2(replacementWriter.rawValue, output.rawValue) == output.rawValue)
        defer { _ = close(output.rawValue) }

        await transport.disconnect()
        #expect(fcntl(output.rawValue, F_GETFL) & O_NONBLOCK != 0)
    }

    @Test("Connect and disconnect over a socket pair")
    func testSocketPair() async throws {
        // Node.js gives a child process socket pairs, not pipes, as stdin and stdout;
        // on Darwin their st_dev is negative.
        #if canImport(Glibc)
            let stream = Int32(SOCK_STREAM.rawValue)
        #else
            let stream = SOCK_STREAM
        #endif
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, stream, 0, &input) == 0)
        #expect(socketpair(AF_UNIX, stream, 0, &output) == 0)
        defer { for fd in input + output { _ = close(fd) } }

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: input[0]), output: FileDescriptor(rawValue: output[0]),
            logger: nil)
        try await transport.connect()
        try await transport.send(Data("{}".utf8))
        await transport.disconnect()
        #expect(fcntl(input[0], F_GETFL) & O_NONBLOCK == 0)
        #expect(fcntl(output[0], F_GETFL) & O_NONBLOCK == 0)
    }

    @Test("Failed connect restores the input descriptor mode")
    func testFailedConnectRestoresInputMode() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
        }

        let transport = StdioTransport(input: input, output: FileDescriptor(rawValue: -1), logger: nil)
        do {
            try await transport.connect()
            Issue.record("Expected connect to reject the closed output descriptor")
        } catch {
            #expect(fcntl(input.rawValue, F_GETFL) & O_NONBLOCK == 0)
        }
    }

    @Test("Send Message")
    func testStdioTransportSendMessage() async throws {
        let (reader, output) = try FileDescriptor.pipe()
        let (input, _) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Test sending a simple message
        let message = #"{"key":"value"}"#
        try await transport.send(message.data(using: .utf8)!)

        // Read and verify the output
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
            try reader.read(into: UnsafeMutableRawBufferPointer(pointer))
        }
        let data = Data(buffer[..<bytesRead])
        let expectedOutput = message.data(using: .utf8)! + "\n".data(using: .utf8)!
        #expect(data == expectedOutput)

        await transport.disconnect()
    }

    @Test("Receive Message")
    func testStdioTransportReceiveMessage() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write test message to input pipe
        let message = ["key": "value"]
        let messageData = try JSONEncoder().encode(message) + "\n".data(using: .utf8)!
        try writer.writeAll(messageData)
        try writer.close()

        // Start receiving messages
        let stream: AsyncThrowingStream<Data, Swift.Error> = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        // Get first message
        let received = try await iterator.next()
        #expect(received == #"{"key":"value"}"#.data(using: .utf8)!)

        await transport.disconnect()
    }

    @Test("Read buffer releases parsed messages")
    func testReadBufferStaysBounded() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (reader, output) = try FileDescriptor.pipe()
        defer {
            try? input.close()
            try? writer.close()
            try? reader.close()
            try? output.close()
        }
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()
        let stream: AsyncThrowingStream<Data, Swift.Error> = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        // Chunks end mid-message, so some reads leave a partial message buffered.
        let messageCount = 2000
        let bytes = Data(
            (0..<messageCount).map { #"{"jsonrpc":"2.0","id":\#($0),"method":"ping"}"# + "\n" }
                .joined().utf8)
        var written = 0
        var complete = 0
        var received = 0
        var largestSpan = 0
        while written < bytes.count {
            let chunk = bytes[written..<min(written + 3000, bytes.count)]
            try writer.writeAll(chunk)
            written += chunk.count
            complete += chunk.count(where: { $0 == UInt8(ascii: "\n") })
            while received < complete {
                _ = try await iterator.next()
                received += 1
            }
            largestSpan = max(largestSpan, await transport.receiveBufferSpan)
        }

        #expect(received == messageCount)
        // At most one read's remainder; before the fix this was every byte received.
        #expect(largestSpan <= 4096)
        await transport.disconnect()
    }

    @Test("Invalid JSON")
    func testStdioTransportInvalidJSON() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write invalid JSON to input pipe
        let invalidJSON = #"{ invalid json }"#
        try writer.writeAll(invalidJSON.data(using: .utf8)!)
        try writer.close()

        let stream: AsyncThrowingStream<Data, Swift.Error> = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        _ = try await iterator.next()

        await transport.disconnect()
    }

    @Test("Send Error")
    func testStdioTransportSendError() async throws {
        let (input, _) = try FileDescriptor.pipe()
        let transport = StdioTransport(
            input: input,
            output: FileDescriptor(rawValue: -1),  // Invalid fd
            logger: nil
        )

        do {
            try await transport.connect()
            #expect(Bool(false), "Expected connect to throw an error")
        } catch {
            #expect(error is MCPError)
        }

        await transport.disconnect()
    }

    @Test("Receive Error")
    func testStdioTransportReceiveError() async throws {
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: -1),  // Invalid fd
            output: output,
            logger: nil
        )

        do {
            try await transport.connect()
            #expect(Bool(false), "Expected connect to throw an error")
        } catch {
            #expect(error is MCPError)
        }

        await transport.disconnect()
    }
}
