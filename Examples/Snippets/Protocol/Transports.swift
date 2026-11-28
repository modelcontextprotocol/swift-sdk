import Foundation
import Logging
import MCP

#if canImport(System)
    import System
#endif

// Snippets for docs/protocol.md, section "Transports".

#if canImport(System)
    /// Serves a server over the process's stdin and stdout until the client goes away.
    func runStdioServer() async throws {
        // snippet: transport-stdio-server
        let server = Server(name: "example", version: "1.0.0", capabilities: .init(tools: .init()))
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
        // endsnippet
    }
#endif

#if canImport(System) && os(macOS)
    /// Launches a server executable and connects to it over pipes.
    func connectToSubprocess(executable: URL) async throws -> Client {
        // snippet: transport-stdio-client
        let process = Process()
        process.executableURL = executable
        let toServer = Pipe()
        let fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        try process.run()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
        let client = Client(name: "example-client", version: "1.0.0")
        try await client.connect(transport: transport)
        // endsnippet
        return client
    }
#endif

/// Connects to a Streamable HTTP server.
func connectOverHTTP(endpoint: URL) async throws -> Client {
    // snippet: transport-http-client
    let transport = HTTPClientTransport(
        endpoint: endpoint,  // for example http://localhost:3000/mcp
        streaming: true,  // open the GET stream on handshake connections
        requestModifier: { request in
            var request = request
            request.setValue("example/1.0", forHTTPHeaderField: "User-Agent")
            return request
        })
    let client = Client(name: "example-client", version: "1.0.0")
    try await client.connect(transport: transport)
    // endsnippet
    return client
}

/// Builds a server. Each HTTP session gets its own instance.
@Sendable func makeHTTPServer() async -> Server {
    let server = Server(name: "example", version: "1.0.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
    return server
}

// snippet: transport-stateful-sessions
/// One `Server` and one `StatefulHTTPServerTransport` per `Mcp-Session-Id`.
/// A sketch: it has no session limit and no idle reaper, and starts a server
/// for any request without a session; `Examples/http-server/main.swift` has
/// the guards a deployed router needs.
actor SessionRouter {
    private var sessions: [String: (server: Server, transport: StatefulHTTPServerTransport)] = [:]

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let id = request.header(HTTPHeaderName.sessionID) {
            guard let session = sessions[id] else {
                return .error(statusCode: 404, .invalidRequest("Session not found"))
            }
            let response = await session.transport.handleRequest(request)
            if request.method == "DELETE", response.statusCode == 200 {
                sessions[id] = nil
                await session.server.stop()
            }
            return response
        }
        // No session yet: the transport accepts only `initialize` here.
        let transport = StatefulHTTPServerTransport()
        let server = await makeHTTPServer()
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(statusCode: 500, .internalError("\(error)"))
        }
        let response = await transport.handleRequest(request)
        // A refused `initialize` (an initialize hook threw) carries the header
        // too: the transport refuses later requests with its ID, and the entry
        // stays until the session is deleted.
        if let id = response.headers[HTTPHeaderName.sessionID] {
            sessions[id] = (server, transport)
        } else {
            await server.stop()
        }
        return response
    }
}
// endsnippet

// snippet: transport-routing
/// Serves both eras on one endpoint.
actor MCPEndpoint {
    private let stateless = StatelessHTTPServerTransport()
    private let sessions = SessionRouter()
    private var startup: Task<Void, Error>?

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // A 2026-07-28 request names its version in MCP-Protocol-Version.
        guard request.statelessProtocolVersion != nil else {
            return await sessions.handle(request)
        }
        // One shared server answers every stateless request. The first request
        // starts it; the others wait for the same start.
        let startup = self.startup ?? Task { try await makeHTTPServer().start(transport: stateless) }
        self.startup = startup
        do {
            try await startup.value
        } catch {
            if self.startup == startup { self.startup = nil }  // the next request tries again
            return .error(statusCode: 500, .internalError("Server failed to start: \(error)"))
        }
        return await stateless.handleRequest(request)
    }
}
// endsnippet

/// The raw headers and body of a 2026-07-28 `tools/list` request.
func statelessListToolsRequest() throws -> HTTPRequest {
    // snippet: transport-stateless-request
    var meta = Metadata()
    meta.protocolVersion = Version.v2026_07_28
    meta.clientCapabilities = Client.Capabilities()
    let body = try JSONEncoder().encode(ListTools.request(.init(), _meta: meta))

    let request = HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            HTTPHeaderName.protocolVersion: Version.v2026_07_28,
            MCPRequestHeaders.method: ListTools.name,
        ],
        body: body,
        path: "/mcp")
    // endsnippet
    return request
}

/// The SEP-2243 header values for a `tools/call` request.
func callToolHeaders() throws -> [String: String] {
    // snippet: transport-request-headers
    let tool = Tool(
        name: "deploy", description: "Deploy a service",
        inputSchema: [
            "type": "object",
            "properties": [
                "region": ["type": "string", "x-mcp-header": "Region"],
                "service": ["type": "string"],
            ],
        ])
    let parameters = try tool.headerParameters()  // throws for invalid annotations
    let headers = MCPRequestHeaders.parameterHeaders(
        parameters, arguments: ["region": "eu-west", "service": "api"])
    print(headers)  // ["Mcp-Param-Region": "eu-west"]

    print(MCPRequestHeaders.encode("Zürich"))  // =?base64?WsO8cmljaA==?=
    // endsnippet
    return headers
}

/// A client and server in one process.
func connectInMemory() async throws -> (Client, Server) {
    // snippet: transport-in-memory
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let server = Server(name: "example", version: "1.0.0")
    let client = Client(name: "example-client", version: "1.0.0")
    try await server.start(transport: serverTransport)
    try await client.connect(transport: clientTransport)
    // endsnippet
    return (client, server)
}

// snippet: transport-custom
/// A transport over a pair of `AsyncStream`s, for example a WebSocket bridge.
actor StreamTransport: Transport {
    nonisolated let logger = Logger(label: "example.stream-transport")
    private let outgoing: AsyncStream<Data>.Continuation
    private let incoming: AsyncThrowingStream<Data, Swift.Error>

    init(incoming: AsyncThrowingStream<Data, Swift.Error>, outgoing: AsyncStream<Data>.Continuation) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    func connect() async throws {}

    func disconnect() async { outgoing.finish() }

    /// `data` is one JSON-RPC message or batch, without a trailing newline.
    func send(_ data: Data) async throws { outgoing.yield(data) }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { incoming }
}
// endsnippet

/// Registers a handler that hands its context to detached work.
func registerDetachedWork(on server: Server) async {
    // snippet: transport-task-local
    await server.withMethodHandler(CallTool.self) { params in
        // Task-locals do not flow into detached tasks: capture first.
        let context = Server.currentHandlerContext
        let userAgent = await Task.detached {
            context?.httpContext?.header("User-Agent") ?? "unknown"
        }.value
        return .init(content: [.text(text: userAgent)])
    }
    // endsnippet
}
