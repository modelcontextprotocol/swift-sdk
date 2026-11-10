import Foundation
import Logging

/// A stateless HTTP server transport: one HTTP exchange per JSON-RPC request.
///
/// This transport serves requests that do not belong to a session:
/// - Protocol 2026-07-28 and later, where every request carries its protocol
///   version and client capabilities in `_meta` (SEP-2575).
/// - Earlier revisions used without session management.
///
/// Behavior:
/// - POST only; GET and DELETE return 405 Method Not Allowed.
/// - No `Mcp-Session-Id` header is read or set.
/// - The response is a single JSON body. When the handler sends notifications
///   for the request (progress, logging) and the client accepts
///   `text/event-stream`, the response is an SSE stream that carries those
///   notifications and ends with the response.
/// - On 2026-07-28 requests, `Mcp-Method` and `Mcp-Name` must match the body
///   (SEP-2243); a mismatch is answered with 400 and -32020.
/// - On 2026-07-28 requests, JSON-RPC errors use HTTP status codes:
///   404 for -32601; 400 for -32600, -32602 and -32020 to -32022.
/// - Validators check `MCP-Protocol-Version` against the versions of the
///   server started on the transport (`Server.Configuration.protocolVersions`),
///   so -32022 lists those. When they include no handshake revision, every
///   error gets its 2026-07-28 HTTP status.
/// - Each request is given a unique internal JSON-RPC id while in flight, so
///   concurrent clients may reuse ids.
/// - A client cancels a request by closing its HTTP request; the adapter
///   must then cancel the task that awaits ``handleRequest(_:)``.
///   `notifications/cancelled` is honored only when it carries the same
///   `Authorization` header as exactly one request in flight with that id;
///   the cancelled request's HTTP response then ends without a JSON-RPC
///   response: 202 Accepted, or the end of its SSE stream.
/// - At most ``maxBufferedMessages`` messages are buffered per request for a
///   slow client; older notifications are dropped first, never the response.
/// - An open SSE stream carries a `: keep-alive` comment every
///   `keepAliveInterval` (15 seconds by default), so that idle streams such
///   as `subscriptions/listen` are not closed by client or proxy timeouts.
/// - `subscriptions/listen` without `text/event-stream` in `Accept` is
///   answered with 406: its notifications need an SSE stream.
///
/// ## Usage
///
/// ```swift
/// let transport = StatelessHTTPServerTransport()
///
/// // Start the MCP server with this transport
/// try await server.start(transport: transport)
///
/// // In your HTTP framework handler:
/// let response = await transport.handleRequest(httpRequest)
/// // Convert response to your framework's response type and return it
/// ```
///
/// To serve both session-based and stateless clients on one endpoint, route
/// requests whose ``HTTPRequest/statelessProtocolVersion`` is non-`nil` to
/// this transport and the rest to a ``StatefulHTTPServerTransport``.
public actor StatelessHTTPServerTransport: Transport, HTTPContextProviding {
    /// The logger of the transport; a no-op logger unless one was passed to `init`.
    public nonisolated let logger: Logger

    // MARK: - Dependencies

    private let validationPipeline: any HTTPRequestValidationPipeline

    // MARK: - State

    private var terminated = false
    private var started = false

    // MARK: - Incoming message stream (client → server)

    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    // MARK: - In-flight requests

    /// A message the server sends for a request in flight.
    private enum Outgoing: Sendable {
        /// A notification or request related to the request.
        case message(Data)
        /// The response, with the client's id, and its error code if any.
        case response(Data, errorCode: Int?)
        /// The client cancelled the request; no response follows.
        case cancelled
    }

    /// A request handed to the server and not yet answered.
    private struct Exchange {
        /// The JSON-RPC id the client sent.
        let clientID: ID
        /// The originating HTTP request, surfaced via ``Server/currentHandlerContext``.
        let request: HTTPRequest
        /// Messages the server sends for this request, ending with the response.
        let outgoing: AsyncStream<Outgoing>.Continuation
    }

    /// The most messages buffered for one request while its client reads
    /// slowly. The oldest are dropped first; the response is always last.
    public static let maxBufferedMessages = 1024

    /// In-flight requests keyed by the internal id given to the server.
    private var exchanges: [String: Exchange] = [:]

    /// The interval of `: keep-alive` comments on open SSE streams; `nil`
    /// sends none.
    public let keepAliveInterval: Duration?

    /// An SSE comment line: ignored by clients, keeps the connection busy.
    static let keepAliveComment = Data(": keep-alive\n\n".utf8)

    /// The protocol versions the server on this transport serves, newest
    /// first; set by ``Server/start(transport:initializeHook:statelessRequestHook:)``.
    private var servedVersions = Version.stateless + Version.handshake

    /// Sets the protocol versions the server on this transport serves.
    func serve(protocolVersions: [String]) {
        servedVersions = protocolVersions
    }

    /// Whether the server serves a handshake revision. A server that serves
    /// none answers every request by the 2026-07-28 rules, including the
    /// HTTP status of its errors.
    private var servesHandshake: Bool {
        servedVersions.contains { Version.handshake.contains($0) }
    }

    // MARK: - Init

    /// Creates a new stateless HTTP server transport.
    ///
    /// - Parameters:
    ///   - validationPipeline: Custom validation pipeline. If `nil`, uses sensible defaults:
    ///     origin validation (localhost), Accept header (JSON required), Content-Type,
    ///     and protocol version validation.
    ///   - keepAliveInterval: The interval of `: keep-alive` comments on
    ///     open SSE streams; `nil` sends none.
    ///   - logger: Optional logger. If `nil`, a no-op logger is used.
    public init(
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        keepAliveInterval: Duration? = .seconds(15),
        logger: Logger? = nil
    ) {
        self.keepAliveInterval = keepAliveInterval
        self.validationPipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
        self.logger = logger ?? Logger(
            label: "mcp.transport.http.server.stateless",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = stream
        self.incomingContinuation = continuation
    }

    // MARK: - Transport Conformance

    /// Marks the transport started; it opens no socket, since the framework
    /// adapter delivers requests through ``handleRequest(_:)``.
    ///
    /// - Throws: ``MCPError/internalError(_:)`` when already started.
    public func connect() async throws {
        guard !started else {
            throw MCPError.internalError("Transport already started")
        }
        started = true
        logger.debug("Stateless HTTP server transport started")
    }

    /// Stops the transport: ends every in-flight exchange and the incoming
    /// stream; later requests get 404.
    public func disconnect() async {
        terminate()
    }

    /// Routes outgoing server messages to the HTTP exchange they belong to.
    ///
    /// Responses are matched by JSON-RPC ID. Other messages are dropped:
    /// there is no stream outside a request.
    public func send(_ data: Data) async throws {
        try await send(data, relatedRequestID: nil)
    }

    /// Routes outgoing server messages to the HTTP exchange they belong to.
    ///
    /// Notifications and requests related to an in-flight request are
    /// delivered on that request's response stream; unrelated ones are
    /// dropped.
    public func send(_ data: Data, relatedRequestID: ID?) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        guard let kind = JSONRPCMessageKind(data: data) else {
            logger.warning("Could not classify outgoing message for routing")
            return
        }

        switch kind {
        case .response(let id):
            guard let exchange = exchanges.removeValue(forKey: id) else {
                logger.debug("No waiter for response", metadata: ["requestID": "\(id)"])
                return
            }
            let rewritten = JSONRPCMessageFields.replacingIDReadingErrorCode(in: data, with: exchange.clientID)
            let response = JSONRPCMessageFields.replacingSubscriptionID(
                in: rewritten?.data ?? data, internalID: id, with: exchange.clientID)
            exchange.outgoing.yield(.response(response, errorCode: rewritten?.errorCode))
            exchange.outgoing.finish()

        case .notification(let method), .request(_, let method):
            guard let related = relatedRequestID?.description, let exchange = exchanges[related]
            else {
                logger.debug(
                    "Message without an in-flight request dropped in stateless mode",
                    metadata: ["method": "\(method)"]
                )
                return
            }
            // A subscriptions/listen stream is identified by the client's id.
            exchange.outgoing.yield(
                .message(
                    JSONRPCMessageFields.replacingSubscriptionID(
                        in: data, internalID: related, with: exchange.clientID)))

        case .invalid(let method, _):
            logger.warning("Invalid outgoing message dropped", metadata: ["method": "\(method)"])
        }
    }

    /// The JSON-RPC messages that clients POST, each request carrying an
    /// internal id in place of the client's.
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    // MARK: - HTTP Request Handler

    /// Handles an incoming HTTP request from the framework adapter.
    ///
    /// Only POST is supported:
    /// - **POST**: JSON-RPC messages (requests, notifications)
    /// - **GET**: 405 Method Not Allowed
    /// - **DELETE**: 405 Method Not Allowed
    /// - Others: 405 Method Not Allowed
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if terminated {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Transport has been terminated")
            )
        }

        switch request.method.uppercased() {
        case "POST":
            return await handlePost(request)
        default:
            // Validators that answer a request themselves, such as
            // ProtectedResourceMetadataValidator for the resource metadata
            // document or ServerCardValidator (which also answers 304), run
            // for every method. Anything else is 405.
            let context = HTTPValidationContext(
                httpMethod: request.method.uppercased(), sessionID: nil,
                supportedProtocolVersions: Set(servedVersions))
            if let response = validationPipeline.validate(request, context: context),
                (200..<300).contains(response.statusCode) || response.statusCode == 304
            {
                return response
            }
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                extraHeaders: [HTTPHeaderName.allow: "POST"]
            )
        }
    }

    // MARK: - POST Handler

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body, !body.isEmpty else {
            return .error(statusCode: 400, .parseError("Empty request body"))
        }

        // Parsers resolve duplicate member names differently (JSONSerialization
        // on Linux keeps the last, JSONDecoder the first). Check and dispatch
        // one re-serialized form, which has none, so the headers are checked
        // against the values the server reads.
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let messageKind = JSONRPCMessageKind(json: json),
            let normalized = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        else {
            return .error(statusCode: 400, .parseError("Invalid JSON-RPC message"))
        }

        // One probe for the id and the `_meta` version.
        let fields = JSONRPCMessageFields.requestFields(in: normalized)
        var requestID: ID?
        switch messageKind {
        case .request, .invalid: requestID = fields.id
        case .notification, .response: break
        }

        // Validators see the versions the server serves, so a version it
        // does not serve gets -32022 listing those, here or in the server.
        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: messageKind.isInitializeRequest,
            supportedProtocolVersions: Set(servedVersions)
        )

        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse.withRequestID(requestID)
        }

        // JSON-RPC 2.0 §5: a request whose `id` cannot be read is answered
        // with -32600 and `"id": null`, not treated as a notification.
        if case .invalid(_, let reason) = messageKind {
            return .error(statusCode: 400, .invalidRequest(reason), id: requestID)
        }

        if let mismatch = Self.standardHeaderError(request, fields: fields) {
            return .error(statusCode: 400, mismatch, id: requestID)
        }

        switch messageKind {
        case .invalid(_, let reason):
            // Answered above, before the headers are checked.
            return .error(statusCode: 400, .invalidRequest(reason), id: requestID)

        case .notification(let method) where method == CancelledNotification.name:
            if let cancellation = cancellation(normalized, request: request) {
                incomingContinuation.yield(cancellation)
            } else {
                logger.debug("notifications/cancelled matches no request in flight; ignored")
            }
            return .accepted()

        case .notification, .response:
            // Forwarded as received unless the headers were checked against it.
            incomingContinuation.yield(Self.usesStandardHeaders(request) ? normalized : body)
            return .accepted()

        case .request:
            guard let requestID else {
                return .error(statusCode: 400, .invalidRequest("Invalid JSON-RPC id"))
            }
            if let mismatch = Self.versionHeaderError(request, metaVersion: fields.metaProtocolVersion) {
                return .error(statusCode: 400, mismatch, id: requestID)
            }
            if case .request(_, SubscriptionsListen.name) = messageKind,
                !(request.header(HTTPHeaderName.accept) ?? "").contains(ContentType.sse)
            {
                return .error(
                    statusCode: 406,
                    .invalidRequest("\(SubscriptionsListen.name) requires Accept: \(ContentType.sse)"),
                    id: requestID)
            }
            return await handleJSONRPCRequest(
                normalized,
                clientID: requestID,
                isStateless: request.statelessProtocolVersion != nil || !servesHandshake,
                request: request
            )
        }
    }

    /// Checks the `MCP-Protocol-Version` header against `params._meta` (SEP-2575).
    private static func versionHeaderError(_ request: HTTPRequest, metaVersion: String?) -> MCPError? {
        if let headerVersion = request.statelessProtocolVersion {
            guard let metaVersion else {
                return .invalidParams("Missing _meta field \"\(MetaKey.protocolVersion)\"")
            }
            guard metaVersion == headerVersion else {
                return .headerMismatch(
                    "\(HTTPHeaderName.protocolVersion) header \(headerVersion) does not match _meta version \(metaVersion)"
                )
            }
        } else if let metaVersion, !Version.handshake.contains(metaVersion) {
            let header = request.header(HTTPHeaderName.protocolVersion) ?? "missing"
            return .headerMismatch(
                "\(HTTPHeaderName.protocolVersion) header (\(header)) does not match _meta version \(metaVersion)"
            )
        }
        return nil
    }

    /// Whether the request's protocol revision defines `Mcp-Method` and
    /// `Mcp-Name` (SEP-2243).
    private static func usesStandardHeaders(_ request: HTTPRequest) -> Bool {
        request.statelessProtocolVersion.map { Version.profile(for: $0).usesStandardHeaders } ?? false
    }

    /// Checks `Mcp-Method` and `Mcp-Name` against the body (SEP-2243).
    ///
    /// Applies to protocol revisions that define the headers. Values are
    /// case-sensitive; surrounding whitespace is ignored.
    private static func standardHeaderError(
        _ request: HTTPRequest, fields: JSONRPCMessageFields.RequestFields
    ) -> MCPError? {
        guard usesStandardHeaders(request), let method = fields.method else { return nil }

        let methodHeader = request.header(MCPRequestHeaders.method)?
            .trimmingCharacters(in: .whitespaces)
        guard let methodHeader else {
            return .headerMismatch("Missing \(MCPRequestHeaders.method) header")
        }
        // Single-valued: repeated on several field lines, or joined with
        // commas, which method names never contain (RFC 9110 §5.3).
        guard !request.isRepeated(MCPRequestHeaders.method) else {
            return .headerMismatch("\(MCPRequestHeaders.method) header appears more than once")
        }
        guard methodHeader == method else {
            return .headerMismatch(
                "\(MCPRequestHeaders.method) header \(methodHeader) does not match method \(method)")
        }

        guard let expected = fields.nameValue else { return nil }
        guard let raw = request.header(MCPRequestHeaders.name) else {
            return .headerMismatch("Missing \(MCPRequestHeaders.name) header")
        }
        // A resource URI may contain commas: only separate lines count.
        guard !request.isRepeated(MCPRequestHeaders.name, valuesMayContainCommas: true) else {
            return .headerMismatch("\(MCPRequestHeaders.name) header appears more than once")
        }
        guard MCPRequestHeaders.decode(raw) == expected else {
            return .headerMismatch("\(MCPRequestHeaders.name) header does not match the request")
        }
        return nil
    }

    private func handleJSONRPCRequest(
        _ body: Data,
        clientID: ID,
        isStateless: Bool,
        request: HTTPRequest
    ) async -> HTTPResponse {
        let internalID = "mcp-http-\(UUID().uuidString)"
        guard let rewritten = JSONRPCMessageFields.replacingID(in: body, with: .string(internalID))
        else {
            return .error(statusCode: 400, .parseError("Invalid JSON-RPC message"), id: clientID)
        }

        let (outgoing, continuation) = AsyncStream<Outgoing>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maxBufferedMessages))
        exchanges[internalID] = Exchange(clientID: clientID, request: request, outgoing: continuation)
        incomingContinuation.yield(rewritten)

        let acceptsSSE = (request.header(HTTPHeaderName.accept) ?? "").contains(ContentType.sse)
        let logger = self.logger
        let keepAliveInterval = self.keepAliveInterval
        // The adapter cancels this task when the client goes away before the
        // response is decided: cancel the request, as for a closed SSE stream.
        return await withTaskCancellationHandler {
            await respond(
                to: outgoing, internalID: internalID, clientID: clientID,
                isStateless: isStateless, acceptsSSE: acceptsSSE, keepAliveInterval: keepAliveInterval,
                logger: logger)
        } onCancel: {
            Task { await self.abandon(internalID) }
        }
    }

    /// Waits for the server's messages for one request and turns them into
    /// the HTTP response: JSON, or an SSE stream once a notification arrives.
    private func respond(
        to outgoing: AsyncStream<Outgoing>, internalID: String, clientID: ID,
        isStateless: Bool, acceptsSSE: Bool, keepAliveInterval: Duration?, logger: Logger
    ) async -> HTTPResponse {
        await withCheckedContinuation { (decision: CheckedContinuation<HTTPResponse, Never>) in
            Task {
                var stream: AsyncThrowingStream<Data, Swift.Error>.Continuation?
                var keepAlive: Task<Void, Never>?
                defer { keepAlive?.cancel() }
                for await message in outgoing {
                    switch message {
                    case .response(let data, let errorCode):
                        if let stream {
                            stream.yield(SSEEvent.message(data: data).formatted())
                            stream.finish()
                        } else {
                            decision.resume(
                                returning: Self.jsonResponse(data, errorCode: errorCode, isStateless: isStateless))
                        }
                        return
                    case .cancelled:
                        // No response follows a cancelled request.
                        if let stream {
                            stream.finish()
                        } else {
                            decision.resume(returning: .accepted())
                        }
                        return
                    case .message(let data):
                        guard acceptsSSE else {
                            logger.debug("Notification dropped: client does not accept SSE")
                            continue
                        }
                        if stream == nil {
                            let (sse, sseContinuation) = AsyncThrowingStream<Data, Swift.Error>
                                .makeStream(bufferingPolicy: .bufferingNewest(Self.maxBufferedMessages))
                            let heartbeat = keepAliveInterval.map { interval in
                                Task {
                                    while (try? await Task.sleep(for: interval)) != nil {
                                        sseContinuation.yield(Self.keepAliveComment)
                                    }
                                }
                            }
                            keepAlive = heartbeat
                            // The client went away: cancel the request.
                            sseContinuation.onTermination = { termination in
                                heartbeat?.cancel()
                                if case .cancelled = termination {
                                    Task { await self.abandon(internalID) }
                                }
                            }
                            stream = sseContinuation
                            decision.resume(
                                returning: .stream(
                                    sse,
                                    headers: [
                                        HTTPHeaderName.contentType: ContentType.sse,
                                        HTTPHeaderName.cacheControl: "no-cache, no-transform",
                                        HTTPHeaderName.connection: "keep-alive",
                                    ]))
                        }
                        stream?.yield(SSEEvent.message(data: data).formatted())
                    }
                }
                // The transport terminated or the request was abandoned
                // before the server answered.
                if let stream {
                    stream.finish(throwing: MCPError.connectionClosed)
                } else {
                    decision.resume(
                        returning: .error(statusCode: 503, .connectionClosed, id: clientID))
                }
            }
        }
    }

    /// Forgets a request whose client went away and cancels it in the
    /// server, so that long-lived handlers such as `subscriptions/listen` end.
    private func abandon(_ internalID: String) {
        guard let exchange = exchanges.removeValue(forKey: internalID) else { return }
        exchange.outgoing.finish()
        let cancelled = CancelledNotification.message(
            .init(requestId: .string(internalID), reason: "Client disconnected"))
        if let data = try? JSONEncoder().encode(cancelled) {
            incomingContinuation.yield(data)
        }
    }

    /// A client's `notifications/cancelled`, rewritten to the internal id of
    /// the request it cancels. The request ids of different clients overlap,
    /// so it must match exactly one request in flight with that id and the
    /// same `Authorization` header; without one there is no way to tell
    /// clients apart, and the notification is not honored. A request that
    /// is cancelled is forgotten and its HTTP response ends.
    private func cancellation(_ body: Data, request: HTTPRequest) -> Data? {
        guard let authorization = request.header(HTTPHeaderName.authorization),
            let requestID = JSONRPCMessageFields.cancelledRequestID(in: body)
        else { return nil }
        let matches = exchanges.filter {
            $0.value.clientID == requestID
                && $0.value.request.header(HTTPHeaderName.authorization) == authorization
        }
        guard matches.count == 1, let internalID = matches.first?.key,
            let exchange = exchanges.removeValue(forKey: internalID)
        else { return nil }
        exchange.outgoing.yield(.cancelled)
        exchange.outgoing.finish()
        let cancelled = CancelledNotification.message(
            .init(requestId: .string(internalID), reason: "Cancelled by the client"))
        return try? JSONEncoder().encode(cancelled)
    }

    /// A JSON response; errors on 2026-07-28 requests get their HTTP status.
    private static func jsonResponse(_ data: Data, errorCode: Int?, isStateless: Bool) -> HTTPResponse {
        var status = 200
        if let code = errorCode {
            if isStateless {
                status = JSONRPCErrorStatus.statusCode(for: code)
            } else if code == MCPError.unsupportedProtocolVersion(supported: []).code {
                status = 400
            }
        }
        return .data(
            data, statusCode: status, headers: [HTTPHeaderName.contentType: ContentType.json])
    }

    // MARK: - HTTPContextProviding

    /// The HTTP request of the in-flight exchange with internal id `id`.
    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        exchanges[id.description]?.request
    }

    // MARK: - Termination

    private func terminate() {
        guard !terminated else { return }
        terminated = true

        logger.debug("Stateless HTTP server transport terminated")

        for exchange in exchanges.values {
            exchange.outgoing.finish()
        }
        exchanges.removeAll()

        incomingContinuation.finish()
    }
}

/// Reads and rewrites members of a single JSON-RPC message.
enum JSONRPCMessageFields {
    /// Decodes each member independently, so one malformed member does not
    /// hide the others.
    private struct Probe: Decodable {
        let id: ID?
        let method: String?
        let name: String?
        let uri: String?
        let taskId: String?
        let protocolVersion: String?
        let errorCode: Int?

        private enum Keys: String, CodingKey {
            case id, method, params, error, _meta, code, name, uri, taskId
            case protocolVersion = "io.modelcontextprotocol/protocolVersion"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            id = try? container.decodeIfPresent(ID.self, forKey: .id)
            method = try? container.decodeIfPresent(String.self, forKey: .method)
            let params = try? container.nestedContainer(keyedBy: Keys.self, forKey: .params)
            name = try? params?.decodeIfPresent(String.self, forKey: .name)
            uri = try? params?.decodeIfPresent(String.self, forKey: .uri)
            taskId = try? params?.decodeIfPresent(String.self, forKey: .taskId)
            let meta = try? params?.nestedContainer(keyedBy: Keys.self, forKey: ._meta)
            // An empty version is malformed, like one that is not a string:
            // read it as absent, so `Server` answers -32602 for both.
            let version = try? meta?.decodeIfPresent(String.self, forKey: .protocolVersion)
            protocolVersion = version?.isEmpty == true ? nil : version
            errorCode = try? container.nestedContainer(keyedBy: Keys.self, forKey: .error)
                .decodeIfPresent(Int.self, forKey: .code)
        }
    }

    private static func probe(_ data: Data) -> Probe? {
        try? JSONDecoder().decode(Probe.self, from: data)
    }

    /// The `id` of a message, if it is a string or an integer. `""` is a
    /// valid id; `null` is none.
    static func id(in data: Data) -> ID? {
        probe(data)?.id
    }

    /// The members of a request the transport reads, from one decode.
    struct RequestFields {
        var id: ID?
        var method: String?
        /// The `Mcp-Name` value: `params.name`, `params.uri` or
        /// `params.taskId` by method.
        var nameValue: String?
        var metaProtocolVersion: String?
    }

    /// The `id`, method, `Mcp-Name` value and `params._meta` protocol
    /// version of a message, from one decode.
    static func requestFields(in data: Data) -> RequestFields {
        let probe = probe(data)
        return RequestFields(
            id: probe?.id,
            method: probe?.method,
            nameValue: probe?.method.flatMap {
                MCPRequestHeaders.nameValue(
                    method: $0, name: probe?.name, uri: probe?.uri, taskID: probe?.taskId)
            },
            metaProtocolVersion: probe?.protocolVersion)
    }

    /// The message with its `id` replaced, and its `error.code` if it is an
    /// error response, from one parse.
    static func replacingIDReadingErrorCode(in data: Data, with id: ID) -> (data: Data, errorCode: Int?)? {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let errorCode = (json["error"] as? [String: Any])?["code"] as? Int
        switch id {
        case .string(let string): json["id"] = string
        case .number(let number): json["id"] = number
        }
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        else { return nil }
        return (rewritten, errorCode)
    }

    /// The message with its `id` replaced.
    static func replacingID(in data: Data, with id: ID) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch id {
        case .string(let string): json["id"] = string
        case .number(let number): json["id"] = number
        }
        return try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
    }

    /// `params.requestId` of a `notifications/cancelled` message, if it is a
    /// string or an integer.
    static func cancelledRequestID(in data: Data) -> ID? {
        struct Cancelled: Decodable {
            struct Params: Decodable { let requestId: ID? }
            let params: Params?
        }
        return (try? JSONDecoder().decode(Cancelled.self, from: data))?.params?.requestId
    }

    /// The message with `_meta["io.modelcontextprotocol/subscriptionId"]` of
    /// its `params` or `result` replaced when it equals `internalID`.
    /// Returns `data` unchanged otherwise.
    static func replacingSubscriptionID(in data: Data, internalID: String, with id: ID) -> Data {
        guard data.range(of: Data(internalID.utf8)) != nil,
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return data }
        var changed = false
        for member in ["params", "result"] {
            guard var object = json[member] as? [String: Any],
                var meta = object["_meta"] as? [String: Any],
                meta[MetaKey.subscriptionID] as? String == internalID
            else { continue }
            switch id {
            case .string(let string): meta[MetaKey.subscriptionID] = string
            case .number(let number): meta[MetaKey.subscriptionID] = number
            }
            object["_meta"] = meta
            json[member] = object
            changed = true
        }
        guard changed,
            let rewritten = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        else { return data }
        return rewritten
    }

    /// `params._meta["io.modelcontextprotocol/protocolVersion"]`, if it is a
    /// non-empty string.
    static func metaProtocolVersion(in data: Data) -> String? {
        probe(data)?.protocolVersion
    }

    /// `error.code` of a response, if it is an error response.
    static func errorCode(in data: Data) -> Int? {
        probe(data)?.errorCode
    }
}
