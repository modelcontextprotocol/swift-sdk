import Foundation
import Testing

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
