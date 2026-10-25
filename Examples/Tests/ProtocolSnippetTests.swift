import Foundation
import Testing

@testable import MCP
@testable import ProtocolSnippets

@Suite("Protocol snippets", .timeLimit(.minutes(1)))
struct ProtocolSnippetTests {
    @Test func handshakeNegotiatesLatestHandshakeRevision() async throws {
        let version = try await connectWithHandshake(server: await makeLifecycleServer())
        #expect(version == Version.v2025_11_25)
    }

    @Test func automaticModeDiscoversStatelessRevision() async throws {
        let version = try await connectAutomatically(server: await makeLifecycleServer())
        #expect(version == Version.v2026_07_28)
    }

    @Test func handlerContextReportsTheEra() async throws {
        let server = await makeLifecycleServer()
        let client = Client(
            name: "example-client", version: "1.0.0", configuration: .init(protocolMode: .automatic))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)
        let (content, _) = try await client.callTool(name: "whoami")
        #expect(content == [.text(text: "example-client at 2026-07-28, stateless: true", annotations: nil, _meta: nil)])
        await client.disconnect()
        await server.stop()
    }

    @Test func initializeHookRefusesClient() async throws {
        let server = Server(name: "example", version: "1.0.0")
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await startWithInitializeHook(server, transport: serverTransport)
        let client = Client(name: "blocked", version: "1.0.0")
        await #expect(throws: MCPError.self) { try await client.connect(transport: clientTransport) }
        await client.disconnect()
        await server.stop()
    }

    @Test func unsupportedVersionListsServedVersions() async throws {
        #expect(try await connectToHandshakeOnlyServer() == Version.handshake)
    }

    @Test func metaKeysEncodeIntoParams() async throws {
        let data = try JSONEncoder().encode(statelessEnvelope())
        let json = try JSONDecoder().decode(Value.self, from: data)
        let meta = json.objectValue?["params"]?.objectValue?["_meta"]?.objectValue
        #expect(meta?[MetaKey.protocolVersion] == "2026-07-28")
        #expect(meta?[MetaKey.logLevel] == "info")
        #expect(meta?[MetaKey.clientInfo]?.objectValue?["name"] == "raw-client")
        #expect(await narrowedServer().configuration.protocolVersions == ["2026-07-28", "2025-11-25"])
    }

    @Test func requestHeaderParameters() throws {
        #expect(try callToolHeaders() == ["Mcp-Param-Region": "eu-west"])
        #expect(MCPRequestHeaders.encode("Zürich") == "=?base64?WsO8cmljaA==?=")
    }

    @Test func endpointRoutesStatelessRequests() async throws {
        let endpoint = MCPEndpoint()
        let response = await endpoint.handle(try statelessListToolsRequest())
        #expect(response.statusCode == 200)
        let body = try #require(response.bodyData)
        let json = try JSONDecoder().decode(Value.self, from: body)
        #expect(json.objectValue?["result"]?.objectValue?["tools"] == [])
        #expect(json.objectValue?["result"]?.objectValue?["resultType"] == "complete")
    }

    @Test func endpointRoutesInitializeToASession() async throws {
        let endpoint = MCPEndpoint()
        let initialize = Initialize.request(
            .init(
                protocolVersion: Version.v2025_11_25, capabilities: .init(),
                clientInfo: .init(name: "curl", version: "1")))
        let request = HTTPRequest(
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"],
            body: try JSONEncoder().encode(initialize), path: "/mcp")
        let response = await endpoint.handle(request)
        #expect(response.headers[HTTPHeaderName.sessionID] != nil)
        guard case .stream(let stream, _) = response else {
            Issue.record("expected an SSE stream, got \(response.statusCode)")
            return
        }
        var text = ""
        for try await chunk in stream {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("\"result\"") { break }
        }
        #expect(text.contains("\"protocolVersion\":\"2025-11-25\""))
    }

    @Test func customTransportCarriesAConnection() async throws {
        let (toServer, toServerContinuation) = AsyncStream<Data>.makeStream()
        let (toClient, toClientContinuation) = AsyncStream<Data>.makeStream()
        func throwing(_ stream: AsyncStream<Data>) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for await data in stream { continuation.yield(data) }
                    continuation.finish()
                }
            }
        }
        let serverTransport = StreamTransport(incoming: throwing(toServer), outgoing: toClientContinuation)
        let clientTransport = StreamTransport(incoming: throwing(toClient), outgoing: toServerContinuation)
        let server = Server(name: "example", version: "1.0.0")
        let client = Client(name: "example-client", version: "1.0.0")
        try await server.start(transport: serverTransport)
        let result = try await client.connect(transport: clientTransport)
        #expect(result.serverInfo.name == "example")
        try await pingServer(client)
        await client.disconnect()
        await server.stop()
    }

    @Test func listenStreamDeliversToolChanges() async throws {
        let honored = try await listenForToolChanges()
        #expect(honored == SubscriptionFilter(toolsListChanged: true))
    }

    @Test("The subscription authorizer narrows the filter")
    func listenAuthorizer() async throws {
        #expect(try await listenToPublicResources() == ["public://a"])
    }

    @Test(arguments: [Client.ProtocolMode.handshake, .automatic])
    func cancellationReachesTheHandler(mode: Client.ProtocolMode) async throws {
        let (client, server) = try await cancelSlowCall(protocolMode: mode)
        #expect(client == "cancelled")
        #expect(server == "tool cancelled")
    }

    @Test func progressNotificationsArriveBeforeTheResult() async throws {
        #expect(try await reportProgress() == ["step 1 1/3", "step 2 2/3", "step 3 3/3"])
    }

    @Test func resourceNotFoundIsMinus32602() async throws {
        let server = Server(name: "example", version: "1.0.0", capabilities: .init(resources: .init()))
        await registerResourceNotFound(on: server)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "example-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        #expect(await classifyError(client) == -32602)
        await client.disconnect()
        await server.stop()
    }

    @Test func protectedPipelineChallengesAndServesMetadata() throws {
        let pipeline = protectedPipeline()
        let post = HTTPRequest(
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"],
            body: Data("{}".utf8), path: "/mcp")
        let context = HTTPValidationContext(
            httpMethod: "POST", sessionID: nil, isInitializationRequest: true,
            supportedProtocolVersions: Version.supported)
        let challenge = try #require(pipeline.validate(post, context: context))
        #expect(challenge.statusCode == 401)
        #expect(challenge.headers[HTTPHeaderName.wwwAuthenticate]?.contains("resource_metadata=") == true)

        var authorized = post.headers
        authorized["Authorization"] = "Bearer valid-token"
        authorized["Host"] = "mcp.example.com"
        let accepted = pipeline.validate(
            HTTPRequest(method: "POST", headers: authorized, body: post.body, path: "/mcp"), context: context)
        #expect(accepted == nil)

        let get = HTTPRequest(method: "GET", path: "/.well-known/oauth-protected-resource")
        let getContext = HTTPValidationContext(
            httpMethod: "GET", sessionID: nil, isInitializationRequest: false,
            supportedProtocolVersions: Version.supported)
        #expect(pipeline.validate(get, context: getContext)?.statusCode == 200)
    }
}
