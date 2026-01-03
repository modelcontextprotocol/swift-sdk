import Foundation
import Testing

@testable import MCP

/// Tests for completion (autocomplete) functionality.
///
/// These tests follow the patterns from:
/// - Python SDK: `tests/server/test_completion_with_context.py`
/// - TypeScript SDK: `packages/core/test/types.test.ts` (CompleteRequest tests)
/// - TypeScript SDK: `test/integration/test/server/mcp.test.ts` (completion integration tests)
@Suite("Completion Tests")
struct CompletionTests {

    // MARK: - Type Encoding/Decoding Tests

    @Test("PromptReference encoding and decoding")
    func testPromptReferenceEncodingDecoding() throws {
        let reference = PromptReference(name: "greeting")

        #expect(reference.type == "ref/prompt")
        #expect(reference.name == "greeting")
        #expect(reference.title == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(PromptReference.self, from: data)

        #expect(decoded.type == "ref/prompt")
        #expect(decoded.name == "greeting")
        #expect(decoded.title == nil)
    }

    @Test("PromptReference with title encoding and decoding")
    func testPromptReferenceWithTitleEncodingDecoding() throws {
        let reference = PromptReference(name: "greeting", title: "Send Greeting")

        #expect(reference.type == "ref/prompt")
        #expect(reference.name == "greeting")
        #expect(reference.title == "Send Greeting")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(PromptReference.self, from: data)

        #expect(decoded.type == "ref/prompt")
        #expect(decoded.name == "greeting")
        #expect(decoded.title == "Send Greeting")

        // Verify JSON structure includes title
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(jsonObject["type"] as? String == "ref/prompt")
        #expect(jsonObject["name"] as? String == "greeting")
        #expect(jsonObject["title"] as? String == "Send Greeting")
    }

    @Test("ResourceTemplateReference encoding and decoding")
    func testResourceTemplateReferenceEncodingDecoding() throws {
        let reference = ResourceTemplateReference(uri: "github://repos/{owner}/{repo}")

        #expect(reference.type == "ref/resource")
        #expect(reference.uri == "github://repos/{owner}/{repo}")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(ResourceTemplateReference.self, from: data)

        #expect(decoded.type == "ref/resource")
        #expect(decoded.uri == "github://repos/{owner}/{repo}")
    }

    @Test("CompletionReference prompt case encoding and decoding")
    func testCompletionReferencePromptCase() throws {
        let reference = CompletionReference.prompt(PromptReference(name: "test-prompt"))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(CompletionReference.self, from: data)

        if case .prompt(let promptRef) = decoded {
            #expect(promptRef.name == "test-prompt")
            #expect(promptRef.type == "ref/prompt")
        } else {
            Issue.record("Expected prompt reference")
        }
    }

    @Test("CompletionReference resource case encoding and decoding")
    func testCompletionReferenceResourceCase() throws {
        let reference = CompletionReference.resource(
            ResourceTemplateReference(uri: "file:///{path}")
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(CompletionReference.self, from: data)

        if case .resource(let resourceRef) = decoded {
            #expect(resourceRef.uri == "file:///{path}")
            #expect(resourceRef.type == "ref/resource")
        } else {
            Issue.record("Expected resource reference")
        }
    }

    @Test("CompletionReference decoding unknown type throws error")
    func testCompletionReferenceUnknownTypeThrows() throws {
        let json = """
            {"type":"ref/unknown","name":"test"}
            """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(CompletionReference.self, from: data)
        }
    }

    @Test("CompletionArgument encoding and decoding")
    func testCompletionArgumentEncodingDecoding() throws {
        let argument = CompletionArgument(name: "language", value: "py")

        #expect(argument.name == "language")
        #expect(argument.value == "py")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(argument)
        let decoded = try decoder.decode(CompletionArgument.self, from: data)

        #expect(decoded.name == "language")
        #expect(decoded.value == "py")
    }

    @Test("CompletionContext encoding and decoding with arguments")
    func testCompletionContextWithArguments() throws {
        let context = CompletionContext(arguments: [
            "owner": "modelcontextprotocol",
            "database": "users_db",
        ])

        #expect(context.arguments?["owner"] == "modelcontextprotocol")
        #expect(context.arguments?["database"] == "users_db")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(context)
        let decoded = try decoder.decode(CompletionContext.self, from: data)

        #expect(decoded.arguments?["owner"] == "modelcontextprotocol")
        #expect(decoded.arguments?["database"] == "users_db")
    }

    @Test("CompletionContext encoding and decoding without arguments")
    func testCompletionContextWithoutArguments() throws {
        let context = CompletionContext(arguments: nil)

        #expect(context.arguments == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(context)
        let decoded = try decoder.decode(CompletionContext.self, from: data)

        #expect(decoded.arguments == nil)
    }

    @Test("CompletionContext with empty arguments")
    func testCompletionContextWithEmptyArguments() throws {
        let context = CompletionContext(arguments: [:])

        #expect(context.arguments?.isEmpty == true)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(context)
        let decoded = try decoder.decode(CompletionContext.self, from: data)

        #expect(decoded.arguments?.isEmpty == true)
    }

    @Test("CompletionSuggestions encoding and decoding")
    func testCompletionSuggestionsEncodingDecoding() throws {
        let suggestions = CompletionSuggestions(
            values: ["python", "javascript", "typescript"],
            total: 10,
            hasMore: true
        )

        #expect(suggestions.values == ["python", "javascript", "typescript"])
        #expect(suggestions.total == 10)
        #expect(suggestions.hasMore == true)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(suggestions)
        let decoded = try decoder.decode(CompletionSuggestions.self, from: data)

        #expect(decoded.values == ["python", "javascript", "typescript"])
        #expect(decoded.total == 10)
        #expect(decoded.hasMore == true)
    }

    @Test("CompletionSuggestions with minimal fields")
    func testCompletionSuggestionsMinimal() throws {
        let suggestions = CompletionSuggestions(values: ["a", "b"])

        #expect(suggestions.values == ["a", "b"])
        #expect(suggestions.total == nil)
        #expect(suggestions.hasMore == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(suggestions)
        let decoded = try decoder.decode(CompletionSuggestions.self, from: data)

        #expect(decoded.values == ["a", "b"])
        #expect(decoded.total == nil)
        #expect(decoded.hasMore == nil)
    }

    // MARK: - Spec Compliance Tests (100-item limit)

    @Test("CompletionSuggestions maxValues constant is 100")
    func testMaxValuesConstant() {
        #expect(CompletionSuggestions.maxValues == 100)
    }

    @Test("CompletionSuggestions.empty returns empty result")
    func testEmptySuggestions() {
        let empty = CompletionSuggestions.empty

        #expect(empty.values.isEmpty)
        #expect(empty.total == nil)
        #expect(empty.hasMore == false)
    }

    @Test("CompletionSuggestions init truncates values over 100")
    func testInitTruncatesOverMaxValues() {
        // Create 150 values
        let allValues = (1...150).map { "value\($0)" }
        let suggestions = CompletionSuggestions(values: allValues, total: 150, hasMore: true)

        // Should be truncated to 100
        #expect(suggestions.values.count == 100)
        #expect(suggestions.values.first == "value1")
        #expect(suggestions.values.last == "value100")
        // User-specified total and hasMore are preserved
        #expect(suggestions.total == 150)
        #expect(suggestions.hasMore == true)
    }

    @Test("CompletionSuggestions init(from:) with few values")
    func testInitFromFewValues() {
        let values = ["python", "javascript", "typescript"]
        let suggestions = CompletionSuggestions(from: values)

        #expect(suggestions.values == values)
        #expect(suggestions.total == 3)
        #expect(suggestions.hasMore == false)
    }

    @Test("CompletionSuggestions init(from:) with exactly 100 values")
    func testInitFromExactly100Values() {
        let values = (1...100).map { "value\($0)" }
        let suggestions = CompletionSuggestions(from: values)

        #expect(suggestions.values.count == 100)
        #expect(suggestions.total == 100)
        #expect(suggestions.hasMore == false)
    }

    @Test("CompletionSuggestions init(from:) with over 100 values")
    func testInitFromOver100Values() {
        let values = (1...250).map { "value\($0)" }
        let suggestions = CompletionSuggestions(from: values)

        #expect(suggestions.values.count == 100)
        #expect(suggestions.values.first == "value1")
        #expect(suggestions.values.last == "value100")
        #expect(suggestions.total == 250)
        #expect(suggestions.hasMore == true)
    }

    @Test("CompletionSuggestions init(from:) with empty array")
    func testInitFromEmptyArray() {
        let suggestions = CompletionSuggestions(from: [])

        #expect(suggestions.values.isEmpty)
        #expect(suggestions.total == 0)
        #expect(suggestions.hasMore == false)
    }

    @Test("Complete.Result.empty returns empty result")
    func testCompleteResultEmpty() {
        let empty = Complete.Result.empty

        #expect(empty.completion.values.isEmpty)
        #expect(empty.completion.hasMore == false)
        #expect(empty._meta == nil)
        #expect(empty.extraFields == nil)
    }

    @Test("Complete.Result init(from:) convenience initializer")
    func testCompleteResultInitFrom() {
        let values = ["alice", "bob", "charlie"]
        let result = Complete.Result(from: values)

        #expect(result.completion.values == values)
        #expect(result.completion.total == 3)
        #expect(result.completion.hasMore == false)
        #expect(result._meta == nil)
        #expect(result.extraFields == nil)
    }

    @Test("Complete.Result init(from:) with over 100 values")
    func testCompleteResultInitFromOver100() {
        let values = (1...200).map { "item\($0)" }
        let result = Complete.Result(from: values)

        #expect(result.completion.values.count == 100)
        #expect(result.completion.total == 200)
        #expect(result.completion.hasMore == true)
    }

    // MARK: - Complete Request/Result Tests

    @Test("Complete.Parameters encoding without context")
    func testCompleteParametersWithoutContext() throws {
        let params = Complete.Parameters(
            ref: .prompt(PromptReference(name: "greeting")),
            argument: CompletionArgument(name: "name", value: "A")
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(Complete.Parameters.self, from: data)

        if case .prompt(let promptRef) = decoded.ref {
            #expect(promptRef.name == "greeting")
            #expect(promptRef.type == "ref/prompt")
        } else {
            Issue.record("Expected prompt reference")
        }
        #expect(decoded.argument.name == "name")
        #expect(decoded.argument.value == "A")
        #expect(decoded.context == nil)
    }

    @Test("Complete.Parameters encoding with context")
    func testCompleteParametersWithContext() throws {
        let params = Complete.Parameters(
            ref: .resource(ResourceTemplateReference(uri: "github://repos/{owner}/{repo}")),
            argument: CompletionArgument(name: "repo", value: "t"),
            context: CompletionContext(arguments: ["{owner}": "microsoft"])
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(Complete.Parameters.self, from: data)

        if case .resource(let resourceRef) = decoded.ref {
            #expect(resourceRef.uri == "github://repos/{owner}/{repo}")
        } else {
            Issue.record("Expected resource reference")
        }
        #expect(decoded.argument.name == "repo")
        #expect(decoded.argument.value == "t")
        #expect(decoded.context?.arguments?["{owner}"] == "microsoft")
    }

    @Test("Complete.Parameters with multiple resolved variables")
    func testCompleteParametersWithMultipleResolvedVariables() throws {
        let params = Complete.Parameters(
            ref: .resource(ResourceTemplateReference(uri: "api://v1/{tenant}/{resource}/{id}")),
            argument: CompletionArgument(name: "id", value: "123"),
            context: CompletionContext(arguments: [
                "{tenant}": "acme-corp",
                "{resource}": "users",
            ])
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(Complete.Parameters.self, from: data)

        #expect(decoded.context?.arguments?["{tenant}"] == "acme-corp")
        #expect(decoded.context?.arguments?["{resource}"] == "users")
    }

    @Test("Complete.Result encoding and decoding")
    func testCompleteResultEncodingDecoding() throws {
        let result = Complete.Result(
            completion: CompletionSuggestions(
                values: ["typescript-sdk", "python-sdk", "specification"],
                total: 3,
                hasMore: false
            )
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(Complete.Result.self, from: data)

        #expect(decoded.completion.values == ["typescript-sdk", "python-sdk", "specification"])
        #expect(decoded.completion.total == 3)
        #expect(decoded.completion.hasMore == false)
    }

    @Test("Complete request JSON-RPC format")
    func testCompleteRequestJsonRpcFormat() throws {
        let request = Complete.request(.init(
            ref: .prompt(PromptReference(name: "review_code")),
            argument: CompletionArgument(name: "language", value: "py")
        ))

        #expect(request.method == Complete.name)
        #expect(Complete.name == "completion/complete")

        // Verify it can roundtrip through JSON
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(Request<Complete>.self, from: data)

        #expect(decoded.method == "completion/complete")
        if case .prompt(let promptRef) = decoded.params.ref {
            #expect(promptRef.name == "review_code")
        } else {
            Issue.record("Expected prompt reference")
        }
    }

    // MARK: - Server Handler Integration Tests

    /// Actor to safely track received parameters across async closures
    private actor ReceivedParams {
        var ref: CompletionReference?
        var argument: CompletionArgument?
        var context: CompletionContext?
        var contextWasNil = false

        func set(ref: CompletionReference, argument: CompletionArgument, context: CompletionContext?) {
            self.ref = ref
            self.argument = argument
            self.context = context
            self.contextWasNil = context == nil
        }

        func getRef() -> CompletionReference? { ref }
        func getArgument() -> CompletionArgument? { argument }
        func getContext() -> CompletionContext? { context }
        func wasContextNil() -> Bool { contextWasNil }
    }

    @Test("Completion handler receives context correctly")
    func testCompletionHandlerReceivesContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Track what the handler receives
        let received = ReceivedParams()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        await server.withRequestHandler(Complete.self) { [received] params, _ in
            await received.set(ref: params.ref, argument: params.argument, context: params.context)
            return Complete.Result(
                completion: CompletionSuggestions(
                    values: ["test-completion"],
                    total: 1,
                    hasMore: false
                )
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Request completion with context
        let result = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "test://resource/{param}")),
            argument: CompletionArgument(name: "param", value: "test"),
            context: CompletionContext(arguments: ["previous": "value"])
        )

        // Verify handler received the context
        let receivedContext = await received.getContext()
        #expect(receivedContext != nil)
        #expect(receivedContext?.arguments?["previous"] == "value")
        #expect(result.values == ["test-completion"])

        // Verify the ref and argument were received correctly
        let receivedRef = await received.getRef()
        if case .resource(let resourceRef) = receivedRef {
            #expect(resourceRef.uri == "test://resource/{param}")
        } else {
            Issue.record("Expected resource reference")
        }
        let receivedArgument = await received.getArgument()
        #expect(receivedArgument?.name == "param")
        #expect(receivedArgument?.value == "test")

        await client.disconnect()
        await server.stop()
    }

    @Test("Completion works without context (backward compatibility)")
    func testCompletionBackwardCompatibility() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let received = ReceivedParams()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        await server.withRequestHandler(Complete.self) { [received] params, _ in
            await received.set(ref: params.ref, argument: params.argument, context: params.context)
            return Complete.Result(
                completion: CompletionSuggestions(
                    values: ["no-context-completion"],
                    total: 1,
                    hasMore: false
                )
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Request completion without context
        let result = try await client.complete(
            ref: .prompt(PromptReference(name: "test-prompt")),
            argument: CompletionArgument(name: "arg", value: "val")
        )

        #expect(await received.wasContextNil())
        #expect(result.values == ["no-context-completion"])

        await client.disconnect()
        await server.stop()
    }

    @Test("Dependent completion scenario (database/table)")
    func testDependentCompletionScenario() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        // Handler that returns different completions based on context
        await server.withRequestHandler(Complete.self) { params, _ in
            if case .resource(let resourceRef) = params.ref {
                if resourceRef.uri == "db://{database}/{table}" {
                    if params.argument.name == "database" {
                        // Complete database names
                        return Complete.Result(
                            completion: CompletionSuggestions(
                                values: ["users_db", "products_db", "analytics_db"],
                                total: 3,
                                hasMore: false
                            )
                        )
                    } else if params.argument.name == "table" {
                        // Complete table names based on selected database
                        let db = params.context?.arguments?["database"]
                        let tables: [String]
                        switch db {
                        case "users_db":
                            tables = ["users", "sessions", "permissions"]
                        case "products_db":
                            tables = ["products", "categories", "inventory"]
                        default:
                            tables = []
                        }
                        return Complete.Result(
                            completion: CompletionSuggestions(
                                values: tables,
                                total: tables.count,
                                hasMore: false
                            )
                        )
                    }
                }
            }
            return Complete.Result(
                completion: CompletionSuggestions(values: [], total: 0, hasMore: false)
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // First, complete database
        let dbResult = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "db://{database}/{table}")),
            argument: CompletionArgument(name: "database", value: "")
        )
        #expect(dbResult.values.contains("users_db"))
        #expect(dbResult.values.contains("products_db"))

        // Then complete table with database context
        let tableResult = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "db://{database}/{table}")),
            argument: CompletionArgument(name: "table", value: ""),
            context: CompletionContext(arguments: ["database": "users_db"])
        )
        #expect(tableResult.values == ["users", "sessions", "permissions"])

        // Different database gives different tables
        let tableResult2 = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "db://{database}/{table}")),
            argument: CompletionArgument(name: "table", value: ""),
            context: CompletionContext(arguments: ["database": "products_db"])
        )
        #expect(tableResult2.values == ["products", "categories", "inventory"])

        await client.disconnect()
        await server.stop()
    }

    @Test("Completion error handling when context is required")
    func testCompletionErrorOnMissingContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        await server.withRequestHandler(Complete.self) { params, _ in
            if case .resource(let resourceRef) = params.ref {
                if resourceRef.uri == "db://{database}/{table}" && params.argument.name == "table" {
                    // Check if database context is provided
                    guard let arguments = params.context?.arguments,
                        arguments["database"] != nil
                    else {
                        throw MCPError.invalidParams(
                            "Please select a database first to see available tables")
                    }
                    // Return completions if context is provided
                    return Complete.Result(
                        completion: CompletionSuggestions(
                            values: ["users", "orders", "products"],
                            total: 3,
                            hasMore: false
                        )
                    )
                }
            }
            return Complete.Result(
                completion: CompletionSuggestions(values: [], total: 0, hasMore: false)
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Try to complete table without database context - should fail
        do {
            _ = try await client.complete(
                ref: .resource(ResourceTemplateReference(uri: "db://{database}/{table}")),
                argument: CompletionArgument(name: "table", value: "")
            )
            Issue.record("Expected error for missing context")
        } catch {
            let errorMessage = String(describing: error)
            #expect(errorMessage.contains("database") || errorMessage.contains("select"))
        }

        // Now complete with proper context - should work
        let result = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "db://{database}/{table}")),
            argument: CompletionArgument(name: "table", value: ""),
            context: CompletionContext(arguments: ["database": "test_db"])
        )
        #expect(result.values == ["users", "orders", "products"])

        await client.disconnect()
        await server.stop()
    }

    @Test("Prompt completion with filtered results")
    func testPromptCompletionWithFilteredResults() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        await server.withRequestHandler(Complete.self) { params, _ in
            if case .prompt(let promptRef) = params.ref {
                if promptRef.name == "review_code" && params.argument.name == "language" {
                    let allLanguages = ["python", "javascript", "typescript", "java", "go", "rust"]
                    let filtered = allLanguages.filter { $0.hasPrefix(params.argument.value) }
                    return Complete.Result(
                        completion: CompletionSuggestions(
                            values: filtered,
                            total: filtered.count,
                            hasMore: false
                        )
                    )
                }
            }
            return Complete.Result(
                completion: CompletionSuggestions(values: [], total: 0, hasMore: false)
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Request completion with "py" prefix
        let result = try await client.complete(
            ref: .prompt(PromptReference(name: "review_code")),
            argument: CompletionArgument(name: "language", value: "py")
        )

        #expect(result.values == ["python"])

        // Request completion with "j" prefix
        let result2 = try await client.complete(
            ref: .prompt(PromptReference(name: "review_code")),
            argument: CompletionArgument(name: "language", value: "j")
        )

        #expect(result2.values.contains("javascript"))
        #expect(result2.values.contains("java"))
        #expect(result2.values.allSatisfy { $0.hasPrefix("j") })

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Capability Tests

    @Test("Server advertises completions capability")
    func testServerAdvertisesCompletionsCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        await server.withRequestHandler(Complete.self) { _, _ in
            Complete.Result(completion: CompletionSuggestions(values: []))
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        #expect(initResult.capabilities.completions != nil)

        await client.disconnect()
        await server.stop()
    }

    @Test("Server without completions capability does not advertise it")
    func testServerWithoutCompletionsCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server without completions capability
        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(tools: .init())  // Only tools, no completions
        )

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        #expect(initResult.capabilities.completions == nil)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client in strict mode rejects completion when server lacks capability")
    func testStrictClientRejectsCompletionWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server without completions capability
        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        try await server.start(transport: serverTransport)

        let client = Client(
            name: "test-client",
            version: "1.0.0",
            configuration: .init(strict: true)
        )
        _ = try await client.connect(transport: clientTransport)

        // Attempt to complete should throw
        do {
            _ = try await client.complete(
                ref: .prompt(PromptReference(name: "test")),
                argument: CompletionArgument(name: "arg", value: "")
            )
            Issue.record("Expected error when server lacks completions capability")
        } catch let error as MCPError {
            if case .methodNotFound(let message) = error {
                let msg = message ?? ""
                #expect(msg.contains("Completions") || msg.contains("not supported"))
            } else {
                Issue.record("Expected methodNotFound error, got: \(error)")
            }
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Resource Template Completion Tests

    @Test("Resource template completion with context")
    func testResourceTemplateCompletionWithContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        // Simulate GitHub repos completion based on owner
        await server.withRequestHandler(Complete.self) { params, _ in
            if case .resource(let resourceRef) = params.ref,
                resourceRef.uri == "github://repos/{owner}/{repo}"
            {
                let owner = params.context?.arguments?["owner"]
                let repos: [String]
                switch owner {
                case "modelcontextprotocol":
                    repos = ["python-sdk", "typescript-sdk", "specification"]
                case "microsoft":
                    repos = ["vscode", "typescript", "playwright"]
                case "facebook":
                    repos = ["react", "react-native", "jest"]
                default:
                    repos = ["repo1", "repo2", "repo3"]
                }
                return Complete.Result(
                    completion: CompletionSuggestions(
                        values: repos,
                        total: repos.count,
                        hasMore: false
                    )
                )
            }
            return Complete.Result(
                completion: CompletionSuggestions(values: [], total: 0, hasMore: false)
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Test with modelcontextprotocol owner
        let result1 = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "github://repos/{owner}/{repo}")),
            argument: CompletionArgument(name: "repo", value: ""),
            context: CompletionContext(arguments: ["owner": "modelcontextprotocol"])
        )
        #expect(result1.values.contains("python-sdk"))
        #expect(result1.values.contains("typescript-sdk"))
        #expect(result1.values.contains("specification"))
        #expect(result1.total == 3)

        // Test with microsoft owner
        let result2 = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "github://repos/{owner}/{repo}")),
            argument: CompletionArgument(name: "repo", value: ""),
            context: CompletionContext(arguments: ["owner": "microsoft"])
        )
        #expect(result2.values.contains("vscode"))
        #expect(result2.values.contains("typescript"))
        #expect(result2.values.contains("playwright"))

        // Test with no context
        let result3 = try await client.complete(
            ref: .resource(ResourceTemplateReference(uri: "github://repos/{owner}/{repo}")),
            argument: CompletionArgument(name: "repo", value: "")
        )
        #expect(result3.values == ["repo1", "repo2", "repo3"])

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Prompt Completion with Context Tests

    @Test("Prompt argument completion with resolved context")
    func testPromptArgumentCompletionWithResolvedContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(completions: .init())
        )

        // Simulate team member completion based on department
        await server.withRequestHandler(Complete.self) { params, _ in
            if case .prompt(let promptRef) = params.ref,
                promptRef.name == "team-greeting",
                params.argument.name == "name"
            {
                let department = params.context?.arguments?["department"]
                let value = params.argument.value
                let names: [String]
                switch department {
                case "engineering":
                    names = ["Alice", "Bob", "Charlie"]
                case "sales":
                    names = ["David", "Eve", "Frank"]
                case "marketing":
                    names = ["Grace", "Henry", "Ivy"]
                default:
                    names = ["Unknown1", "Unknown2"]
                }
                let filtered = names.filter { $0.lowercased().hasPrefix(value.lowercased()) }
                return Complete.Result(
                    completion: CompletionSuggestions(
                        values: filtered,
                        total: filtered.count,
                        hasMore: false
                    )
                )
            }
            return Complete.Result(
                completion: CompletionSuggestions(values: [], total: 0, hasMore: false)
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Test with engineering department
        let result1 = try await client.complete(
            ref: .prompt(PromptReference(name: "team-greeting")),
            argument: CompletionArgument(name: "name", value: "A"),
            context: CompletionContext(arguments: ["department": "engineering"])
        )
        #expect(result1.values == ["Alice"])

        // Test with sales department
        let result2 = try await client.complete(
            ref: .prompt(PromptReference(name: "team-greeting")),
            argument: CompletionArgument(name: "name", value: "D"),
            context: CompletionContext(arguments: ["department": "sales"])
        )
        #expect(result2.values == ["David"])

        // Test with marketing department
        let result3 = try await client.complete(
            ref: .prompt(PromptReference(name: "team-greeting")),
            argument: CompletionArgument(name: "name", value: "G"),
            context: CompletionContext(arguments: ["department": "marketing"])
        )
        #expect(result3.values == ["Grace"])

        // Test with no context
        let result4 = try await client.complete(
            ref: .prompt(PromptReference(name: "team-greeting")),
            argument: CompletionArgument(name: "name", value: "U")
        )
        #expect(result4.values.contains("Unknown1"))
        #expect(result4.values.contains("Unknown2"))

        await client.disconnect()
        await server.stop()
    }
}
