import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

actor HTTPApp {
    /// Configuration for the HTTP application.
    struct Configuration: Sendable {
        /// The host address to bind to.
        var host: String

        /// The port to bind to.
        var port: Int

        /// The MCP endpoint path.
        var endpoint: String

        /// Session timeout in seconds.
        var sessionTimeout: TimeInterval

        /// SSE retry interval in milliseconds for priming events.
        var retryInterval: Int?

        init(
            host: String = "127.0.0.1",
            port: Int = 3000,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = nil
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
            self.retryInterval = retryInterval
        }
    }

    /// Factory function to create MCP Server instances for each session.
    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]

    nonisolated let logger: Logger

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    // MARK: - Init

    /// Creates a new HTTP application.
    ///
    /// - Parameters:
    ///   - configuration: Application configuration.
    ///   - validationPipeline: Custom validation pipeline passed to each transport.
    ///     If `nil`, transports use their sensible defaults.
    ///   - serverFactory: Factory function to create Server instances for each session.
    ///   - logger: Optional logger instance.
    init(
        configuration: Configuration = Configuration(),
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline
        self.logger = logger ?? Logger(
            label: "mcp.http.app",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    /// Convenience initializer with individual parameters.
    init(
        host: String = "127.0.0.1",
        port: Int = 3000,
        endpoint: String = "/mcp",
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.init(
            configuration: Configuration(host: host, port: port, endpoint: endpoint),
            serverFactory: serverFactory,
            logger: logger
        )
    }

    // MARK: - Lifecycle

    /// Starts the HTTP application.
    ///
    /// This starts the NIO HTTP server and begins accepting connections.
    /// The call blocks until the server is shut down via ``stop()``.
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        logger.info(
            "Starting MCP HTTP application",
            metadata: [
                "host": "\(configuration.host)",
                "port": "\(configuration.port)",
                "endpoint": "\(configuration.endpoint)",
            ]
        )

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel

        Task { await sessionCleanupLoop() }

        try await channel.closeFuture.get()
    }

    /// Stops the HTTP application gracefully, closing all sessions.
    func stop() async {
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        logger.info("MCP HTTP application stopped")
    }

    // MARK: - Request Routing

    var endpoint: String { configuration.endpoint }

    /// Routes an incoming HTTP request to the appropriate session transport.
    ///
    /// - Requests with a valid `Mcp-Session-Id` are forwarded to the matching transport.
    /// - POST requests with an `initialize` body or a modern-profile request
    ///   (`server/discover`, `subscriptions/listen`, modern `_meta`) create a session.
    /// - All other requests without a session return an error.
    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            // Clean up on successful DELETE
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }

            return response
        }

        // No session — create one for initialize or modern-profile POSTs
        // (server/discover, subscriptions/listen, modern `_meta` version).
        // Stale/unknown Mcp-Session-Id must 404, not mint a replacement session.
        if sessionID == nil,
            request.method.uppercased() == "POST",
            let body = request.body,
            let kind = JSONRPCMessageKind(data: body)
        {
            let headerVersion = request.header(HTTPHeaderName.protocolVersion)
            let isModern = JSONRPCMessageKind.isModernProfile(
                kind: kind,
                body: body,
                headerProtocolVersion: headerVersion
            )
            if kind.isInitializeRequest || isModern {
                return await createSessionAndHandle(request)
            }
        }

        // No session and not a session-creating request
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger
        )

        do {
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            // If transport returned an error, clean up
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
        logger.info("Closed session", metadata: ["sessionID": "\(sessionID)"])
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
    }

    private func sessionCleanupLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(60))

            let now = Date()
            let expired = sessions.filter { _, context in
                now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout
            }

            for (sessionID, _) in expired {
                logger.info("Session expired", metadata: ["sessionID": "\(sessionID)"])
                await closeSession(sessionID)
            }
        }
    }
}

// MARK: - NIO HTTP Handler

/// Thin NIO adapter that converts between NIO HTTP types and the framework-agnostic
/// `HTTPRequest`/`HTTPResponse` types, delegating all logic to the `HTTPApp`.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: HTTPApp

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var requestState: RequestState?
    /// Active SSE response pump; cancelled when the client disconnects.
    /// Mutated only on the channel event loop (channelInactive / eventLoop.execute).
    private var activeStreamTask: Task<Void, Never>?
    /// Identity for the active pump (Task is not Equatable).
    private var activeStreamToken: UUID?
    /// Set on the event loop when the channel becomes inactive so a late pump
    /// registration can cancel immediately instead of parking forever.
    private var channelClosed = false

    init(app: HTTPApp) {
        self.app = app
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelClosed = true
        let task = activeStreamTask
        activeStreamTask = nil
        activeStreamToken = nil
        task?.cancel()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            Task { @MainActor in
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    // MARK: - Request Processing

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await app.endpoint

        guard path == endpoint else {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return
        }

        let httpRequest = makeHTTPRequest(from: state)
        let response = await app.handleHTTPRequest(httpRequest)
        await writeResponse(response, version: head.version, context: context)
    }

    // MARK: - NIO ↔ HTTPRequest/HTTPResponse Conversion

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        // Combine multiple header values per RFC 7230
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
            let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))

        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        // Write response head
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            // Gate the pump until it is registered on the event loop so
            // channelInactive can cancel it if the client disconnects immediately.
            let gate = OneShotGate()
            let pumpToken = UUID()
            let pump = Task {
                await gate.wait()
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        eventLoop.execute {
                            var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                            buffer.writeBytes(chunk)
                            ctx.writeAndFlush(
                                self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        }
                    }
                } catch {
                    // Truncate the SSE stream so the client can distinguish failure.
                    eventLoop.execute {
                        self.channelClosed = true
                        ctx.close(promise: nil)
                    }
                }
            }
            eventLoop.execute {
                if self.channelClosed {
                    pump.cancel()
                } else {
                    self.activeStreamTask = pump
                    self.activeStreamToken = pumpToken
                }
                gate.open()
            }
            await pump.value
            eventLoop.execute {
                if self.activeStreamToken == pumpToken {
                    self.activeStreamTask = nil
                    self.activeStreamToken = nil
                }
            }

            if !pump.isCancelled {
                eventLoop.execute {
                    // Skip a graceful .end if the channel already closed (error path).
                    guard !self.channelClosed else { return }
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }

                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

/// Single-use async gate so an SSE pump can wait until it is registered for cancel.
private final class OneShotGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private let lock = NSLock()

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}
