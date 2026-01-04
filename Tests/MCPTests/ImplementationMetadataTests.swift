import Foundation
import Testing

@testable import MCP

// MARK: - Server.Info Metadata Tests

@Suite("Server.Info Metadata Tests")
struct ServerInfoMetadataTests {

    @Test("Server.Info with all fields encodes correctly")
    func testServerInfoWithAllFields() throws {
        let icons = [
            Icon(
                src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                mimeType: "image/png",
                sizes: ["1x1"]
            )
        ]

        let info = Server.Info(
            name: "test-server",
            version: "1.0.0",
            title: "Test Server Display Name",
            description: "A test server for unit testing",
            icons: icons,
            websiteUrl: "https://example.com"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(info)

        // Decode and verify fields directly (avoids JSON escaping issues)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Info.self, from: data)

        #expect(decoded.name == "test-server")
        #expect(decoded.version == "1.0.0")
        #expect(decoded.title == "Test Server Display Name")
        #expect(decoded.description == "A test server for unit testing")
        #expect(decoded.websiteUrl == "https://example.com")
        #expect(decoded.icons?.count == 1)
        #expect(decoded.icons?[0].mimeType == "image/png")
    }

    @Test("Server.Info with only required fields encodes correctly")
    func testServerInfoWithRequiredFieldsOnly() throws {
        let info = Server.Info(name: "basic-server", version: "0.1.0")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(info)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"name\":\"basic-server\""))
        #expect(json.contains("\"version\":\"0.1.0\""))
        // Optional fields should not be present when nil
        #expect(!json.contains("\"title\""))
        #expect(!json.contains("\"description\""))
        #expect(!json.contains("\"icons\""))
        #expect(!json.contains("\"websiteUrl\""))
    }

    @Test("Server.Info roundtrips correctly with all fields")
    func testServerInfoRoundtrip() throws {
        let original = Server.Info(
            name: "roundtrip-server",
            version: "2.0.0",
            title: "Roundtrip Test Server",
            description: "Testing roundtrip encoding",
            icons: [
                Icon(src: "https://example.com/icon.png", mimeType: "image/png", sizes: ["48x48"], theme: .light),
                Icon(src: "https://example.com/icon-dark.png", mimeType: "image/png", sizes: ["48x48"], theme: .dark)
            ],
            websiteUrl: "https://example.com/server"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Server.Info.self, from: data)

        #expect(decoded.name == original.name)
        #expect(decoded.version == original.version)
        #expect(decoded.title == original.title)
        #expect(decoded.description == original.description)
        #expect(decoded.websiteUrl == original.websiteUrl)
        #expect(decoded.icons?.count == 2)
        #expect(decoded.icons?[0].theme == .light)
        #expect(decoded.icons?[1].theme == .dark)
    }

    @Test("Server.Info decodes from TypeScript SDK format")
    func testServerInfoDecodesFromTypeScriptFormat() throws {
        // Format matching TypeScript SDK title.test.ts
        let json = """
        {
            "name": "test-server",
            "version": "1.0.0",
            "title": "Test Server Display Name"
        }
        """

        let decoder = JSONDecoder()
        let info = try decoder.decode(Server.Info.self, from: json.data(using: .utf8)!)

        #expect(info.name == "test-server")
        #expect(info.version == "1.0.0")
        #expect(info.title == "Test Server Display Name")
    }

    @Test("Server.Info decodes from Python SDK format with icons")
    func testServerInfoDecodesFromPythonFormat() throws {
        // Format matching Python SDK test_1338_icons_and_metadata.py
        let json = """
        {
            "name": "TestServer",
            "version": "1.0.0",
            "websiteUrl": "https://example.com",
            "icons": [
                {
                    "src": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                    "mimeType": "image/png",
                    "sizes": ["1x1"]
                }
            ]
        }
        """

        let decoder = JSONDecoder()
        let info = try decoder.decode(Server.Info.self, from: json.data(using: .utf8)!)

        #expect(info.name == "TestServer")
        #expect(info.version == "1.0.0")
        #expect(info.websiteUrl == "https://example.com")
        #expect(info.icons?.count == 1)
        #expect(info.icons?[0].mimeType == "image/png")
        #expect(info.icons?[0].sizes == ["1x1"])
    }
}

// MARK: - Client.Info Metadata Tests

@Suite("Client.Info Metadata Tests")
struct ClientInfoMetadataTests {

    @Test("Client.Info with all fields encodes correctly")
    func testClientInfoWithAllFields() throws {
        let info = Client.Info(
            name: "test-client",
            version: "1.0.0",
            title: "Test Client Display Name",
            description: "A test client for unit testing",
            icons: [Icon(src: "https://example.com/client-icon.png", mimeType: "image/png")],
            websiteUrl: "https://example.com/client"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(info)

        // Decode and verify fields directly (avoids JSON escaping issues)
        let decoded = try decoder.decode(Client.Info.self, from: data)

        #expect(decoded.name == "test-client")
        #expect(decoded.version == "1.0.0")
        #expect(decoded.title == "Test Client Display Name")
        #expect(decoded.description == "A test client for unit testing")
        #expect(decoded.websiteUrl == "https://example.com/client")
        #expect(decoded.icons?.count == 1)
    }

    @Test("Client.Info with only required fields encodes correctly")
    func testClientInfoWithRequiredFieldsOnly() throws {
        let info = Client.Info(name: "basic-client", version: "0.1.0")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(info)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"name\":\"basic-client\""))
        #expect(json.contains("\"version\":\"0.1.0\""))
        #expect(!json.contains("\"title\""))
        #expect(!json.contains("\"description\""))
        #expect(!json.contains("\"icons\""))
        #expect(!json.contains("\"websiteUrl\""))
    }

    @Test("Client.Info decodes from Python SDK format")
    func testClientInfoDecodesFromPythonFormat() throws {
        // Format matching Python SDK test_session.py custom_client_info
        let json = """
        {
            "name": "test-client",
            "version": "1.2.3"
        }
        """

        let decoder = JSONDecoder()
        let info = try decoder.decode(Client.Info.self, from: json.data(using: .utf8)!)

        #expect(info.name == "test-client")
        #expect(info.version == "1.2.3")
    }
}

// MARK: - Icon Type Tests

@Suite("Icon Type Tests")
struct IconTypeTests {

    @Test("Icon with all fields encodes correctly")
    func testIconWithAllFields() throws {
        let icon = Icon(
            src: "https://example.com/icon.png",
            mimeType: "image/png",
            sizes: ["48x48", "96x96"],
            theme: .light
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(icon)

        // Decode and verify fields directly (avoids JSON escaping issues)
        let decoded = try decoder.decode(Icon.self, from: data)

        #expect(decoded.src == "https://example.com/icon.png")
        #expect(decoded.mimeType == "image/png")
        #expect(decoded.sizes == ["48x48", "96x96"])
        #expect(decoded.theme == .light)
    }

    @Test("Icon with only src encodes correctly")
    func testIconWithOnlySrc() throws {
        let icon = Icon(src: "https://example.com/icon.svg")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(icon)

        // Decode and verify - optional fields should be nil
        let decoded = try decoder.decode(Icon.self, from: data)

        #expect(decoded.src == "https://example.com/icon.svg")
        #expect(decoded.mimeType == nil)
        #expect(decoded.sizes == nil)
        #expect(decoded.theme == nil)
    }

    @Test("Icon with data URI encodes correctly")
    func testIconWithDataUri() throws {
        let dataUri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let icon = Icon(src: dataUri, mimeType: "image/png", sizes: ["1x1"])

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(icon)
        let decoded = try decoder.decode(Icon.self, from: data)

        #expect(decoded.src == dataUri)
        #expect(decoded.mimeType == "image/png")
        #expect(decoded.sizes == ["1x1"])
    }

    @Test("Icon dark theme encodes correctly")
    func testIconDarkTheme() throws {
        let icon = Icon(src: "https://example.com/dark-icon.png", theme: .dark)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(icon)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"theme\":\"dark\""))
    }

    @Test("Multiple icons roundtrip correctly")
    func testMultipleIconsRoundtrip() throws {
        // Based on Python SDK test_multiple_icons test
        let icons = [
            Icon(src: "data:image/png;base64,icon1", mimeType: "image/png", sizes: ["16x16"]),
            Icon(src: "data:image/png;base64,icon2", mimeType: "image/png", sizes: ["32x32"]),
            Icon(src: "data:image/png;base64,icon3", mimeType: "image/png", sizes: ["64x64"])
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(icons)
        let decoded = try decoder.decode([Icon].self, from: data)

        #expect(decoded.count == 3)
        #expect(decoded[0].sizes == ["16x16"])
        #expect(decoded[1].sizes == ["32x32"])
        #expect(decoded[2].sizes == ["64x64"])
    }
}

// MARK: - Server Initialization with Metadata Tests

@Suite("Server Initialization with Metadata Tests")
struct ServerInitializationMetadataTests {

    @Test("Server can be initialized with all metadata fields")
    func testServerInitWithAllMetadata() async throws {
        let icons = [
            Icon(
                src: "https://example.com/server-icon.png",
                mimeType: "image/png",
                sizes: ["48x48"]
            )
        ]

        let server = Server(
            name: "metadata-server",
            version: "1.0.0",
            title: "Metadata Test Server",
            description: "A server with full metadata",
            icons: icons,
            websiteUrl: "https://example.com"
        )

        // Verify the server info has all the fields
        #expect(server.name == "metadata-server")
        #expect(server.version == "1.0.0")

        // Access the serverInfo through the internal property
        let serverInfo = await server.serverInfo
        #expect(serverInfo.title == "Metadata Test Server")
        #expect(serverInfo.description == "A server with full metadata")
        #expect(serverInfo.websiteUrl == "https://example.com")
        #expect(serverInfo.icons?.count == 1)
        #expect(serverInfo.icons?[0].src == "https://example.com/server-icon.png")
    }

    @Test("Server without optional metadata fields")
    func testServerInitWithoutOptionalMetadata() async throws {
        // Based on Python SDK test_no_icons_or_website test
        let server = Server(
            name: "basic-server",
            version: "0.1.0"
        )

        #expect(server.name == "basic-server")
        #expect(server.version == "0.1.0")

        let serverInfo = await server.serverInfo
        #expect(serverInfo.title == nil)
        #expect(serverInfo.description == nil)
        #expect(serverInfo.icons == nil)
        #expect(serverInfo.websiteUrl == nil)
    }
}

// MARK: - Client Initialization with Metadata Tests

@Suite("Client Initialization with Metadata Tests")
struct ClientInitializationMetadataTests {

    @Test("Client can be initialized with all metadata fields")
    func testClientInitWithAllMetadata() async throws {
        let client = Client(
            name: "metadata-client",
            version: "1.0.0",
            title: "Metadata Test Client",
            description: "A client with full metadata",
            icons: [Icon(src: "https://example.com/client-icon.png")],
            websiteUrl: "https://example.com/client"
        )

        #expect(client.name == "metadata-client")
        #expect(client.version == "1.0.0")

        // Access the clientInfo
        let clientInfo = await client.clientInfo
        #expect(clientInfo.title == "Metadata Test Client")
        #expect(clientInfo.description == "A client with full metadata")
        #expect(clientInfo.websiteUrl == "https://example.com/client")
        #expect(clientInfo.icons?.count == 1)
    }

    @Test("Client without optional metadata fields")
    func testClientInitWithoutOptionalMetadata() async throws {
        let client = Client(
            name: "basic-client",
            version: "0.1.0"
        )

        #expect(client.name == "basic-client")
        #expect(client.version == "0.1.0")

        let clientInfo = await client.clientInfo
        #expect(clientInfo.title == nil)
        #expect(clientInfo.description == nil)
        #expect(clientInfo.icons == nil)
        #expect(clientInfo.websiteUrl == nil)
    }
}

// MARK: - Initialize Result with Metadata Tests

@Suite("Initialize Result Metadata Tests")
struct InitializeResultMetadataTests {

    @Test("Initialize result with server title in serverInfo")
    func testInitializeResultWithServerTitle() throws {
        // Based on TypeScript SDK title.test.ts "should support serverInfo with title"
        let result = Initialize.Result(
            protocolVersion: Version.latest,
            capabilities: Server.Capabilities(),
            serverInfo: Server.Info(
                name: "test-server",
                version: "1.0.0",
                title: "Test Server Display Name"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(result)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"name\":\"test-server\""))
        #expect(json.contains("\"version\":\"1.0.0\""))
        #expect(json.contains("\"title\":\"Test Server Display Name\""))
    }

    @Test("Initialize result with all metadata fields decodes correctly")
    func testInitializeResultWithAllMetadata() throws {
        let json = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "serverInfo": {
                "name": "full-metadata-server",
                "version": "2.0.0",
                "title": "Full Metadata Server",
                "description": "Server with all metadata fields",
                "websiteUrl": "https://example.com",
                "icons": [
                    {
                        "src": "https://example.com/icon.png",
                        "mimeType": "image/png",
                        "sizes": ["48x48"],
                        "theme": "light"
                    }
                ]
            },
            "instructions": "Use this server for testing."
        }
        """

        let decoder = JSONDecoder()
        let result = try decoder.decode(Initialize.Result.self, from: json.data(using: .utf8)!)

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(result.serverInfo.name == "full-metadata-server")
        #expect(result.serverInfo.version == "2.0.0")
        #expect(result.serverInfo.title == "Full Metadata Server")
        #expect(result.serverInfo.description == "Server with all metadata fields")
        #expect(result.serverInfo.websiteUrl == "https://example.com")
        #expect(result.serverInfo.icons?.count == 1)
        #expect(result.serverInfo.icons?[0].theme == .light)
        #expect(result.instructions == "Use this server for testing.")
    }

    @Test("Initialize result from Python SDK format")
    func testInitializeResultFromPythonFormat() throws {
        // Based on Python SDK test_session.py test_client_session_initialize
        let json = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "logging": null,
                "resources": null,
                "tools": null,
                "experimental": null,
                "prompts": null
            },
            "serverInfo": {
                "name": "mock-server",
                "version": "0.1.0"
            },
            "instructions": "The server instructions."
        }
        """

        let decoder = JSONDecoder()
        let result = try decoder.decode(Initialize.Result.self, from: json.data(using: .utf8)!)

        #expect(result.serverInfo.name == "mock-server")
        #expect(result.serverInfo.version == "0.1.0")
        #expect(result.instructions == "The server instructions.")
    }
}

// MARK: - Integration: Metadata in Initialize Flow

@Suite("Metadata in Initialize Integration Tests")
struct MetadataInitializeIntegrationTests {

    @Test("Server metadata is returned in initialize result")
    func testServerMetadataInInitializeResult() async throws {
        // Based on TypeScript SDK title.test.ts "should support serverInfo with title"
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            title: "Test Server Display Name",
            description: "A server for integration testing",
            websiteUrl: "https://example.com"
        )

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        // Verify server metadata is in the initialize result
        #expect(initResult.serverInfo.name == "test-server")
        #expect(initResult.serverInfo.version == "1.0.0")
        #expect(initResult.serverInfo.title == "Test Server Display Name")
        #expect(initResult.serverInfo.description == "A server for integration testing")
        #expect(initResult.serverInfo.websiteUrl == "https://example.com")

        await client.disconnect()
        await server.stop()
    }

    @Test("Server with icons metadata is returned correctly")
    func testServerWithIconsMetadataInInitializeResult() async throws {
        // Based on Python SDK test_1338_icons_and_metadata.py
        let testIcon = Icon(
            src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
            mimeType: "image/png",
            sizes: ["1x1"]
        )

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "icon-server",
            version: "1.0.0",
            icons: [testIcon],
            websiteUrl: "https://example.com"
        )

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        // Verify icons are in the initialize result
        #expect(initResult.serverInfo.icons?.count == 1)
        #expect(initResult.serverInfo.icons?[0].src == testIcon.src)
        #expect(initResult.serverInfo.icons?[0].mimeType == "image/png")
        #expect(initResult.serverInfo.icons?[0].sizes == ["1x1"])
        #expect(initResult.serverInfo.websiteUrl == "https://example.com")

        await client.disconnect()
        await server.stop()
    }

    @Test("Server instructions are included in initialize result")
    func testServerInstructionsInInitializeResult() async throws {
        // Based on Python SDK test_client_session_initialize
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let instructions = "This server provides tools for testing. Use the 'test' tool for validation."
        let server = Server(
            name: "instructions-server",
            version: "1.0.0",
            instructions: instructions
        )

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        #expect(initResult.instructions == instructions)

        await client.disconnect()
        await server.stop()
    }

    @Test("Server without optional metadata still initializes correctly")
    func testServerWithoutOptionalMetadata() async throws {
        // Based on Python SDK test_no_icons_or_website
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "basic-server",
            version: "1.0.0"
        )

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        #expect(initResult.serverInfo.name == "basic-server")
        #expect(initResult.serverInfo.version == "1.0.0")
        #expect(initResult.serverInfo.title == nil)
        #expect(initResult.serverInfo.description == nil)
        #expect(initResult.serverInfo.icons == nil)
        #expect(initResult.serverInfo.websiteUrl == nil)
        #expect(initResult.instructions == nil)

        await client.disconnect()
        await server.stop()
    }
}
