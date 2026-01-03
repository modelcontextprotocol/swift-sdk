import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Notification Tests")
struct NotificationTests {
    struct TestNotification: Notification {
        struct Parameters: Codable, Hashable, Sendable {
            let event: String
        }
        static let name = "test.notification"
    }

    struct InitializedNotification: Notification {
        static let name = "notifications/initialized"
    }

    @Test("Notification initialization with parameters")
    func testNotificationWithParameters() throws {
        let params = TestNotification.Parameters(event: "test-event")
        let notification = TestNotification.message(params)

        #expect(notification.method == TestNotification.name)
        #expect(notification.params.event == "test-event")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(Message<TestNotification>.self, from: data)

        #expect(decoded.method == notification.method)
        #expect(decoded.params.event == notification.params.event)
    }

    @Test("Empty parameters notification")
    func testEmptyParametersNotification() throws {
        struct EmptyNotification: Notification {
            static let name = "empty.notification"
        }

        let notification = EmptyNotification.message()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(Message<EmptyNotification>.self, from: data)

        #expect(decoded.method == notification.method)
    }

    @Test("Initialized notification encoding")
    func testInitializedNotificationEncoding() throws {
        let notification = InitializedNotification.message()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)

        // Verify the exact JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/initialized")
        #expect(json.count == 2, "Should only contain jsonrpc and method fields")

        // Verify we can decode it back
        let decoded = try decoder.decode(Message<InitializedNotification>.self, from: data)
        #expect(decoded.method == InitializedNotification.name)
    }

    @Test("Initialized notification decoding")
    func testInitializedNotificationDecoding() throws {
        // Create a minimal JSON string
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<InitializedNotification>.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test("Resource updated notification with parameters")
    func testResourceUpdatedNotification() throws {
        let params = ResourceUpdatedNotification.Parameters(uri: "test://resource")
        let notification = ResourceUpdatedNotification.message(params)

        #expect(notification.method == ResourceUpdatedNotification.name)
        #expect(notification.params.uri == "test://resource")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)

        // Verify the exact JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/resources/updated")
        #expect(json["params"] != nil)
        #expect(json.count == 3, "Should contain jsonrpc, method, and params fields")

        // Verify we can decode it back
        let decoded = try decoder.decode(Message<ResourceUpdatedNotification>.self, from: data)
        #expect(decoded.method == ResourceUpdatedNotification.name)
        #expect(decoded.params.uri == "test://resource")
    }

    @Test("AnyNotification decoding - without params")
    func testAnyNotificationDecodingWithoutParams() throws {
        // Test decoding when params field is missing
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test("AnyNotification decoding - with null params")
    func testAnyNotificationDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/initialized","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test("AnyNotification decoding - with empty params")
    func testAnyNotificationDecodingWithEmptyParams() throws {
        // Test decoding when params field is empty
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test("AnyNotification decoding - with non-empty params")
    func testAnyNotificationDecodingWithNonEmptyParams() throws {
        // Test decoding when params field has values
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"test://resource"}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == ResourceUpdatedNotification.name)
        #expect(decoded.params.objectValue?["uri"]?.stringValue == "test://resource")
    }

    // MARK: - LogMessageNotification Tests

    @Test("LogMessageNotification encoding with all fields")
    func testLogMessageNotificationEncodingAllFields() throws {
        let params = LogMessageNotification.Parameters(
            level: .info,
            logger: "test-logger",
            data: .string("Test log message")
        )
        let notification = LogMessageNotification.message(params)

        #expect(notification.method == LogMessageNotification.name)
        #expect(notification.params.level == .info)
        #expect(notification.params.logger == "test-logger")
        #expect(notification.params.data == .string("Test log message"))

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/message")
        #expect(json["params"]?.objectValue?["level"] == "info")
        #expect(json["params"]?.objectValue?["logger"] == "test-logger")
        #expect(json["params"]?.objectValue?["data"] == "Test log message")
    }

    @Test("LogMessageNotification encoding with minimal fields")
    func testLogMessageNotificationEncodingMinimal() throws {
        let params = LogMessageNotification.Parameters(
            level: .warning,
            data: .string("Warning message")
        )
        let notification = LogMessageNotification.message(params)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure (logger should be omitted)
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["method"] == "notifications/message")
        #expect(json["params"]?.objectValue?["level"] == "warning")
        #expect(json["params"]?.objectValue?["logger"] == nil)
        #expect(json["params"]?.objectValue?["data"] == "Warning message")
    }

    @Test("LogMessageNotification decoding")
    func testLogMessageNotificationDecoding() throws {
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"error","logger":"app","data":"Error occurred"}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<LogMessageNotification>.self, from: data)

        #expect(decoded.method == LogMessageNotification.name)
        #expect(decoded.params.level == .error)
        #expect(decoded.params.logger == "app")
        #expect(decoded.params.data == .string("Error occurred"))
    }

    @Test("LogMessageNotification with object data")
    func testLogMessageNotificationWithObjectData() throws {
        let params = LogMessageNotification.Parameters(
            level: .debug,
            data: .object(["key": .string("value"), "count": .int(42)])
        )
        let notification = LogMessageNotification.message(params)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)
        let decoded = try JSONDecoder().decode(Message<LogMessageNotification>.self, from: data)

        #expect(decoded.params.level == .debug)
        #expect(decoded.params.data.objectValue?["key"] == .string("value"))
        #expect(decoded.params.data.objectValue?["count"] == .int(42))
    }

    @Test("LogMessageNotification all log levels")
    func testLogMessageNotificationAllLogLevels() throws {
        let levels: [LoggingLevel] = [
            .debug, .info, .notice, .warning, .error, .critical, .alert, .emergency
        ]

        for level in levels {
            let params = LogMessageNotification.Parameters(level: level, data: .string("test"))
            let notification = LogMessageNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let decoded = try JSONDecoder().decode(Message<LogMessageNotification>.self, from: data)

            #expect(decoded.params.level == level, "Log level \(level) should roundtrip correctly")
        }
    }

    // MARK: - ToolListChangedNotification Tests

    @Test("ToolListChangedNotification encoding")
    func testToolListChangedNotificationEncoding() throws {
        let notification = ToolListChangedNotification.message()

        #expect(notification.method == ToolListChangedNotification.name)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/tools/list_changed")
        // Empty params may be included as {} per JSON-RPC conventions
        if let params = json["params"] {
            #expect(params == .object([:]), "Params should be empty object if present")
        }
    }

    @Test("ToolListChangedNotification decoding")
    func testToolListChangedNotificationDecoding() throws {
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ToolListChangedNotification>.self, from: data)

        #expect(decoded.method == ToolListChangedNotification.name)
    }

    @Test("ToolListChangedNotification decoding with empty params")
    func testToolListChangedNotificationDecodingWithEmptyParams() throws {
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ToolListChangedNotification>.self, from: data)

        #expect(decoded.method == ToolListChangedNotification.name)
    }

    // MARK: - PromptListChangedNotification Tests

    @Test("PromptListChangedNotification encoding")
    func testPromptListChangedNotificationEncoding() throws {
        let notification = PromptListChangedNotification.message()

        #expect(notification.method == PromptListChangedNotification.name)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/prompts/list_changed")
        // Empty params may be included as {} per JSON-RPC conventions
        if let params = json["params"] {
            #expect(params == .object([:]), "Params should be empty object if present")
        }
    }

    @Test("PromptListChangedNotification decoding")
    func testPromptListChangedNotificationDecoding() throws {
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/prompts/list_changed"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<PromptListChangedNotification>.self, from: data)

        #expect(decoded.method == PromptListChangedNotification.name)
    }

    @Test("PromptListChangedNotification decoding with empty params")
    func testPromptListChangedNotificationDecodingWithEmptyParams() throws {
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/prompts/list_changed","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<PromptListChangedNotification>.self, from: data)

        #expect(decoded.method == PromptListChangedNotification.name)
    }

    // MARK: - ResourceListChangedNotification Tests

    @Test("ResourceListChangedNotification encoding")
    func testResourceListChangedNotificationEncoding() throws {
        let notification = ResourceListChangedNotification.message()

        #expect(notification.method == ResourceListChangedNotification.name)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/resources/list_changed")
        // Empty params may be included as {} per JSON-RPC conventions
        if let params = json["params"] {
            #expect(params == .object([:]), "Params should be empty object if present")
        }
    }

    @Test("ResourceListChangedNotification decoding")
    func testResourceListChangedNotificationDecoding() throws {
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/resources/list_changed"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ResourceListChangedNotification>.self, from: data)

        #expect(decoded.method == ResourceListChangedNotification.name)
    }

    @Test("ResourceListChangedNotification decoding with empty params")
    func testResourceListChangedNotificationDecodingWithEmptyParams() throws {
        let jsonString = """
            {"jsonrpc":"2.0","method":"notifications/resources/list_changed","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ResourceListChangedNotification>.self, from: data)

        #expect(decoded.method == ResourceListChangedNotification.name)
    }
}
