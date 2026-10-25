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

    // MARK: - Init

    /// Creates a new stateless HTTP server transport.
    ///
    /// - Parameters:
    ///   - validationPipeline: Custom validation pipeline. If `nil`, uses sensible defaults:
    ///     origin validation (localhost), Accept header (JSON required), Content-Type,
    ///     and protocol version validation.
    ///   - logger: Optional logger. If `nil`, a no-op logger is used.
    public init(
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        logger: Logger? = nil
    ) {
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

    public func connect() async throws {
        guard !started else {
            throw MCPError.internalError("Transport already started")
        }
        started = true
        logger.debug("Stateless HTTP server transport started")
    }

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
            exchange.outgoing.yield(
                .response(rewritten?.data ?? data, errorCode: rewritten?.errorCode))
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
            exchange.outgoing.yield(.message(data))
        }
    }

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
            // document, run for every method. Anything else is 405.
            let context = HTTPValidationContext(
                httpMethod: request.method.uppercased(), sessionID: nil,
                supportedProtocolVersions: Set(Version.stateless + Version.handshake))
            if let response = validationPipeline.validate(request, context: context),
                (200..<300).contains(response.statusCode)
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

        guard let messageKind = JSONRPCMessageKind(data: body) else {
            return .error(statusCode: 400, .parseError("Invalid JSON-RPC message"))
        }

        // One probe for the id and the `_meta` version.
        let fields = JSONRPCMessageFields.requestFields(in: body)
        var requestID: ID?
        if case .request = messageKind {
            requestID = fields.id
        }

        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: messageKind.isInitializeRequest,
            supportedProtocolVersions: Set(Version.stateless + Version.handshake)
        )

        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse.withRequestID(requestID)
        }

        if let mismatch = Self.standardHeaderError(request, fields: fields) {
            return .error(statusCode: 400, mismatch, id: requestID)
        }

        switch messageKind {
        case .notification(let method) where method == CancelledNotification.name:
            if let cancellation = cancellation(body, request: request) {
                incomingContinuation.yield(cancellation)
            } else {
                logger.debug("notifications/cancelled matches no request in flight; ignored")
            }
            return .accepted()

        case .notification, .response:
            incomingContinuation.yield(body)
            return .accepted()

        case .request:
            guard let requestID else {
                return .error(statusCode: 400, .invalidRequest("Invalid JSON-RPC id"))
            }
            if let mismatch = Self.versionHeaderError(request, metaVersion: fields.metaProtocolVersion) {
                return .error(statusCode: 400, mismatch, id: requestID)
            }
            return await handleJSONRPCRequest(
                body,
                clientID: requestID,
                isStateless: request.statelessProtocolVersion != nil,
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

    /// Checks `Mcp-Method` and `Mcp-Name` against the body (SEP-2243).
    ///
    /// Applies to protocol revisions that define the headers. Values are
    /// case-sensitive; surrounding whitespace is ignored.
    private static func standardHeaderError(
        _ request: HTTPRequest, fields: JSONRPCMessageFields.RequestFields
    ) -> MCPError? {
        guard let version = request.statelessProtocolVersion,
            Version.profile(for: version).usesStandardHeaders,
            let method = fields.method
        else { return nil }

        let methodHeader = request.header(MCPRequestHeaders.method)?
            .trimmingCharacters(in: .whitespaces)
        guard let methodHeader else {
            return .headerMismatch("Missing \(MCPRequestHeaders.method) header")
        }
        guard methodHeader == method else {
            return .headerMismatch(
                "\(MCPRequestHeaders.method) header \(methodHeader) does not match method \(method)")
        }

        guard let expected = fields.nameValue else { return nil }
        guard let raw = request.header(MCPRequestHeaders.name) else {
            return .headerMismatch("Missing \(MCPRequestHeaders.name) header")
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
        // The adapter cancels this task when the client goes away before the
        // response is decided: cancel the request, as for a closed SSE stream.
        return await withTaskCancellationHandler {
            await respond(
                to: outgoing, internalID: internalID, clientID: clientID,
                isStateless: isStateless, acceptsSSE: acceptsSSE, logger: logger)
        } onCancel: {
            Task { await self.abandon(internalID) }
        }
    }

    /// Waits for the server's messages for one request and turns them into
    /// the HTTP response: JSON, or an SSE stream once a notification arrives.
    private func respond(
        to outgoing: AsyncStream<Outgoing>, internalID: String, clientID: ID,
        isStateless: Bool, acceptsSSE: Bool, logger: Logger
    ) async -> HTTPResponse {
        await withCheckedContinuation { (decision: CheckedContinuation<HTTPResponse, Never>) in
            Task {
                var stream: AsyncThrowingStream<Data, Swift.Error>.Continuation?
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
                            // The client went away: cancel the request.
                            sseContinuation.onTermination = { termination in
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

    /// Forgets a request whose client went away and cancels it in the server.
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
        let protocolVersion: String?
        let errorCode: Int?

        private enum Keys: String, CodingKey {
            case id, method, params, error, _meta, code, name, uri
            case protocolVersion = "io.modelcontextprotocol/protocolVersion"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            id = try? container.decodeIfPresent(ID.self, forKey: .id)
            method = try? container.decodeIfPresent(String.self, forKey: .method)
            let params = try? container.nestedContainer(keyedBy: Keys.self, forKey: .params)
            name = try? params?.decodeIfPresent(String.self, forKey: .name)
            uri = try? params?.decodeIfPresent(String.self, forKey: .uri)
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

    /// The `id` of a message, if it is a string or an integer.
    static func id(in data: Data) -> ID? {
        guard let id = probe(data)?.id, id != .string("") else { return nil }
        return id
    }

    /// The members of a request the transport reads, from one decode.
    struct RequestFields {
        var id: ID?
        var method: String?
        /// The `Mcp-Name` value: `params.name` or `params.uri` by method.
        var nameValue: String?
        var metaProtocolVersion: String?
    }

    /// The `id`, method, `Mcp-Name` value and `params._meta` protocol
    /// version of a message, from one decode.
    static func requestFields(in data: Data) -> RequestFields {
        let probe = probe(data)
        return RequestFields(
            id: probe?.id == .string("") ? nil : probe?.id,
            method: probe?.method,
            nameValue: probe?.method.flatMap {
                MCPRequestHeaders.nameValue(method: $0, name: probe?.name, uri: probe?.uri)
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
