// An MCP server over HTTP that serves one tool to clients of both protocol eras.
//
//   swift run HTTPServerExample --port 3000
//
// The endpoint is http://127.0.0.1:<port>/mcp. Requests are routed as the SDK
// expects (see docs/protocol.md, "Routing both eras on one endpoint"):
//
// - A request whose MCP-Protocol-Version header names a stateless revision
//   (2026-07-28) goes to one shared Server on a StatelessHTTPServerTransport.
// - Any other request belongs to a handshake session: `initialize` creates a
//   Server and a StatefulHTTPServerTransport, and later requests are routed by
//   their Mcp-Session-Id header. Idle sessions are closed after 10 minutes.
//
// Limits a deployed server needs too: at most 100 sessions (503 beyond),
// request bodies of at most 4 MiB (413), and the Host and Origin checks of
// OriginValidator for this port. The server has no authentication: anyone who
// can reach the port can use it, so it listens on 127.0.0.1 only.
//
// Try it with curl:
//
//   curl -sN http://127.0.0.1:3000/mcp \
//     -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
//     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25",
//          "capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
//
//   curl -s http://127.0.0.1:3000/mcp \
//     -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
//     -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' \
//     -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{
//          "io.modelcontextprotocol/protocolVersion":"2026-07-28",
//          "io.modelcontextprotocol/clientCapabilities":{}}}}'

import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

// MARK: - The MCP server

/// A server with one tool, `echo`. The same code serves both eras.
func makeServer() async -> Server {
    let server = Server(name: "http-example", version: "1.0.0", capabilities: .init(tools: .init()))
    let echo = Tool(
        name: "echo", description: "Returns its input",
        inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]])
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: [echo]) }
    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == echo.name, let text = params.arguments?["text"]?.stringValue else {
            throw MCPError.invalidParams("echo needs a string argument \"text\"")
        }
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
    }
    return server
}

// MARK: - Routing

actor Router {
    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastUsed = Date()
        /// Requests whose response, or SSE stream, has not ended.
        var inFlight = 0
    }

    static let maxSessions = 100
    static let idleTimeout: TimeInterval = 600

    private let port: Int
    private let stateless: StatelessHTTPServerTransport
    private var sessions: [String: Session] = [:]

    init(port: Int) {
        self.port = port
        stateless = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ]))
    }

    /// Starts the shared stateless server and the idle-session reaper.
    func start() async throws {
        try await makeServer().start(transport: stateless)
        Task { await reapIdleSessions() }
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // 2026-07-28: no session, one shared server.
        if request.statelessProtocolVersion != nil {
            return await stateless.handleRequest(request)
        }
        // Handshake era: route by session.
        if let id = request.header(HTTPHeaderName.sessionID) {
            guard let session = sessions[id] else {
                return .error(statusCode: 404, .invalidRequest("Session not found"))
            }
            sessions[id]?.lastUsed = Date()
            sessions[id]?.inFlight += 1
            let response = await session.transport.handleRequest(request)
            if request.method == "DELETE", response.statusCode == 200 {
                await close(id)
                return response
            }
            return tracked(response) { await self.finished(id) }
        }
        // No session: only a POST `initialize` creates one.
        guard request.method == "POST", Self.isInitialize(request.body) else {
            return .error(statusCode: 400, .invalidRequest("Missing Mcp-Session-Id; send initialize first"))
        }
        guard sessions.count < Self.maxSessions else {
            return .error(statusCode: 503, .internalError("Too many sessions"))
        }
        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ]))
        let server = await makeServer()
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(statusCode: 500, .internalError("\(error)"))
        }
        let response = await transport.handleRequest(request)
        if let id = response.headers[HTTPHeaderName.sessionID], case .stream = response {
            sessions[id] = Session(server: server, transport: transport, inFlight: 1)
            return tracked(response) { await self.finished(id) }
        }
        await server.stop()
        return response
    }

    private static func isInitialize(_ body: Data?) -> Bool {
        guard let body, let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return message["method"] as? String == "initialize"
    }

    /// Calls `onEnd` when the response, or its SSE stream, ends.
    private nonisolated func tracked(
        _ response: HTTPResponse, onEnd: @escaping @Sendable () async -> Void
    ) -> HTTPResponse {
        guard case .stream(let events, let headers) = response else {
            Task { await onEnd() }
            return response
        }
        let (forwarded, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        let forwarding = Task {
            do {
                for try await chunk in events { continuation.yield(chunk) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await onEnd()
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return .stream(forwarded, headers: headers)
    }

    private func finished(_ id: String) {
        sessions[id]?.inFlight -= 1
        sessions[id]?.lastUsed = Date()
    }

    private func close(_ id: String) async {
        await sessions.removeValue(forKey: id)?.server.stop()
    }

    /// Closes sessions with nothing in flight and no request for 10 minutes.
    private func reapIdleSessions() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            for id in Array(sessions.keys) {
                // Read the live entry: a request may have arrived during an await.
                guard let session = sessions[id], session.inFlight == 0,
                    Date().timeIntervalSince(session.lastUsed) > Self.idleTimeout
                else { continue }
                await close(id)
            }
        }
    }
}

// MARK: - SwiftNIO adapter

/// Converts NIO requests to `HTTPRequest`, and `HTTPResponse` back, including SSE streams.
final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// The largest request body accepted.
    static let maxBodySize = 4 << 20

    private let router: Router
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var bodyTooLarge = false
    private var task: Task<Void, Never>?

    init(router: Router) { self.router = router }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body.clear()
            bodyTooLarge = false
        case .body(var chunk):
            guard !bodyTooLarge else { return }
            guard body.readableBytes + chunk.readableBytes <= Self.maxBodySize else {
                bodyTooLarge = true
                body.clear()
                return
            }
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            if bodyTooLarge {
                let response = HTTPResponse.error(statusCode: 413, .invalidRequest("Request body too large"))
                nonisolated(unsafe) let context = context
                task = Task {
                    await self.write(response, version: head.version, context: context)
                    context.eventLoop.execute { context.close(promise: nil) }
                }
                return
            }
            let request = makeRequest(head)
            nonisolated(unsafe) let context = context
            task = Task {
                let response: HTTPResponse
                if request.path == "/mcp" {
                    response = await router.handle(request)
                } else {
                    response = .error(statusCode: 404, .invalidRequest("Not Found"))
                }
                await self.write(response, version: head.version, context: context)
            }
        }
    }

    /// The client went away: cancel the response, which ends its SSE stream.
    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel()
        context.fireChannelInactive()
    }

    private func makeRequest(_ head: HTTPRequestHead) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let bytes = body.readableBytes > 0 ? body.getBytes(at: body.readerIndex, length: body.readableBytes) : nil
        let path = String(head.uri.split(separator: "?").first ?? "")
        return HTTPRequest(method: head.method.rawValue, headers: headers, body: bytes.map { Data($0) }, path: path)
    }

    private func write(_ response: HTTPResponse, version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let context = context
        let responseHead = HTTPResponseHead(
            version: version, status: .init(statusCode: response.statusCode),
            headers: HTTPHeaders(response.headers.map { ($0.key, $0.value) }))

        let send: @Sendable (ByteBuffer) -> Void = { buffer in
            context.eventLoop.execute {
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
        }
        context.eventLoop.execute {
            context.writeAndFlush(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        }
        if case .stream(let events, _) = response {
            do {
                for try await chunk in events { send(ByteBuffer(bytes: chunk)) }
            } catch {}  // the stream failed: end the response
        } else if let data = response.bodyData {
            send(ByteBuffer(bytes: data))
        }
        context.eventLoop.execute {
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

// MARK: - Main

var port = 3000
if let index = CommandLine.arguments.firstIndex(of: "--port"), index + 1 < CommandLine.arguments.count {
    port = Int(CommandLine.arguments[index + 1]) ?? port
}

let router = Router(port: port)
try await router.start()

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(HTTPHandler(router: router))
        }
    }
let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
print("MCP server listening on http://127.0.0.1:\(port)/mcp")
try await channel.closeFuture.get()
