import Foundation
import Testing

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

// MARK: - Basic Tests

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

// MARK: - Multiple Message Tests (mirrors TypeScript server/stdio.test.ts)

@Suite("Stdio Transport Multiple Message Tests")
struct StdioTransportMultipleMessageTests {
    @Test("Receive multiple messages")
    func testReceiveMultipleMessages() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write multiple JSON-RPC messages (mirrors TypeScript test_stdio_client)
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        ]

        for message in messages {
            try writer.writeAll((message + "\n").data(using: .utf8)!)
        }
        try writer.close()

        // Receive and verify all messages
        let stream = await transport.receive()
        var receivedMessages: [String] = []

        for try await data in stream {
            if let message = String(data: data, encoding: .utf8) {
                receivedMessages.append(message)
            }
        }

        #expect(receivedMessages.count == 2)
        #expect(receivedMessages[0] == messages[0])
        #expect(receivedMessages[1] == messages[1])

        await transport.disconnect()
    }

    @Test("Send multiple messages")
    func testSendMultipleMessages() async throws {
        let (reader, output) = try FileDescriptor.pipe()
        let (input, _) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Send multiple messages
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{}}"#,
        ]

        for message in messages {
            try await transport.send(message.data(using: .utf8)!)
        }

        // Read all output at once
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
            try reader.read(into: UnsafeMutableRawBufferPointer(pointer))
        }

        let receivedOutput = String(data: Data(buffer[..<bytesRead]), encoding: .utf8)!
        let lines = receivedOutput.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[0] == messages[0])
        #expect(lines[1] == messages[1])

        await transport.disconnect()
    }
}

// MARK: - Message Framing Tests (mirrors TypeScript core/shared/stdio.test.ts)

@Suite("Stdio Transport Message Framing Tests")
struct StdioTransportMessageFramingTests {
    @Test("Partial messages are buffered until newline")
    func testPartialMessagesBuffered() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write a message in two parts - the transport must buffer and reassemble
        let part1 = #"{"jsonrpc":"2.0","#
        let part2 = #""id":1,"method":"ping"}"# + "\n"

        try writer.writeAll(part1.data(using: .utf8)!)
        try writer.writeAll(part2.data(using: .utf8)!)
        try writer.close()

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()

        // Should receive the complete reassembled message
        let expectedMessage = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        #expect(received == expectedMessage.data(using: .utf8)!)

        await transport.disconnect()
    }

    @Test("CRLF line endings are normalized")
    func testCRLFLineEndingsNormalized() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write messages with Windows-style CRLF line endings
        let message1 = #"{"id":1}"#
        let message2 = #"{"id":2}"#
        let inputData = message1 + "\r\n" + message2 + "\r\n"
        try writer.writeAll(inputData.data(using: .utf8)!)
        try writer.close()

        let stream = await transport.receive()
        var receivedMessages: [String] = []

        for try await data in stream {
            if let message = String(data: data, encoding: .utf8) {
                receivedMessages.append(message)
            }
        }

        // Should receive clean messages without carriage returns
        #expect(receivedMessages.count == 2)
        #expect(receivedMessages[0] == message1)
        #expect(receivedMessages[1] == message2)

        await transport.disconnect()
    }

    @Test("Empty lines are ignored")
    func testEmptyLinesIgnored() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write messages with empty lines between them
        let inputData = "\n\n" + #"{"id":1}"# + "\n\n\n" + #"{"id":2}"# + "\n\n"
        try writer.writeAll(inputData.data(using: .utf8)!)
        try writer.close()

        let stream = await transport.receive()
        var receivedMessages: [String] = []

        for try await data in stream {
            if let message = String(data: data, encoding: .utf8) {
                receivedMessages.append(message)
            }
        }

        // Should only receive the two actual messages, not empty lines
        #expect(receivedMessages.count == 2)
        #expect(receivedMessages[0] == #"{"id":1}"#)
        #expect(receivedMessages[1] == #"{"id":2}"#)

        await transport.disconnect()
    }

    @Test("Large message handling")
    func testLargeMessageHandling() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Create a large message (larger than typical buffer size)
        let largeContent = String(repeating: "x", count: 10000)
        let largeMessage = #"{"content":""# + largeContent + #""}"#

        try writer.writeAll((largeMessage + "\n").data(using: .utf8)!)
        try writer.close()

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()

        #expect(received == largeMessage.data(using: .utf8)!)

        await transport.disconnect()
    }
}

// MARK: - Bidirectional Communication Tests (mirrors Python test_stdio_server)

@Suite("Stdio Transport Bidirectional Tests")
struct StdioTransportBidirectionalTests {
    @Test("Bidirectional message exchange")
    func testBidirectionalMessageExchange() async throws {
        // Create bidirectional pipes simulating client <-> server communication
        let (transportInput, clientWriter) = try FileDescriptor.pipe()
        let (clientReader, transportOutput) = try FileDescriptor.pipe()

        let transport = StdioTransport(
            input: transportInput, output: transportOutput, logger: nil)
        try await transport.connect()

        // Client sends a request
        let request = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        try clientWriter.writeAll((request + "\n").data(using: .utf8)!)

        // Transport receives the request
        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let receivedRequest = try await iterator.next()
        #expect(receivedRequest == request.data(using: .utf8)!)

        // Transport sends a response back
        let response = #"{"jsonrpc":"2.0","id":1,"result":{"status":"ok"}}"#
        try await transport.send(response.data(using: .utf8)!)

        // Client reads the response
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
            try clientReader.read(into: UnsafeMutableRawBufferPointer(pointer))
        }
        let receivedResponse = String(
            data: Data(buffer[..<bytesRead]), encoding: .utf8)!
            .trimmingCharacters(in: .newlines)
        #expect(receivedResponse == response)

        try clientWriter.close()
        await transport.disconnect()
    }
}

// MARK: - EOF Handling Tests

@Suite("Stdio Transport EOF Handling Tests")
struct StdioTransportEOFHandlingTests {
    @Test("Stream ends on EOF")
    func testStreamEndsOnEOF() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write one message then close (EOF)
        let message = #"{"id":1}"#
        try writer.writeAll((message + "\n").data(using: .utf8)!)
        try writer.close()

        let stream = await transport.receive()
        var messages: [Data] = []

        for try await data in stream {
            messages.append(data)
        }

        // Should have received exactly one message, then stream should end
        #expect(messages.count == 1)
        #expect(messages[0] == message.data(using: .utf8)!)

        await transport.disconnect()
    }

    @Test("Incomplete message discarded on EOF")
    func testIncompleteMessageDiscardedOnEOF() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write a complete message, then an incomplete one (no trailing newline)
        let completeMessage = #"{"id":1}"#
        let incompleteMessage = #"{"id":2"#  // Missing closing brace and newline

        try writer.writeAll((completeMessage + "\n").data(using: .utf8)!)
        try writer.writeAll(incompleteMessage.data(using: .utf8)!)
        try writer.close()  // EOF while incomplete message in buffer

        let stream = await transport.receive()
        var messages: [Data] = []

        for try await data in stream {
            messages.append(data)
        }

        // Should only receive the complete message, incomplete one is discarded
        #expect(messages.count == 1)
        #expect(messages[0] == completeMessage.data(using: .utf8)!)

        await transport.disconnect()
    }
}

// MARK: - Connection State Tests

@Suite("Stdio Transport Connection State Tests")
struct StdioTransportConnectionStateTests {
    @Test("Send fails when not connected")
    func testSendFailsWhenNotConnected() async throws {
        let (input, _) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)

        // Don't call connect() - should fail with ENOTCONN

        do {
            try await transport.send(#"{"id":1}"#.data(using: .utf8)!)
            #expect(Bool(false), "Expected send to throw when not connected")
        } catch {
            #expect(error is MCPError)
        }
    }
}
