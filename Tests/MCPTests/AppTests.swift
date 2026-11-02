import Foundation
import Testing

@testable import MCP

// MCP Apps (SEP-1865): the wire types against the specification's examples
// (ext-apps v2.0.4, specification/draft/apps.mdx), the CSP builder, serving
// views, and reading them as a host.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func encoded(_ value: some Encodable) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

private func statelessMessage(id: Int, method: String, params: [String: Value] = [:]) -> String {
    var params = params
    params["_meta"] = [
        MetaKey.protocolVersion: .string(Version.v2026_07_28), MetaKey.clientCapabilities: [:],
    ]
    let value: Value = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)]
    return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private let dashboardURI = "ui://weather-server/dashboard-template"

private let weatherMeta = UIResourceMeta(
    csp: .init(connectDomains: ["https://api.openweathermap.org"], resourceDomains: ["https://cdn.jsdelivr.net"]),
    prefersBorder: true)

@Suite("MCP Apps wire types")
struct AppWireTests {
    @Test("A tool for the model and the view (Resource Discovery example)")
    func toolForBoth() throws {
        let json = """
            {"name": "get_weather", "description": "Get current weather for a location",
             "inputSchema": {"type": "object", "properties": {"location": {"type": "string"}}},
             "_meta": {"ui": {"resourceUri": "\(dashboardURI)", "visibility": ["model", "app"]}}}
            """
        let tool = try decode(Tool.self, json)
        #expect(tool.ui == ToolUIMeta(resourceUri: dashboardURI, visibility: [.model, .app]))
        #expect(tool.isVisibleToModel)
        #expect(tool.isCallableFromApp)
        #expect(try encoded(tool) == decode(Value.self, json))
    }

    @Test("An app-only tool is hidden from the model (Resource Discovery example)")
    func appOnlyTool() throws {
        let tool = try decode(
            Tool.self,
            """
            {"name": "refresh_dashboard", "description": "Refresh dashboard data", "inputSchema": {"type": "object"},
             "_meta": {"ui": {"resourceUri": "\(dashboardURI)", "visibility": ["app"]}}}
            """)
        #expect(!tool.isVisibleToModel)
        #expect(tool.isCallableFromApp)
    }

    @Test("Visibility: omitted means both, a model-only tool, an empty list, an unknown value")
    func visibility() {
        var tool = Tool(name: "t", description: nil, inputSchema: ["type": "object"])
        #expect(tool.ui == nil && tool.isVisibleToModel && tool.isCallableFromApp)
        tool.ui = ToolUIMeta(resourceUri: dashboardURI)
        #expect(tool.isVisibleToModel && tool.isCallableFromApp)
        tool.ui = ToolUIMeta(visibility: [.model])
        #expect(tool.isVisibleToModel && !tool.isCallableFromApp)
        tool.ui = ToolUIMeta(visibility: [])
        #expect(!tool.isVisibleToModel && !tool.isCallableFromApp)
        tool.ui = ToolUIMeta(visibility: ["agent"])
        #expect(tool.ui?.visibility == ["agent"])
        #expect(!tool.isVisibleToModel && !tool.isCallableFromApp)
    }

    @Test("The deprecated flat key is read, never written, and the setter removes it")
    func legacyResourceUri() throws {
        var tool = try decode(
            Tool.self,
            #"{"name": "t", "inputSchema": {"type": "object"}, "_meta": {"ui/resourceUri": "ui://old", "x": 1}}"#)
        #expect(tool.ui == ToolUIMeta(resourceUri: "ui://old"))

        let both = try decode(
            Tool.self,
            #"{"name": "t", "inputSchema": {"type": "object"}, "_meta": {"ui/resourceUri": "ui://old", "ui": {"resourceUri": "ui://new", "visibility": ["app"]}}}"#
        )
        #expect(both.ui == ToolUIMeta(resourceUri: "ui://new", visibility: [.app]))

        let visibilityOnly = try decode(
            Tool.self,
            #"{"name": "t", "inputSchema": {"type": "object"}, "_meta": {"ui/resourceUri": "ui://old", "ui": {"visibility": ["app"]}}}"#
        )
        #expect(visibilityOnly.ui == ToolUIMeta(resourceUri: "ui://old", visibility: [.app]))

        tool.ui = ToolUIMeta(resourceUri: "ui://new")
        #expect(tool._meta?.fields == ["ui": ["resourceUri": "ui://new"], "x": 1])
    }

    @Test("Setters keep unknown keys of _meta and of _meta.ui; nil removes _meta.ui")
    func settersKeepUnknownKeys() throws {
        var tool = try decode(
            Tool.self,
            #"{"name": "t", "inputSchema": {"type": "object"}, "_meta": {"other": true, "ui": {"future": 1, "visibility": ["app"]}}}"#
        )
        tool.ui = ToolUIMeta(resourceUri: "ui://v")
        #expect(tool._meta?.fields == ["other": true, "ui": ["future": 1, "resourceUri": "ui://v"]])
        tool.ui = nil
        #expect(tool._meta?.fields == ["other": true])

        var resource = Resource(name: "r", uri: "ui://v")
        resource.ui = UIResourceMeta(prefersBorder: false)
        #expect(resource._meta?.fields == ["ui": ["prefersBorder": false]])
        resource.ui = nil
        #expect(resource._meta == nil)
    }

    @Test("Resource metadata on the listing and on the content item (Metadata Location example)")
    func resourceMeta() throws {
        let listing = try decode(
            Resource.self,
            """
            {"uri": "\(dashboardURI)", "name": "weather_dashboard", "description": "Interactive weather dashboard view",
             "mimeType": "text/html;profile=mcp-app",
             "_meta": {"ui": {"csp": {"connectDomains": ["https://api.openweathermap.org"],
                                      "resourceDomains": ["https://cdn.jsdelivr.net"]}, "prefersBorder": true}}}
            """)
        #expect(listing.ui == weatherMeta)
        let content = try decode(
            Resource.Content.self,
            """
            {"uri": "\(dashboardURI)", "mimeType": "text/html;profile=mcp-app", "text": "<!DOCTYPE html><html>...</html>",
             "_meta": {"ui": {"csp": {"connectDomains": ["https://api.openweathermap.org"],
                                      "resourceDomains": ["https://cdn.jsdelivr.net"]}, "prefersBorder": true}}}
            """)
        #expect(content.ui == weatherMeta)
    }

    @Test("Permissions are presence flags; domain is kept as is")
    func permissions() throws {
        let meta = try decode(
            UIResourceMeta.self,
            #"{"permissions": {"camera": {}, "clipboardWrite": true, "microphone": null, "geolocation": false}, "domain": "a904794854a047f6.claudemcpcontent.com"}"#
        )
        #expect(meta.permissions == .init(camera: true, clipboardWrite: true))
        #expect(meta.permissions?.policyFeatures == ["camera", "clipboard-write"])
        #expect(meta.domain == "a904794854a047f6.claudemcpcontent.com")
        #expect(
            try encoded(meta)
                == decode(
                    Value.self,
                    #"{"permissions": {"camera": {}, "clipboardWrite": {}}, "domain": "a904794854a047f6.claudemcpcontent.com"}"#
                ))
    }

    @Test("Decoding is lenient: a field of the wrong type is absent")
    func lenientDecoding() throws {
        let meta = try decode(
            UIResourceMeta.self,
            #"{"csp": {"connectDomains": ["https://a.example", 1], "frameDomains": "x"}, "prefersBorder": "yes", "domain": 3}"#
        )
        #expect(meta == UIResourceMeta(csp: .init(connectDomains: ["https://a.example"])))
        let tool = try decode(
            Tool.self, #"{"name": "t", "inputSchema": {"type": "object"}, "_meta": {"ui": {"resourceUri": 1, "visibility": "app"}}}"#)
        #expect(tool.ui == ToolUIMeta())
        #expect(tool.isVisibleToModel)
        let notObject = try decode(Tool.self, #"{"name": "t", "inputSchema": {"type": "object"}, "_meta": {"ui": "x"}}"#)
        #expect(notObject.ui == nil)
    }

    @Test("Client capabilities: the extension settings of the Client <> Server negotiation example")
    func clientSettings() throws {
        var capabilities = Client.Capabilities()
        #expect(capabilities.ui == nil)
        capabilities.ui = UIExtensionSettings()
        #expect(
            try encoded(capabilities)
                == decode(Value.self, #"{"extensions": {"io.modelcontextprotocol/ui": {"mimeTypes": ["text/html;profile=mcp-app"]}}}"#))
        #expect(capabilities.ui?.supports() == true)
        #expect(capabilities.ui?.supports("text/uri-list") == false)
        capabilities.ui = nil
        #expect(capabilities.extensions == nil)

        let lenient = UIExtensionSettings([ExtensionID.ui: ["mimeTypes": ["text/html;profile=mcp-app", 1]]])
        #expect(lenient?.mimeTypes == [UIResource.mimeType])
        #expect(UIExtensionSettings([ExtensionID.ui: [:]])?.mimeTypes == [])
        #expect(UIExtensionSettings([ExtensionID.tasks: [:]]) == nil)
    }
}

@Suite("MCP Apps Content Security Policy")
struct AppCSPTests {
    @Test("Without csp, the restrictive default of the specification")
    func restrictiveDefault() {
        #expect(
            UIResourceMeta.CSP.restrictiveDefault
                == "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
                + "img-src 'self' data:; media-src 'self' data:; object-src 'none'; connect-src 'none'")
        #expect(UIResourceMeta().contentSecurityPolicy == UIResourceMeta.CSP.restrictiveDefault)
    }

    @Test("With csp, the construction of the specification")
    func construction() {
        let csp = UIResourceMeta.CSP(
            connectDomains: ["https://api.weather.com", "wss://realtime.service.com"],
            resourceDomains: ["https://cdn.jsdelivr.net", "https://*.cloudflare.com"],
            frameDomains: ["https://www.youtube.com"], baseUriDomains: ["https://cdn.example.com"])
        #expect(
            csp.policy()
                == "default-src 'none'; "
                + "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://*.cloudflare.com; "
                + "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://*.cloudflare.com; "
                + "connect-src 'self' https://api.weather.com wss://realtime.service.com; "
                + "img-src 'self' data: https://cdn.jsdelivr.net https://*.cloudflare.com; "
                + "font-src 'self' https://cdn.jsdelivr.net https://*.cloudflare.com; "
                + "media-src 'self' data: https://cdn.jsdelivr.net https://*.cloudflare.com; "
                + "frame-src https://www.youtube.com; object-src 'none'; base-uri https://cdn.example.com")
        #expect(
            UIResourceMeta.CSP().policy()
                == "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
                + "connect-src 'self'; img-src 'self' data:; font-src 'self'; media-src 'self' data:; "
                + "frame-src 'none'; object-src 'none'; base-uri 'self'")
    }

    @Test("An origin that could add a keyword or a directive is dropped")
    func injection() {
        let csp = UIResourceMeta.CSP(
            connectDomains: [
                "https://ok.example", "https://a.example; script-src *", "'unsafe-eval'", "https://b.example c",
                "https://c.example,d", "\"x\"", "https://d.example\n", "", "https://e.example\u{0}",
            ],
            frameDomains: ["'self'; img-src *"])
        let policy = csp.policy()
        #expect(policy.contains("connect-src 'self' https://ok.example;"))
        #expect(policy.contains("frame-src 'none';"))
        #expect(!policy.contains("unsafe-eval") && !policy.contains("*") && !policy.contains("b.example"))
    }
}

@Suite("Serving MCP Apps views")
struct AppServerTests {
    private func view(_ uri: String = dashboardURI, html: String = "<!DOCTYPE html><html></html>") throws
        -> UIResource
    {
        try UIResource(
            uri: uri, name: "weather_dashboard", description: "Interactive weather dashboard view", html: html,
            meta: weatherMeta)
    }

    private func server(
        views: [UIResource], listInResources: Bool = true, appResources: [Resource]? = nil, skills: Bool = false
    ) async throws -> WireExchange {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        if let appResources {
            await server.withMethodHandler(ListResources.self) { params in
                let start = Int(params.cursor ?? "0") ?? 0
                let end = min(appResources.count, start + 1)
                return .init(
                    resources: Array(appResources[start..<end]), nextCursor: end < appResources.count ? "\(end)" : nil)
            }
            await server.withMethodHandler(ReadResource.self) { params in
                guard params.uri == "ui://dynamic" else { throw MCPError.resourceNotFound(uri: params.uri) }
                return .init(contents: [.text("<html>dynamic</html>", uri: params.uri, mimeType: UIResource.mimeType)])
            }
        }
        if skills {
            await server.withSkills(
                InMemorySkillCatalog([
                    try SkillPackage(path: "pdf", files: ["SKILL.md": Data("---\nname: pdf\ndescription: d\n---\n".utf8)])
                ]))
        }
        await server.withAppResources(views, listInResources: listInResources)
        let wire = WireExchange(server: server)
        try await wire.start()
        return wire
    }

    private func result(_ wire: WireExchange, _ method: String, _ params: [String: Value] = [:]) async throws -> Value {
        let reply = try await wire.send(statelessMessage(id: 1, method: method, params: params))
        return try #require(reply.first?.objectValue?["result"], "\(reply)")
    }

    private func errorCode(_ wire: WireExchange, _ method: String, _ params: [String: Value] = [:]) async throws -> Int? {
        try await wire.send(statelessMessage(id: 1, method: method, params: params)).first?
            .objectValue?["error"]?.objectValue?["code"]?.intValue
    }

    private func uris(_ page: Value) -> [String] {
        page.objectValue?["resources"]?.arrayValue?.compactMap { $0.objectValue?["uri"]?.stringValue } ?? []
    }

    @Test("A view must have a ui:// URI")
    func validation() throws {
        // The scheme must be lowercase: views are looked up by the exact URI.
        for invalid in ["https://x", "ui://", "ui:x", "skill://a", "UI://Upper", "Ui://x"] {
            #expect(throws: UIResource.ValidationError.self, "\(invalid)") { try view(invalid) }
        }
        #expect(try view("ui://Upper").uri == "ui://Upper")
    }

    @Test("server/discover declares the extension and resources")
    func discover() async throws {
        let wire = try await server(views: [try view()])
        defer { Task { await wire.stop() } }
        let capabilities = try await result(wire, ServerDiscover.name).objectValue?["capabilities"]
        expectWire(try #require(capabilities), matches: ["extensions": [ExtensionID.ui: [:]], "resources": [:]])
    }

    @Test("resources/list and resources/read: the meta on the entry and on the content item")
    func listAndRead() async throws {
        let wire = try await server(views: [try view()])
        defer { Task { await wire.stop() } }
        let listed = try await result(wire, ListResources.name)
        let expectedMeta: Value = [
            "ui": [
                "csp": ["connectDomains": ["https://api.openweathermap.org"], "resourceDomains": ["https://cdn.jsdelivr.net"]],
                "prefersBorder": true,
            ]
        ]
        #expect(
            listed.objectValue?["resources"]
                == [
                    [
                        "uri": .string(dashboardURI), "name": "weather_dashboard",
                        "description": "Interactive weather dashboard view", "mimeType": "text/html;profile=mcp-app",
                        "_meta": expectedMeta,
                    ]
                ])
        let read = try await result(wire, ReadResource.name, ["uri": .string(dashboardURI)])
        expectWire(read, matches: ["resultType": "complete", "ttlMs": "<any>", "cacheScope": "<any>"])
        #expect(
            read.objectValue?["contents"]
                == [
                    [
                        "uri": .string(dashboardURI), "mimeType": "text/html;profile=mcp-app",
                        "text": "<!DOCTYPE html><html></html>", "_meta": expectedMeta,
                    ]
                ])
        #expect(try await errorCode(wire, ReadResource.name, ["uri": "ui://unknown"]) == -32602)
    }

    @Test("A blob view is base64-encoded")
    func blob() async throws {
        let html = Data("<html>é</html>".utf8)
        let wire = try await server(views: [try UIResource(uri: "ui://b", name: "b", body: .blob(html))])
        defer { Task { await wire.stop() } }
        let read = try await result(wire, ReadResource.name, ["uri": "ui://b"])
        #expect(
            read.objectValue?["contents"]
                == [["uri": "ui://b", "mimeType": "text/html;profile=mcp-app", "blob": .string(html.base64EncodedString())]])
    }

    @Test("The first page has the application's page, the views and the skills; then the application continues")
    func merged() async throws {
        let app = [Resource(name: "one", uri: "app://1"), Resource(name: "two", uri: "app://2")]
        let views = try (1...101).map { try view("ui://v\($0)") }
        let wire = try await server(views: views, appResources: app, skills: true)
        defer { Task { await wire.stop() } }
        let first = try await result(wire, ListResources.name)
        #expect(uris(first) == ["app://1"] + (1...100).map { "ui://v\($0)" } + ["skill://pdf/SKILL.md"])
        var cursor = try #require(first.objectValue?["nextCursor"]?.stringValue)
        #expect(cursor.hasPrefix("mcp-resources:"))
        let second = try await result(wire, ListResources.name, ["cursor": .string(cursor)])
        #expect(uris(second) == ["app://2"])
        cursor = try #require(second.objectValue?["nextCursor"]?.stringValue)
        let third = try await result(wire, ListResources.name, ["cursor": .string(cursor)])
        #expect(uris(third) == ["ui://v101"])
        #expect(third.objectValue?["nextCursor"] == nil)
        #expect(try await errorCode(wire, ListResources.name, ["cursor": "mcp-resources:eyJ4IjpudWxsfQ=="]) == -32602)
    }

    @Test("A cursor with a position that the server cannot advance ends the listing")
    func foreignCursor() async throws {
        // Views only: no application listing and no skills.
        let wire = try await server(views: [try view()])
        defer { Task { await wire.stop() } }
        // {"a": "x", "s": null}: an application page and the skills' first page.
        let cursor = "mcp-resources:" + Data(#"{"a":"x","s":null}"#.utf8).base64EncodedString()
        let page = try await result(wire, ListResources.name, ["cursor": .string(cursor)])
        #expect(uris(page) == [])
        #expect(page.objectValue?["nextCursor"] == nil)
    }

    @Test("Unlisted views are read; other ui:// URIs go to the application; a later view replaces an earlier one")
    func unlistedAndApplication() async throws {
        let views = [try view(html: "old"), try view(html: "new")]
        let wire = try await server(
            views: views, listInResources: false, appResources: [Resource(name: "one", uri: "app://1")])
        defer { Task { await wire.stop() } }
        #expect(uris(try await result(wire, ListResources.name)) == ["app://1"])
        let read = try await result(wire, ReadResource.name, ["uri": .string(dashboardURI)])
        #expect(read.objectValue?["contents"]?.arrayValue?.first?.objectValue?["text"] == "new")
        let dynamic = try await result(wire, ReadResource.name, ["uri": "ui://dynamic"])
        #expect(dynamic.objectValue?["contents"]?.arrayValue?.first?.objectValue?["text"] == "<html>dynamic</html>")
    }

    /// A skill catalog whose `resources/list` page has caching hints.
    private struct HintedSkillCatalog: SkillCatalog {
        let ttlMs: Int
        let cacheScope: CacheScope

        func listSkills(cursor: String?) async throws -> ListSkills.Result { .init(skills: []) }
        func skill(uri: String) async throws -> Skill? { nil }
        func readResource(uri: String) async throws -> ReadResource.Result? { nil }
        func listResources(cursor: String?) async throws -> ListResources.Result {
            .init(resources: [Resource(name: "s", uri: "skill://s/SKILL.md")], ttlMs: ttlMs, cacheScope: cacheScope)
        }
    }

    @Test(
        "A merged page has the shortest ttlMs and is private when any page is",
        arguments: [(3600, CacheScope.public, 60, CacheScope.private), (60, .private, 3600, .public)])
    func mergedCacheHints(application: Int, applicationScope: CacheScope, skills: Int, skillsScope: CacheScope)
        async throws
    {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [Resource(name: "one", uri: "app://1")], ttlMs: application, cacheScope: applicationScope)
        }
        await server.withSkills(HintedSkillCatalog(ttlMs: skills, cacheScope: skillsScope))
        await server.withAppResources([try view()])
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }
        let page = try await result(wire, ListResources.name)
        #expect(uris(page) == ["app://1", dashboardURI, "skill://s/SKILL.md"])
        #expect(page.objectValue?["ttlMs"] == 60)
        #expect(page.objectValue?["cacheScope"] == "private")
    }

    @Test("The skills merge still works next to the views", arguments: [true, false])
    func skillsNextToViews(listViews: Bool) async throws {
        let wire = try await server(views: [try view()], listInResources: listViews, skills: true)
        defer { Task { await wire.stop() } }
        let listed = try await result(wire, ListResources.name)
        #expect(uris(listed) == (listViews ? [dashboardURI] : []) + ["skill://pdf/SKILL.md"])
        #expect(listed.objectValue?["nextCursor"] == nil)
        let skill = try await result(wire, ReadResource.name, ["uri": "skill://pdf/SKILL.md"])
        #expect(skill.objectValue?["contents"]?.arrayValue?.count == 1)
    }
}

@Suite("Reading MCP Apps views")
struct AppClientTests {
    private func connect(
        views: [UIResource] = [], configuration: Client.Configuration = .default,
        capabilities: Client.Capabilities = .init(), customize: (Server) async -> Void = { _ in }
    ) async throws -> (Client, Server) {
        let server = Server(name: "s", version: "1", capabilities: .init(resources: .init(), tools: .init()))
        await customize(server)
        if !views.isEmpty { await server.withAppResources(views) }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "c", version: "1", capabilities: capabilities, configuration: configuration)
        try await client.connect(transport: clientTransport)
        return (client, server)
    }

    @Test("The HTML and the content item's meta, as text and as a blob")
    func read() async throws {
        let (client, server) = try await connect(views: [
            try UIResource(uri: "ui://t", name: "t", html: "<html>t</html>", meta: weatherMeta),
            try UIResource(uri: "ui://b", name: "b", body: .blob(Data("<html>é</html>".utf8))),
        ])
        defer { Task { await client.disconnect(); await server.stop() } }
        let text = try await client.readAppResource(uri: "ui://t")
        #expect(text.html == "<html>t</html>")
        #expect(text.meta == weatherMeta)
        #expect(text.contentSecurityPolicy == weatherMeta.csp?.policy())
        let blob = try await client.readAppResource(uri: "ui://b")
        #expect(blob.html == "<html>é</html>")
        #expect(blob.meta == nil)
        #expect(blob.contentSecurityPolicy == UIResourceMeta.CSP.restrictiveDefault)
    }

    /// A server whose read has no meta and whose listing has `listed`, over
    /// two pages.
    private func listingOnlyServer(_ server: Server, listed: UIResourceMeta, content: UIResourceMeta? = nil) async {
        await server.withMethodHandler(ListResources.self) { params in
            var entry = Resource(name: "v", uri: "ui://v", mimeType: UIResource.mimeType)
            entry.ui = listed
            return params.cursor == nil
                ? .init(resources: [Resource(name: "x", uri: "app://x")], nextCursor: "2") : .init(resources: [entry])
        }
        await server.withMethodHandler(ReadResource.self) { params in
            var item = Resource.Content.text("<html></html>", uri: params.uri, mimeType: "text/html; profile=mcp-app")
            item.ui = content
            return .init(contents: [item])
        }
    }

    @Test("The content item's meta takes precedence over the listing's")
    func contentWins() async throws {
        let content = UIResourceMeta(prefersBorder: false)
        let (client, server) = try await connect { await listingOnlyServer($0, listed: weatherMeta, content: content) }
        defer { Task { await client.disconnect(); await server.stop() } }
        var entry = Resource(name: "v", uri: "ui://v")
        entry.ui = weatherMeta
        #expect(try await client.readAppResource(uri: "ui://v", listing: entry).meta == content)
        #expect(try await client.readAppResource(uri: "ui://v").meta == content)
    }

    @Test("Without meta on the content item: the given listing entry, else the server's listing")
    func listingFallback() async throws {
        let (client, server) = try await connect { await listingOnlyServer($0, listed: weatherMeta) }
        defer { Task { await client.disconnect(); await server.stop() } }
        var entry = Resource(name: "v", uri: "ui://v")
        entry.ui = UIResourceMeta(domain: "given.example")
        #expect(try await client.readAppResource(uri: "ui://v", listing: entry).meta?.domain == "given.example")
        #expect(try await client.readAppResource(uri: "ui://v").meta == weatherMeta)
        let otherEntry = Resource(name: "o", uri: "ui://other", _meta: entry._meta)
        #expect(try await client.readAppResource(uri: "ui://v", listing: otherEntry).meta == weatherMeta)
    }

    @Test("A content item's _meta.ui that is not an object gives no meta; a null one, the listing's")
    func malformedContentMeta() async throws {
        for (ui, expected) in [(Value.int(5), UIResourceMeta?.none), (.null, weatherMeta)] {
            let (client, server) = try await connect { server in
                await listingOnlyServer(server, listed: weatherMeta)
                await server.withMethodHandler(ReadResource.self) { params in
                    var item = Resource.Content.text("<html></html>", uri: params.uri, mimeType: UIResource.mimeType)
                    item._meta = Metadata(additionalFields: ["ui": ui])
                    return .init(contents: [item])
                }
            }
            defer { Task { await client.disconnect(); await server.stop() } }
            var entry = Resource(name: "v", uri: "ui://v")
            entry.ui = weatherMeta
            let given = try await client.readAppResource(uri: "ui://v", listing: entry)
            #expect(given.meta == expected, "\(ui)")
            let found = try await client.readAppResource(uri: "ui://v")
            #expect(found.meta == expected, "\(ui)")
            #expect(found.contentSecurityPolicy == (expected ?? .init()).contentSecurityPolicy)
        }
    }

    @Test("Errors: not a ui:// URI, no content for the URI, another MIME type, no HTML")
    func errors() async throws {
        let (client, server) = try await connect { server in
            await server.withMethodHandler(ReadResource.self) { params in
                switch params.uri {
                case "ui://other": return .init(contents: [.text("x", uri: "ui://elsewhere", mimeType: UIResource.mimeType)])
                case "ui://plain": return .init(contents: [.text("x", uri: params.uri, mimeType: "text/html")])
                case "ui://none": return .init(contents: [.text("x", uri: params.uri)])
                default: return .init(contents: [.binary(Data([0xff, 0xfe]), uri: params.uri, mimeType: UIResource.mimeType)])
                }
            }
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        let cases: [(String, AppResourceError.Reason)] = [
            ("https://x", .notUIResource), ("ui://", .notUIResource), ("ui://other", .missingContent),
            ("ui://plain", .unsupportedMimeType), ("ui://none", .unsupportedMimeType), ("ui://bytes", .invalidContent),
        ]
        for (uri, reason) in cases {
            do {
                _ = try await client.readAppResource(uri: uri)
                Issue.record("\(uri) was read")
            } catch let error as AppResourceError {
                #expect(error.reason == reason, "\(uri)")
                #expect(error.uri == uri)
            }
        }
    }

    @Test("The view MIME type: case, whitespace, quotes and other parameters")
    func mimeType() {
        for valid in [
            "text/html;profile=mcp-app", "text/html; profile=mcp-app", "TEXT/HTML;Profile=\"mcp-app\"",
            "text/html;charset=utf-8;profile=mcp-app", "text/html ; profile = mcp-app",
        ] {
            #expect(Client.isViewMimeType(valid), "\(valid)")
        }
        for invalid in [
            "text/html", "text/plain;profile=mcp-app", "text/html;profile=MCP-APP", "text/html;profile=mcp-app2",
            "text/html;profile", "",
        ] {
            #expect(!Client.isViewMimeType(invalid), "\(invalid)")
        }
    }

    @Test("A handler reads the client's settings", arguments: [false, true])
    func clientSettings(handshake: Bool) async throws {
        var capabilities = Client.Capabilities()
        capabilities.ui = UIExtensionSettings()
        let (client, server) = try await connect(
            configuration: handshake ? .handshake : .default, capabilities: capabilities
        ) { server in
            await server.withMethodHandler(ListTools.self) { _ in
                var tool = Tool(name: "weather", description: "Weather", inputSchema: ["type": "object"])
                if Server.currentHandlerContext?.clientUISettings?.supports() == true {
                    tool.ui = ToolUIMeta(resourceUri: dashboardURI)
                }
                return .init(tools: [tool])
            }
            await server.withMethodHandler(CallTool.self) { _ in .init(content: [.text(text: "sunny")]) }
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(try await client.listTools().tools.first?.ui?.resourceUri == dashboardURI)
    }
}
