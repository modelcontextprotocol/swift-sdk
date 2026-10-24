import Foundation
import Testing

@testable import MCP

@Suite("Logging Tests")
struct LoggingTests {
    // MARK: - LogLevel Tests

    @Test("LogLevel case values")
    func testLogLevelCases() throws {
        #expect(LogLevel.debug.rawValue == "debug")
        #expect(LogLevel.info.rawValue == "info")
        #expect(LogLevel.notice.rawValue == "notice")
        #expect(LogLevel.warning.rawValue == "warning")
        #expect(LogLevel.error.rawValue == "error")
        #expect(LogLevel.critical.rawValue == "critical")
        #expect(LogLevel.alert.rawValue == "alert")
        #expect(LogLevel.emergency.rawValue == "emergency")
    }

    @Test("LogLevel encoding and decoding")
    func testLogLevelEncodingDecoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for level in LogLevel.allCases {
            let data = try encoder.encode(level)
            let decoded = try decoder.decode(LogLevel.self, from: data)
            #expect(decoded == level)

            // Verify it encodes to the raw string value
            let jsonString = String(data: data, encoding: .utf8)
            #expect(jsonString == "\"\(level.rawValue)\"")
        }
    }

    // MARK: - SetLoggingLevel Tests

    @Test("SetLoggingLevel request initialization")
    func testSetLoggingLevelRequest() throws {
        let request = SetLoggingLevel.request(.init(level: .info))

        #expect(request.method == "logging/setLevel")
        #expect(request.params.level == LogLevel.info)
    }

    @Test("SetLoggingLevel request encoding")
    func testSetLoggingLevelRequestEncoding() throws {
        let request = SetLoggingLevel.request(.init(level: .error))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["method"] as? String == "logging/setLevel")

        let params = json?["params"] as? [String: Any]
        #expect(params?["level"] as? String == "error")
    }

    @Test("SetLoggingLevel request decoding")
    func testSetLoggingLevelRequestDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "test-id",
            "method": "logging/setLevel",
            "params": {
                "level": "warning"
            }
        }
        """

        let decoder = JSONDecoder()
        let request = try decoder.decode(Request<SetLoggingLevel>.self, from: json.data(using: .utf8)!)

        #expect(request.method == "logging/setLevel")
        #expect(request.params.level == .warning)
    }

    @Test("SetLoggingLevel response")
    func testSetLoggingLevelResponse() throws {
        let response = SetLoggingLevel.response(id: .random)

        if case .success = response.result {
            // Success case
        } else {
            Issue.record("Expected success result")
        }
    }

    // MARK: - LogMessageNotification Tests

    @Test("LogMessageNotification initialization")
    func testLogMessageNotificationInitialization() throws {
        let data = Value.object([
            "message": Value.string("Test log message"),
            "code": Value.int(42)
        ])

        let params = LogMessageNotification.Parameters(
            level: .info,
            logger: "test-logger",
            data: data
        )

        #expect(params.level == LogLevel.info)
        #expect(params.logger == "test-logger")
        #expect(params.data == data)
    }

    @Test("LogMessageNotification with nil logger")
    func testLogMessageNotificationWithNilLogger() throws {
        let data = Value.object(["message": Value.string("Test")])

        let params = LogMessageNotification.Parameters(
            level: .debug,
            logger: nil,
            data: data
        )

        #expect(params.level == LogLevel.debug)
        #expect(params.logger == nil)
        #expect(params.data == data)
    }

    @Test("LogMessageNotification encoding")
    func testLogMessageNotificationEncoding() throws {
        let data = Value.object([
            "error": Value.string("Connection failed"),
            "details": .object([
                "host": Value.string("localhost"),
                "port": Value.int(5432)
            ])
        ])

        let notification = LogMessageNotification.message(
            .init(level: .error, logger: "database", data: data)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let encodedData = try encoder.encode(notification)
        let json = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any]

        guard let jsonValue = json else {
            Issue.record("Failed to parse JSON")
            return
        }

        #expect(jsonValue["jsonrpc"] as? String == "2.0")
        #expect(jsonValue["method"] as? String == "notifications/message")

        guard let params = jsonValue["params"] as? [String: Any] else {
            Issue.record("Failed to get params")
            return
        }
        #expect(params["level"] as? String == "error")
        #expect(params["logger"] as? String == "database")

        guard let dataDict = params["data"] as? [String: Any] else {
            Issue.record("Failed to get data")
            return
        }
        #expect(dataDict["error"] as? String == "Connection failed")
    }

    @Test("LogMessageNotification decoding")
    func testLogMessageNotificationDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": {
                "level": "info",
                "logger": "app",
                "data": {
                    "message": "Server started",
                    "port": 8080
                }
            }
        }
        """

        let decoder = JSONDecoder()
        let notification = try decoder.decode(Message<LogMessageNotification>.self, from: json.data(using: .utf8)!)

        #expect(notification.method == "notifications/message")
        #expect(notification.params.level == LogLevel.info)
        #expect(notification.params.logger == "app")

        if case .object(let dataDict) = notification.params.data {
            #expect(dataDict["message"] == Value.string("Server started"))
            #expect(dataDict["port"] == Value.int(8080))
        } else {
            Issue.record("Expected object data")
        }
    }

    // MARK: - Client Integration Tests

    @Test("Client setLoggingLevel sends correct request")
    func testClientSetLoggingLevel() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(logging: .init())
        )

        actor TestState {
            var receivedLevel: LogLevel?
            func setLevel(_ level: LogLevel) { receivedLevel = level }
            func getLevel() -> LogLevel? { receivedLevel }
        }

        let state = TestState()

        // Register handler for setLoggingLevel on server
        await server.withMethodHandler(SetLoggingLevel.self) { params in
            await state.setLevel(params.level)
            return Empty()
        }

        try await server.start(transport: serverTransport)
        let initResult = try await client.connect(transport: clientTransport)

        // Verify logging capability is advertised
        #expect(initResult.capabilities.logging != nil)

        // Call setLoggingLevel
        try await client.setLoggingLevel(.warning)

        // Give time for message processing
        try await Task.sleep(for: .milliseconds(100))

        // Verify the handler was called
        #expect(await state.getLevel() == .warning)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client setLoggingLevel fails without logging capability")
    func testClientSetLoggingLevelFailsWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0", configuration: .strict)
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()  // No logging capability
        )

        try await server.start(transport: serverTransport)
        let initResult = try await client.connect(transport: clientTransport)

        // Verify logging capability is NOT advertised
        #expect(initResult.capabilities.logging == nil)

        // Attempt to set logging level should fail in strict mode
        await #expect(throws: MCPError.self) {
            try await client.setLoggingLevel(.info)
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Server Integration Tests

    @Test("Server log method sends notification")
    func testServerLogMethod() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(logging: .init())
        )

        actor TestState {
            var logMessages: [(level: LogLevel, logger: String?, data: Value)] = []
            func addLog(level: LogLevel, logger: String?, data: Value) {
                logMessages.append((level, logger, data))
            }
            func getLogs() -> [(level: LogLevel, logger: String?, data: Value)] { logMessages }
        }

        let state = TestState()

        // Register handler for log notifications on client
        await client.onNotification(LogMessageNotification.self) { message in
            await state.addLog(
                level: message.params.level,
                logger: message.params.logger,
                data: message.params.data
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Send a log message
        let logData = Value.object([
            "message": Value.string("Test log"),
            "count": Value.int(42)
        ])

        try await server.log(level: .info, logger: "test", data: logData)

        // Wait for message processing
        try await Task.sleep(for: .milliseconds(100))

        // Verify the notification was received
        let logs = await state.getLogs()
        #expect(logs.count == 1)
        #expect(logs[0].level == LogLevel.info)
        #expect(logs[0].logger == "test")
        #expect(logs[0].data == logData)

        await client.disconnect()
        await server.stop()
    }

    @Test("Server log method with codable data")
    func testServerLogMethodWithCodableData() async throws {
        struct LogData: Codable, Hashable {
            let message: String
            let timestamp: String
            let code: Int
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(logging: .init())
        )

        actor TestState {
            var logMessages: [(level: LogLevel, logger: String?, data: Value)] = []
            func addLog(level: LogLevel, logger: String?, data: Value) {
                logMessages.append((level, logger, data))
            }
            func getLogs() -> [(level: LogLevel, logger: String?, data: Value)] { logMessages }
        }

        let state = TestState()

        // Register handler for log notifications on client
        await client.onNotification(LogMessageNotification.self) { message in
            await state.addLog(
                level: message.params.level,
                logger: message.params.logger,
                data: message.params.data
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Send a log message with codable data
        let logData = LogData(
            message: "Error occurred",
            timestamp: "2025-01-29T12:00:00Z",
            code: 500
        )

        try await server.log(level: .error, logger: "api", data: logData)

        // Wait for message processing
        try await Task.sleep(for: .milliseconds(100))

        // Verify the notification was received
        let logs = await state.getLogs()
        #expect(logs.count == 1)
        #expect(logs[0].level == LogLevel.error)
        #expect(logs[0].logger == "api")

        // Verify data content
        if case .object(let dataDict) = logs[0].data {
            #expect(dataDict["message"] == Value.string("Error occurred"))
            #expect(dataDict["timestamp"] == Value.string("2025-01-29T12:00:00Z"))
            #expect(dataDict["code"] == Value.int(500))
        } else {
            Issue.record("Expected object data")
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("Server log without logger name")
    func testServerLogWithoutLoggerName() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(logging: .init())
        )

        actor TestState {
            var logMessages: [(level: LogLevel, logger: String?, data: Value)] = []
            func addLog(level: LogLevel, logger: String?, data: Value) {
                logMessages.append((level, logger, data))
            }
            func getLogs() -> [(level: LogLevel, logger: String?, data: Value)] { logMessages }
        }

        let state = TestState()

        // Register handler for log notifications on client
        await client.onNotification(LogMessageNotification.self) { message in
            await state.addLog(
                level: message.params.level,
                logger: message.params.logger,
                data: message.params.data
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Send a log message without logger name
        let logData = Value.object(["message": Value.string("Generic log")])
        try await server.log(level: .debug, data: logData)

        // Wait for message processing
        try await Task.sleep(for: .milliseconds(100))

        // Verify the notification was received
        let logs = await state.getLogs()
        #expect(logs.count == 1)
        #expect(logs[0].level == LogLevel.debug)
        #expect(logs[0].logger == nil)

        await client.disconnect()
        await server.stop()
    }

    @Test("Multiple log levels sent correctly")
    func testMultipleLogLevels() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(logging: .init())
        )

        actor TestState {
            var logMessages: [(level: LogLevel, logger: String?, data: Value)] = []
            func addLog(level: LogLevel, logger: String?, data: Value) {
                logMessages.append((level, logger, data))
            }
            func getLogs() -> [(level: LogLevel, logger: String?, data: Value)] { logMessages }
        }

        let state = TestState()

        // Register handler for log notifications on client
        await client.onNotification(LogMessageNotification.self) { message in
            await state.addLog(
                level: message.params.level,
                logger: message.params.logger,
                data: message.params.data
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Send log messages at different levels
        try await server.log(level: .debug, data: Value.object(["msg": Value.string("Debug message")]))
        try await server.log(level: .info, data: Value.object(["msg": Value.string("Info message")]))
        try await server.log(level: .warning, data: Value.object(["msg": Value.string("Warning message")]))
        try await server.log(level: .error, data: Value.object(["msg": Value.string("Error message")]))
        try await server.log(level: .critical, data: Value.object(["msg": Value.string("Critical message")]))

        // Wait for message processing
        try await Task.sleep(for: .milliseconds(200))

        // Verify all notifications were received
        let logs = await state.getLogs()
        #expect(logs.count == 5)
        #expect(logs[0].level == LogLevel.debug)
        #expect(logs[1].level == LogLevel.info)
        #expect(logs[2].level == LogLevel.warning)
        #expect(logs[3].level == LogLevel.error)
        #expect(logs[4].level == LogLevel.critical)

        await client.disconnect()
        await server.stop()
    }
}
