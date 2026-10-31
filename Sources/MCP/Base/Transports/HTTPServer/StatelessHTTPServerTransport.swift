import Foundation
import Logging

/// A stateless HTTP server transport that returns single JSON responses.
///
/// This transport implements a minimal subset of the MCP Streamable HTTP specification:
/// - No session management (no `Mcp-Session-Id` header)
/// - POST requests receive direct JSON responses (no SSE streaming)
/// - GET and DELETE requests return 405 Method Not Allowed
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
/// ## When to Use
///
/// Use this transport when:
/// - You don't need server-initiated messages (no GET SSE stream)
/// - You want simple request-response semantics
/// - Session management is handled externally or not needed
///
/// For full streaming and session support, use ``StatefulHTTPServerTransport`` instead.
/// A cancelled request ends with an empty SSE response so no JSON-RPC reply is sent.
public actor StatelessHTTPServerTransport:
    Transport, HTTPContextProviding, RoutedRequestIDProviding, CancelledHTTPExchangeCompleting
{
    public nonisolated let logger: Logger

    // MARK: - Dependencies

    private let validationPipeline: any HTTPRequestValidationPipeline

    // MARK: - State

    private var terminated = false
    private var started = false

    // MARK: - Incoming message stream (client → server)

    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    // MARK: - Response waiters

    private enum ResponseOutcome {
        case data(Data)
        case cancelled
    }

    private struct ResponseWaiter {
        let originalID: ID
        let continuation: CheckedContinuation<ResponseOutcome, any Error>
    }

    /// Maps a transport-private exchange ID to the matching HTTP response waiter.
    private var responseWaiters: [String: ResponseWaiter] = [:]

    /// Maps request ID → originating HTTP request, surfaced to handlers via
    /// ``Server/currentHTTPContext``. Entries live only while a JSON-RPC request
    /// is in flight.
    private var httpRequestContexts: [String: HTTPRequest] = [:]

    /// Preserves the existing raw-ID context lookup for callers outside `Server`.
    /// Multiple entries are possible because JSON-RPC IDs are scoped to each client.
    private var exchangeIDsByRequestID: [ID: [String]] = [:]

    // MARK: - Init

    /// Creates a new stateless HTTP server transport.
    ///
    /// - Parameters:
    ///   - validationPipeline: Custom validation pipeline. If `nil`, uses sensible defaults:
    ///     origin validation (localhost), Accept header (JSON only), Content-Type,
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
        await terminate()
    }

    /// Routes outgoing server messages to the appropriate waiting HTTP handler.
    ///
    /// - Responses are matched by JSON-RPC ID and delivered to the waiting `handleRequest` call.
    /// - Notifications and server-initiated requests are logged and dropped
    ///   (no streaming channel available in stateless mode).
    public func send(_ data: Data) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        guard let kind = JSONRPCMessageKind(data: data) else {
            logger.warning("Could not classify outgoing message for routing")
            return
        }

        switch kind {
        case .response(let id):
            guard let waiter = responseWaiters.removeValue(forKey: id) else {
                logger.debug(
                    "No waiter for response, may have timed out",
                    metadata: ["requestID": "\(id)"]
                )
                return
            }
            do {
                let response = try restoringResponseID(in: data, to: waiter.originalID)
                waiter.continuation.resume(returning: .data(response))
            } catch {
                waiter.continuation.resume(throwing: error)
                throw error
            }

        case .notification(let method):
            logger.debug(
                "Server-initiated notification dropped in stateless mode (no GET SSE stream)",
                metadata: ["method": "\(method)"]
            )

        case .request(_, let method):
            logger.debug(
                "Server-initiated request dropped in stateless mode (no GET SSE stream)",
                metadata: ["method": "\(method)"]
            )
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
    ///
    /// If the adapter cancels this task because its HTTP exchange ended, it must not write the
    /// returned response. The adapter owns disconnect and timeout behavior.
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
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                extraHeaders: [HTTPHeaderName.allow: "POST"]
            )
        }
    }

    // MARK: - POST Handler

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse body first to determine message type
        guard let body = request.body, !body.isEmpty else {
            return .error(
                statusCode: 400,
                .parseError("Empty request body")
            )
        }

        guard let messageKind = JSONRPCMessageKind(data: body) else {
            return .error(
                statusCode: 400,
                .parseError("Invalid JSON-RPC message")
            )
        }
        if case .notification = messageKind,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            json.keys.contains("id")
        {
            return .error(statusCode: 400, .parseError("Invalid JSON-RPC request id"))
        }

        // Build validation context
        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: messageKind.isInitializeRequest,
            supportedProtocolVersions: Version.supported
        )

        // Run validation pipeline
        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse
        }

        // Handle by message type
        switch messageKind {
        case .notification:
            // Yield to server and return 202 Accepted
            incomingContinuation.yield(body)
            return .accepted()

        case .response:
            // Yield to server and return 202 Accepted
            incomingContinuation.yield(body)
            return .accepted()

        case .request(let id, _):
            return await handleJSONRPCRequest(body, requestID: id, request: request)
        }
    }

    private func handleJSONRPCRequest(
        _ body: Data,
        requestID: String,
        request: HTTPRequest
    ) async -> HTTPResponse {
        let exchangeID = makeExchangeID(excluding: requestID)
        let routedBody: Data
        let originalID: ID
        do {
            (routedBody, originalID) = try routingRequest(body, as: exchangeID)
        } catch {
            return .error(
                statusCode: 400,
                .parseError("Invalid JSON-RPC request id")
            )
        }

        registerHTTPContext(request, exchangeID: exchangeID, requestID: originalID)
        // Yield the incoming message to the server
        incomingContinuation.yield(routedBody)

        // Wait for the server to process and send a response
        let outcome: ResponseOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    responseWaiters[exchangeID] = ResponseWaiter(
                        originalID: originalID,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancelWaitingExchange(exchangeID) }
            }
        } catch MCPError.connectionClosed {
            removeHTTPContext(exchangeID: exchangeID, requestID: originalID)
            return .error(statusCode: 503, .connectionClosed)
        } catch {
            removeHTTPContext(exchangeID: exchangeID, requestID: originalID)
            return .error(
                statusCode: 500,
                .internalError("Error processing request: \(error.localizedDescription)")
            )
        }

        removeHTTPContext(exchangeID: exchangeID, requestID: originalID)
        switch outcome {
        case .data(let responseData):
            return .data(responseData, headers: [HTTPHeaderName.contentType: ContentType.json])
        case .cancelled:
            if request.header(HTTPHeaderName.accept)?.lowercased().contains(ContentType.sse) == true {
                return .stream(
                    AsyncThrowingStream { $0.finish() },
                    headers: [HTTPHeaderName.contentType: ContentType.sse]
                )
            }
            let cancellation = AnyMethod.response(
                id: originalID,
                error: .serverError(code: -32800, message: "Request cancelled")
            )
            guard let data = try? JSONEncoder().encode(cancellation) else {
                return .error(statusCode: 500, .internalError("Failed to encode cancellation"))
            }
            return .data(data, headers: [HTTPHeaderName.contentType: ContentType.json])
        }
    }

    private func makeExchangeID(excluding requestID: String) -> String {
        var exchangeID: String
        repeat {
            exchangeID = UUID().uuidString
        } while exchangeID == requestID
            || responseWaiters[exchangeID] != nil
            || httpRequestContexts[exchangeID] != nil
            || exchangeIDsByRequestID[.string(exchangeID)] != nil
        return exchangeID
    }

    private func routingRequest(_ body: Data, as exchangeID: String) throws -> (Data, ID) {
        try replacingTopLevelID(in: body, with: .string(exchangeID))
    }

    private func restoringResponseID(in data: Data, to originalID: ID) throws -> Data {
        try replacingTopLevelID(in: data, with: originalID).0
    }

    /// Replace only the top-level ID. Re-encoding the whole message can change numeric payloads.
    private func replacingTopLevelID(in data: Data, with replacement: ID) throws -> (Data, ID) {
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw MCPError.parseError("Invalid JSON-RPC object")
        }

        let bytes = Array(data)
        var index = 0
        func skipWhitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        func stringEnd() throws -> Int {
            guard index < bytes.count, bytes[index] == 34 else {
                throw MCPError.parseError("Invalid JSON-RPC member")
            }
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { return index }
            }
            throw MCPError.parseError("Invalid JSON string")
        }

        skipWhitespace()
        index += 1 // Opening brace, checked by JSONSerialization above.
        var idRange: Range<Int>?
        while index < bytes.count {
            skipWhitespace()
            if bytes[index] == 125 { break }
            let keyStart = index
            let keyEnd = try stringEnd()
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<keyEnd]))
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 58 else {
                throw MCPError.parseError("Invalid JSON-RPC member")
            }
            index += 1
            skipWhitespace()
            let valueStart = index
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 {
                    _ = try stringEnd()
                    continue
                }
                if byte == 91 || byte == 123 { depth += 1 }
                if byte == 93 || byte == 125 {
                    if depth == 0 { break }
                    depth -= 1
                }
                if byte == 44 && depth == 0 { break }
                index += 1
            }
            var valueEnd = index
            while valueEnd > valueStart && [9, 10, 13, 32].contains(bytes[valueEnd - 1]) {
                valueEnd -= 1
            }
            if key == "id" {
                guard idRange == nil else {
                    throw MCPError.parseError("Duplicate JSON-RPC request id")
                }
                idRange = valueStart..<valueEnd
            }
            if index < bytes.count, bytes[index] == 44 { index += 1 }
        }

        guard let idRange else { throw MCPError.parseError("Missing JSON-RPC request id") }
        let idData = Data(bytes[idRange])
        let originalID: ID
        if let value = try? JSONDecoder().decode(String.self, from: idData) {
            originalID = .string(value)
        } else if let first = idData.first,
            (first == 45 || (48...57).contains(first)),
            !idData.contains(46), !idData.contains(69), !idData.contains(101),
            let value = try? JSONDecoder().decode(Int.self, from: idData)
        {
            originalID = .number(value)
        } else {
            throw MCPError.parseError("Invalid JSON-RPC request id")
        }
        let replacementData = try JSONEncoder().encode(replacement)
        var result = Data(bytes[..<idRange.lowerBound])
        result.append(replacementData)
        result.append(contentsOf: bytes[idRange.upperBound...])
        return (result, originalID)
    }

    private func registerHTTPContext(
        _ request: HTTPRequest,
        exchangeID: String,
        requestID: ID
    ) {
        httpRequestContexts[exchangeID] = request
        exchangeIDsByRequestID[requestID, default: []].append(exchangeID)
    }

    private func removeHTTPContext(exchangeID: String, requestID: ID) {
        httpRequestContexts.removeValue(forKey: exchangeID)
        guard var exchangeIDs = exchangeIDsByRequestID[requestID] else { return }
        exchangeIDs.removeAll { $0 == exchangeID }
        if exchangeIDs.isEmpty {
            exchangeIDsByRequestID.removeValue(forKey: requestID)
        } else {
            exchangeIDsByRequestID[requestID] = exchangeIDs
        }
    }

    private func cancelWaitingExchange(_ exchangeID: String) {
        guard let waiter = responseWaiters.removeValue(forKey: exchangeID) else { return }
        removeHTTPContext(exchangeID: exchangeID, requestID: waiter.originalID)
        waiter.continuation.resume(throwing: CancellationError())
    }

    package func completeCancelledExchange(for routedID: ID, reason: String?) {
        guard case .string(let exchangeID) = routedID,
            let waiter = responseWaiters.removeValue(forKey: exchangeID)
        else { return }

        removeHTTPContext(exchangeID: exchangeID, requestID: waiter.originalID)
        logger.debug("Completed cancelled HTTP exchange", metadata: ["reason": "\(reason ?? "none")"])
        waiter.continuation.resume(returning: .cancelled)
    }

    // MARK: - HTTPContextProviding

    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        if case .string(let exchangeID) = id,
            let request = httpRequestContexts[exchangeID]
        {
            return request
        }
        guard let exchangeIDs = exchangeIDsByRequestID[id],
            exchangeIDs.count == 1,
            let exchangeID = exchangeIDs.first
        else {
            return nil
        }
        return httpRequestContexts[exchangeID]
    }

    package func originalRequestID(for routedID: ID) -> ID? {
        guard case .string(let exchangeID) = routedID else { return nil }
        return responseWaiters[exchangeID]?.originalID
    }

    package func routedRequestID(for originalID: ID) -> ID? {
        guard let exchangeIDs = exchangeIDsByRequestID[originalID],
            exchangeIDs.count == 1,
            let exchangeID = exchangeIDs.first
        else {
            return nil
        }
        return .string(exchangeID)
    }

    // MARK: - Termination

    private func terminate() async {
        guard !terminated else { return }
        terminated = true

        logger.debug("Stateless HTTP server transport terminated")

        // Cancel all waiting continuations
        for (exchangeID, waiter) in responseWaiters {
            waiter.continuation.resume(throwing: MCPError.connectionClosed)
            logger.debug(
                "Cancelled waiter for request",
                metadata: [
                    "exchangeID": "\(exchangeID)",
                    "requestID": "\(waiter.originalID)",
                ]
            )
        }
        responseWaiters.removeAll()
        httpRequestContexts.removeAll()
        exchangeIDsByRequestID.removeAll()

        // Close incoming stream
        incomingContinuation.finish()
    }
}
