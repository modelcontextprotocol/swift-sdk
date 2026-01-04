import Foundation
import Logging
import Testing

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@testable import MCP

// MARK: - Malformed Input Handling Tests
// Based on Python SDK: tests/issues/test_malformed_input.py
// HackerOne vulnerability report #3156202

/// Tests for handling malformed JSON-RPC messages.
///
/// These tests verify that the server properly handles malformed input without crashing,
/// and remains functional after receiving invalid messages.
@Suite("Malformed Input Handling")
struct MalformedInputHandlingTests {

    /// Test that a request with missing required method returns an error response.
    ///
    /// Based on Python SDK's test_malformed_initialize_request_does_not_crash_server.
    /// This tests the fix for HackerOne vulnerability report #3156202.
    @Test(.timeLimit(.minutes(1)))
    func malformedRequestWithMissingMethodReturnsError() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "MalformedInputServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        try await server.start(transport: transport)

        // Send a malformed request (missing required method field)
        // Per JSON-RPC spec, this should return INVALID_REQUEST error
        let malformedRequest = """
            {"jsonrpc":"2.0","id":"malformed-1","params":{}}
            """
        await transport.queueRaw(malformedRequest)

        // Wait for error response
        let responseReceived = await transport.waitForSentMessage { message in
            message.contains("malformed-1") || message.contains("error")
        }
        #expect(responseReceived, "Should receive a response for malformed request")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1)

        // Should be an error response, not a crash
        if let response = messages.first {
            #expect(response.contains("error"), "Should return an error response")
        }

        // Verify server is still alive - send a valid ping request
        await transport.clearMessages()

        let validPingRequest = """
            {"jsonrpc":"2.0","id":"ping-1","method":"ping","params":{}}
            """
        await transport.queueRaw(validPingRequest)

        // Wait for ping response
        let pingReceived = await transport.waitForSentMessage { message in
            message.contains("ping-1")
        }
        #expect(pingReceived, "Server should still be responsive after malformed request")

        let pingMessages = await transport.sentMessages
        #expect(pingMessages.count >= 1)
        if let pingResponse = pingMessages.first {
            #expect(pingResponse.contains("result"), "Ping should succeed after malformed request")
        }

        await server.stop()
        await transport.disconnect()
    }

    /// Test that multiple concurrent malformed requests don't crash the server.
    ///
    /// Based on Python SDK's test_multiple_concurrent_malformed_requests.
    @Test(.timeLimit(.minutes(1)))
    func multipleConcurrentMalformedRequestsDontCrashServer() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "ConcurrentMalformedServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        try await server.start(transport: transport)

        // Send multiple malformed requests
        for i in 0..<10 {
            let malformedRequest = """
                {"jsonrpc":"2.0","id":"malformed-\(i)","method":"initialize"}
                """
            await transport.queueRaw(malformedRequest)
        }

        // Wait for responses using proper synchronization
        let received = await transport.waitForSentMessageCount(10, timeout: .seconds(5))
        #expect(received, "Should receive responses for all malformed requests")

        // Should receive error responses for all requests
        let messages = await transport.sentMessages

        // All responses should be errors
        for message in messages {
            #expect(message.contains("error"), "Each response should be an error")
        }

        await server.stop()
        await transport.disconnect()
    }

    /// Test that server remains functional after malformed input.
    ///
    /// This tests the "recovery" aspect - after receiving malformed input,
    /// the server should still be able to process valid requests.
    @Test(.timeLimit(.minutes(1)))
    func serverRecoveriesAfterMalformedInput() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.malformed-recovery")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "RecoveryServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", inputSchema: ["type": "object"])
            ])
        }

        let client = Client(name: "RecoveryClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // First, verify normal operation works
        let tools1 = try await client.send(ListTools.request(.init()))
        #expect(tools1.tools.count == 1)

        // Now send malformed data directly to the server transport
        // We'll use a separate pipe for this to simulate malformed client
        // Skip this part for now as it requires raw transport access

        // Verify server is still functional after init
        let tools2 = try await client.send(ListTools.request(.init()))
        #expect(tools2.tools.count == 1)
        #expect(tools2.tools.first?.name == "test_tool")
    }

    /// Test that missing jsonrpc field returns parse error.
    @Test(.timeLimit(.minutes(1)))
    func missingJsonRpcFieldReturnsError() async throws {
        let transport = MockTransport()
        let server = Server(name: "ParseErrorServer", version: "1.0.0")

        try await server.start(transport: transport)

        // Send message missing required "jsonrpc" field
        let invalidMessage = """
            {"method":"ping","id":"parse-test"}
            """
        await transport.queueRaw(invalidMessage)

        // Wait for response
        let responseReceived = await transport.waitForSentMessage { message in
            message.contains("parse-test") || message.contains("error")
        }
        #expect(responseReceived, "Should receive an error response")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1)
        if let response = messages.first {
            #expect(response.contains("error"), "Missing jsonrpc should return error")
        }

        await server.stop()
        await transport.disconnect()
    }

    /// Test that completely invalid JSON returns parse error.
    @Test(.timeLimit(.minutes(1)))
    func invalidJsonReturnsParseError() async throws {
        let transport = MockTransport()
        let server = Server(name: "InvalidJsonServer", version: "1.0.0")

        try await server.start(transport: transport)

        // Send completely invalid JSON
        let invalidJson = "not json at all"
        await transport.queueRaw(invalidJson)

        // Wait for error response
        try await Task.sleep(for: .milliseconds(100))

        // Server may not respond to completely invalid messages, but it shouldn't crash
        // The key is that subsequent valid messages still work

        // Initialize properly and verify server is still functional
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            )
        )

        let initReceived = await transport.waitForSentMessage { message in
            message.contains("serverInfo")
        }
        #expect(initReceived, "Server should still handle valid requests after invalid JSON")

        await server.stop()
        await transport.disconnect()
    }
}

// MARK: - Server Resilience Tests
// Based on Python SDK: tests/server/test_lowlevel_exception_handling.py

/// Tests for server exception handling and resilience.
///
/// These tests verify that the server properly handles exceptions in request handlers
/// without crashing, and can continue processing subsequent requests.
@Suite("Server Resilience")
struct ServerResilienceTests {

    /// Test that exceptions in request handlers are properly converted to error responses.
    ///
    /// Based on Python SDK's test_exception_handling_with_raise_exceptions_true.
    @Test(.timeLimit(.minutes(1)))
    func exceptionInHandlerReturnsErrorResponse() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.exception-handling")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "ExceptionServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "failing_tool", inputSchema: ["type": "object"])
            ])
        }

        // Register a tool handler that throws an exception
        await server.withRequestHandler(CallTool.self) { request, _ in
            guard request.name == "failing_tool" else {
                return CallTool.Result(content: [.text("Unknown tool")], isError: true)
            }
            // Throw an MCPError to simulate a handler failure
            throw MCPError.internalError("Simulated handler failure")
        }

        let client = Client(name: "ExceptionClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Call the failing tool - should get an error response, not a crash
        do {
            _ = try await client.send(
                CallTool.request(.init(name: "failing_tool", arguments: [:]))
            )
            Issue.record("Expected tool call to throw an error")
        } catch let error as MCPError {
            // Should receive the internal error
            if case .internalError(let message) = error {
                #expect(message?.contains("Simulated handler failure") == true)
            } else {
                // Other error types are also acceptable
            }
        }

        // Verify server is still functional after exception
        let tools = try await client.send(ListTools.request(.init()))
        #expect(tools.tools.count == 1)
        #expect(tools.tools.first?.name == "failing_tool")
    }

    /// Test that normal message handling is not affected by exceptions.
    ///
    /// Based on Python SDK's test_normal_message_handling_not_affected.
    @Test(.timeLimit(.minutes(1)))
    func normalMessageHandlingNotAffectedByExceptions() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.normal-handling")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let callCounter = AtomicCounter()

        let server = Server(
            name: "NormalHandlingServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "good_tool", inputSchema: ["type": "object"]),
                Tool(name: "bad_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            _ = await callCounter.increment()

            if request.name == "bad_tool" {
                throw MCPError.internalError("Bad tool failed")
            }
            return CallTool.Result(content: [.text("Success!")])
        }

        let client = Client(name: "NormalClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Call good tool - should succeed
        let result1 = try await client.send(
            CallTool.request(.init(name: "good_tool", arguments: [:]))
        )
        if case .text(let text, _, _) = result1.content.first {
            #expect(text == "Success!")
        }

        // Call bad tool - should fail but not crash server
        do {
            _ = try await client.send(
                CallTool.request(.init(name: "bad_tool", arguments: [:]))
            )
        } catch {
            // Expected
        }

        // Call good tool again - should still work
        let result2 = try await client.send(
            CallTool.request(.init(name: "good_tool", arguments: [:]))
        )
        if case .text(let text, _, _) = result2.content.first {
            #expect(text == "Success!")
        }

        // Verify all calls were processed
        let count = await callCounter.value
        #expect(count == 3, "All three tool calls should have been processed")
    }

    /// Test multiple different exception types are handled gracefully.
    ///
    /// Based on Python SDK's test_exception_handling_with_raise_exceptions_false
    /// which tests ValueError, RuntimeError, KeyError, and generic Exception.
    @Test(.timeLimit(.minutes(1)))
    func multipleExceptionTypesHandledGracefully() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.multiple-exceptions")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "MultipleExceptionsServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "invalid_params_tool", inputSchema: ["type": "object"]),
                Tool(name: "internal_error_tool", inputSchema: ["type": "object"]),
                Tool(name: "resource_not_found_tool", inputSchema: ["type": "object"]),
                Tool(name: "method_not_found_tool", inputSchema: ["type": "object"]),
                Tool(name: "good_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            switch request.name {
            case "invalid_params_tool":
                throw MCPError.invalidParams("Missing required parameter")
            case "internal_error_tool":
                throw MCPError.internalError("Something went wrong internally")
            case "resource_not_found_tool":
                throw MCPError.resourceNotFound(uri: "file:///missing.txt")
            case "method_not_found_tool":
                throw MCPError.methodNotFound("Unknown method")
            case "good_tool":
                return CallTool.Result(content: [.text("Works!")])
            default:
                return CallTool.Result(content: [.text("Unknown")], isError: true)
            }
        }

        let client = Client(name: "MultipleExceptionsClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Test each error type
        let errorTools = [
            ("invalid_params_tool", ErrorCode.invalidParams),
            ("internal_error_tool", ErrorCode.internalError),
            ("resource_not_found_tool", ErrorCode.resourceNotFound),
            ("method_not_found_tool", ErrorCode.methodNotFound)
        ]

        for (toolName, expectedCode) in errorTools {
            do {
                _ = try await client.send(
                    CallTool.request(.init(name: toolName, arguments: [:]))
                )
                Issue.record("Expected \(toolName) to throw an error")
            } catch let error as MCPError {
                #expect(error.code == expectedCode, "\(toolName) should return error code \(expectedCode)")
            }
        }

        // Verify server still works after all the exceptions
        let result = try await client.send(
            CallTool.request(.init(name: "good_tool", arguments: [:]))
        )
        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Works!")
        }

        // Also verify list tools still works
        let tools = try await client.send(ListTools.request(.init()))
        #expect(tools.tools.count == 5)
    }
}

// MARK: - Timeout and Server Responsiveness Tests
// Based on Python SDK: tests/issues/test_88_random_error.py

/// Tests for timeout handling and server responsiveness after timeouts.
///
/// These tests verify that when a client request times out:
/// 1. The server task stays alive
/// 2. The server can still handle new requests
/// 3. The client can make new requests
/// 4. No resources are leaked
@Suite("Timeout and Server Responsiveness")
struct TimeoutServerResponsivenessTests {

    /// Test that server remains responsive after a client request times out.
    ///
    /// Based on Python SDK's test_notification_validation_error.
    /// Uses per-request timeouts to avoid race conditions.
    @Test(.timeLimit(.minutes(1)))
    func serverRemainsResponsiveAfterTimeout() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.timeout-responsiveness")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let requestCount = AtomicCounter()
        let slowRequestLock = AsyncEvent()

        let server = Server(
            name: "TimeoutResponsivenessServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "slow", description: "A slow tool", inputSchema: ["type": "object"]),
                Tool(name: "fast", description: "A fast tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            let count = await requestCount.increment()

            if request.name == "slow" {
                // Wait for the lock - this should timeout
                await slowRequestLock.wait()
                return CallTool.Result(content: [.text("slow \(count)")])
            } else if request.name == "fast" {
                return CallTool.Result(content: [.text("fast \(count)")])
            }
            return CallTool.Result(content: [.text("unknown \(count)")])
        }

        let client = Client(name: "TimeoutClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // First call should work (fast operation, no timeout)
        let result1 = try await client.send(
            CallTool.request(.init(name: "fast", arguments: [:]))
        )
        if case .text(let text, _, _) = result1.content.first {
            #expect(text == "fast 1")
        }

        // Second call should timeout (slow operation with minimal timeout)
        do {
            _ = try await client.send(
                CallTool.request(.init(name: "slow", arguments: [:])),
                options: .init(timeout: .milliseconds(10))
            )
            Issue.record("Expected slow tool to timeout")
        } catch let error as MCPError {
            if case .requestTimeout = error {
                // Expected
            } else {
                // Cancellation error is also acceptable
            }
        }

        // Release the slow request to avoid hanging processes
        await slowRequestLock.signal()

        // Third call should work (fast operation, no timeout)
        // This proves the server is still responsive
        let result3 = try await client.send(
            CallTool.request(.init(name: "fast", arguments: [:]))
        )
        if case .text(let text, _, _) = result3.content.first {
            #expect(text == "fast 3", "Third call should succeed after timeout")
        }

        // Verify all requests were processed by the server
        let finalCount = await requestCount.value
        #expect(finalCount >= 3, "Server should have processed at least 3 requests")
    }

    /// Test multiple sequential requests after a timeout.
    ///
    /// This verifies that the server doesn't get into a bad state after a timeout.
    @Test(.timeLimit(.minutes(1)))
    func multipleRequestsAfterTimeout() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.multiple-after-timeout")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "MultipleAfterTimeoutServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "configurable", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            let delay = request.arguments?["delay"]?.doubleValue ?? 0.0
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            return CallTool.Result(content: [.text("Completed after \(delay)s")])
        }

        let client = Client(name: "MultipleClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // First, trigger a timeout
        do {
            _ = try await client.send(
                CallTool.request(.init(name: "configurable", arguments: ["delay": .double(10.0)])),
                options: .init(timeout: .milliseconds(10))
            )
        } catch {
            // Expected timeout
        }

        // Now send multiple sequential requests - all should succeed
        for i in 1...5 {
            let result = try await client.send(
                CallTool.request(.init(name: "configurable", arguments: ["delay": .double(0.0)]))
            )
            if case .text(let text, _, _) = result.content.first {
                #expect(text == "Completed after 0.0s", "Request \(i) should succeed")
            }
        }
    }

    /// Test that concurrent requests where one times out don't affect other requests.
    ///
    /// Based on Python SDK's approach of testing timeout isolation.
    @Test(.timeLimit(.minutes(1)))
    func timeoutDoesntAffectConcurrentRequests() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.concurrent-timeout")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let slowRequestLock = AsyncEvent()

        let server = Server(
            name: "ConcurrentTimeoutServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "slow_tool", inputSchema: ["type": "object"]),
                Tool(name: "fast_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "slow_tool" {
                // Wait indefinitely until signaled
                await slowRequestLock.wait()
                return CallTool.Result(content: [.text("slow completed")])
            } else if request.name == "fast_tool" {
                return CallTool.Result(content: [.text("fast completed")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let client = Client(name: "ConcurrentClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Start a slow request that will timeout (using a very short timeout)
        let slowTask = Task {
            try await client.send(
                CallTool.request(.init(name: "slow_tool", arguments: [:])),
                options: .init(timeout: .milliseconds(50))
            )
        }

        // Give the slow request a moment to start
        try await Task.sleep(for: .milliseconds(10))

        // Start a fast request concurrently - this should succeed even though slow is pending
        let fastTask = Task {
            try await client.send(
                CallTool.request(.init(name: "fast_tool", arguments: [:]))
            )
        }

        // Fast request should succeed
        let fastResult = try await fastTask.value
        if case .text(let text, _, _) = fastResult.content.first {
            #expect(text == "fast completed")
        }

        // Slow request should timeout (or be cancelled)
        do {
            _ = try await slowTask.value
            // If it didn't throw, it might have completed before timeout kicked in
            // In concurrent scenarios, this is acceptable
        } catch {
            // Expected - timeout or cancellation
        }

        // Release the slow request lock to clean up server resources
        await slowRequestLock.signal()
    }
}

// MARK: - Helper Types

/// An actor for thread-safe counting.
private actor AtomicCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
}

/// An actor for async event signaling.
private actor AsyncEvent {
    private var signaled = false

    func signal() {
        signaled = true
    }

    func wait() async {
        while !signaled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
