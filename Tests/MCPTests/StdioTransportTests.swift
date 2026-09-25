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

        try output.close()
        #expect(dup2(replacementWriter.rawValue, output.rawValue) == output.rawValue)
        defer { _ = close(output.rawValue) }

        await transport.disconnect()
        #expect(fcntl(output.rawValue, F_GETFL) & O_NONBLOCK != 0)
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
