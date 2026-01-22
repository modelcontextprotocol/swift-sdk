import Foundation
import Testing

@testable import MCP

@Suite("Progress Tests")
struct ProgressTests {
    // MARK: - ProgressToken Tests

    @Test("ProgressToken string encoding and decoding")
    func testProgressTokenStringEncodingDecoding() throws {
        let token = ProgressToken.string("test-token-123")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(token)
        let decoded = try decoder.decode(ProgressToken.self, from: data)

        #expect(decoded == token)
        if case .string(let value) = decoded {
            #expect(value == "test-token-123")
        } else {
            #expect(Bool(false), "Expected string token")
        }
    }

    @Test("ProgressToken integer encoding and decoding")
    func testProgressTokenIntegerEncodingDecoding() throws {
        let token = ProgressToken.integer(42)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(token)
        let decoded = try decoder.decode(ProgressToken.self, from: data)

        #expect(decoded == token)
        if case .integer(let value) = decoded {
            #expect(value == 42)
        } else {
            #expect(Bool(false), "Expected integer token")
        }
    }

    @Test("ProgressToken unique generation")
    func testProgressTokenUnique() {
        let token1 = ProgressToken.unique()
        let token2 = ProgressToken.unique()

        #expect(token1 != token2)

        if case .string(let value1) = token1, case .string(let value2) = token2 {
            #expect(value1 != value2)
        } else {
            #expect(Bool(false), "Expected string tokens")
        }
    }

    @Test("ProgressToken hashable")
    func testProgressTokenHashable() {
        let token1 = ProgressToken.string("test")
        let token2 = ProgressToken.string("test")
        let token3 = ProgressToken.integer(1)
        let token4 = ProgressToken.integer(1)

        #expect(token1 == token2)
        #expect(token3 == token4)
        #expect(token1 != token3)

        let set: Set<ProgressToken> = [token1, token2, token3, token4]
        #expect(set.count == 2)
    }

    // MARK: - RequestMeta Tests

    @Test("RequestMeta empty initialization")
    func testRequestMetaEmptyInit() throws {
        let meta = RequestMeta()

        #expect(meta.progressToken == nil)
        #expect(meta.fields.isEmpty)
    }

    @Test("RequestMeta with progress token")
    func testRequestMetaWithProgressToken() throws {
        let token = ProgressToken.string("my-token")
        let meta = RequestMeta(progressToken: token)

        #expect(meta.progressToken == token)
        #expect(meta.fields["progressToken"] == .string("my-token"))
    }

    @Test("RequestMeta with integer progress token")
    func testRequestMetaWithIntegerProgressToken() throws {
        let token = ProgressToken.integer(42)
        let meta = RequestMeta(progressToken: token)

        #expect(meta.progressToken == token)
        #expect(meta.fields["progressToken"] == .int(42))
    }

    @Test("RequestMeta encoding with progress token")
    func testRequestMetaEncodingWithProgressToken() throws {
        let token = ProgressToken.string("my-token")
        let meta = RequestMeta(progressToken: token)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(meta)
        let decoded = try decoder.decode(RequestMeta.self, from: data)

        #expect(decoded.progressToken == token)
    }

    @Test("RequestMeta encoding without progress token")
    func testRequestMetaEncodingWithoutProgressToken() throws {
        let meta = RequestMeta()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(meta)
        let decoded = try decoder.decode(RequestMeta.self, from: data)

        #expect(decoded.progressToken == nil)
    }

    @Test("RequestMeta JSON representation with progress token")
    func testRequestMetaJSONWithProgressToken() throws {
        let token = ProgressToken.string("test-token")
        let meta = RequestMeta(progressToken: token)

        let encoder = JSONEncoder()
        let data = try encoder.encode(meta)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("progressToken"))
        #expect(jsonString.contains("test-token"))
    }

    @Test("RequestMeta with additional fields")
    func testRequestMetaWithAdditionalFields() throws {
        let meta = RequestMeta(
            progressToken: .string("token"),
            additionalFields: ["customField": .string("customValue")]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(meta)
        let decoded = try decoder.decode(RequestMeta.self, from: data)

        #expect(decoded.progressToken == .string("token"))
        #expect(decoded.fields["customField"] == .string("customValue"))
    }

    @Test("RequestMeta with only additional fields")
    func testRequestMetaWithOnlyAdditionalFields() throws {
        let meta = RequestMeta(additionalFields: [
            "customKey": .int(123),
            "anotherKey": .string("value")
        ])

        #expect(meta.progressToken == nil)
        #expect(meta.fields["customKey"] == .int(123))
        #expect(meta.fields["anotherKey"] == .string("value"))
    }


    // MARK: - ProgressNotification Tests

    @Test("ProgressNotification name")
    func testProgressNotificationName() {
        #expect(ProgressNotification.name == "notifications/progress")
    }

    @Test("ProgressNotification parameters encoding and decoding")
    func testProgressNotificationParametersEncodingDecoding() throws {
        let params = ProgressNotification.Parameters(
            progressToken: .string("test-token"),
            progress: 50,
            total: 100,
            message: "Processing..."
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(ProgressNotification.Parameters.self, from: data)

        #expect(decoded.progressToken == .string("test-token"))
        #expect(decoded.progress == 50)
        #expect(decoded.total == 100)
        #expect(decoded.message == "Processing...")
    }

    @Test("ProgressNotification parameters without optional fields")
    func testProgressNotificationParametersWithoutOptionals() throws {
        let params = ProgressNotification.Parameters(
            progressToken: .integer(42),
            progress: 75
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(ProgressNotification.Parameters.self, from: data)

        #expect(decoded.progressToken == .integer(42))
        #expect(decoded.progress == 75)
        #expect(decoded.total == nil)
        #expect(decoded.message == nil)
    }

    @Test("ProgressNotification message creation")
    func testProgressNotificationMessage() throws {
        let params = ProgressNotification.Parameters(
            progressToken: .string("my-token"),
            progress: 30,
            total: 100,
            message: "Step 3 of 10"
        )

        let message = ProgressNotification.message(params)

        #expect(message.method == "notifications/progress")
        #expect(message.params.progressToken == .string("my-token"))
        #expect(message.params.progress == 30)
        #expect(message.params.total == 100)
        #expect(message.params.message == "Step 3 of 10")
    }

    // MARK: - CallTool with _meta Tests

    @Test("CallTool parameters without meta")
    func testCallToolParametersWithoutMeta() throws {
        let params = CallTool.Parameters(name: "test_tool", arguments: ["key": "value"])

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(CallTool.Parameters.self, from: data)

        #expect(decoded.name == "test_tool")
        #expect(decoded.arguments?["key"] == .string("value"))
        #expect(decoded._meta == nil)

        // Verify _meta is not included in JSON when nil
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(!jsonString.contains("_meta"))
    }

    @Test("CallTool parameters with progress token")
    func testCallToolParametersWithProgressToken() throws {
        let token = ProgressToken.string("call-tool-token")
        let meta = RequestMeta(progressToken: token)
        let params = CallTool.Parameters(name: "test_tool", arguments: ["key": "value"], meta: meta)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(CallTool.Parameters.self, from: data)

        #expect(decoded.name == "test_tool")
        #expect(decoded.arguments?["key"] == .string("value"))
        #expect(decoded._meta?.progressToken == token)

        // Verify _meta is included in JSON
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("_meta"))
        #expect(jsonString.contains("progressToken"))
        #expect(jsonString.contains("call-tool-token"))
    }

    @Test("CallTool request encoding with progress token")
    func testCallToolRequestEncodingWithProgressToken() throws {
        let token = ProgressToken.string("request-token")
        let meta = RequestMeta(progressToken: token)
        let request = CallTool.request(.init(name: "my_tool", arguments: ["arg": 42], meta: meta))

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let jsonString = String(data: data, encoding: .utf8)!

        // Note: JSON encoding may escape forward slashes as \/
        #expect(jsonString.contains("tools") && jsonString.contains("call"))
        #expect(jsonString.contains("my_tool"))
        #expect(jsonString.contains("_meta"))
        #expect(jsonString.contains("progressToken"))
        #expect(jsonString.contains("request-token"))
    }

    @Test("CallTool request decoding with _meta")
    func testCallToolRequestDecodingWithMeta() throws {
        let jsonString = """
            {
                "jsonrpc": "2.0",
                "id": "test-id",
                "method": "tools/call",
                "params": {
                    "_meta": {
                        "progressToken": "decoded-token"
                    },
                    "name": "decoded_tool",
                    "arguments": {"x": 10}
                }
            }
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let request = try decoder.decode(Request<CallTool>.self, from: data)

        #expect(request.id == "test-id")
        #expect(request.method == "tools/call")
        #expect(request.params.name == "decoded_tool")
        #expect(request.params.arguments?["x"] == .int(10))
        #expect(request.params._meta?.progressToken == .string("decoded-token"))
    }

    @Test("CallTool request decoding without _meta")
    func testCallToolRequestDecodingWithoutMeta() throws {
        let jsonString = """
            {
                "jsonrpc": "2.0",
                "id": "test-id",
                "method": "tools/call",
                "params": {
                    "name": "tool_without_meta",
                    "arguments": {"y": 20}
                }
            }
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let request = try decoder.decode(Request<CallTool>.self, from: data)

        #expect(request.params.name == "tool_without_meta")
        #expect(request.params.arguments?["y"] == .int(20))
        #expect(request.params._meta == nil)
    }

    @Test("Client notification updates should fire when server sends them")
    func testClientNotificationUpdates() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "testClient", version: "1")
        let token = ProgressToken.unique()

        var progresses: [Double] = []
        await client.onNotification(ProgressNotification.self) { message in
            let receivedToken = message.params.progressToken
            #expect(receivedToken == token)
            await MainActor.run {
                progresses.append(message.params.progress)
            }
        }

        let server = Server(name: "testServer", version: "1")
        let expectedToolCallResult = CallTool.Result(content: [.text("success")])
        await server.withMethodHandler(CallTool.self) { params in
            if let token = params._meta?.progressToken {
                for i in 1...5 {
                    let notification = ProgressNotification.message(
                        .init(progressToken: token, progress: Double(i * 20))
                    )
                    try await server.notify(notification)
                }
            }

            return .init(content: [.text("success")])
        }

        try await server.start(transport: pair.server)
        try await client.connect(transport: pair.client)
        let result = try await client.callTool(name: "random", meta: RequestMeta(progressToken: token))

        #expect(progresses == [20, 40, 60, 80, 100])
        #expect(result.0 == expectedToolCallResult.content)
        #expect(result.1 == nil)
    }
}
