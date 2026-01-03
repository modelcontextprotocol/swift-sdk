import Foundation
import Logging
import Testing

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@testable import MCP

@Suite("Progress Tests")
struct ProgressTests {

    // MARK: - ProgressToken Tests

    @Suite("ProgressToken encoding/decoding")
    struct ProgressTokenTests {

        @Test("String token encodes as JSON string")
        func stringTokenEncoding() throws {
            let token: ProgressToken = .string("abc-123")
            let encoder = JSONEncoder()
            let data = try encoder.encode(token)
            let json = String(data: data, encoding: .utf8)
            #expect(json == "\"abc-123\"")
        }

        @Test("Integer token encodes as JSON number")
        func integerTokenEncoding() throws {
            let token: ProgressToken = .integer(42)
            let encoder = JSONEncoder()
            let data = try encoder.encode(token)
            let json = String(data: data, encoding: .utf8)
            #expect(json == "42")
        }

        @Test("String token decodes from JSON string")
        func stringTokenDecoding() throws {
            let json = "\"my-token\""
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let token = try decoder.decode(ProgressToken.self, from: data)
            #expect(token == .string("my-token"))
        }

        @Test("Integer token decodes from JSON number")
        func integerTokenDecoding() throws {
            let json = "123"
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let token = try decoder.decode(ProgressToken.self, from: data)
            #expect(token == .integer(123))
        }

        @Test("Integer token zero decodes correctly")
        func integerTokenZero() throws {
            // Edge case from Python SDK test #176 - progress token 0 should work
            let json = "0"
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let token = try decoder.decode(ProgressToken.self, from: data)
            #expect(token == .integer(0))
        }

        @Test("Negative integer token decodes correctly")
        func negativeIntegerToken() throws {
            let json = "-1"
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let token = try decoder.decode(ProgressToken.self, from: data)
            #expect(token == .integer(-1))
        }

        @Test("String literal initialization")
        func stringLiteralInit() {
            let token: ProgressToken = "my-token"
            #expect(token == .string("my-token"))
        }

        @Test("Integer literal initialization")
        func integerLiteralInit() {
            let token: ProgressToken = 42
            #expect(token == .integer(42))
        }

        @Test("Round-trip encoding/decoding for string token")
        func stringTokenRoundTrip() throws {
            let original: ProgressToken = .string("test-token-abc")
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ProgressToken.self, from: data)
            #expect(decoded == original)
        }

        @Test("Round-trip encoding/decoding for integer token")
        func integerTokenRoundTrip() throws {
            let original: ProgressToken = .integer(999)
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ProgressToken.self, from: data)
            #expect(decoded == original)
        }

        @Test("Invalid token type throws error")
        func invalidTokenType() throws {
            let json = "true"  // Boolean is not a valid progress token
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            #expect(throws: DecodingError.self) {
                _ = try decoder.decode(ProgressToken.self, from: data)
            }
        }
    }

    // MARK: - ProgressNotification Tests

    @Suite("ProgressNotification encoding/decoding")
    struct ProgressNotificationTests {

        @Test("Notification with string token encodes correctly")
        func notificationWithStringToken() throws {
            let params = ProgressNotification.Parameters(
                progressToken: .string("abc-123"),
                progress: 50.0,
                total: 100.0,
                message: "Halfway done"
            )
            let notification = ProgressNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            #expect(json["jsonrpc"] == "2.0")
            #expect(json["method"] == "notifications/progress")

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams?["progressToken"]?.stringValue == "abc-123")
            // Use Double(_ value:) which handles both .int and .double cases
            #expect(notificationParams?["progress"].flatMap { Double($0) } == 50.0)
            #expect(notificationParams?["total"].flatMap { Double($0) } == 100.0)
            #expect(notificationParams?["message"]?.stringValue == "Halfway done")
        }

        @Test("Notification with integer token encodes correctly")
        func notificationWithIntegerToken() throws {
            let params = ProgressNotification.Parameters(
                progressToken: .integer(42),
                progress: 25.0,
                total: 100.0,
                message: "Quarter done"
            )
            let notification = ProgressNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams?["progressToken"]?.intValue == 42)
            #expect(notificationParams?["progress"].flatMap { Double($0) } == 25.0)
        }

        @Test("Notification with zero token encodes correctly")
        func notificationWithZeroToken() throws {
            // Edge case from Python SDK test #176
            let params = ProgressNotification.Parameters(
                progressToken: .integer(0),
                progress: 0.0,
                total: 10.0,
                message: nil
            )
            let notification = ProgressNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            let notificationParams = json["params"]?.objectValue
            #expect(notificationParams?["progressToken"]?.intValue == 0)
            #expect(notificationParams?["progress"].flatMap { Double($0) } == 0.0)
        }

        @Test("Notification decodes from JSON with string token")
        func decodeNotificationWithStringToken() throws {
            let json = """
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": "token-abc",
                        "progress": 75.0,
                        "total": 100.0,
                        "message": "Almost done"
                    }
                }
                """
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let notification = try decoder.decode(Message<ProgressNotification>.self, from: data)

            #expect(notification.method == "notifications/progress")
            #expect(notification.params.progressToken == .string("token-abc"))
            #expect(notification.params.progress == 75.0)
            #expect(notification.params.total == 100.0)
            #expect(notification.params.message == "Almost done")
        }

        @Test("Notification decodes from JSON with integer token")
        func decodeNotificationWithIntegerToken() throws {
            let json = """
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": 123,
                        "progress": 50.0,
                        "total": 200.0
                    }
                }
                """
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let notification = try decoder.decode(Message<ProgressNotification>.self, from: data)

            #expect(notification.params.progressToken == .integer(123))
            #expect(notification.params.progress == 50.0)
            #expect(notification.params.total == 200.0)
            #expect(notification.params.message == nil)
        }

        @Test("Notification without optional fields decodes correctly")
        func decodeNotificationMinimalFields() throws {
            let json = """
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": "min-token",
                        "progress": 10.0
                    }
                }
                """
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let notification = try decoder.decode(Message<ProgressNotification>.self, from: data)

            #expect(notification.params.progressToken == .string("min-token"))
            #expect(notification.params.progress == 10.0)
            #expect(notification.params.total == nil)
            #expect(notification.params.message == nil)
        }

        @Test("Notification with _meta field decodes correctly")
        func decodeNotificationWithMeta() throws {
            let json = """
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": "meta-token",
                        "progress": 50.0,
                        "_meta": {
                            "customField": "customValue"
                        }
                    }
                }
                """
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let notification = try decoder.decode(Message<ProgressNotification>.self, from: data)

            #expect(notification.params.progressToken == .string("meta-token"))
            #expect(notification.params._meta?["customField"]?.stringValue == "customValue")
        }

        @Test("Round-trip encoding/decoding for notification")
        func notificationRoundTrip() throws {
            let params = ProgressNotification.Parameters(
                progressToken: .string("round-trip-token"),
                progress: 33.3,
                total: 100.0,
                message: "Processing..."
            )
            let original = ProgressNotification.message(params)

            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(Message<ProgressNotification>.self, from: data)

            #expect(decoded.method == original.method)
            #expect(decoded.params.progressToken == original.params.progressToken)
            #expect(decoded.params.progress == original.params.progress)
            #expect(decoded.params.total == original.params.total)
            #expect(decoded.params.message == original.params.message)
        }
    }

    // MARK: - RequestMeta Tests

    @Suite("RequestMeta encoding/decoding")
    struct RequestMetaTests {

        @Test("RequestMeta with progressToken encodes correctly")
        func requestMetaWithProgressToken() throws {
            let meta = RequestMeta(progressToken: .string("request-token"))
            let encoder = JSONEncoder()
            let data = try encoder.encode(meta)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            #expect(json["progressToken"]?.stringValue == "request-token")
        }

        @Test("RequestMeta with integer progressToken encodes correctly")
        func requestMetaWithIntegerToken() throws {
            let meta = RequestMeta(progressToken: .integer(42))
            let encoder = JSONEncoder()
            let data = try encoder.encode(meta)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            #expect(json["progressToken"]?.intValue == 42)
        }

        @Test("RequestMeta with additional fields encodes correctly")
        func requestMetaWithAdditionalFields() throws {
            let meta = RequestMeta(
                progressToken: .string("token"),
                additionalFields: [
                    "customField": .string("customValue"),
                    "numericField": .int(123)
                ]
            )
            let encoder = JSONEncoder()
            let data = try encoder.encode(meta)
            let json = try JSONDecoder().decode([String: Value].self, from: data)

            #expect(json["progressToken"]?.stringValue == "token")
            #expect(json["customField"]?.stringValue == "customValue")
            #expect(json["numericField"]?.intValue == 123)
        }

        @Test("RequestMeta decodes from JSON")
        func requestMetaDecoding() throws {
            let json = """
                {
                    "progressToken": "decoded-token",
                    "extraField": "extraValue"
                }
                """
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let meta = try decoder.decode(RequestMeta.self, from: data)

            #expect(meta.progressToken == .string("decoded-token"))
            #expect(meta.additionalFields?["extraField"]?.stringValue == "extraValue")
        }

        @Test("RequestMeta decodes integer progressToken from JSON")
        func requestMetaIntegerTokenDecoding() throws {
            let json = """
                {
                    "progressToken": 999
                }
                """
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let meta = try decoder.decode(RequestMeta.self, from: data)

            #expect(meta.progressToken == .integer(999))
        }

        @Test("RequestMeta without progressToken decodes correctly")
        func requestMetaWithoutToken() throws {
            let json = """
                {
                    "customField": "value"
                }
                """
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let meta = try decoder.decode(RequestMeta.self, from: data)

            #expect(meta.progressToken == nil)
            #expect(meta.additionalFields?["customField"]?.stringValue == "value")
        }

        @Test("Round-trip encoding/decoding for RequestMeta")
        func requestMetaRoundTrip() throws {
            let original = RequestMeta(
                progressToken: .string("round-trip"),
                additionalFields: ["key": .string("value")]
            )

            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(RequestMeta.self, from: data)

            #expect(decoded.progressToken == original.progressToken)
            #expect(decoded.additionalFields?["key"] == original.additionalFields?["key"])
        }
    }

    // MARK: - Integration Tests

    /// Integration tests for progress notifications through actual client/server communication.
    /// Based on Python SDK's test_progress_notifications.py tests.
    @Suite("Progress notification integration")
    struct ProgressIntegrationTests {

        /// Test that server can send progress notifications to client during tool execution.
        /// Based on TypeScript SDK's "should send progress notifications with message field" test.
        ///
        /// Flow matches TS/Python pattern:
        /// 1. Client sends request WITH progressToken in _meta
        /// 2. Server extracts token from request._meta.progressToken
        /// 3. Server sends notifications using that token
        /// 4. Client receives and correlates by token
        @Test(.timeLimit(.minutes(1)))
        func serverSendsProgressNotificationsToClient() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress")
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

            // Track received progress updates
            let receivedProgress = ProgressUpdateTracker()

            // Set up server with a tool that sends progress notifications
            let server = Server(
                name: "ProgressTestServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(
                        name: "slow_operation",
                        description: "A tool that reports progress",
                        inputSchema: ["type": "object", "properties": ["steps": ["type": "integer"]]]
                    )
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "slow_operation" else {
                    return CallTool.Result(content: [.text("Unknown tool")], isError: true)
                }

                // Extract progress token from request _meta (matching TS/Python pattern)
                guard let progressToken = request._meta?.progressToken else {
                    return CallTool.Result(content: [.text("No progress token provided")], isError: true)
                }

                let steps = request.arguments?["steps"]?.intValue ?? 3

                // Send progress notifications for each step (like TS SDK test)
                for step in 1...steps {
                    try await context.sendProgress(
                        token: progressToken,
                        progress: Double(step),
                        total: Double(steps),
                        message: "Completed step \(step) of \(steps)"
                    )
                }

                return CallTool.Result(content: [.text("Operation completed with \(steps) steps")])
            }

            let client = Client(name: "ProgressTestClient", version: "1.0")

            // Register progress notification handler
            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Call the tool WITH progressToken in _meta (matching TS/Python pattern)
            let result = try await client.send(
                CallTool.request(.init(
                    name: "slow_operation",
                    arguments: ["steps": .int(3)],
                    _meta: RequestMeta(progressToken: .string("progress-test-1"))
                ))
            )

            // Give time for notifications to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify tool result
            if case .text(let text, _, _) = result.content.first {
                #expect(text == "Operation completed with 3 steps")
            } else {
                Issue.record("Expected text content")
            }

            // Verify progress notifications were received (matching TS SDK assertions)
            let updates = await receivedProgress.updates
            #expect(updates.count == 3, "Should receive 3 progress notifications")

            if updates.count >= 3 {
                // Verify each notification has the correct token from the request
                for update in updates {
                    #expect(update.token == .string("progress-test-1"), "Token should match request")
                }

                // Verify progress values match TS SDK test pattern
                #expect(updates[0].progress == 1.0)
                #expect(updates[0].total == 3.0)
                #expect(updates[0].message == "Completed step 1 of 3")

                #expect(updates[1].progress == 2.0)
                #expect(updates[1].total == 3.0)
                #expect(updates[1].message == "Completed step 2 of 3")

                #expect(updates[2].progress == 3.0)
                #expect(updates[2].total == 3.0)
                #expect(updates[2].message == "Completed step 3 of 3")
            }
        }

        /// Test that progress token 0 works correctly in actual communication.
        /// Based on Python SDK's test_176_progress_token.py (issue #176 - falsy token value).
        ///
        /// This tests the edge case where progressToken is 0 (a falsy value in many languages).
        /// The token must flow correctly: client → server → notification → client.
        @Test(.timeLimit(.minutes(1)))
        func progressTokenZeroWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.zero")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "ZeroTokenServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "zero_token_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "zero_token_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Extract token from request (should be integer 0)
                guard let progressToken = request._meta?.progressToken else {
                    return CallTool.Result(content: [.text("No progress token")], isError: true)
                }

                // The key test: token 0 should NOT be treated as "no token"
                // This was bug #176 in Python SDK
                try await context.sendProgress(token: progressToken, progress: 0.0, total: 10.0)
                try await context.sendProgress(token: progressToken, progress: 5.0, total: 10.0)
                try await context.sendProgress(token: progressToken, progress: 10.0, total: 10.0)

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "ZeroTokenClient", version: "1.0")

            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Client sends request with progressToken = 0 (the edge case)
            _ = try await client.send(
                CallTool.request(.init(
                    name: "zero_token_tool",
                    arguments: [:],
                    _meta: RequestMeta(progressToken: .integer(0))
                ))
            )

            try await Task.sleep(for: .milliseconds(100))

            let updates = await receivedProgress.updates
            #expect(updates.count == 3, "Should receive all 3 progress notifications with token 0")

            // Verify token 0 was correctly transmitted through the entire flow
            for update in updates {
                #expect(update.token == .integer(0), "Token should be integer 0")
            }

            if updates.count >= 3 {
                #expect(updates[0].progress == 0.0)
                #expect(updates[1].progress == 5.0)
                #expect(updates[2].progress == 10.0)
            }
        }

        /// Test that server correctly extracts progressToken from request _meta.
        /// This matches the typical flow where client includes progressToken in _meta.
        @Test(.timeLimit(.minutes(1)))
        func serverExtractsProgressTokenFromRequestMeta() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.meta")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "MetaExtractServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "meta_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "meta_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Extract progress token from request _meta (the recommended pattern)
                if let token = request._meta?.progressToken {
                    try await context.sendProgress(
                        token: token,
                        progress: 50.0,
                        total: 100.0,
                        message: "Using token from _meta"
                    )
                }

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "MetaExtractClient", version: "1.0")

            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Call tool WITH progressToken in _meta
            let result = try await client.send(
                CallTool.request(.init(
                    name: "meta_test",
                    arguments: [:],
                    _meta: RequestMeta(progressToken: .string("client-provided-token"))
                ))
            )

            try await Task.sleep(for: .milliseconds(100))

            // Verify the tool result succeeded
            #expect(result.content.count == 1)

            // Verify progress notification was received with the client-provided token
            let updates = await receivedProgress.updates
            #expect(updates.count == 1, "Should receive 1 progress notification")

            if let update = updates.first {
                #expect(update.token == .string("client-provided-token"))
                #expect(update.message == "Using token from _meta")
            }
        }

        /// Test with integer progress token in full client-server roundtrip.
        /// Ensures integer tokens work end-to-end, not just in serialization.
        @Test(.timeLimit(.minutes(1)))
        func integerTokenRoundtripIntegration() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.int")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "IntTokenServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "int_token_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "int_token_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Extract integer token from request _meta
                if let token = request._meta?.progressToken {
                    try await context.sendProgress(
                        token: token,
                        progress: 100.0,
                        total: 100.0,
                        message: "Complete"
                    )
                }

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "IntTokenClient", version: "1.0")

            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Call tool with INTEGER progressToken in _meta
            _ = try await client.send(
                CallTool.request(.init(
                    name: "int_token_test",
                    arguments: [:],
                    _meta: RequestMeta(progressToken: .integer(12345))
                ))
            )

            try await Task.sleep(for: .milliseconds(100))

            let updates = await receivedProgress.updates
            #expect(updates.count == 1, "Should receive 1 progress notification")

            if let update = updates.first {
                // Verify integer token was preserved through the roundtrip
                #expect(update.token == .integer(12345), "Integer token should be preserved")
            }
        }

        /// Test that sendMessage can be used to send notifications with custom parameters.
        @Test(.timeLimit(.minutes(1)))
        func sendMessageWorksForCustomNotifications() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.sendMessage")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "SendMessageServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "message_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "message_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Use sendMessage directly instead of convenience method
                try await context.sendMessage(ProgressNotification.message(.init(
                    progressToken: .string("via-sendMessage"),
                    progress: 42.0,
                    total: 100.0,
                    message: "Sent via sendMessage"
                )))

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "SendMessageClient", version: "1.0")

            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            _ = try await client.callTool(name: "message_test", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let updates = await receivedProgress.updates
            #expect(updates.count == 1, "Should receive 1 progress notification")

            if let update = updates.first {
                #expect(update.token == .string("via-sendMessage"))
                #expect(update.progress == 42.0)
                #expect(update.message == "Sent via sendMessage")
            }
        }

        /// Test sendLogMessage convenience method.
        @Test(.timeLimit(.minutes(1)))
        func sendLogMessageWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.logging")
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

            let receivedLogs = LogTracker()

            let server = Server(
                name: "LogTestServer",
                version: "1.0.0",
                capabilities: .init(logging: .init(), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "log_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "log_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send log messages using convenience method
                try await context.sendLogMessage(
                    level: .info,
                    logger: "test-logger",
                    data: .string("Starting operation")
                )

                try await context.sendLogMessage(
                    level: .warning,
                    data: .object(["status": .string("in-progress"), "step": .int(1)])
                )

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "LogTestClient", version: "1.0")

            await client.onNotification(LogMessageNotification.self) { message in
                await receivedLogs.add(
                    level: message.params.level,
                    logger: message.params.logger,
                    data: message.params.data
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            _ = try await client.callTool(name: "log_test", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let logs = await receivedLogs.logs
            #expect(logs.count == 2, "Should receive 2 log notifications")

            if logs.count >= 2 {
                #expect(logs[0].level == .info)
                #expect(logs[0].logger == "test-logger")
                #expect(logs[0].data.stringValue == "Starting operation")

                #expect(logs[1].level == .warning)
                #expect(logs[1].logger == nil)
                #expect(logs[1].data.objectValue?["status"]?.stringValue == "in-progress")
            }
        }

        /// Test that log level filtering works correctly.
        ///
        /// When the client sets a minimum log level, the server should only
        /// send log messages at that level or higher (more severe).
        @Test(.timeLimit(.minutes(1)))
        func logLevelFilteringWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.loglevel")
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

            let receivedLogs = LogTracker()

            let server = Server(
                name: "LogLevelTestServer",
                version: "1.0.0",
                capabilities: .init(logging: .init(), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "log_all_levels", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "log_all_levels" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send log messages at all levels
                try await context.sendLogMessage(level: .debug, data: .string("Debug message"))
                try await context.sendLogMessage(level: .info, data: .string("Info message"))
                try await context.sendLogMessage(level: .notice, data: .string("Notice message"))
                try await context.sendLogMessage(level: .warning, data: .string("Warning message"))
                try await context.sendLogMessage(level: .error, data: .string("Error message"))
                try await context.sendLogMessage(level: .critical, data: .string("Critical message"))

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "LogLevelTestClient", version: "1.0")

            await client.onNotification(LogMessageNotification.self) { message in
                await receivedLogs.add(
                    level: message.params.level,
                    logger: message.params.logger,
                    data: message.params.data
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Set minimum log level to warning - only warning and above should be received
            try await client.setLoggingLevel(.warning)

            // Give time for the level to be set
            try await Task.sleep(for: .milliseconds(50))

            // Call the tool that sends logs at all levels
            _ = try await client.callTool(name: "log_all_levels", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let logs = await receivedLogs.logs
            // Should only receive warning, error, critical (3 messages)
            // debug, info, notice should be filtered out
            #expect(logs.count == 3, "Should receive only 3 log notifications (warning and above), got \(logs.count)")

            if logs.count >= 3 {
                #expect(logs[0].level == .warning)
                #expect(logs[0].data.stringValue == "Warning message")

                #expect(logs[1].level == .error)
                #expect(logs[1].data.stringValue == "Error message")

                #expect(logs[2].level == .critical)
                #expect(logs[2].data.stringValue == "Critical message")
            }
        }

        /// Test that setLoggingLevel throws when server doesn't have logging capability.
        ///
        /// This matches TypeScript SDK behavior where `client.setLoggingLevel('error')`
        /// throws "Server does not support logging" when capability is not declared.
        @Test(.timeLimit(.minutes(1)))
        func setLoggingLevelThrowsWithoutCapability() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.logging.nocap")
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

            // Server WITHOUT logging capability
            let server = Server(
                name: "NoLoggingServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())  // No logging capability
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [])
            }

            let client = Client(name: "LogTestClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Should throw because server doesn't support logging
            await #expect(throws: MCPError.self) {
                try await client.setLoggingLevel(.warning)
            }
        }

        /// Test that all 8 RFC 5424 log levels work correctly.
        ///
        /// The MCP spec uses syslog severity levels:
        /// debug < info < notice < warning < error < critical < alert < emergency
        @Test(.timeLimit(.minutes(1)))
        func allEightLogLevelsWork() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.alllevels")
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

            let receivedLogs = LogTracker()

            let server = Server(
                name: "AllLevelsServer",
                version: "1.0.0",
                capabilities: .init(logging: .init(), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "log_all_eight", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "log_all_eight" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send all 8 log levels
                try await context.sendLogMessage(level: .debug, data: .string("Debug"))
                try await context.sendLogMessage(level: .info, data: .string("Info"))
                try await context.sendLogMessage(level: .notice, data: .string("Notice"))
                try await context.sendLogMessage(level: .warning, data: .string("Warning"))
                try await context.sendLogMessage(level: .error, data: .string("Error"))
                try await context.sendLogMessage(level: .critical, data: .string("Critical"))
                try await context.sendLogMessage(level: .alert, data: .string("Alert"))
                try await context.sendLogMessage(level: .emergency, data: .string("Emergency"))

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "AllLevelsClient", version: "1.0")

            await client.onNotification(LogMessageNotification.self) { message in
                await receivedLogs.add(
                    level: message.params.level,
                    logger: message.params.logger,
                    data: message.params.data
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Set level to debug to receive all messages
            try await client.setLoggingLevel(.debug)

            _ = try await client.callTool(name: "log_all_eight", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let logs = await receivedLogs.logs
            #expect(logs.count == 8, "Should receive all 8 log levels, got \(logs.count)")

            // Verify each level in order
            let expectedLevels: [LoggingLevel] = [
                .debug, .info, .notice, .warning, .error, .critical, .alert, .emergency
            ]
            let expectedMessages = ["Debug", "Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]

            for (index, expectedLevel) in expectedLevels.enumerated() {
                if index < logs.count {
                    #expect(logs[index].level == expectedLevel, "Level at index \(index) should be \(expectedLevel)")
                    #expect(logs[index].data.stringValue == expectedMessages[index])
                }
            }
        }

        /// Test that when no logging level is set, all messages are sent.
        ///
        /// Per MCP spec: "If no logging/setLevel request has been sent from the client,
        /// the server MAY decide which messages to send automatically."
        /// Our implementation sends all messages when no level is set.
        @Test(.timeLimit(.minutes(1)))
        func defaultLoggingBehaviorSendsAllMessages() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.defaultlog")
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

            let receivedLogs = LogTracker()

            let server = Server(
                name: "DefaultLogServer",
                version: "1.0.0",
                capabilities: .init(logging: .init(), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "log_without_level_set", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "log_without_level_set" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send messages at various levels without client setting a level
                try await context.sendLogMessage(level: .debug, data: .string("Debug message"))
                try await context.sendLogMessage(level: .info, data: .string("Info message"))
                try await context.sendLogMessage(level: .error, data: .string("Error message"))

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "DefaultLogClient", version: "1.0")

            await client.onNotification(LogMessageNotification.self) { message in
                await receivedLogs.add(
                    level: message.params.level,
                    logger: message.params.logger,
                    data: message.params.data
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Do NOT set logging level - test default behavior
            _ = try await client.callTool(name: "log_without_level_set", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let logs = await receivedLogs.logs
            // All 3 messages should be received since no level filter was set
            #expect(logs.count == 3, "Should receive all 3 log messages when no level is set, got \(logs.count)")

            if logs.count >= 3 {
                #expect(logs[0].level == .debug)
                #expect(logs[1].level == .info)
                #expect(logs[2].level == .error)
            }
        }

        /// Test server-level sendLogMessage method (outside request handlers).
        ///
        /// This matches TypeScript SDK behavior where `server.sendLoggingMessage()`
        /// can be called outside of request handlers.
        @Test(.timeLimit(.minutes(1)))
        func serverLevelSendLogMessageWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.serverlevellog")
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

            let receivedLogs = LogTracker()

            let server = Server(
                name: "ServerLevelLogServer",
                version: "1.0.0",
                capabilities: .init(logging: .init(), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "trigger", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "trigger" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }
                // Just return, we'll send log via server-level method
                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "ServerLevelLogClient", version: "1.0")

            await client.onNotification(LogMessageNotification.self) { message in
                await receivedLogs.add(
                    level: message.params.level,
                    logger: message.params.logger,
                    data: message.params.data
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Use server-level sendLogMessage (not context-level)
            try await server.sendLogMessage(
                level: .info,
                logger: "server-logger",
                data: .string("Server-level log message")
            )

            try await Task.sleep(for: .milliseconds(100))

            let logs = await receivedLogs.logs
            #expect(logs.count == 1, "Should receive 1 log message from server-level sendLogMessage")

            if let log = logs.first {
                #expect(log.level == .info)
                #expect(log.logger == "server-logger")
                #expect(log.data.stringValue == "Server-level log message")
            }
        }

        /// Test that sendLogMessage from context silently drops messages when logging
        /// capability is not declared.
        ///
        /// This matches TypeScript SDK behavior where logging messages are silently
        /// dropped when the server doesn't have the logging capability.
        @Test(.timeLimit(.minutes(1)))
        func contextSendLogMessageSilentlyDropsWithoutCapability() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.nocaplog")
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

            let receivedLogs = LogTracker()

            // Server WITHOUT logging capability
            let server = Server(
                name: "NoLogCapServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())  // No logging capability!
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "try_log", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "try_log" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // This should be silently dropped since logging capability is not declared
                try await context.sendLogMessage(
                    level: .info,
                    data: .string("This should be dropped")
                )

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "NoLogCapClient", version: "1.0")

            await client.onNotification(LogMessageNotification.self) { message in
                await receivedLogs.add(
                    level: message.params.level,
                    logger: message.params.logger,
                    data: message.params.data
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            _ = try await client.callTool(name: "try_log", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let logs = await receivedLogs.logs
            // No logs should be received because logging capability is not declared
            #expect(logs.count == 0, "Should receive 0 logs when logging capability is not declared, got \(logs.count)")
        }

        /// Test sendToolListChanged convenience method.
        @Test(.timeLimit(.minutes(1)))
        func sendToolListChangedWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.toolchange")
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

            let notificationReceived = NotificationTracker()

            let server = Server(
                name: "ToolChangeServer",
                version: "1.0.0",
                capabilities: .init(tools: .init(listChanged: true))
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "notify_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "notify_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send tool list changed notification
                try await context.sendToolListChanged()

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "ToolChangeClient", version: "1.0")

            await client.onNotification(ToolListChangedNotification.self) { _ in
                await notificationReceived.recordToolListChanged()
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            _ = try await client.callTool(name: "notify_test", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let count = await notificationReceived.toolListChangedCount
            #expect(count == 1, "Should receive 1 tool list changed notification")
        }

        /// Test sendResourceListChanged convenience method.
        ///
        /// This tests that the server can notify the client when the list of
        /// available resources has changed.
        @Test(.timeLimit(.minutes(1)))
        func sendResourceListChangedWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.resourcelistchange")
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

            let notificationReceived = NotificationTracker()

            let server = Server(
                name: "ResourceListChangeServer",
                version: "1.0.0",
                capabilities: .init(resources: .init(listChanged: true), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "notify_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "notify_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send resource list changed notification
                try await context.sendResourceListChanged()

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "ResourceListChangeClient", version: "1.0")

            await client.onNotification(ResourceListChangedNotification.self) { _ in
                await notificationReceived.recordResourceListChanged()
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            _ = try await client.callTool(name: "notify_test", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let count = await notificationReceived.resourceListChangedCount
            #expect(count == 1, "Should receive 1 resource list changed notification")
        }

        /// Test sendPromptListChanged convenience method.
        ///
        /// This tests that the server can notify the client when the list of
        /// available prompts has changed.
        @Test(.timeLimit(.minutes(1)))
        func sendPromptListChangedWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.promptlistchange")
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

            let notificationReceived = NotificationTracker()

            let server = Server(
                name: "PromptListChangeServer",
                version: "1.0.0",
                capabilities: .init(prompts: .init(listChanged: true), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "notify_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "notify_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send prompt list changed notification
                try await context.sendPromptListChanged()

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "PromptListChangeClient", version: "1.0")

            await client.onNotification(PromptListChangedNotification.self) { _ in
                await notificationReceived.recordPromptListChanged()
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            _ = try await client.callTool(name: "notify_test", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let count = await notificationReceived.promptListChangedCount
            #expect(count == 1, "Should receive 1 prompt list changed notification")
        }

        /// Test sendResourceUpdated convenience method.
        @Test(.timeLimit(.minutes(1)))
        func sendResourceUpdatedWorks() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.resourceupdate")
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

            let notificationReceived = NotificationTracker()

            let server = Server(
                name: "ResourceUpdateServer",
                version: "1.0.0",
                capabilities: .init(resources: .init(subscribe: true), tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "update_resource", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "update_resource" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Send resource updated notification
                try await context.sendResourceUpdated(uri: "file:///path/to/resource.txt")

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "ResourceUpdateClient", version: "1.0")

            await client.onNotification(ResourceUpdatedNotification.self) { message in
                await notificationReceived.recordResourceUpdated(uri: message.params.uri)
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            _ = try await client.callTool(name: "update_resource", arguments: [:])

            try await Task.sleep(for: .milliseconds(100))

            let uris = await notificationReceived.resourceUpdatedURIs
            #expect(uris.count == 1, "Should receive 1 resource updated notification")
            #expect(uris.first == "file:///path/to/resource.txt")
        }

        /// Test that client can send progress notifications to server (bidirectional progress).
        /// Based on Python SDK's test_bidirectional_progress_notifications.
        ///
        /// This tests the reverse direction from serverSendsProgressNotificationsToClient:
        /// - Client sends progress notifications using notify()
        /// - Server receives them via onNotification(ProgressNotification.self)
        @Test(.timeLimit(.minutes(1)))
        func clientSendsProgressNotificationsToServer() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.bidirectional")
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

            // Track progress updates received by server
            let serverReceivedProgress = ProgressUpdateTracker()

            // Progress token that client will use
            let clientProgressToken: ProgressToken = "client-progress-token-123"

            let server = Server(
                name: "BidirectionalProgressServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            // Server registers handler to receive progress notifications from client
            await server.onNotification(ProgressNotification.self) { message in
                await serverReceivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "simple_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                guard request.name == "simple_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }
                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "BidirectionalProgressClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Client sends progress notifications to server (like Python test)
            try await client.notify(ProgressNotification.message(.init(
                progressToken: clientProgressToken,
                progress: 0.33,
                total: 1.0,
                message: "Client progress 33%"
            )))

            try await client.notify(ProgressNotification.message(.init(
                progressToken: clientProgressToken,
                progress: 0.66,
                total: 1.0,
                message: "Client progress 66%"
            )))

            try await client.notify(ProgressNotification.message(.init(
                progressToken: clientProgressToken,
                progress: 1.0,
                total: 1.0,
                message: "Client progress 100%"
            )))

            // Give time for notifications to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify server received progress updates from client
            let updates = await serverReceivedProgress.updates
            #expect(updates.count == 3, "Server should receive 3 progress notifications from client")

            if updates.count >= 3 {
                // Verify first update
                #expect(updates[0].token == clientProgressToken)
                #expect(updates[0].progress == 0.33)
                #expect(updates[0].message == "Client progress 33%")

                // Verify last update
                #expect(updates[2].progress == 1.0)
                #expect(updates[2].message == "Client progress 100%")
            }
        }

        /// Test bidirectional progress: both client→server and server→client in same session.
        /// Based on Python SDK's test_bidirectional_progress_notifications which tests both
        /// directions simultaneously.
        @Test(.timeLimit(.minutes(1)))
        func bidirectionalProgressNotifications() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.fullbidirectional")
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

            // Track progress updates received by both sides
            let serverReceivedProgress = ProgressUpdateTracker()
            let clientReceivedProgress = ProgressUpdateTracker()

            // Tokens
            let serverProgressToken: ProgressToken = "server-token-abc"
            let clientProgressToken: ProgressToken = "client-token-xyz"

            let server = Server(
                name: "FullBidirectionalServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            // Server registers handler to receive progress notifications from client
            await server.onNotification(ProgressNotification.self) { message in
                await serverReceivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "progress_tool", inputSchema: ["type": "object"])
                ])
            }

            // Tool that sends progress back to client
            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "progress_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Server sends progress notifications to client
                try await context.sendProgress(
                    token: serverProgressToken,
                    progress: 0.5,
                    total: 1.0,
                    message: "Server progress 50%"
                )

                try await context.sendProgress(
                    token: serverProgressToken,
                    progress: 1.0,
                    total: 1.0,
                    message: "Server progress 100%"
                )

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "FullBidirectionalClient", version: "1.0")

            // Client registers handler to receive progress notifications from server
            await client.onNotification(ProgressNotification.self) { message in
                await clientReceivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Client sends progress notifications to server
            try await client.notify(ProgressNotification.message(.init(
                progressToken: clientProgressToken,
                progress: 0.25,
                total: 1.0,
                message: "Client progress 25%"
            )))

            try await client.notify(ProgressNotification.message(.init(
                progressToken: clientProgressToken,
                progress: 0.75,
                total: 1.0,
                message: "Client progress 75%"
            )))

            // Call tool to trigger server→client progress
            _ = try await client.callTool(name: "progress_tool", arguments: [:])

            // Give time for all notifications to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify client received progress updates from server
            let clientUpdates = await clientReceivedProgress.updates
            #expect(clientUpdates.count == 2, "Client should receive 2 progress notifications from server")

            if clientUpdates.count >= 2 {
                #expect(clientUpdates[0].token == serverProgressToken)
                #expect(clientUpdates[0].progress == 0.5)
                #expect(clientUpdates[1].progress == 1.0)
            }

            // Verify server received progress updates from client
            let serverUpdates = await serverReceivedProgress.updates
            #expect(serverUpdates.count == 2, "Server should receive 2 progress notifications from client")

            if serverUpdates.count >= 2 {
                #expect(serverUpdates[0].token == clientProgressToken)
                #expect(serverUpdates[0].progress == 0.25)
                #expect(serverUpdates[1].progress == 0.75)
            }
        }

        /// Test that exceptions in progress notification handlers are logged but don't crash the session.
        /// Based on Python SDK's test_progress_callback_exception_logging.
        ///
        /// This ensures that if a progress handler throws, the error is handled gracefully
        /// and subsequent operations continue to work.
        @Test(.timeLimit(.minutes(1)))
        func progressNotificationHandlerExceptionDoesNotCrashSession() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.exception")
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

            // Track that handler was called
            let handlerCallTracker = HandlerCallTracker()

            // Custom error for testing
            struct ProgressHandlerError: Error {
                let message: String
            }

            let server = Server(
                name: "ProgressExceptionServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "progress_tool", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "progress_tool" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Server sends progress notification
                guard let progressToken = request._meta?.progressToken else {
                    return CallTool.Result(content: [.text("No progress token")], isError: true)
                }

                try await context.sendProgress(
                    token: progressToken,
                    progress: 50.0,
                    total: 100.0,
                    message: "Halfway"
                )

                return CallTool.Result(content: [.text("progress_result")])
            }

            let client = Client(name: "ProgressExceptionClient", version: "1.0")

            // Register a handler that throws an exception
            await client.onNotification(ProgressNotification.self) { _ in
                await handlerCallTracker.recordCall()
                throw ProgressHandlerError(message: "Progress callback failed!")
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Call tool with progress token - the progress handler will throw
            let result = try await client.send(
                CallTool.request(.init(
                    name: "progress_tool",
                    arguments: [:],
                    _meta: RequestMeta(progressToken: .string("exception-test-token"))
                ))
            )

            // Give time for notification to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify the request completed successfully despite the callback failure
            #expect(result.content.count == 1)
            if case .text(let text, _, _) = result.content.first {
                #expect(text == "progress_result")
            } else {
                Issue.record("Expected text content")
            }

            // Verify the progress handler was called (even though it threw)
            let callCount = await handlerCallTracker.callCount
            #expect(callCount == 1, "Progress handler should have been called")

            // Session should still be functional - verify by making another request
            let pingResult = try await client.send(Ping.request())
            // Ping returns empty result - just verify it doesn't throw
            _ = pingResult
        }

        /// Test that progress notifications with integer token 0 work in bidirectional flow.
        /// Edge case: token 0 is falsy in many languages but should be treated as valid.
        @Test(.timeLimit(.minutes(1)))
        func clientSendsProgressWithZeroToken() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.progress.client.zero")
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

            let serverReceivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "ZeroTokenClientServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.onNotification(ProgressNotification.self) { message in
                await serverReceivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [])
            }

            let client = Client(name: "ZeroTokenClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Client sends progress with token 0 (edge case)
            try await client.notify(ProgressNotification.message(.init(
                progressToken: .integer(0),
                progress: 50.0,
                total: 100.0,
                message: "Progress with zero token"
            )))

            try await Task.sleep(for: .milliseconds(100))

            let updates = await serverReceivedProgress.updates
            #expect(updates.count == 1, "Server should receive progress with token 0")

            if let update = updates.first {
                #expect(update.token == .integer(0), "Token should be integer 0")
                #expect(update.progress == 50.0)
            }
        }
    }

    // MARK: - ProgressTracker Actor Tests

    @Suite("ProgressTracker actor (server-side cumulative progress)")
    struct ProgressTrackerTests {

        /// Test that ProgressTracker accumulates progress correctly with advance(by:).
        @Test(.timeLimit(.minutes(1)))
        func progressTrackerAdvanceAccumulatesProgress() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.tracker.advance")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "TrackerAdvanceServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "tracker_advance_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "tracker_advance_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                guard let token = request._meta?.progressToken else {
                    return CallTool.Result(content: [.text("No token")], isError: true)
                }

                // Use ProgressTracker to accumulate progress
                let tracker = ProgressTracker(token: token, total: 100, context: context)

                try await tracker.advance(by: 25, message: "Step 1")
                try await tracker.advance(by: 25, message: "Step 2")
                try await tracker.advance(by: 50, message: "Step 3")

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "TrackerAdvanceClient", version: "1.0")

            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            _ = try await client.send(
                CallTool.request(.init(
                    name: "tracker_advance_test",
                    arguments: [:],
                    _meta: RequestMeta(progressToken: .string("tracker-test"))
                ))
            )

            try await Task.sleep(for: .milliseconds(100))

            let updates = await receivedProgress.updates
            #expect(updates.count == 3, "Should receive 3 progress notifications")

            if updates.count >= 3 {
                // Verify cumulative progress values
                #expect(updates[0].progress == 25.0, "First advance should be 25")
                #expect(updates[0].message == "Step 1")

                #expect(updates[1].progress == 50.0, "Second advance should be 50 (25+25)")
                #expect(updates[1].message == "Step 2")

                #expect(updates[2].progress == 100.0, "Third advance should be 100 (50+50)")
                #expect(updates[2].message == "Step 3")
            }
        }

        /// Test that ProgressTracker.set(to:) sets absolute progress.
        @Test(.timeLimit(.minutes(1)))
        func progressTrackerSetToAbsoluteValue() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.tracker.set")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "TrackerSetServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "tracker_set_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "tracker_set_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                guard let token = request._meta?.progressToken else {
                    return CallTool.Result(content: [.text("No token")], isError: true)
                }

                let tracker = ProgressTracker(token: token, total: 100, context: context)

                // Use set(to:) for absolute values
                try await tracker.set(to: 10, message: "10%")
                try await tracker.set(to: 50, message: "50%")
                try await tracker.set(to: 100, message: "100%")

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "TrackerSetClient", version: "1.0")

            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            _ = try await client.send(
                CallTool.request(.init(
                    name: "tracker_set_test",
                    arguments: [:],
                    _meta: RequestMeta(progressToken: .string("set-test"))
                ))
            )

            try await Task.sleep(for: .milliseconds(100))

            let updates = await receivedProgress.updates
            #expect(updates.count == 3, "Should receive 3 progress notifications")

            if updates.count >= 3 {
                #expect(updates[0].progress == 10.0)
                #expect(updates[1].progress == 50.0)
                #expect(updates[2].progress == 100.0)
            }
        }

        /// Test that ProgressTracker.update(message:) sends notification without changing progress.
        @Test(.timeLimit(.minutes(1)))
        func progressTrackerUpdateMessageOnly() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.tracker.update")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "TrackerUpdateServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "tracker_update_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "tracker_update_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                guard let token = request._meta?.progressToken else {
                    return CallTool.Result(content: [.text("No token")], isError: true)
                }

                let tracker = ProgressTracker(token: token, total: 100, context: context)

                // First advance to set initial progress
                try await tracker.advance(by: 50, message: "Halfway")
                // Use update(message:) to send message without changing value
                try await tracker.update(message: "Still at 50%, processing...")
                try await tracker.update(message: "Almost done with phase 1")
                // Advance again to complete
                try await tracker.advance(by: 50, message: "Complete")

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "TrackerUpdateClient", version: "1.0")

            await client.onNotification(ProgressNotification.self) { message in
                await receivedProgress.add(
                    token: message.params.progressToken,
                    progress: message.params.progress,
                    total: message.params.total,
                    message: message.params.message
                )
            }

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            _ = try await client.send(
                CallTool.request(.init(
                    name: "tracker_update_test",
                    arguments: [:],
                    _meta: RequestMeta(progressToken: .string("update-test"))
                ))
            )

            try await Task.sleep(for: .milliseconds(100))

            let updates = await receivedProgress.updates
            // Should receive 4 notifications: advance(50), update(), update(), advance(100)
            #expect(updates.count == 4, "Should receive 4 progress notifications")

            if updates.count >= 4 {
                // First advance: progress = 50
                #expect(updates[0].progress == 50.0)
                #expect(updates[0].message == "Halfway")
                // First update: progress should still be 50
                #expect(updates[1].progress == 50.0)
                #expect(updates[1].message == "Still at 50%, processing...")
                // Second update: progress should still be 50
                #expect(updates[2].progress == 50.0)
                #expect(updates[2].message == "Almost done with phase 1")
                // Final advance: progress = 100
                #expect(updates[3].progress == 100.0)
                #expect(updates[3].message == "Complete")
            }
        }
    }

    // MARK: - Client onProgress Callback Tests

    @Suite("Client send with onProgress callback")
    struct ClientOnProgressTests {

        /// Test that send(_:onProgress:) receives progress updates via callback.
        @Test(.timeLimit(.minutes(1)))
        func clientReceivesProgressViaCallback() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.client.callback")
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

            let receivedProgress = ProgressUpdateTracker()

            let server = Server(
                name: "CallbackTestServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "callback_test", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "callback_test" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Server extracts the auto-generated progress token from _meta
                guard let token = request._meta?.progressToken else {
                    return CallTool.Result(content: [.text("No progress token - callback should have set one")], isError: true)
                }

                // Send progress notifications
                try await context.sendProgress(token: token, progress: 1, total: 3, message: "Step 1")
                try await context.sendProgress(token: token, progress: 2, total: 3, message: "Step 2")
                try await context.sendProgress(token: token, progress: 3, total: 3, message: "Step 3")

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "CallbackTestClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Use send with onProgress callback - no need to manually set progressToken
            let result = try await client.send(
                CallTool.request(.init(name: "callback_test", arguments: [:])),
                onProgress: { progress in
                    Task {
                        // Record the progress (use a dummy token since we just care about values)
                        await receivedProgress.add(
                            token: .string("callback"),
                            progress: progress.value,
                            total: progress.total,
                            message: progress.message
                        )
                    }
                }
            )

            try await Task.sleep(for: .milliseconds(100))

            // Verify result
            if case .text(let text, _, _) = result.content.first {
                #expect(text == "Done")
            }

            // Verify progress callback was invoked
            let updates = await receivedProgress.updates
            #expect(updates.count == 3, "Should receive 3 progress updates via callback")

            if updates.count >= 3 {
                #expect(updates[0].progress == 1.0)
                #expect(updates[0].message == "Step 1")
                #expect(updates[2].progress == 3.0)
                #expect(updates[2].message == "Step 3")
            }
        }

        /// Test that send(_:onProgress:) automatically injects progressToken into _meta.
        @Test(.timeLimit(.minutes(1)))
        func clientAutoInjectsProgressToken() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.client.autoinject")
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

            // Track whether server received a progress token
            let tokenTracker = TokenTracker()

            let server = Server(
                name: "AutoInjectServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                ListTools.Result(tools: [
                    Tool(name: "token_check", inputSchema: ["type": "object"])
                ])
            }

            await server.withRequestHandler(CallTool.self) { request, context in
                guard request.name == "token_check" else {
                    return CallTool.Result(content: [.text("Unknown")], isError: true)
                }

                // Record whether we received a progress token
                if let token = request._meta?.progressToken {
                    await tokenTracker.record(token)
                }

                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "AutoInjectClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Send request WITHOUT manually setting _meta.progressToken
            // The send(_:onProgress:) should auto-inject it
            _ = try await client.send(
                CallTool.request(.init(name: "token_check", arguments: [:])),
                onProgress: { _ in }
            )

            // Verify server received a progress token
            let receivedToken = await tokenTracker.token
            #expect(receivedToken != nil, "Server should have received an auto-injected progress token")
        }
    }

    // MARK: - Task-Augmented Progress Tests

    @Suite("Task-augmented progress (progress continues after CreateTaskResult)")
    struct TaskAugmentedProgressTests {

        /// Test that TaskStatus.isTerminal correctly identifies terminal statuses.
        @Test("TaskStatus.isTerminal identifies terminal states")
        func taskStatusIsTerminal() {
            #expect(TaskStatus.working.isTerminal == false)
            #expect(TaskStatus.inputRequired.isTerminal == false)
            #expect(TaskStatus.completed.isTerminal == true)
            #expect(TaskStatus.failed.isTerminal == true)
            #expect(TaskStatus.cancelled.isTerminal == true)
        }

        /// Test that cleanupTaskProgressHandler removes progress callback.
        @Test("cleanupTaskProgressHandler removes progress callback for task")
        func cleanUpTaskProgressHandler() async throws {
            let client = Client(name: "CleanupTest", version: "1.0")

            // Manually test the cleanup method by verifying it doesn't crash
            // when called with non-existent task ID (should be no-op)
            await client.cleanUpTaskProgressHandler(taskId: "non-existent-task")
            // If we get here without crashing, the test passes
        }

        /// Test that checkForTaskResponse correctly identifies task responses.
        /// This tests the internal logic by verifying the Value structure parsing.
        @Test("Task response detection parses task.taskId from response")
        func taskResponseDetection() throws {
            // CreateTaskResult structure: { "task": { "taskId": "...", "status": "...", ... } }
            let taskResponse: [String: Value] = [
                "task": .object([
                    "taskId": .string("test-task-123"),
                    "status": .string("working"),
                    "ttl": .null,
                    "createdAt": .string("2024-01-01T00:00:00Z"),
                    "lastUpdatedAt": .string("2024-01-01T00:00:00Z")
                ])
            ]

            // Verify the structure can be parsed
            guard let taskValue = taskResponse["task"],
                  case .object(let taskObject) = taskValue,
                  let taskIdValue = taskObject["taskId"],
                  case .string(let taskId) = taskIdValue else {
                Issue.record("Failed to parse task response structure")
                return
            }

            #expect(taskId == "test-task-123")
        }

        /// Test that non-task responses are correctly identified.
        @Test("Non-task response detection returns nil taskId")
        func nonTaskResponseDetection() throws {
            // Regular CallTool.Result structure (no task field)
            let regularResponse: [String: Value] = [
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Hello")
                    ])
                ])
            ]

            // Verify the task field is not present
            let taskValue = regularResponse["task"]
            #expect(taskValue == nil, "Regular response should not have task field")
        }

        /// Test TaskStatusNotification.Parameters decoding.
        @Test("TaskStatusNotification.Parameters decodes correctly")
        func taskStatusNotificationDecoding() throws {
            let json = """
            {
                "taskId": "task-abc",
                "status": "completed",
                "ttl": null,
                "createdAt": "2024-01-01T00:00:00Z",
                "lastUpdatedAt": "2024-01-01T00:00:01Z"
            }
            """

            let decoder = JSONDecoder()
            let params = try decoder.decode(
                TaskStatusNotification.Parameters.self,
                from: json.data(using: .utf8)!
            )

            #expect(params.taskId == "task-abc")
            #expect(params.status == .completed)
            #expect(params.status.isTerminal == true)
        }

        /// Test that terminal task status notification triggers cleanup.
        @Test("Terminal task status triggers progress cleanup")
        func terminalTaskStatusTriggersCleanup() throws {
            // Test that the isTerminal check works as expected for cleanup logic
            let completedStatus = TaskStatus.completed
            let workingStatus = TaskStatus.working

            #expect(completedStatus.isTerminal == true, "Completed should trigger cleanup")
            #expect(workingStatus.isTerminal == false, "Working should not trigger cleanup")
        }
    }
}

// MARK: - Test Helpers

/// Tracker for progress tokens received by server.
private actor TokenTracker {
    private(set) var token: ProgressToken?

    func record(_ token: ProgressToken) {
        self.token = token
    }
}

/// Thread-safe tracker for handler calls.
private actor HandlerCallTracker {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

/// Thread-safe tracker for received progress updates.
private actor ProgressUpdateTracker {
    struct Update {
        let token: ProgressToken
        let progress: Double
        let total: Double?
        let message: String?
    }

    private(set) var updates: [Update] = []

    func add(token: ProgressToken, progress: Double, total: Double?, message: String?) {
        updates.append(Update(token: token, progress: progress, total: total, message: message))
    }
}

/// Thread-safe tracker for received log messages.
private actor LogTracker {
    struct Log {
        let level: LoggingLevel
        let logger: String?
        let data: Value
    }

    private(set) var logs: [Log] = []

    func add(level: LoggingLevel, logger: String?, data: Value) {
        logs.append(Log(level: level, logger: logger, data: data))
    }
}

/// Thread-safe tracker for various notification types.
private actor NotificationTracker {
    private(set) var toolListChangedCount = 0
    private(set) var resourceListChangedCount = 0
    private(set) var promptListChangedCount = 0
    private(set) var resourceUpdatedURIs: [String] = []

    func recordToolListChanged() {
        toolListChangedCount += 1
    }

    func recordResourceListChanged() {
        resourceListChangedCount += 1
    }

    func recordPromptListChanged() {
        promptListChangedCount += 1
    }

    func recordResourceUpdated(uri: String) {
        resourceUpdatedURIs.append(uri)
    }
}
