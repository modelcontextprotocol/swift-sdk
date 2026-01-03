import Foundation
import Testing

@testable import MCP

// MARK: - Client Capabilities Encoding Tests

@Suite("Client Capabilities Encoding Tests")
struct ClientCapabilitiesEncodingTests {

    @Test("Empty client capabilities encodes correctly")
    func testEmptyClientCapabilities() throws {
        let capabilities = Client.Capabilities()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Empty capabilities should encode to empty object
        #expect(json == "{}")

        // Verify roundtrip
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.sampling == nil)
        #expect(decoded.elicitation == nil)
        #expect(decoded.roots == nil)
        #expect(decoded.experimental == nil)
        #expect(decoded.tasks == nil)
    }

    @Test("Client capabilities with roots encodes correctly")
    func testClientCapabilitiesWithRoots() throws {
        let capabilities = Client.Capabilities(
            roots: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"roots\""))
        #expect(json.contains("\"listChanged\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.roots?.listChanged == true)
    }

    @Test("Client capabilities with experimental encodes correctly")
    func testClientCapabilitiesWithExperimental() throws {
        let capabilities = Client.Capabilities(
            experimental: [
                "feature": [
                    "enabled": .bool(true),
                    "count": .int(42)
                ]
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"experimental\""))
        #expect(json.contains("\"feature\""))
        #expect(json.contains("\"enabled\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.experimental?["feature"]?["enabled"] == .bool(true))
        #expect(decoded.experimental?["feature"]?["count"] == .int(42))
    }

    @Test("Client capabilities all fields roundtrip")
    func testClientCapabilitiesAllFieldsRoundtrip() throws {
        let capabilities = Client.Capabilities(
            sampling: .init(context: .init(), tools: .init()),
            elicitation: .init(form: .init(applyDefaults: true), url: .init()),
            experimental: ["test": ["value": .string("data")]],
            roots: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded.sampling?.context != nil)
        #expect(decoded.sampling?.tools != nil)
        #expect(decoded.elicitation?.form?.applyDefaults == true)
        #expect(decoded.elicitation?.url != nil)
        #expect(decoded.experimental?["test"]?["value"] == .string("data"))
        #expect(decoded.roots?.listChanged == true)
    }
}

// MARK: - Server Capabilities Encoding Tests

@Suite("Server Capabilities Encoding Tests")
struct ServerCapabilitiesEncodingTests {

    @Test("Empty server capabilities encodes correctly")
    func testEmptyServerCapabilities() throws {
        let capabilities = Server.Capabilities()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Empty capabilities should encode to empty object
        #expect(json == "{}")

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.logging == nil)
        #expect(decoded.prompts == nil)
        #expect(decoded.resources == nil)
        #expect(decoded.tools == nil)
        #expect(decoded.completions == nil)
        #expect(decoded.experimental == nil)
    }

    @Test("Server capabilities with logging encodes correctly")
    func testServerCapabilitiesWithLogging() throws {
        let capabilities = Server.Capabilities(
            logging: .init()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"logging\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.logging != nil)
    }

    @Test("Server capabilities with prompts listChanged true")
    func testServerCapabilitiesWithPromptsListChangedTrue() throws {
        let capabilities = Server.Capabilities(
            prompts: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"prompts\""))
        #expect(json.contains("\"listChanged\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.prompts?.listChanged == true)
    }

    @Test("Server capabilities with prompts listChanged false")
    func testServerCapabilitiesWithPromptsListChangedFalse() throws {
        let capabilities = Server.Capabilities(
            prompts: .init(listChanged: false)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.prompts?.listChanged == false)
    }

    @Test("Server capabilities with resources encodes correctly")
    func testServerCapabilitiesWithResources() throws {
        let capabilities = Server.Capabilities(
            resources: .init(subscribe: true, listChanged: true)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"resources\""))
        #expect(json.contains("\"subscribe\":true"))
        #expect(json.contains("\"listChanged\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.resources?.subscribe == true)
        #expect(decoded.resources?.listChanged == true)
    }

    @Test("Server capabilities with tools listChanged")
    func testServerCapabilitiesWithToolsListChanged() throws {
        let capabilities = Server.Capabilities(
            tools: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.tools?.listChanged == true)
    }

    @Test("Server capabilities with completions encodes correctly")
    func testServerCapabilitiesWithCompletions() throws {
        let capabilities = Server.Capabilities(
            completions: .init()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"completions\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.completions != nil)
    }

    @Test("Server capabilities with experimental encodes correctly")
    func testServerCapabilitiesWithExperimental() throws {
        let capabilities = Server.Capabilities(
            experimental: [
                "customFeature": [
                    "supported": .bool(true)
                ]
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"experimental\""))
        #expect(json.contains("\"customFeature\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.experimental?["customFeature"]?["supported"] == .bool(true))
    }

    @Test("Server capabilities all fields roundtrip")
    func testServerCapabilitiesAllFieldsRoundtrip() throws {
        let capabilities = Server.Capabilities(
            logging: .init(),
            prompts: .init(listChanged: true),
            resources: .init(subscribe: true, listChanged: true),
            tools: .init(listChanged: false),
            completions: .init(),
            experimental: ["test": ["enabled": .bool(true)]]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)

        #expect(decoded.logging != nil)
        #expect(decoded.prompts?.listChanged == true)
        #expect(decoded.resources?.subscribe == true)
        #expect(decoded.resources?.listChanged == true)
        #expect(decoded.tools?.listChanged == false)
        #expect(decoded.completions != nil)
        #expect(decoded.experimental?["test"]?["enabled"] == .bool(true))
    }
}

// MARK: - Initialize Request Encoding Tests

@Suite("Initialize Request Encoding Tests")
struct InitializeRequestEncodingTests {

    @Test("Initialize parameters encodes with capabilities")
    func testInitializeParametersEncoding() throws {
        let params = Initialize.Parameters(
            protocolVersion: Version.latest,
            capabilities: Client.Capabilities(
                sampling: .init(tools: .init()),
                roots: .init(listChanged: true)
            ),
            clientInfo: Client.Info(name: "TestClient", version: "1.0.0")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(params)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"protocolVersion\":\"\(Version.latest)\""))
        #expect(json.contains("\"clientInfo\""))
        #expect(json.contains("\"name\":\"TestClient\""))
        #expect(json.contains("\"capabilities\""))
        #expect(json.contains("\"sampling\""))
        #expect(json.contains("\"roots\""))
    }

    @Test("Initialize parameters decodes correctly")
    func testInitializeParametersDecoding() throws {
        let json = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "sampling": {"tools": {}},
                "roots": {"listChanged": true}
            },
            "clientInfo": {
                "name": "TestClient",
                "version": "1.0.0"
            }
        }
        """

        let decoder = JSONDecoder()
        let params = try decoder.decode(Initialize.Parameters.self, from: json.data(using: .utf8)!)

        #expect(params.protocolVersion == Version.v2025_11_25)
        #expect(params.capabilities.sampling?.tools != nil)
        #expect(params.capabilities.roots?.listChanged == true)
        #expect(params.clientInfo.name == "TestClient")
        #expect(params.clientInfo.version == "1.0.0")
    }

    @Test("Initialize parameters defaults when fields missing")
    func testInitializeParametersDefaults() throws {
        let json = "{}"

        let decoder = JSONDecoder()
        let params = try decoder.decode(Initialize.Parameters.self, from: json.data(using: .utf8)!)

        // Should use defaults
        #expect(params.protocolVersion == Version.latest)
        #expect(params.clientInfo.name == "unknown")
        #expect(params.clientInfo.version == "0.0.0")
    }

    @Test("Initialize result encodes with server capabilities")
    func testInitializeResultEncoding() throws {
        let result = Initialize.Result(
            protocolVersion: Version.latest,
            capabilities: Server.Capabilities(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: false)
            ),
            serverInfo: Server.Info(name: "TestServer", version: "2.0.0"),
            instructions: "Server instructions."
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(result)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"protocolVersion\":\"\(Version.latest)\""))
        #expect(json.contains("\"serverInfo\""))
        #expect(json.contains("\"name\":\"TestServer\""))
        #expect(json.contains("\"instructions\":\"Server instructions.\""))
        #expect(json.contains("\"capabilities\""))
        #expect(json.contains("\"logging\""))
        #expect(json.contains("\"prompts\""))
        #expect(json.contains("\"resources\""))
        #expect(json.contains("\"tools\""))
    }

    @Test("Initialize result decodes correctly")
    func testInitializeResultDecoding() throws {
        let json = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "logging": {},
                "prompts": {"listChanged": true},
                "resources": {"subscribe": true, "listChanged": true},
                "tools": {"listChanged": false}
            },
            "serverInfo": {
                "name": "TestServer",
                "version": "2.0.0"
            },
            "instructions": "Server instructions."
        }
        """

        let decoder = JSONDecoder()
        let result = try decoder.decode(Initialize.Result.self, from: json.data(using: .utf8)!)

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(result.capabilities.logging != nil)
        #expect(result.capabilities.prompts?.listChanged == true)
        #expect(result.capabilities.resources?.subscribe == true)
        #expect(result.capabilities.resources?.listChanged == true)
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.serverInfo.name == "TestServer")
        #expect(result.serverInfo.version == "2.0.0")
        #expect(result.instructions == "Server instructions.")
    }

    @Test("Initialize result roundtrip")
    func testInitializeResultRoundtrip() throws {
        let original = Initialize.Result(
            protocolVersion: Version.latest,
            capabilities: Server.Capabilities(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: false),
                completions: .init()
            ),
            serverInfo: Server.Info(
                name: "TestServer",
                version: "2.0.0",
                title: "Test Server Title",
                description: "A test server"
            ),
            instructions: "Follow these instructions."
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Initialize.Result.self, from: data)

        #expect(decoded.protocolVersion == original.protocolVersion)
        #expect(decoded.capabilities.logging != nil)
        #expect(decoded.capabilities.prompts?.listChanged == true)
        #expect(decoded.capabilities.resources?.subscribe == true)
        #expect(decoded.capabilities.tools?.listChanged == false)
        #expect(decoded.capabilities.completions != nil)
        #expect(decoded.serverInfo.name == original.serverInfo.name)
        #expect(decoded.serverInfo.version == original.serverInfo.version)
        #expect(decoded.serverInfo.title == original.serverInfo.title)
        #expect(decoded.serverInfo.description == original.serverInfo.description)
        #expect(decoded.instructions == original.instructions)
    }
}

// MARK: - Capability Negotiation Integration Tests

@Suite("Capability Negotiation Integration Tests")
struct CapabilityNegotiationTests {

    @Test("Client sends capabilities to server during initialization")
    func testClientSendsCapabilitiesToServer() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Set up server with specific capabilities
        let server = Server(
            name: "CapabilityTestServer",
            version: "1.0.0",
            capabilities: .init(
                logging: .init(),
                prompts: .init(listChanged: true),
                tools: .init()
            )
        )

        // Register a tools handler
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Set up client with specific capabilities
        let client = Client(
            name: "CapabilityTestClient",
            version: "1.0.0"
        )

        // Set capabilities before connecting
        await client.setCapabilities(.init(
            sampling: .init(tools: .init()),
            roots: .init(listChanged: true)
        ))

        // Connect and verify
        try await client.connect(transport: clientTransport)

        // Verify the server is running correctly
        let tools = try await client.listTools()
        // Just verify the connection works - server has no tools registered
        #expect(tools.tools.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test("Server responds with its capabilities")
    func testServerRespondsWithCapabilities() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Set up server with all capabilities
        let server = Server(
            name: "FullCapabilityServer",
            version: "1.0.0",
            capabilities: .init(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true),
                completions: .init()
            )
        )

        // Register handlers for capabilities that require them
        await server.withRequestHandler(ListPrompts.self) { _, _ in
            ListPrompts.Result(prompts: [])
        }
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [])
        }
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Set up client
        let client = Client(
            name: "TestClient",
            version: "1.0.0"
        )

        try await client.connect(transport: clientTransport)

        // Verify we can use the capabilities
        let prompts = try await client.listPrompts()
        #expect(prompts.prompts.isEmpty)

        let resources = try await client.listResources()
        #expect(resources.resources.isEmpty)

        let tools = try await client.listTools()
        #expect(tools.tools.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client in strict mode fails on missing capability")
    func testStrictModeFailsOnMissingCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server without completions capability
        let server = Server(
            name: "LimitedServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Client in strict mode
        let client = Client(
            name: "StrictClient",
            version: "1.0.0",
            configuration: .strict
        )

        try await client.connect(transport: clientTransport)

        // Attempting to use completions should fail
        do {
            let _ = try await client.complete(
                ref: .prompt(PromptReference(name: "test")),
                argument: CompletionArgument(name: "arg", value: "val")
            )
            #expect(Bool(false), "Should have thrown error")
        } catch {
            // Expected to fail
            #expect(error is MCPError)
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("getServerCapabilities returns nil before connect")
    func testGetServerCapabilitiesReturnsNilBeforeConnect() async throws {
        let client = Client(
            name: "TestClient",
            version: "1.0.0"
        )

        // Before connecting, server capabilities should be nil
        let capabilities = await client.getServerCapabilities()
        #expect(capabilities == nil)
    }

    @Test("getServerCapabilities returns capabilities after connect")
    func testGetServerCapabilitiesReturnsCapabilitiesAfterConnect() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Set up server with specific capabilities
        let server = Server(
            name: "CapabilityServer",
            version: "1.0.0",
            capabilities: .init(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: false),
                tools: .init(listChanged: true)
            )
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(
            name: "TestClient",
            version: "1.0.0"
        )

        // Before connecting
        let beforeCapabilities = await client.getServerCapabilities()
        #expect(beforeCapabilities == nil)

        // Connect
        try await client.connect(transport: clientTransport)

        // After connecting, should have server capabilities
        let afterCapabilities = await client.getServerCapabilities()
        #expect(afterCapabilities != nil)
        #expect(afterCapabilities?.logging != nil)
        #expect(afterCapabilities?.prompts?.listChanged == true)
        #expect(afterCapabilities?.resources?.subscribe == true)
        #expect(afterCapabilities?.resources?.listChanged == false)
        #expect(afterCapabilities?.tools?.listChanged == true)

        await client.disconnect()
        await server.stop()
    }
}

// MARK: - JSON Format Compatibility Tests

@Suite("Capability JSON Format Compatibility Tests")
struct CapabilityJSONCompatibilityTests {

    @Test("Client capabilities matches TypeScript format")
    func testClientCapabilitiesMatchesTypeScriptFormat() throws {
        // TypeScript format: { "sampling": {}, "roots": { "listChanged": true } }
        let typeScriptJSON = """
        {"sampling":{},"roots":{"listChanged":true}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!)

        #expect(capabilities.sampling != nil)
        #expect(capabilities.roots?.listChanged == true)

        // Encode and verify format
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Should match the TypeScript format
        #expect(json.contains("\"sampling\":{}"))
        #expect(json.contains("\"roots\":{\"listChanged\":true}"))
    }

    @Test("Server capabilities matches TypeScript format")
    func testServerCapabilitiesMatchesTypeScriptFormat() throws {
        // TypeScript format from protocol.test.ts
        let typeScriptJSON = """
        {"logging":{},"prompts":{"listChanged":true},"resources":{"subscribe":true},"tools":{"listChanged":false}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Server.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!)

        #expect(capabilities.logging != nil)
        #expect(capabilities.prompts?.listChanged == true)
        #expect(capabilities.resources?.subscribe == true)
        #expect(capabilities.tools?.listChanged == false)
    }

    @Test("Client elicitation capability with form matches TypeScript format")
    func testClientElicitationFormMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "form": {} } }
        let typeScriptJSON = """
        {"elicitation":{"form":{}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!)

        #expect(capabilities.elicitation?.form != nil)
        #expect(capabilities.elicitation?.url == nil)
    }

    @Test("Client elicitation capability with form applyDefaults matches TypeScript format")
    func testClientElicitationFormApplyDefaultsMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "form": { "applyDefaults": true } } }
        let typeScriptJSON = """
        {"elicitation":{"form":{"applyDefaults":true}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!)

        #expect(capabilities.elicitation?.form?.applyDefaults == true)
    }

    @Test("Client elicitation capability with url matches TypeScript format")
    func testClientElicitationURLMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "url": {} } }
        let typeScriptJSON = """
        {"elicitation":{"url":{}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!)

        #expect(capabilities.elicitation?.form == nil)
        #expect(capabilities.elicitation?.url != nil)
    }

    @Test("Client elicitation capability with both form and url matches TypeScript format")
    func testClientElicitationBothMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "form": {}, "url": {} } }
        let typeScriptJSON = """
        {"elicitation":{"form":{},"url":{}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!)

        #expect(capabilities.elicitation?.form != nil)
        #expect(capabilities.elicitation?.url != nil)
    }

    @Test("Initialize request matches Python format")
    func testInitializeRequestMatchesPythonFormat() throws {
        // Python format from test_session.py
        let pythonJSON = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "sampling": {}
            },
            "clientInfo": {
                "name": "mcp-client",
                "version": "0.1.0"
            }
        }
        """

        let decoder = JSONDecoder()
        let params = try decoder.decode(Initialize.Parameters.self, from: pythonJSON.data(using: .utf8)!)

        #expect(params.protocolVersion == Version.v2025_11_25)
        #expect(params.capabilities.sampling != nil)
        #expect(params.clientInfo.name == "mcp-client")
        #expect(params.clientInfo.version == "0.1.0")
    }

    @Test("Initialize result matches Python format")
    func testInitializeResultMatchesPythonFormat() throws {
        // Python format from test_session.py
        let pythonJSON = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "logging": {},
                "prompts": {"listChanged": true},
                "resources": {"subscribe": true, "listChanged": true},
                "tools": {"listChanged": false}
            },
            "serverInfo": {
                "name": "mock-server",
                "version": "0.1.0"
            },
            "instructions": "The server instructions."
        }
        """

        let decoder = JSONDecoder()
        let result = try decoder.decode(Initialize.Result.self, from: pythonJSON.data(using: .utf8)!)

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(result.capabilities.logging != nil)
        #expect(result.capabilities.prompts?.listChanged == true)
        #expect(result.capabilities.resources?.subscribe == true)
        #expect(result.capabilities.resources?.listChanged == true)
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.serverInfo.name == "mock-server")
        #expect(result.serverInfo.version == "0.1.0")
        #expect(result.instructions == "The server instructions.")
    }
}

// MARK: - Sampling Capability Tests (additional coverage)

@Suite("Sampling Capability Encoding Tests")
struct SamplingCapabilityEncodingTests {

    @Test("Client sampling with no sub-capabilities encodes correctly")
    func testClientSamplingBasic() throws {
        let capabilities = Client.Capabilities(
            sampling: .init()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Should have empty sampling object
        #expect(json == "{\"sampling\":{}}")

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.sampling != nil)
        #expect(decoded.sampling?.tools == nil)
        #expect(decoded.sampling?.context == nil)
    }
}

// MARK: - Tasks Capability Tests

@Suite("Tasks Capability Encoding Tests")
struct TasksCapabilityEncodingTests {

    @Test("Server tasks capability encodes correctly")
    func testServerTasksCapability() throws {
        let capabilities = Server.Capabilities(
            tasks: .init(
                list: .init(),
                cancel: .init(),
                requests: .init(tools: .init(call: .init()))
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"tasks\""))
        #expect(json.contains("\"list\""))
        #expect(json.contains("\"cancel\""))
        #expect(json.contains("\"requests\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.tasks != nil)
        #expect(decoded.tasks?.list != nil)
        #expect(decoded.tasks?.cancel != nil)
        #expect(decoded.tasks?.requests?.tools?.call != nil)
    }

    @Test("Client tasks capability encodes correctly")
    func testClientTasksCapability() throws {
        let capabilities = Client.Capabilities(
            tasks: .init(
                list: .init(),
                cancel: .init()
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"tasks\""))
        #expect(json.contains("\"list\""))
        #expect(json.contains("\"cancel\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.tasks != nil)
        #expect(decoded.tasks?.list != nil)
        #expect(decoded.tasks?.cancel != nil)
    }
}
