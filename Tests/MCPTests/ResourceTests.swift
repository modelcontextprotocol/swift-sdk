import Foundation
import Testing

@testable import MCP

@Suite("Resource Tests")
struct ResourceTests {
    @Test("Resource initialization with valid parameters")
    func testResourceInitialization() throws {
        let resource = Resource(
            name: "test_resource",
            uri: "file://test.txt",
            description: "A test resource",
            mimeType: "text/plain",
            _meta: ["key": "value"]
        )

        #expect(resource.name == "test_resource")
        #expect(resource.uri == "file://test.txt")
        #expect(resource.description == "A test resource")
        #expect(resource.mimeType == "text/plain")
        #expect(resource._meta?["key"] == "value")
    }

    @Test("Resource encoding and decoding")
    func testResourceEncodingDecoding() throws {
        let resource = Resource(
            name: "test_resource",
            uri: "file://test.txt",
            description: "Test resource description",
            mimeType: "text/plain",
            _meta: ["key1": "value1", "key2": "value2"]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(resource)
        let decoded = try decoder.decode(Resource.self, from: data)

        #expect(decoded.name == resource.name)
        #expect(decoded.uri == resource.uri)
        #expect(decoded.description == resource.description)
        #expect(decoded.mimeType == resource.mimeType)
        #expect(decoded._meta == resource._meta)
    }

    @Test("Resource.Content text initialization and encoding")
    func testResourceContentTextEncoding() throws {
        let content = Resource.Content.text(
            "Hello, world!", uri: "file://test.txt", mimeType: "text/plain")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Resource.Content.self, from: data)

        #expect(decoded.uri == "file://test.txt")
        #expect(decoded.mimeType == "text/plain")
        #expect(decoded.text == "Hello, world!")
        #expect(decoded.blob == nil)
    }

    @Test("Resource.Content binary initialization and encoding")
    func testResourceContentBinaryEncoding() throws {
        let binaryData = "Test binary data".data(using: .utf8)!
        let content = Resource.Content.binary(
            binaryData, uri: "file://test.bin", mimeType: "application/octet-stream")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Resource.Content.self, from: data)

        #expect(decoded.uri == "file://test.bin")
        #expect(decoded.mimeType == "application/octet-stream")
        #expect(decoded.text == nil)
        #expect(decoded.blob == binaryData.base64EncodedString())
    }

    @Test("ListResources parameters validation")
    func testListResourcesParameters() throws {
        let params = ListResources.Parameters(cursor: "next_page")
        #expect(params.cursor == "next_page")

        let emptyParams = ListResources.Parameters()
        #expect(emptyParams.cursor == nil)
    }
    
    @Test("ListResources request decoding with omitted params")
    func testListResourcesRequestDecodingWithOmittedParams() throws {
        // Test decoding when params field is omitted
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"resources/list"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListResources>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListResources.name)
    }
    
    @Test("ListResources request decoding with null params")
    func testListResourcesRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"resources/list","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListResources>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListResources.name)
    }

    @Test("ListResources result validation")
    func testListResourcesResult() throws {
        let resources = [
            Resource(name: "resource1", uri: "file://test1.txt"),
            Resource(name: "resource2", uri: "file://test2.txt"),
        ]

        let result = ListResources.Result(resources: resources, nextCursor: "next_page")
        #expect(result.resources.count == 2)
        #expect(result.resources[0].name == "resource1")
        #expect(result.resources[1].name == "resource2")
        #expect(result.nextCursor == "next_page")
    }

    @Test("ReadResource parameters validation")
    func testReadResourceParameters() throws {
        let params = ReadResource.Parameters(uri: "file://test.txt")
        #expect(params.uri == "file://test.txt")
    }

    @Test("ReadResource result validation")
    func testReadResourceResult() throws {
        let contents = [
            Resource.Content.text("Content 1", uri: "file://test1.txt"),
            Resource.Content.text("Content 2", uri: "file://test2.txt"),
        ]

        let result = ReadResource.Result(contents: contents)
        #expect(result.contents.count == 2)
    }

    @Test("ResourceSubscribe parameters validation")
    func testResourceSubscribeParameters() throws {
        let params = ResourceSubscribe.Parameters(uri: "file://test.txt")
        #expect(params.uri == "file://test.txt")
        #expect(ResourceSubscribe.name == "resources/subscribe")
    }

    @Test("ResourceUnsubscribe parameters validation")
    func testResourceUnsubscribeParameters() throws {
        let params = ResourceUnsubscribe.Parameters(uri: "file://test.txt")
        #expect(params.uri == "file://test.txt")
        #expect(ResourceUnsubscribe.name == "resources/unsubscribe")
    }

    @Test("ResourceUpdatedNotification parameters validation")
    func testResourceUpdatedNotification() throws {
        let params = ResourceUpdatedNotification.Parameters(uri: "file://test.txt")
        #expect(params.uri == "file://test.txt")
        #expect(ResourceUpdatedNotification.name == "notifications/resources/updated")
    }

    @Test("ResourceListChangedNotification name validation")
    func testResourceListChangedNotification() throws {
        #expect(ResourceListChangedNotification.name == "notifications/resources/list_changed")
    }

    // MARK: - MIME Type Parameter Tests (RFC 2045)

    /// Tests for MIME types with parameters as specified in RFC 2045.
    /// Based on: Python SDK `tests/issues/test_1754_mime_type_parameters.py`
    @Test("Resource with MIME type parameters (RFC 2045)")
    func testMimeTypeWithParameters() throws {
        // MIME types with parameters should be accepted per RFC 2045
        let resource = Resource(
            name: "widget",
            uri: "ui://widget",
            mimeType: "text/html;profile=mcp-app"
        )

        #expect(resource.mimeType == "text/html;profile=mcp-app")

        // Verify encoding/decoding preserves the full MIME type
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(resource)
        let decoded = try decoder.decode(Resource.self, from: data)

        #expect(decoded.mimeType == "text/html;profile=mcp-app")
    }

    @Test("Resource with MIME type parameters and space after semicolon")
    func testMimeTypeWithParametersAndSpace() throws {
        let resource = Resource(
            name: "data",
            uri: "data://json",
            mimeType: "application/json; charset=utf-8"
        )

        #expect(resource.mimeType == "application/json; charset=utf-8")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(resource)
        let decoded = try decoder.decode(Resource.self, from: data)

        #expect(decoded.mimeType == "application/json; charset=utf-8")
    }

    @Test("Resource with multiple MIME type parameters")
    func testMimeTypeWithMultipleParameters() throws {
        let resource = Resource(
            name: "multi",
            uri: "data://multi",
            mimeType: "text/plain; charset=utf-8; format=fixed"
        )

        #expect(resource.mimeType == "text/plain; charset=utf-8; format=fixed")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(resource)
        let decoded = try decoder.decode(Resource.self, from: data)

        #expect(decoded.mimeType == "text/plain; charset=utf-8; format=fixed")
    }

    @Test("Resource.Content preserves MIME type with parameters")
    func testResourceContentPreservesMimeTypeWithParameters() throws {
        let content = Resource.Content.text(
            "<html><body>Hello MCP-UI</body></html>",
            uri: "ui://my-widget",
            mimeType: "text/html;profile=mcp-app"
        )

        #expect(content.mimeType == "text/html;profile=mcp-app")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Resource.Content.self, from: data)

        #expect(decoded.mimeType == "text/html;profile=mcp-app")
    }

    // MARK: - Resource Template Tests

    /// Tests for Resource.Template encoding and decoding.
    /// Based on: Python SDK `tests/issues/test_129_resource_templates.py`
    @Test("Resource.Template initialization and encoding")
    func testResourceTemplateInitialization() throws {
        let template = Resource.Template(
            uriTemplate: "greeting://{name}",
            name: "greeting",
            title: "Greeting Resource",
            description: "Get a personalized greeting",
            mimeType: "text/plain"
        )

        #expect(template.uriTemplate == "greeting://{name}")
        #expect(template.name == "greeting")
        #expect(template.title == "Greeting Resource")
        #expect(template.description == "Get a personalized greeting")
        #expect(template.mimeType == "text/plain")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(template)
        let decoded = try decoder.decode(Resource.Template.self, from: data)

        #expect(decoded.uriTemplate == "greeting://{name}")
        #expect(decoded.name == "greeting")
        #expect(decoded.title == "Greeting Resource")
        #expect(decoded.description == "Get a personalized greeting")
        #expect(decoded.mimeType == "text/plain")
    }

    @Test("Resource.Template with multiple URI parameters")
    func testResourceTemplateMultipleParams() throws {
        let template = Resource.Template(
            uriTemplate: "users://{user_id}/posts/{post_id}",
            name: "user_post",
            description: "User post resource"
        )

        #expect(template.uriTemplate == "users://{user_id}/posts/{post_id}")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(template)
        let decoded = try decoder.decode(Resource.Template.self, from: data)

        #expect(decoded.uriTemplate == "users://{user_id}/posts/{post_id}")
    }

    @Test("Resource.Template with annotations and metadata")
    func testResourceTemplateWithAnnotations() throws {
        let template = Resource.Template(
            uriTemplate: "file:///{path}",
            name: "file",
            annotations: Annotations(audience: [.user], priority: 0.8),
            _meta: ["custom": "value"]
        )

        #expect(template.uriTemplate == "file:///{path}")
        #expect(template.annotations?.audience == [.user])
        #expect(template.annotations?.priority == 0.8)
        #expect(template._meta?["custom"] == "value")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(template)
        let decoded = try decoder.decode(Resource.Template.self, from: data)

        #expect(decoded.annotations?.audience == [.user])
        #expect(decoded.annotations?.priority == 0.8)
        #expect(decoded._meta?["custom"] == "value")
    }

    @Test("ListResourceTemplates parameters validation")
    func testListResourceTemplatesParameters() throws {
        let params = ListResourceTemplates.Parameters(cursor: "template_page_2")
        #expect(params.cursor == "template_page_2")

        let emptyParams = ListResourceTemplates.Parameters()
        #expect(emptyParams.cursor == nil)
    }

    @Test("ListResourceTemplates result encoding/decoding")
    func testListResourceTemplatesResult() throws {
        let templates = [
            Resource.Template(
                uriTemplate: "greeting://{name}",
                name: "greeting",
                description: "Get a personalized greeting"
            ),
            Resource.Template(
                uriTemplate: "users://{user_id}/profile",
                name: "user_profile",
                description: "User profile resource"
            ),
        ]

        let result = ListResourceTemplates.Result(
            templates: templates,
            nextCursor: "next_template_page"
        )

        #expect(result.templates.count == 2)
        #expect(result.nextCursor == "next_template_page")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListResourceTemplates.Result.self, from: data)

        #expect(decoded.templates.count == 2)
        #expect(decoded.templates[0].uriTemplate == "greeting://{name}")
        #expect(decoded.templates[1].uriTemplate == "users://{user_id}/profile")
        #expect(decoded.nextCursor == "next_template_page")
    }

    @Test("ListResourceTemplates result uses 'resourceTemplates' key in JSON")
    func testListResourceTemplatesUsesCorrectJsonKey() throws {
        let result = ListResourceTemplates.Result(
            templates: [
                Resource.Template(uriTemplate: "test://{id}", name: "test")
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let jsonString = String(data: data, encoding: .utf8)!

        // Verify the JSON uses "resourceTemplates" as the key (per MCP spec)
        #expect(jsonString.contains("resourceTemplates"))
        #expect(!jsonString.contains("\"templates\""))
    }

    // MARK: - ResourceLink Tests

    @Test("ResourceLink initialization and encoding")
    func testResourceLinkInitialization() throws {
        let link = ResourceLink(
            name: "example_file",
            title: "Example File",
            uri: "file:///example.txt",
            description: "An example resource link",
            mimeType: "text/plain",
            size: 1024
        )

        #expect(link.name == "example_file")
        #expect(link.title == "Example File")
        #expect(link.uri == "file:///example.txt")
        #expect(link.description == "An example resource link")
        #expect(link.mimeType == "text/plain")
        #expect(link.size == 1024)
    }

    @Test("ResourceLink encodes with 'resource_link' type")
    func testResourceLinkEncodesWithType() throws {
        let link = ResourceLink(
            name: "test",
            uri: "file:///test.txt"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(link)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("\"type\":\"resource_link\""))
    }

    @Test("ResourceLink decoding validates type field")
    func testResourceLinkDecodingValidatesType() throws {
        // Valid resource_link type
        let validJson = """
            {"type":"resource_link","name":"test","uri":"file:///test.txt"}
            """
        let validData = validJson.data(using: .utf8)!
        let decoder = JSONDecoder()

        let decoded = try decoder.decode(ResourceLink.self, from: validData)
        #expect(decoded.name == "test")
        #expect(decoded.uri == "file:///test.txt")

        // Invalid type should throw
        let invalidJson = """
            {"type":"wrong_type","name":"test","uri":"file:///test.txt"}
            """
        let invalidData = invalidJson.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(ResourceLink.self, from: invalidData)
        }
    }

    @Test("ResourceLink decodes without type field (backward compatibility)")
    func testResourceLinkDecodesWithoutType() throws {
        // Type field is optional for backward compatibility
        let json = """
            {"name":"test","uri":"file:///test.txt"}
            """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()

        let decoded = try decoder.decode(ResourceLink.self, from: data)
        #expect(decoded.name == "test")
        #expect(decoded.uri == "file:///test.txt")
    }

    @Test("ResourceLink encoding/decoding roundtrip with all optional fields")
    func testResourceLinkRoundtripAllFields() throws {
        let link = ResourceLink(
            name: "complete_resource",
            title: "Complete Resource Title",
            uri: "file:///complete.txt",
            description: "A complete resource link",
            mimeType: "application/json; charset=utf-8",
            size: 4096,
            annotations: Annotations(audience: [.user, .assistant], priority: 0.75),
            _meta: ["version": "2.0", "author": "test"]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(link)
        let decoded = try decoder.decode(ResourceLink.self, from: data)

        #expect(decoded.name == link.name)
        #expect(decoded.title == link.title)
        #expect(decoded.uri == link.uri)
        #expect(decoded.description == link.description)
        #expect(decoded.mimeType == link.mimeType)
        #expect(decoded.size == link.size)
        #expect(decoded.annotations?.audience == link.annotations?.audience)
        #expect(decoded.annotations?.priority == link.annotations?.priority)
        #expect(decoded._meta?["version"] == "2.0")
        #expect(decoded._meta?["author"] == "test")
    }

    @Test("ResourceLink decoding fails when required 'name' field is missing")
    func testResourceLinkDecodingFailsMissingName() throws {
        // Missing required 'name' field
        let json = """
            {"type":"resource_link","uri":"file:///test.txt"}
            """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(ResourceLink.self, from: data)
        }
    }

    @Test("ResourceLink decoding fails when required 'uri' field is missing")
    func testResourceLinkDecodingFailsMissingUri() throws {
        // Missing required 'uri' field
        let json = """
            {"type":"resource_link","name":"test"}
            """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(ResourceLink.self, from: data)
        }
    }

    // MARK: - Pagination Encoding Tests

    @Test("ListResources pagination cursor encoding roundtrip")
    func testPaginationCursorEncodingRoundtrip() throws {
        // Test that cursor values are properly encoded and decoded
        let cursor = "page_2_cursor_abc123"
        let params = ListResources.Parameters(cursor: cursor)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(ListResources.Parameters.self, from: data)

        #expect(decoded.cursor == cursor)
    }

    @Test("ListResources result nextCursor encoding roundtrip")
    func testPaginationNextCursorEncodingRoundtrip() throws {
        let resources = [
            Resource(name: "resource1", uri: "file://test1.txt"),
            Resource(name: "resource2", uri: "file://test2.txt"),
        ]

        let result = ListResources.Result(
            resources: resources,
            nextCursor: "next_page_cursor_xyz789"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListResources.Result.self, from: data)

        #expect(decoded.resources.count == 2)
        #expect(decoded.nextCursor == "next_page_cursor_xyz789")
    }

    @Test("Pagination result with no more pages")
    func testPaginationResultNoMorePages() throws {
        let resources = [
            Resource(name: "last_resource", uri: "file://last.txt")
        ]

        let result = ListResources.Result(resources: resources, nextCursor: nil)

        #expect(result.nextCursor == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListResources.Result.self, from: data)

        #expect(decoded.nextCursor == nil)
    }

    // MARK: - Resource with All Fields Tests

    @Test("Resource with all optional fields")
    func testResourceWithAllFields() throws {
        let resource = Resource(
            name: "complete_resource",
            title: "Complete Resource Title",
            uri: "file:///complete.txt",
            description: "A resource with all fields populated",
            mimeType: "application/json; charset=utf-8",
            size: 2048,
            annotations: Annotations(audience: [.user, .assistant], priority: 0.9),
            _meta: ["version": "1.0", "author": "test"]
        )

        #expect(resource.name == "complete_resource")
        #expect(resource.title == "Complete Resource Title")
        #expect(resource.uri == "file:///complete.txt")
        #expect(resource.description == "A resource with all fields populated")
        #expect(resource.mimeType == "application/json; charset=utf-8")
        #expect(resource.size == 2048)
        #expect(resource.annotations?.audience == [.user, .assistant])
        #expect(resource.annotations?.priority == 0.9)
        #expect(resource._meta?["version"] == "1.0")
        #expect(resource._meta?["author"] == "test")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(resource)
        let decoded = try decoder.decode(Resource.self, from: data)

        #expect(decoded.name == resource.name)
        #expect(decoded.title == resource.title)
        #expect(decoded.uri == resource.uri)
        #expect(decoded.description == resource.description)
        #expect(decoded.mimeType == resource.mimeType)
        #expect(decoded.size == resource.size)
        #expect(decoded.annotations?.audience == resource.annotations?.audience)
        #expect(decoded.annotations?.priority == resource.annotations?.priority)
    }

    // MARK: - Integration Tests

    @Test("Paginated resource listing")
    func testPaginatedResourceListing() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Track pagination state
        let paginationState = PaginationState()

        let server = Server(
            name: "PaginatedResourceServer",
            version: "1.0.0",
            capabilities: .init(resources: .init())
        )

        // Handler returns paginated resources
        await server.withRequestHandler(ListResources.self) { [paginationState] params, _ in
            let cursor = params.cursor
            return await paginationState.getPage(cursor: cursor)
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "PaginationClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // First page (no cursor)
        let page1 = try await client.listResources()
        #expect(page1.resources.count == 3)
        #expect(page1.resources[0].name == "resource_1")
        #expect(page1.resources[1].name == "resource_2")
        #expect(page1.resources[2].name == "resource_3")
        #expect(page1.nextCursor == "page_2")

        // Second page (with cursor)
        let page2 = try await client.listResources(cursor: page1.nextCursor)
        #expect(page2.resources.count == 3)
        #expect(page2.resources[0].name == "resource_4")
        #expect(page2.resources[1].name == "resource_5")
        #expect(page2.resources[2].name == "resource_6")
        #expect(page2.nextCursor == "page_3")

        // Third page (last page)
        let page3 = try await client.listResources(cursor: page2.nextCursor)
        #expect(page3.resources.count == 2)
        #expect(page3.resources[0].name == "resource_7")
        #expect(page3.resources[1].name == "resource_8")
        #expect(page3.nextCursor == nil)

        await client.disconnect()
        await server.stop()
    }

    @Test("Resource template listing and reading")
    func testResourceTemplateListingAndReading() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TemplateServer",
            version: "1.0.0",
            capabilities: .init(resources: .init())
        )

        // Handler for listing resource templates
        await server.withRequestHandler(ListResourceTemplates.self) { _, _ in
            ListResourceTemplates.Result(templates: [
                Resource.Template(
                    uriTemplate: "greeting://{name}",
                    name: "greeting",
                    description: "Get a personalized greeting"
                ),
                Resource.Template(
                    uriTemplate: "users://{user_id}/profile",
                    name: "user_profile",
                    description: "User profile resource"
                ),
            ])
        }

        // Handler for reading resources (handles templated URIs)
        await server.withRequestHandler(ReadResource.self) { params, _ in
            let uri = params.uri

            if uri.hasPrefix("greeting://") {
                let name = String(uri.dropFirst("greeting://".count))
                return ReadResource.Result(contents: [
                    .text("Hello, \(name)!", uri: uri, mimeType: "text/plain")
                ])
            } else if uri.hasPrefix("users://") && uri.hasSuffix("/profile") {
                let userId = uri
                    .replacingOccurrences(of: "users://", with: "")
                    .replacingOccurrences(of: "/profile", with: "")
                return ReadResource.Result(contents: [
                    .text("Profile for user \(userId)", uri: uri, mimeType: "text/plain")
                ])
            }

            throw MCPError.invalidParams("Unknown resource: \(uri)")
        }

        // Handler for listing resources (required for resources capability)
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TemplateClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // List templates
        let templates = try await client.listResourceTemplates()
        #expect(templates.templates.count == 2)
        #expect(templates.templates[0].uriTemplate == "greeting://{name}")
        #expect(templates.templates[1].uriTemplate == "users://{user_id}/profile")

        // Read a resource using a templated URI
        let greetingContent = try await client.readResource(uri: "greeting://World")
        #expect(greetingContent.count == 1)
        #expect(greetingContent[0].text == "Hello, World!")
        #expect(greetingContent[0].mimeType == "text/plain")

        // Read another templated resource
        let profileContent = try await client.readResource(uri: "users://123/profile")
        #expect(profileContent.count == 1)
        #expect(profileContent[0].text == "Profile for user 123")

        await client.disconnect()
        await server.stop()
    }

    @Test("Resource with MIME type parameters in integration")
    func testResourceWithMimeTypeParametersIntegration() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "MimeTypeServer",
            version: "1.0.0",
            capabilities: .init(resources: .init())
        )

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(
                    name: "widget",
                    uri: "ui://widget",
                    mimeType: "text/html;profile=mcp-app"
                ),
                Resource(
                    name: "data",
                    uri: "data://json",
                    mimeType: "application/json; charset=utf-8"
                ),
            ])
        }

        await server.withRequestHandler(ReadResource.self) { params, _ in
            if params.uri == "ui://widget" {
                return ReadResource.Result(contents: [
                    .text(
                        "<html><body>Hello MCP-UI</body></html>",
                        uri: params.uri,
                        mimeType: "text/html;profile=mcp-app"
                    )
                ])
            }
            throw MCPError.invalidParams("Unknown resource")
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "MimeTypeClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // List resources and verify MIME types are preserved
        let resources = try await client.listResources()
        #expect(resources.resources.count == 2)
        #expect(resources.resources[0].mimeType == "text/html;profile=mcp-app")
        #expect(resources.resources[1].mimeType == "application/json; charset=utf-8")

        // Read resource and verify MIME type is preserved
        let content = try await client.readResource(uri: "ui://widget")
        #expect(content.count == 1)
        #expect(content[0].mimeType == "text/html;profile=mcp-app")

        await client.disconnect()
        await server.stop()
    }

    @Test("Paginated resource template listing")
    func testPaginatedResourceTemplateListing() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PaginatedTemplateServer",
            version: "1.0.0",
            capabilities: .init(resources: .init())
        )

        await server.withRequestHandler(ListResourceTemplates.self) { params, _ in
            if params.cursor == nil {
                return ListResourceTemplates.Result(
                    templates: [
                        Resource.Template(uriTemplate: "template://{id1}", name: "template1"),
                        Resource.Template(uriTemplate: "template://{id2}", name: "template2"),
                    ],
                    nextCursor: "page_2"
                )
            } else if params.cursor == "page_2" {
                return ListResourceTemplates.Result(
                    templates: [
                        Resource.Template(uriTemplate: "template://{id3}", name: "template3")
                    ],
                    nextCursor: nil
                )
            }
            return ListResourceTemplates.Result(templates: [])
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "PaginatedTemplateClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // First page
        let page1 = try await client.listResourceTemplates()
        #expect(page1.templates.count == 2)
        #expect(page1.nextCursor == "page_2")

        // Second page
        let page2 = try await client.listResourceTemplates(cursor: page1.nextCursor)
        #expect(page2.templates.count == 1)
        #expect(page2.nextCursor == nil)

        await client.disconnect()
        await server.stop()
    }

    @Test("Empty resource listing result")
    func testEmptyResourceListingResult() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "EmptyResourceServer",
            version: "1.0.0",
            capabilities: .init(resources: .init())
        )

        // Handler returns empty resource list
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "EmptyResourceClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Verify empty list is handled correctly
        let result = try await client.listResources()
        #expect(result.resources.isEmpty)
        #expect(result.nextCursor == nil)

        await client.disconnect()
        await server.stop()
    }

    @Test("Empty resource template listing result")
    func testEmptyResourceTemplateListingResult() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "EmptyTemplateServer",
            version: "1.0.0",
            capabilities: .init(resources: .init())
        )

        // Handler returns empty template list
        await server.withRequestHandler(ListResourceTemplates.self) { _, _ in
            ListResourceTemplates.Result(templates: [])
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "EmptyTemplateClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Verify empty list is handled correctly
        let result = try await client.listResourceTemplates()
        #expect(result.templates.isEmpty)
        #expect(result.nextCursor == nil)

        await client.disconnect()
        await server.stop()
    }
}

// MARK: - Test Helpers

/// Actor to track pagination state for tests
private actor PaginationState {
    private let allResources: [Resource] = (1...8).map { i in
        Resource(name: "resource_\(i)", uri: "file:///resource_\(i).txt")
    }
    private let pageSize = 3

    func getPage(cursor: String?) -> ListResources.Result {
        let startIndex: Int
        let nextCursor: String?

        switch cursor {
        case nil:
            startIndex = 0
            nextCursor = "page_2"
        case "page_2":
            startIndex = 3
            nextCursor = "page_3"
        case "page_3":
            startIndex = 6
            nextCursor = nil
        default:
            return ListResources.Result(resources: [])
        }

        let endIndex = min(startIndex + pageSize, allResources.count)
        let pageResources = Array(allResources[startIndex..<endIndex])

        return ListResources.Result(resources: pageResources, nextCursor: nextCursor)
    }
}
