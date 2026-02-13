import Foundation
import Testing

@testable import MCP

@Suite("Completion Tests")
struct CompletionTests {
    // MARK: - Reference Types Tests

    @Test("PromptReference initialization and encoding")
    func testPromptReferenceEncodingDecoding() throws {
        let ref = PromptReference(name: "code_review")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(ref)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["type"] as? String == "ref/prompt")
        #expect(json?["name"] as? String == "code_review")

        // Test decoding
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PromptReference.self, from: data)
        #expect(decoded.name == "code_review")
    }

    @Test("ResourceReference initialization and encoding")
    func testResourceReferenceEncodingDecoding() throws {
        let ref = ResourceReference(uri: "file:///path/to/resource")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(ref)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["type"] as? String == "ref/resource")
        #expect(json?["uri"] as? String == "file:///path/to/resource")

        // Test decoding
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ResourceReference.self, from: data)
        #expect(decoded.uri == "file:///path/to/resource")
    }

    @Test("CompletionReference prompt case encoding")
    func testCompletionReferencePromptEncoding() throws {
        let ref = CompletionReference.prompt(PromptReference(name: "test"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(ref)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["type"] as? String == "ref/prompt")
        #expect(json?["name"] as? String == "test")
    }

    @Test("CompletionReference resource case encoding")
    func testCompletionReferenceResourceEncoding() throws {
        let ref = CompletionReference.resource(ResourceReference(uri: "file:///test"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(ref)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["type"] as? String == "ref/resource")
        #expect(json?["uri"] as? String == "file:///test")
    }

    @Test("CompletionReference decoding prompt type")
    func testCompletionReferenceDecodingPrompt() throws {
        let json = """
        {
            "type": "ref/prompt",
            "name": "code_review"
        }
        """

        let decoder = JSONDecoder()
        let ref = try decoder.decode(CompletionReference.self, from: json.data(using: .utf8)!)

        if case .prompt(let promptRef) = ref {
            #expect(promptRef.name == "code_review")
        } else {
            Issue.record("Expected prompt reference")
        }
    }

    @Test("CompletionReference decoding resource type")
    func testCompletionReferenceDecodingResource() throws {
        let json = """
        {
            "type": "ref/resource",
            "uri": "file:///path"
        }
        """

        let decoder = JSONDecoder()
        let ref = try decoder.decode(CompletionReference.self, from: json.data(using: .utf8)!)

        if case .resource(let resourceRef) = ref {
            #expect(resourceRef.uri == "file:///path")
        } else {
            Issue.record("Expected resource reference")
        }
    }

    // MARK: - Complete Request Tests

    @Test("Complete request initialization")
    func testCompleteRequestInitialization() throws {
        let ref = CompletionReference.prompt(PromptReference(name: "code_review"))
        let argument = Complete.Parameters.Argument(name: "language", value: "py")
        let request = Complete.request(.init(ref: ref, argument: argument))

        #expect(request.method == "completion/complete")
        #expect(request.params.argument.name == "language")
        #expect(request.params.argument.value == "py")
    }

    @Test("Complete request with context")
    func testCompleteRequestWithContext() throws {
        let ref = CompletionReference.prompt(PromptReference(name: "code_review"))
        let argument = Complete.Parameters.Argument(name: "framework", value: "fla")
        let context = Complete.Parameters.Context(arguments: ["language": .string("python")])

        let request = Complete.request(.init(ref: ref, argument: argument, context: context))

        #expect(request.params.context != nil)
        #expect(request.params.context?.arguments["language"] == .string("python"))
    }

    @Test("Complete request encoding")
    func testCompleteRequestEncoding() throws {
        let ref = CompletionReference.prompt(PromptReference(name: "code_review"))
        let argument = Complete.Parameters.Argument(name: "language", value: "py")
        let request = Complete.request(.init(ref: ref, argument: argument))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["method"] as? String == "completion/complete")

        guard let params = json?["params"] as? [String: Any] else {
            Issue.record("Failed to get params")
            return
        }
        guard let refDict = params["ref"] as? [String: Any] else {
            Issue.record("Failed to get ref")
            return
        }
        #expect(refDict["type"] as? String == "ref/prompt")
        #expect(refDict["name"] as? String == "code_review")

        guard let arg = params["argument"] as? [String: Any] else {
            Issue.record("Failed to get argument")
            return
        }
        #expect(arg["name"] as? String == "language")
        #expect(arg["value"] as? String == "py")
    }

    @Test("Complete request decoding")
    func testCompleteRequestDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "test-id",
            "method": "completion/complete",
            "params": {
                "ref": {
                    "type": "ref/prompt",
                    "name": "code_review"
                },
                "argument": {
                    "name": "language",
                    "value": "py"
                }
            }
        }
        """

        let decoder = JSONDecoder()
        let request = try decoder.decode(Request<Complete>.self, from: json.data(using: .utf8)!)

        #expect(request.method == "completion/complete")
        #expect(request.params.argument.name == "language")
        #expect(request.params.argument.value == "py")

        if case .prompt(let promptRef) = request.params.ref {
            #expect(promptRef.name == "code_review")
        } else {
            Issue.record("Expected prompt reference")
        }
    }

    // MARK: - Complete Result Tests

    @Test("Complete result initialization")
    func testCompleteResultInitialization() throws {
        let completion = Complete.Result.Completion(
            values: ["python", "pytorch", "pyside"],
            total: 10,
            hasMore: true
        )
        let result = Complete.Result(completion: completion)

        #expect(result.completion.values.count == 3)
        #expect(result.completion.values[0] == "python")
        #expect(result.completion.total == 10)
        #expect(result.completion.hasMore == true)
    }

    @Test("Complete result encoding")
    func testCompleteResultEncoding() throws {
        let completion = Complete.Result.Completion(
            values: ["python", "pytorch"],
            total: 2,
            hasMore: false
        )
        let result = Complete.Result(completion: completion)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let completionDict = json?["completion"] as? [String: Any]
        let values = completionDict?["values"] as? [String]
        #expect(values == ["python", "pytorch"])
        #expect(completionDict?["total"] as? Int == 2)
        #expect(completionDict?["hasMore"] as? Bool == false)
    }

    @Test("Complete result decoding")
    func testCompleteResultDecoding() throws {
        let json = """
        {
            "completion": {
                "values": ["python", "pytorch", "pyside"],
                "total": 10,
                "hasMore": true
            }
        }
        """

        let decoder = JSONDecoder()
        let result = try decoder.decode(Complete.Result.self, from: json.data(using: .utf8)!)

        #expect(result.completion.values.count == 3)
        #expect(result.completion.values == ["python", "pytorch", "pyside"])
        #expect(result.completion.total == 10)
        #expect(result.completion.hasMore == true)
    }

    @Test("Complete result with optional fields")
    func testCompleteResultWithOptionalFields() throws {
        let completion = Complete.Result.Completion(
            values: ["value1"],
            total: nil,
            hasMore: nil
        )

        #expect(completion.values == ["value1"])
        #expect(completion.total == nil)
        #expect(completion.hasMore == nil)
    }

    // MARK: - Client Integration Tests

    @Test("Client complete for prompt argument")
    func testClientCompleteForPrompt() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(completions: .init())
        )

        // Register handler for complete on server
        await server.withMethodHandler(Complete.self) { params in
            #expect(params.argument.name == "language")
            #expect(params.argument.value == "py")

            if case .prompt(let promptRef) = params.ref {
                #expect(promptRef.name == "code_review")
            } else {
                Issue.record("Expected prompt reference")
            }

            return .init(
                completion: .init(
                    values: ["python", "pytorch", "pyside"],
                    total: 10,
                    hasMore: true
                )
            )
        }

        try await server.start(transport: serverTransport)
        let initResult = try await client.connect(transport: clientTransport)

        // Verify completions capability is advertised
        #expect(initResult.capabilities.completions != nil)

        // Request completions
        let completion = try await client.complete(
            promptName: "code_review",
            argumentName: "language",
            argumentValue: "py"
        )

        #expect(completion.values == ["python", "pytorch", "pyside"])
        #expect(completion.total == 10)
        #expect(completion.hasMore == true)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client complete for resource argument")
    func testClientCompleteForResource() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(completions: .init())
        )

        // Register handler for complete on server
        await server.withMethodHandler(Complete.self) { params in
            #expect(params.argument.name == "path")
            #expect(params.argument.value == "/usr/")

            if case .resource(let resourceRef) = params.ref {
                #expect(resourceRef.uri == "file:///{path}")
            } else {
                Issue.record("Expected resource reference")
            }

            return .init(
                completion: .init(
                    values: ["/usr/bin", "/usr/lib", "/usr/local"],
                    total: 3,
                    hasMore: false
                )
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Request completions for resource
        let completion = try await client.complete(
            resourceURI: "file:///{path}",
            argumentName: "path",
            argumentValue: "/usr/"
        )

        #expect(completion.values == ["/usr/bin", "/usr/lib", "/usr/local"])
        #expect(completion.total == 3)
        #expect(completion.hasMore == false)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client complete with context")
    func testClientCompleteWithContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(completions: .init())
        )

        // Register handler for complete on server
        await server.withMethodHandler(Complete.self) { params in
            #expect(params.argument.name == "framework")
            #expect(params.argument.value == "fla")
            #expect(params.context != nil)
            #expect(params.context?.arguments["language"] == .string("python"))

            return .init(
                completion: .init(
                    values: ["flask"],
                    total: 1,
                    hasMore: false
                )
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Request completions with context
        let completion = try await client.complete(
            promptName: "code_review",
            argumentName: "framework",
            argumentValue: "fla",
            context: ["language": .string("python")]
        )

        #expect(completion.values == ["flask"])
        #expect(completion.total == 1)
        #expect(completion.hasMore == false)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client complete fails without completions capability")
    func testClientCompleteFailsWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0", configuration: .strict)
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()  // No completions capability
        )

        try await server.start(transport: serverTransport)
        let initResult = try await client.connect(transport: clientTransport)

        // Verify completions capability is NOT advertised
        #expect(initResult.capabilities.completions == nil)

        // Attempt to request completions should fail in strict mode
        await #expect(throws: MCPError.self) {
            try await client.complete(
                promptName: "test",
                argumentName: "arg",
                argumentValue: "val"
            )
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("Empty completion values")
    func testEmptyCompletionValues() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(completions: .init())
        )

        // Register handler that returns empty results
        await server.withMethodHandler(Complete.self) { _ in
            return .init(
                completion: .init(
                    values: [],
                    total: 0,
                    hasMore: false
                )
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let completion = try await client.complete(
            promptName: "test",
            argumentName: "arg",
            argumentValue: "xyz"
        )

        #expect(completion.values.isEmpty)
        #expect(completion.total == 0)
        #expect(completion.hasMore == false)

        await client.disconnect()
        await server.stop()
    }

    @Test("Maximum completion values (100 items)")
    func testMaximumCompletionValues() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(completions: .init())
        )

        // Register handler that returns 100 items
        await server.withMethodHandler(Complete.self) { _ in
            let values = (1...100).map { "value\($0)" }
            return .init(
                completion: .init(
                    values: values,
                    total: 200,
                    hasMore: true
                )
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let completion = try await client.complete(
            promptName: "test",
            argumentName: "arg",
            argumentValue: ""
        )

        #expect(completion.values.count == 100)
        #expect(completion.values.first == "value1")
        #expect(completion.values.last == "value100")
        #expect(completion.total == 200)
        #expect(completion.hasMore == true)

        await client.disconnect()
        await server.stop()
    }

    @Test("Fuzzy matching completion scenario")
    func testFuzzyMatchingScenario() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(completions: .init())
        )

        // Register handler that implements fuzzy matching
        await server.withMethodHandler(Complete.self) { params in
            let input = params.argument.value.lowercased()
            let allLanguages = ["python", "perl", "php", "pascal", "prolog", "javascript", "java"]

            // Simple prefix matching
            let matches = allLanguages.filter { $0.lowercased().hasPrefix(input) }

            return .init(
                completion: .init(
                    values: matches,
                    total: matches.count,
                    hasMore: false
                )
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Test with "p" prefix
        let completion1 = try await client.complete(
            promptName: "language_selector",
            argumentName: "language",
            argumentValue: "p"
        )
        #expect(completion1.values.count == 5)  // python, perl, php, pascal, prolog

        // Test with "py" prefix
        let completion2 = try await client.complete(
            promptName: "language_selector",
            argumentName: "language",
            argumentValue: "py"
        )
        #expect(completion2.values == ["python"])

        // Test with "ja" prefix
        let completion3 = try await client.complete(
            promptName: "language_selector",
            argumentName: "language",
            argumentValue: "ja"
        )
        #expect(completion3.values == ["javascript", "java"])

        await client.disconnect()
        await server.stop()
    }
}
