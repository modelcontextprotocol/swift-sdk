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

    // MARK: - Response waiters

    /// Maps request ID → continuation waiting for the server's response.
    /// When the server calls `send()` with a response, the matching continuation is resumed.
    private var responseWaiters: [String: CheckedContinuation<Data, any Error>] = [:]

    /// Maps request ID → originating HTTP request, surfaced to handlers via
    /// ``Server/currentHTTPContext``. Entries live only while a JSON-RPC request
    /// is in flight.
    private var httpRequestContexts: [String: HTTPRequest] = [:]

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
            guard let continuation = responseWaiters.removeValue(forKey: id) else {
                logger.debug(
                    "No waiter for response, may have timed out",
                    metadata: ["requestID": "\(id)"]
                )
                return
            }
            continuation.resume(returning: data)

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
        case .notification(let method):
            // Yield to server and return 202 Accepted
            incomingContinuation.yield(body)
            if method == CancelledNotification.name {
                completeExchangeForCancelledRequest(body)
            }
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
        httpRequestContexts[requestID] = request
        // Yield the incoming message to the server
        incomingContinuation.yield(body)

        // Wait for the server to process and send a response
        let responseData: Data
        do {
            responseData = try await withCheckedThrowingContinuation { continuation in
                responseWaiters[requestID] = continuation
            }
        } catch {
            httpRequestContexts.removeValue(forKey: requestID)
            return .error(
                statusCode: 500,
                .internalError("Error processing request: \(error.localizedDescription)")
            )
        }

        httpRequestContexts.removeValue(forKey: requestID)
        return .data(responseData, headers: [HTTPHeaderName.contentType: ContentType.json])
    }

    // MARK: - Cancellation

    /// JSON-RPC error code for the synthesized "Request cancelled" response.
    ///
    /// MCP defines no cancellation error code; its schema designates [-32000, -32099] as
    /// "Implementation-specific JSON-RPC error codes". This SDK already uses -32000
    /// (connection closed) and -32001 (transport error), so -32002 is the next available.
    private static let requestCancelledErrorCode = -32002

    /// Completes the HTTP exchange for an in-flight request targeted by a
    /// `notifications/cancelled` notification.
    ///
    /// Per the MCP cancellation spec, the server sends no JSON-RPC response for a
    /// cancelled request (``Server`` suppresses it). But the Streamable HTTP transport
    /// requires that a POST carrying a JSON-RPC request receive a response: "the server
    /// MUST either return `Content-Type: text/event-stream` … or `Content-Type:
    /// application/json`, to return one JSON object". Without this method, nothing
    /// resumes the request's response waiter and the POST hangs until transport
    /// termination.
    ///
    /// To satisfy that MUST, the waiter is resumed with a synthesized JSON-RPC error
    /// response. Deviating from the cancellation SHOULD ("Not send a response for the
    /// cancelled request") is anticipated by the same spec: "The sender of the
    /// cancellation notification SHOULD ignore any response to the request that arrives
    /// afterward."
    ///
    /// Cancellations for unknown or already-completed requests are ignored, as the spec
    /// requires ("Invalid cancellation notifications SHOULD be ignored").
    ///
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    private func completeExchangeForCancelledRequest(_ body: Data) {
        guard
            let notification = try? JSONDecoder().decode(
                Message<CancelledNotification>.self, from: body),
            let requestID = notification.params.requestId
        else {
            // Malformed or missing requestId — ignore per spec. Server logs it.
            return
        }

        guard let continuation = responseWaiters.removeValue(forKey: requestID.description)
        else {
            // Unknown or already-completed request — ignore per spec.
            return
        }

        var message = "Request cancelled"
        if let reason = notification.params.reason {
            message += ": \(reason)"
        }
        let response = AnyMethod.response(
            id: requestID,
            error: .serverError(code: Self.requestCancelledErrorCode, message: message)
        )

        do {
            // Match the wire format Server uses for outgoing messages.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            continuation.resume(returning: try encoder.encode(response))
            logger.debug(
                "Completed HTTP exchange for cancelled request",
                metadata: ["requestID": "\(requestID)"]
            )
        } catch {
            continuation.resume(
                throwing: MCPError.internalError(
                    "Failed to encode cancellation response: \(error)"))
        }
    }

    // MARK: - HTTPContextProviding

    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        httpRequestContexts[id.description]
    }

    // MARK: - Termination

    private func terminate() async {
        guard !terminated else { return }
        terminated = true

        logger.debug("Stateless HTTP server transport terminated")

        // Cancel all waiting continuations
        for (id, continuation) in responseWaiters {
            continuation.resume(throwing: MCPError.connectionClosed)
            logger.debug("Cancelled waiter for request", metadata: ["requestID": "\(id)"])
        }
        responseWaiters.removeAll()
        httpRequestContexts.removeAll()

        // Close incoming stream
        incomingContinuation.finish()
    }
}
