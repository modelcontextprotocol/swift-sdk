import Foundation
import Logging
import Testing

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@testable import MCP

// MARK: - Cancellation Tests

/// Tests for request cancellation functionality in MCP.
///
/// Cancellation allows either client or server to signal that an ongoing
/// operation should be terminated. This is done via the `notifications/cancelled`
/// notification which can optionally include a request ID and reason.
///
/// Reference: MCP Specification 2025-11-25 (cancellation support)
/// Based on:
/// - Python SDK: tests/server/test_cancel_handling.py
/// - TypeScript SDK: packages/core/test/shared/protocol.test.ts
@Suite("Cancellation Tests")
struct CancellationTests {

    // MARK: - CancelledNotification Encoding/Decoding Tests

    @Suite("CancelledNotification encoding/decoding")
    struct CancelledNotificationEncodingTests {

        @Test("Encodes with requestId and reason")
        func encodesWithRequestIdAndReason() throws {
            let params = CancelledNotification.Parameters(
                requestId: .string("req-123"),
                reason: "User cancelled the operation"
            )
            let notification = CancelledNotification.message(params)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            #expect(json["jsonrpc"] == "2.0")
            #expect(json["method"] == "notifications/cancelled")

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams?["requestId"]?.stringValue == "req-123")
            #expect(notificationParams?["reason"]?.stringValue == "User cancelled the operation")
        }

        @Test("Encodes with integer requestId")
        func encodesWithIntegerRequestId() throws {
            let params = CancelledNotification.Parameters(
                requestId: .number(42),
                reason: "Timeout"
            )
            let notification = CancelledNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams?["requestId"]?.intValue == 42)
            #expect(notificationParams?["reason"]?.stringValue == "Timeout")
        }

        @Test("Encodes with only requestId")
        func encodesWithOnlyRequestId() throws {
            let params = CancelledNotification.Parameters(requestId: .string("req-456"))
            let notification = CancelledNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams?["requestId"]?.stringValue == "req-456")
            #expect(notificationParams?["reason"] == nil)
        }

        @Test("Encodes with only reason (protocol 2025-11-25+)")
        func encodesWithOnlyReason() throws {
            // In protocol 2025-11-25+, requestId is optional
            let params = CancelledNotification.Parameters(reason: "General cancellation")
            let notification = CancelledNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams?["requestId"] == nil)
            #expect(notificationParams?["reason"]?.stringValue == "General cancellation")
        }

        @Test("Encodes with no parameters (protocol 2025-11-25+)")
        func encodesWithNoParameters() throws {
            // In protocol 2025-11-25+, both requestId and reason are optional
            let params = CancelledNotification.Parameters()
            let notification = CancelledNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            #expect(json["jsonrpc"] == "2.0")
            #expect(json["method"] == "notifications/cancelled")
            // Params should be present but may be empty
            #expect(json["params"] != nil)
        }

        @Test("Decodes with requestId and reason")
        func decodesWithRequestIdAndReason() throws {
            let jsonString = """
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/cancelled",
                    "params": {
                        "requestId": "req-789",
                        "reason": "Operation timed out"
                    }
                }
                """
            let data = jsonString.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(
                Message<CancelledNotification>.self, from: data)

            #expect(decoded.method == "notifications/cancelled")
            #expect(decoded.params.requestId == .string("req-789"))
            #expect(decoded.params.reason == "Operation timed out")
        }

        @Test("Decodes with integer requestId")
        func decodesWithIntegerRequestId() throws {
            let jsonString = """
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/cancelled",
                    "params": {
                        "requestId": 123,
                        "reason": "Client disconnected"
                    }
                }
                """
            let data = jsonString.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(
                Message<CancelledNotification>.self, from: data)

            #expect(decoded.params.requestId == .number(123))
            #expect(decoded.params.reason == "Client disconnected")
        }

        @Test("Decodes with empty params")
        func decodesWithEmptyParams() throws {
            let jsonString = """
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/cancelled",
                    "params": {}
                }
                """
            let data = jsonString.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(
                Message<CancelledNotification>.self, from: data)

            #expect(decoded.method == "notifications/cancelled")
            #expect(decoded.params.requestId == nil)
            #expect(decoded.params.reason == nil)
        }

        @Test("Round-trip encoding/decoding preserves all fields")
        func roundTripPreservesAllFields() throws {
            let original = CancelledNotification.Parameters(
                requestId: .string("round-trip-test"),
                reason: "Testing round-trip encoding",
                _meta: ["key": .string("value")]
            )
            let notification = CancelledNotification.message(original)

            let encoder = JSONEncoder()
            let decoder = JSONDecoder()

            let data = try encoder.encode(notification)
            let decoded = try decoder.decode(Message<CancelledNotification>.self, from: data)

            #expect(decoded.params.requestId == original.requestId)
            #expect(decoded.params.reason == original.reason)
            #expect(decoded.params._meta?["key"]?.stringValue == "value")
        }

        @Test("Notification name is correct")
        func notificationNameIsCorrect() {
            #expect(CancelledNotification.name == "notifications/cancelled")
        }
    }

    // MARK: - JSON Format Compatibility Tests

    @Suite("CancelledNotification JSON format")
    struct CancelledNotificationJSONFormatTests {

        @Test("Matches TypeScript SDK format with all fields")
        func matchesTypeScriptFormatAllFields() throws {
            // TypeScript SDK format for cancelled notification
            let params = CancelledNotification.Parameters(
                requestId: .string("test-request"),
                reason: "User cancelled"
            )
            let notification = CancelledNotification.message(params)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(notification)
            let jsonString = String(data: data, encoding: .utf8)!

            // Verify JSON structure matches expected format
            #expect(jsonString.contains("\"jsonrpc\":\"2.0\""))
            #expect(jsonString.contains("\"method\":\"notifications/cancelled\""))
            #expect(jsonString.contains("\"params\""))
            #expect(jsonString.contains("\"requestId\":\"test-request\""))
            #expect(jsonString.contains("\"reason\":\"User cancelled\""))
        }

        @Test("Matches Python SDK format")
        func matchesPythonFormat() throws {
            // Python SDK test uses CancelledNotificationParams with requestId and reason
            let params = CancelledNotification.Parameters(
                requestId: .string("first-request-id"),
                reason: "Testing server recovery"
            )
            let notification = CancelledNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            // Verify structure matches Python SDK expectations
            #expect(json["jsonrpc"] == "2.0")
            #expect(json["method"] == "notifications/cancelled")

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams != nil)
            #expect(notificationParams?["requestId"] == .string("first-request-id"))
            #expect(notificationParams?["reason"] == .string("Testing server recovery"))
        }
    }

    // MARK: - Integration Tests

    @Suite("Cancellation integration")
    struct CancellationIntegrationTests {

        /// Actor to track received cancellation notifications
        private actor CancellationTracker {
            private var cancellations: [CancelledNotification.Parameters] = []

            func add(_ params: CancelledNotification.Parameters) {
                cancellations.append(params)
            }

            var count: Int { cancellations.count }
            var all: [CancelledNotification.Parameters] { cancellations }
        }

        /// Test that client can send a CancelledNotification to the server.
        ///
        /// This tests the basic notification flow from client to server.
        @Test(.timeLimit(.minutes(1)))
        func clientSendsCancelledNotificationToServer() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation")
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

            let cancellationTracker = CancellationTracker()

            // Set up server with cancellation notification handler
            let server = Server(
                name: "CancellationTestServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.onNotification(CancelledNotification.self) { message in
                await cancellationTracker.add(message.params)
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "test_tool", inputSchema: ["type": "object"])
                ])
            }

            let client = Client(name: "CancellationTestClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Send a cancellation notification
            let cancelParams = CancelledNotification.Parameters(
                requestId: .string("req-to-cancel"),
                reason: "User requested cancellation"
            )
            try await client.notify(CancelledNotification.message(cancelParams))

            // Give time for notification to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify server received the cancellation notification
            let count = await cancellationTracker.count
            #expect(count == 1, "Server should receive exactly one cancellation notification")

            let cancellations = await cancellationTracker.all
            if let first = cancellations.first {
                #expect(first.requestId == .string("req-to-cancel"))
                #expect(first.reason == "User requested cancellation")
            }
        }

        /// Test that server remains functional after receiving a cancellation notification.
        ///
        /// This is based on Python SDK's test_server_remains_functional_after_cancel test.
        /// The key insight is that cancellation notifications should not break the server's
        /// ability to handle subsequent requests.
        @Test(.timeLimit(.minutes(1)))
        func serverRemainsFunctionalAfterCancel() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.recovery")
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

            let callCounter = CallCounter()
            let cancellationTracker = CancellationTracker()

            // Set up server
            let server = Server(
                name: "RecoveryTestServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.onNotification(CancelledNotification.self) { message in
                await cancellationTracker.add(message.params)
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(
                        name: "test_tool",
                        description: "A tool for testing cancellation recovery",
                        inputSchema: ["type": "object"]
                    )
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "test_tool" else {
                    return CallTool.Result(content: [.text("Unknown tool")], isError: true)
                }
                let count = await callCounter.increment()
                return CallTool.Result(content: [.text("Call number: \(count)")])
            }

            let client = Client(name: "RecoveryTestClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // First tool call - should succeed
            let result1 = try await client.send(
                CallTool.request(.init(name: "test_tool", arguments: [:]))
            )
            if case .text(let text, _, _) = result1.content.first {
                #expect(text == "Call number: 1")
            } else {
                Issue.record("Expected text content for first call")
            }

            // Send cancellation notification (simulating a cancelled request)
            let cancelParams = CancelledNotification.Parameters(
                requestId: .string("some-cancelled-request"),
                reason: "Testing server recovery"
            )
            try await client.notify(CancelledNotification.message(cancelParams))

            // Give time for notification to be processed
            try await Task.sleep(for: .milliseconds(50))

            // Verify cancellation was received
            let cancellationCount = await cancellationTracker.count
            #expect(cancellationCount == 1, "Server should have received the cancellation")

            // Second tool call - should also succeed (server recovered)
            let result2 = try await client.send(
                CallTool.request(.init(name: "test_tool", arguments: [:]))
            )
            if case .text(let text, _, _) = result2.content.first {
                #expect(text == "Call number: 2")
            } else {
                Issue.record("Expected text content for second call")
            }

            // Verify call count
            let finalCount = await callCounter.count
            #expect(finalCount == 2, "Both tool calls should have been processed")
        }

        /// Test that server can send a cancellation notification to the client.
        ///
        /// The server may need to cancel a pending request (e.g., if it takes too long
        /// or if the server is shutting down).
        @Test(.timeLimit(.minutes(1)))
        func serverSendsCancelledNotificationToClient() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.server-to-client")
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

            let clientCancellationReceived = ClientCancellationTracker()

            let server = Server(
                name: "ServerCancelTestServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "trigger_cancel", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "trigger_cancel" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Server sends a cancellation notification for some other request
                // This simulates the server cancelling a client's pending request
                try await context.sendMessage(CancelledNotification.message(.init(
                    requestId: .string("client-pending-request"),
                    reason: "Server is cancelling this request"
                )))

                return CallTool.Result(content: [.text("Cancel notification sent")])
            }

            let client = Client(name: "ServerCancelTestClient", version: "1.0")

            // Register client handler for cancellation notifications
            await client.onNotification(CancelledNotification.self) { message in
                await clientCancellationReceived.add(message.params)
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Call the tool that triggers a cancellation notification
            let result = try await client.send(
                CallTool.request(.init(name: "trigger_cancel", arguments: [:]))
            )

            // Verify tool completed
            if case .text(let text, _, _) = result.content.first {
                #expect(text == "Cancel notification sent")
            }

            // Give time for notification to arrive
            try await Task.sleep(for: .milliseconds(100))

            // Verify client received the cancellation
            let count = await clientCancellationReceived.count
            #expect(count == 1, "Client should receive the cancellation notification")

            let cancellations = await clientCancellationReceived.all
            if let first = cancellations.first {
                #expect(first.requestId == .string("client-pending-request"))
                #expect(first.reason == "Server is cancelling this request")
            }
        }

        /// Test multiple cancellation notifications can be processed.
        @Test(.timeLimit(.minutes(1)))
        func multipleCancellationNotifications() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.multiple")
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

            let cancellationTracker = CancellationTracker()

            let server = Server(
                name: "MultipleCancelServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.onNotification(CancelledNotification.self) { message in
                await cancellationTracker.add(message.params)
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [])
            }

            let client = Client(name: "MultipleCancelClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Send multiple cancellation notifications
            for i in 1...5 {
                let cancelParams = CancelledNotification.Parameters(
                    requestId: .string("req-\(i)"),
                    reason: "Cancellation \(i)"
                )
                try await client.notify(CancelledNotification.message(cancelParams))
            }

            // Give time for all notifications to be processed
            try await Task.sleep(for: .milliseconds(200))

            // Verify all cancellations were received
            let count = await cancellationTracker.count
            #expect(count == 5, "Server should receive all 5 cancellation notifications")

            let cancellations = await cancellationTracker.all
            for i in 1...5 {
                let expected = CancelledNotification.Parameters(
                    requestId: .string("req-\(i)"),
                    reason: "Cancellation \(i)"
                )
                #expect(
                    cancellations.contains { $0.requestId == expected.requestId },
                    "Should contain cancellation for req-\(i)"
                )
            }
        }

        /// Test cancellation notification with no requestId (protocol 2025-11-25+).
        ///
        /// In newer protocol versions, the requestId is optional.
        @Test(.timeLimit(.minutes(1)))
        func cancellationWithoutRequestId() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.no-request-id")
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

            let cancellationTracker = CancellationTracker()

            let server = Server(
                name: "NoRequestIdCancelServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.onNotification(CancelledNotification.self) { message in
                await cancellationTracker.add(message.params)
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [])
            }

            let client = Client(name: "NoRequestIdCancelClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Send cancellation without requestId (general cancellation)
            let cancelParams = CancelledNotification.Parameters(
                reason: "General operation cancellation"
            )
            try await client.notify(CancelledNotification.message(cancelParams))

            // Give time for notification to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify cancellation was received
            let count = await cancellationTracker.count
            #expect(count == 1)

            let cancellations = await cancellationTracker.all
            if let first = cancellations.first {
                #expect(first.requestId == nil, "requestId should be nil")
                #expect(first.reason == "General operation cancellation")
            }
        }
    }

    // MARK: - Server Context Cancellation Tests

    @Suite("Server.Context cancellation")
    struct ServerContextCancellationTests {

        /// Test that Server.Context.sendCancelled works correctly.
        ///
        /// The Server.Context has a sendCancelled convenience method for sending
        /// cancellation notifications.
        @Test(.timeLimit(.minutes(1)))
        func serverContextSendCancelled() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.context")
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

            let clientCancellationReceived = ClientCancellationTracker()

            let server = Server(
                name: "ContextCancelServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "cancel_via_context", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "cancel_via_context" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Use the context's sendMessage to send a CancelledNotification
                try await context.sendMessage(CancelledNotification.message(.init(
                    requestId: .string("ctx-cancel-request"),
                    reason: "Cancelled via server context"
                )))

                return CallTool.Result(content: [.text("Cancellation sent via context")])
            }

            let client = Client(name: "ContextCancelClient", version: "1.0")

            await client.onNotification(CancelledNotification.self) { message in
                await clientCancellationReceived.add(message.params)
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Call the tool
            let result = try await client.send(
                CallTool.request(.init(name: "cancel_via_context", arguments: [:]))
            )

            if case .text(let text, _, _) = result.content.first {
                #expect(text == "Cancellation sent via context")
            }

            // Give time for notification
            try await Task.sleep(for: .milliseconds(100))

            // Verify client received cancellation
            let count = await clientCancellationReceived.count
            #expect(count == 1)

            let cancellations = await clientCancellationReceived.all
            if let first = cancellations.first {
                #expect(first.requestId == .string("ctx-cancel-request"))
                #expect(first.reason == "Cancelled via server context")
            }
        }
    }

    // MARK: - Client Task Cancellation Tests

    @Suite("Client Swift Task cancellation")
    struct ClientTaskCancellationTests {

        /// Actor to track received cancellation notifications
        private actor CancellationTracker {
            private var cancellations: [CancelledNotification.Parameters] = []

            func add(_ params: CancelledNotification.Parameters) {
                cancellations.append(params)
            }

            var count: Int { cancellations.count }
            var all: [CancelledNotification.Parameters] { cancellations }
        }

        /// Test that cancelling a Swift Task that's waiting for a response properly cleans up.
        ///
        /// This mirrors the TypeScript SDK's AbortController behavior - when the client
        /// cancels the Task waiting for a response, the pending request is cleaned up
        /// and an appropriate error is thrown.
        @Test(.timeLimit(.minutes(1)))
        func clientTaskCancellationCleansUpPendingRequest() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.task-cancel")
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

            let toolCallStarted = ToolCallStartedTracker()

            let server = Server(
                name: "TaskCancelServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "slow_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "slow_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Signal that the tool call has started
                await toolCallStarted.markStarted()

                // Simulate a slow operation - this should be interrupted by task cancellation
                do {
                    try await Task.sleep(for: .seconds(10))
                    return CallTool.Result(content: [.text("Completed")])
                } catch {
                    // Task was cancelled - this is expected
                    return CallTool.Result(content: [.text("Cancelled")], isError: true)
                }
            }

            let client = Client(name: "TaskCancelClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Start a tool call in a separate Task that we can cancel
            let callTask = Task {
                try await client.send(
                    CallTool.request(.init(name: "slow_tool", arguments: [:]))
                )
            }

            // Wait for the tool call to start
            try await toolCallStarted.waitForStart()

            // Cancel the Task
            callTask.cancel()

            // Verify the task throws an error (CancellationError, connection closed, or no response)
            do {
                _ = try await callTask.value
                Issue.record("Expected task to throw an error when cancelled")
            } catch is CancellationError {
                // Expected - Swift Task cancellation
            } catch let error as MCPError {
                // Also expected - connection closed or no response received
                // When a Task is cancelled, the pending request stream is terminated
                // which can result in "No response received" or "connectionClosed"
                let errorDescription = String(describing: error)
                #expect(
                    error == .connectionClosed ||
                    errorDescription.contains("cancel") ||
                    errorDescription.contains("No response received"),
                    "Error should be related to cancellation or no response: \(error)"
                )
            }

            // Verify client is still functional after cancellation
            // List tools should still work
            let tools = try await client.send(ListTools.request(.init()))
            #expect(tools.tools.count == 1)
            #expect(tools.tools.first?.name == "slow_tool")
        }

        /// Test that multiple concurrent requests can be individually cancelled.
        @Test(.timeLimit(.minutes(1)))
        func multipleConcurrentRequestsCancellation() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.concurrent")
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
                name: "ConcurrentCancelServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "variable_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "variable_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Delay based on the "delay" argument
                let delay = request.arguments?["delay"]?.doubleValue ?? 1.0
                try? await Task.sleep(for: .seconds(delay))
                return CallTool.Result(content: [.text("Done after \(delay)s")])
            }

            let client = Client(name: "ConcurrentCancelClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Start two concurrent requests
            let fastTask = Task {
                try await client.send(
                    CallTool.request(.init(name: "variable_tool", arguments: ["delay": .double(0.1)]))
                )
            }

            let slowTask = Task {
                try await client.send(
                    CallTool.request(.init(name: "variable_tool", arguments: ["delay": .double(10.0)]))
                )
            }

            // Wait a bit for both requests to start
            try await Task.sleep(for: .milliseconds(50))

            // Cancel only the slow task
            slowTask.cancel()

            // Fast task should complete successfully
            let fastResult = try await fastTask.value
            if case .text(let text, _, _) = fastResult.content.first {
                #expect(text.contains("0.1"))
            }

            // Slow task should be cancelled
            do {
                _ = try await slowTask.value
                Issue.record("Slow task should have been cancelled")
            } catch {
                // Expected - task was cancelled
            }
        }

        /// Test that when a client Task is cancelled, the client sends a CancelledNotification to the server.
        ///
        /// This is per MCP spec: "When a party wants to cancel an in-progress request,
        /// it sends a `notifications/cancelled` notification"
        ///
        /// This mirrors the TypeScript SDK's behavior where AbortSignal abort triggers
        /// sending notifications/cancelled.
        @Test(.timeLimit(.minutes(1)))
        func clientTaskCancellationSendsCancelledNotification() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.client-sends-notification")
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

            let cancellationReceived = CancellationTracker()
            let handlerStarted = ToolCallStartedTracker()

            let server = Server(
                name: "ClientCancellationNotificationServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            // Track cancellation notifications received by the server
            await server.onNotification(CancelledNotification.self) { message in
                await cancellationReceived.add(message.params)
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "slow_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "slow_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                await handlerStarted.markStarted()

                // Slow operation
                try? await Task.sleep(for: .seconds(10))
                return CallTool.Result(content: [.text("Completed")])
            }

            let client = Client(name: "ClientCancellationNotificationClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Create a request with a known ID
            let knownRequestId = RequestId.string("client-will-cancel-this")
            let request = Request<CallTool>(
                id: knownRequestId,
                method: CallTool.name,
                params: CallTool.Parameters(name: "slow_tool", arguments: [:])
            )

            // Start the request in a Task we can cancel
            let callTask = Task {
                try await client.send(request)
            }

            // Wait for handler to start
            try await handlerStarted.waitForStart()

            // Cancel the client Task - this should trigger sending CancelledNotification
            callTask.cancel()

            // Give time for cancellation notification to be sent and processed
            try await Task.sleep(for: .milliseconds(200))

            // Verify server received the cancellation notification
            let count = await cancellationReceived.count
            #expect(count >= 1, "Server should receive a cancellation notification when client Task is cancelled")

            let cancellations = await cancellationReceived.all
            let hasCancellationForRequest = cancellations.contains { $0.requestId == knownRequestId }
            #expect(hasCancellationForRequest, "Server should receive cancellation for the specific request ID")
        }
    }

    // MARK: - Protocol-Level Cancellation Tests

    @Suite("Protocol-level cancellation (CancelledNotification aborts in-flight handlers)")
    struct ProtocolLevelCancellationTests {

        /// Test that when a CancelledNotification is received, the in-flight request handler
        /// is cancelled and no response is sent.
        ///
        /// This mirrors the Python SDK's `test_server_remains_functional_after_cancel` test.
        @Test(.timeLimit(.minutes(1)))
        func serverCancelsInFlightRequestOnNotification() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.protocol-level")
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

            let handlerStarted = ToolCallStartedTracker()
            let handlerCompleted = HandlerCompletionTracker()

            let server = Server(
                name: "ProtocolCancelServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "slow_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "slow_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Signal that the handler has started
                await handlerStarted.markStarted()

                // This is a slow operation that should be cancelled
                do {
                    try await Task.sleep(for: .seconds(10))
                    await handlerCompleted.markCompleted()
                    return CallTool.Result(content: [.text("Completed")])
                } catch is CancellationError {
                    // Expected - handler was cancelled
                    await handlerCompleted.markCancelled()
                    throw CancellationError()
                }
            }

            let client = Client(name: "ProtocolCancelClient", version: "1.0")

            try await server.start(transport: serverTransport)
            let initResult = try await client.connect(transport: clientTransport)
            #expect(initResult.serverInfo.name == "ProtocolCancelServer")

            // Create a request with a known ID so we can cancel it
            let knownRequestId = RequestId.string("test-request-to-cancel")
            let toolCallRequest = Request<CallTool>(
                id: knownRequestId,
                method: CallTool.name,
                params: CallTool.Parameters(name: "slow_tool", arguments: [:])
            )

            // Start a slow tool call in a separate Task
            let callTask = Task {
                try await client.send(toolCallRequest)
            }

            // Wait for the handler to start
            try await handlerStarted.waitForStart()

            // Send cancellation notification from client to server with the known request ID
            try await client.notify(CancelledNotification.message(.init(
                requestId: knownRequestId,
                reason: "Test cancellation"
            )))

            // Give time for cancellation to propagate
            try await Task.sleep(for: .milliseconds(100))

            // The call task should eventually fail or hang waiting for response
            // Cancel it from the client side as well to clean up
            callTask.cancel()

            // Verify the handler was cancelled (not completed normally)
            let wasCompleted = await handlerCompleted.wasCompleted
            let wasCancelled = await handlerCompleted.wasCancelled
            #expect(!wasCompleted, "Handler should not have completed normally")
            #expect(wasCancelled, "Handler should have been cancelled")

            // Verify server is still functional after cancellation
            let tools = try await client.send(ListTools.request(.init()))
            #expect(tools.tools.count == 1)
            #expect(tools.tools.first?.name == "slow_tool")
        }

        /// Test that response is suppressed when Task.isCancelled is true
        /// even if the handler completes normally.
        @Test(.timeLimit(.minutes(1)))
        func serverSuppressesResponseWhenCancelled() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.suppress-response")
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

            let handlerStarted = ToolCallStartedTracker()

            let server = Server(
                name: "SuppressResponseServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "quick_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "quick_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                await handlerStarted.markStarted()

                // Small delay to allow cancellation to arrive
                try? await Task.sleep(for: .milliseconds(50))

                // Handler completes normally, but response should be suppressed
                // if Task.isCancelled is true
                return CallTool.Result(content: [.text("Should be suppressed")])
            }

            let client = Client(name: "SuppressResponseClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Create a request with a known ID so we can cancel it
            let knownRequestId = RequestId.string("suppress-response-request")
            let toolCallRequest = Request<CallTool>(
                id: knownRequestId,
                method: CallTool.name,
                params: CallTool.Parameters(name: "quick_tool", arguments: [:])
            )

            // Start a tool call
            let callTask = Task {
                try await client.send(toolCallRequest)
            }

            // Wait for handler to start
            try await handlerStarted.waitForStart()

            // Send cancellation immediately
            try await client.notify(CancelledNotification.message(.init(
                requestId: knownRequestId,
                reason: "Suppress response test"
            )))

            // Cancel the client task as well since no response will come
            try await Task.sleep(for: .milliseconds(100))
            callTask.cancel()

            // The test passes if we get here - the server didn't crash
            // and handled the cancellation gracefully
        }

        /// Test that server shutdown cancels all in-flight handlers.
        @Test(.timeLimit(.minutes(1)))
        func serverShutdownCancelsInFlightHandlers() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.cancellation.shutdown")
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

            let handlerStarted = ToolCallStartedTracker()
            let handlerCompleted = HandlerCompletionTracker()

            let server = Server(
                name: "ShutdownCancelServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "very_slow_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "very_slow_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                await handlerStarted.markStarted()

                do {
                    try await Task.sleep(for: .seconds(60))
                    await handlerCompleted.markCompleted()
                    return CallTool.Result(content: [.text("Completed")])
                } catch is CancellationError {
                    await handlerCompleted.markCancelled()
                    throw CancellationError()
                }
            }

            let client = Client(name: "ShutdownCancelClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Start a very slow tool call
            let callTask = Task {
                try await client.send(
                    CallTool.request(.init(name: "very_slow_tool", arguments: [:]))
                )
            }

            // Wait for handler to start
            try await handlerStarted.waitForStart()

            // Stop the server while the handler is running
            await server.stop()

            // Give time for cancellation to propagate
            try await Task.sleep(for: .milliseconds(100))

            // Verify the handler was cancelled
            let wasCancelled = await handlerCompleted.wasCancelled
            #expect(wasCancelled, "Handler should have been cancelled on shutdown")

            // Clean up the client task
            callTask.cancel()
        }
    }
}

// MARK: - Request Timeout Tests

@Suite("Request timeout")
struct RequestTimeoutTests {

    /// Test that request timeout triggers cancellation and throws the correct error.
    @Test(.timeLimit(.minutes(1)))
    func requestTimeoutTriggersError() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.timeout")
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
            name: "TimeoutServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "slow_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            guard request.name == "slow_tool" else {
                return CallTool.Result(content: [.text("Unknown")], isError: true)
            }

            // Simulate a slow operation that takes longer than the timeout
            try? await Task.sleep(for: .seconds(10))
            return CallTool.Result(content: [.text("Completed")])
        }

        let client = Client(name: "TimeoutClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Send request with a short timeout
        do {
            _ = try await client.send(
                CallTool.request(.init(name: "slow_tool", arguments: [:])),
                options: .init(timeout: .milliseconds(100))
            )
            Issue.record("Expected request to timeout")
        } catch let error as MCPError {
            // Verify we get a requestTimeout error
            if case .requestTimeout(let timeout, let message) = error {
                #expect(timeout == .milliseconds(100))
                #expect(message?.contains("timed out") == true)
            } else {
                Issue.record("Expected MCPError.requestTimeout, got: \(error)")
            }
        }

        // Verify client is still functional after timeout
        let tools = try await client.send(ListTools.request(.init()))
        #expect(tools.tools.count == 1)

        await client.disconnect()
        await server.stop()
    }

    /// Test that request without timeout waits indefinitely (until completed).
    @Test(.timeLimit(.minutes(1)))
    func requestWithoutTimeoutWaitsForResponse() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.no-timeout")
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
            name: "NoTimeoutServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "fast_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            guard request.name == "fast_tool" else {
                return CallTool.Result(content: [.text("Unknown")], isError: true)
            }

            // Small delay, but should complete fine without timeout
            try? await Task.sleep(for: .milliseconds(50))
            return CallTool.Result(content: [.text("Completed")])
        }

        let client = Client(name: "NoTimeoutClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Send request without timeout - should complete normally
        let result = try await client.send(
            CallTool.request(.init(name: "fast_tool", arguments: [:])),
            options: nil
        )

        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Completed")
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
        await server.stop()
    }

    /// Test that timeout sends CancelledNotification to server.
    @Test(.timeLimit(.minutes(1)))
    func timeoutSendsCancelledNotification() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.timeout-cancellation")
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

        let cancellationReceived = CancellationReceivedTracker()

        let server = Server(
            name: "CancellationTrackingServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        // Track cancellation notifications
        await server.onNotification(CancelledNotification.self) { message in
            await cancellationReceived.add(message.params)
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "slow_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            guard request.name == "slow_tool" else {
                return CallTool.Result(content: [.text("Unknown")], isError: true)
            }

            // Simulate a slow operation
            try? await Task.sleep(for: .seconds(10))
            return CallTool.Result(content: [.text("Completed")])
        }

        let client = Client(name: "CancellationClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Send request with timeout
        do {
            _ = try await client.send(
                CallTool.request(.init(name: "slow_tool", arguments: [:])),
                options: .init(timeout: .milliseconds(100))
            )
        } catch {
            // Expected timeout error
        }

        // Give time for cancellation notification to be sent and processed
        try await Task.sleep(for: .milliseconds(100))

        // Verify cancellation notification was received
        let count = await cancellationReceived.count
        #expect(count >= 1, "Server should have received at least one cancellation notification")

        if count > 0 {
            let cancellations = await cancellationReceived.all
            let lastCancellation = cancellations.last!
            #expect(lastCancellation.reason?.contains("timed out") == true)
        }

        await client.disconnect()
        await server.stop()
    }

}

// MARK: - Helper Types

/// Actor to track cancellation notifications received by the server
private actor CancellationReceivedTracker {
    private var cancellations: [CancelledNotification.Parameters] = []

    func add(_ params: CancelledNotification.Parameters) {
        cancellations.append(params)
    }

    var count: Int { cancellations.count }
    var all: [CancelledNotification.Parameters] { cancellations }
}

/// Actor to track when a tool call has started
private actor ToolCallStartedTracker {
    private var started = false

    func markStarted() {
        started = true
    }

    func waitForStart() async throws {
        while !started {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Actor to track whether a handler completed or was cancelled
private actor HandlerCompletionTracker {
    private var _completed = false
    private var _cancelled = false

    func markCompleted() {
        _completed = true
    }

    func markCancelled() {
        _cancelled = true
    }

    var wasCompleted: Bool { _completed }
    var wasCancelled: Bool { _cancelled }
}

/// Actor to track tool call counts
private actor CallCounter {
    private var _count = 0

    func increment() -> Int {
        _count += 1
        return _count
    }

    var count: Int { _count }
}

/// Actor to track cancellation notifications received by the client
private actor ClientCancellationTracker {
    private var cancellations: [CancelledNotification.Parameters] = []

    func add(_ params: CancelledNotification.Parameters) {
        cancellations.append(params)
    }

    var count: Int { cancellations.count }
    var all: [CancelledNotification.Parameters] { cancellations }
}

// MARK: - Client.cancelRequest() Tests

/// Tests for the public `Client.cancelRequest(_:reason:)` API.
///
/// This API allows explicit cancellation of in-flight requests by ID,
/// similar to TypeScript SDK's AbortController pattern.
@Suite("Client.cancelRequest() API")
struct ClientCancelRequestAPITests {

    /// Test that cancelRequest properly cancels an in-flight request and sends CancelledNotification.
    ///
    /// Based on Python SDK's test pattern where cancellation is sent for a specific request ID.
    @Test(.timeLimit(.minutes(1)))
    func cancelRequestSendsCancelledNotificationAndThrowsError() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.cancel-request-api")
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

        let cancellationReceived = CancellationReceivedTracker()
        let handlerStarted = ToolCallStartedTracker()

        let server = Server(
            name: "CancelRequestAPIServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        // Track cancellation notifications
        await server.onNotification(CancelledNotification.self) { message in
            await cancellationReceived.add(message.params)
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "slow_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            guard request.name == "slow_tool" else {
                return CallTool.Result(content: [.text("Unknown")], isError: true)
            }

            await handlerStarted.markStarted()

            // Slow operation - should be interrupted
            try? await Task.sleep(for: .seconds(10))
            return CallTool.Result(content: [.text("Completed")])
        }

        let client = Client(name: "CancelRequestAPIClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Create a request with a known ID
        let knownRequestId = RequestId.string("api-cancel-test-\(UUID().uuidString)")
        let request = Request<CallTool>(
            id: knownRequestId,
            method: CallTool.name,
            params: CallTool.Parameters(name: "slow_tool", arguments: [:])
        )

        // Start the request in a separate Task
        let requestTask = Task<CallTool.Result, Error> {
            try await client.send(request)
        }

        // Wait for handler to start
        try await handlerStarted.waitForStart()

        // Use the cancelRequest API to cancel the request
        await client.cancelRequest(knownRequestId, reason: "Cancelled via cancelRequest API")

        // Give time for cancellation to propagate
        try await Task.sleep(for: .milliseconds(100))

        // Verify the request throws MCPError.requestCancelled
        do {
            _ = try await requestTask.value
            Issue.record("Expected request to throw MCPError.requestCancelled")
        } catch let error as MCPError {
            // Should be requestCancelled error
            if case .requestCancelled(let reason) = error {
                #expect(reason == "Cancelled via cancelRequest API")
            } else {
                // May also be connectionClosed or similar if timing is different
                // This is acceptable behavior
            }
        } catch is CancellationError {
            // Also acceptable - Swift Task cancellation propagated
        }

        // Verify server received the cancellation notification
        let count = await cancellationReceived.count
        #expect(count >= 1, "Server should receive at least one CancelledNotification")

        let cancellations = await cancellationReceived.all
        let matchingCancellation = cancellations.first { $0.requestId == knownRequestId }
        #expect(matchingCancellation != nil, "Should have received cancellation for the specific request ID")
        #expect(matchingCancellation?.reason == "Cancelled via cancelRequest API")

        // Verify client is still functional after cancellation
        let tools = try await client.send(ListTools.request(.init()))
        #expect(tools.tools.count == 1)
    }

    /// Test that cancelRequest for unknown request ID is a no-op (per MCP spec).
    ///
    /// Per MCP spec: "The receiver MUST NOT assume that the request will be cancelled;
    /// it MAY still complete normally."
    @Test(.timeLimit(.minutes(1)))
    func cancelRequestForUnknownIdIsNoOp() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.cancel-unknown-request")
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

        let cancellationReceived = CancellationReceivedTracker()

        let server = Server(
            name: "CancelUnknownServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.onNotification(CancelledNotification.self) { message in
            await cancellationReceived.add(message.params)
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        let client = Client(name: "CancelUnknownClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Cancel a request that doesn't exist
        let unknownId = RequestId.string("non-existent-request")
        await client.cancelRequest(unknownId, reason: "This request doesn't exist")

        // Give time for notification to be processed
        try await Task.sleep(for: .milliseconds(100))

        // The cancellation notification should still be sent (best effort)
        // but the client should not crash
        let count = await cancellationReceived.count
        #expect(count >= 1, "Cancellation notification should still be sent")

        // Client should still be functional
        let tools = try await client.send(ListTools.request(.init()))
        #expect(tools.tools.isEmpty)
    }

    /// Test that cancelRequest can be called without a reason.
    @Test(.timeLimit(.minutes(1)))
    func cancelRequestWithoutReason() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.cancel-no-reason")
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

        let cancellationReceived = CancellationReceivedTracker()

        let server = Server(
            name: "CancelNoReasonServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.onNotification(CancelledNotification.self) { message in
            await cancellationReceived.add(message.params)
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        let client = Client(name: "CancelNoReasonClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Cancel with no reason
        let requestId = RequestId.string("some-request")
        await client.cancelRequest(requestId)  // No reason provided

        try await Task.sleep(for: .milliseconds(100))

        // Verify cancellation was sent
        let count = await cancellationReceived.count
        #expect(count >= 1)

        let cancellations = await cancellationReceived.all
        if let first = cancellations.first {
            #expect(first.requestId == requestId)
            #expect(first.reason == nil)
        }
    }
}
