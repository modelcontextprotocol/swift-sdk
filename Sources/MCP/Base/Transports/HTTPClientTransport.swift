import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Timeout Helpers

/// An implementation of the MCP Streamable HTTP transport protocol for clients.
///
/// This transport implements the [Streamable HTTP transport](https://spec.modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http)
/// of the Model Context Protocol. On stateless (2026-07-28) connections it
/// also sends the `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*` request headers.
///
/// It supports:
/// - Sending JSON-RPC messages via HTTP POST requests
/// - Receiving responses via both direct JSON responses and SSE streams
/// - Session management using the `MCP-Session-Id` header
/// - Protocol version negotiation via `MCP-Protocol-Version` header
/// - Automatic reconnection for dropped SSE streams with resumability support
///
/// The transport supports two modes:
/// - Regular HTTP (`streaming=false`): Simple request/response pattern
/// - Streaming HTTP with SSE (`streaming=true`): Enables server-to-client push messages
///
/// ``disconnect()`` ends the connection at once. A transport dropped without
/// it is still released, and then stops its GET stream and invalidates its
/// URL sessions; a ``send(_:)`` still running keeps the transport alive until
/// it finishes or its task is cancelled.
///
/// It behaves the same on Apple platforms and Linux. Response bodies are read
/// as they arrive: with `URLSession.bytes(for:)` on Apple platforms, and with a
/// data delegate on swift-corelibs-foundation, which has no `bytes(for:)`.
///
/// An SSE line, or the data of one event, longer than 16 MiB ends its
/// stream with `internalError`. On a POST's stream the request fails and the
/// stream is not resumed; the GET stream reconnects after its backoff,
/// without `Last-Event-ID`, since a replay would repeat the event, which is
/// lost.
///
/// ## Example Usage
///
/// ```swift
/// import MCP
///
/// // Create a streaming HTTP transport with bearer token authentication
/// let transport = HTTPClientTransport(
///     endpoint: URL(string: "https://api.example.com/mcp")!,
///     requestModifier: { request in
///         var modifiedRequest = request
///         modifiedRequest.addValue("Bearer your-token-here", forHTTPHeaderField: "Authorization")
///         return modifiedRequest
///     }
/// )
///
/// // Initialize the client with streaming transport
/// let client = Client(name: "MyApp", version: "1.0.0")
/// try await client.connect(transport: transport)
///
/// // The transport will automatically handle SSE events
/// // and deliver them through the client's notification handlers
/// ```
public actor HTTPClientTransport: Transport {
    /// The server endpoint URL to connect to
    public let endpoint: URL
    private let session: URLSession

    /// The session ID assigned by the server, used for maintaining state across requests
    public private(set) var sessionID: String?

    /// The negotiated protocol version to send in MCP-Protocol-Version header
    public var protocolVersion: String?

    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?
    /// Streams response bodies on swift-corelibs-foundation.
    let streamingSession: StreamingSession

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// Maximum time to wait for a session ID before proceeding with SSE connection
    public let sseInitializationTimeout: TimeInterval

    /// Closure to modify requests before they are sent
    private let requestModifier: (URLRequest) -> URLRequest

    /// Optional OAuth 2.1 authorizer.
    private let authorizer: (any HTTPClientAuthorizer)?

    private var isConnected = false
    /// Whether the connection uses a stateless revision.
    private var isStateless = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Ends the GET stream's wait for a session ID; replaced by each ``connect()``.
    private var sessionIDSignal = SessionIDSignal()

    /// The last event ID received from the server for SSE stream resumability
    private var lastEventID: String?

    /// The retry interval (in milliseconds) from the server's SSE `retry:` field,
    /// clamped to ``retryIntervalBounds``.
    private var retryInterval: Int = 3000  // Default 3000ms per SSE spec

    /// The POSTs of requests in flight, by JSON-RPC ID. Cancelled by
    /// ``disconnect()`` and by an outgoing `notifications/cancelled`.
    private var inFlightPosts: [String: Task<Void, Swift.Error>] = [:]
    /// The other POSTs in flight: notifications, and responses to server
    /// requests. Cancelled by ``disconnect()``.
    private var otherPosts: [UUID: Task<Void, Swift.Error>] = [:]

    /// The authorizer calls of requests in flight, by JSON-RPC ID. See
    /// ``authorizationEnd(of:)``.
    private var authorizations: [String: Authorization] = [:]

    private struct Authorization {
        /// Authorizer calls in progress for the request's POST.
        var active = 0
        /// When the last one ended.
        var lastEnded: ContinuousClock.Instant?
        /// Callers of ``HTTPClientTransport/authorizationEnd(of:)`` waiting for `active` to reach 0.
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

        mutating func resumeWaiters() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.continuation.resume() }
        }
    }

    /// Requests passed to ``cancelRequest(_:)`` before their POST started,
    /// oldest first, at most ``maxCancelledBeforeSend``.
    private var cancelledBeforeSend: [String] = []
    static let maxCancelledBeforeSend = 64

    /// The bounds applied to a server's SSE `retry:` value, in milliseconds.
    static let retryIntervalBounds = 10...60_000

    /// The longest wait before reconnecting the GET stream after repeated failures,
    /// in milliseconds.
    static let maxReconnectDelay = 60_000

    /// A server's SSE `retry:` value, clamped to ``retryIntervalBounds``.
    static func clampedRetryInterval(_ milliseconds: Int) -> Int {
        min(max(milliseconds, retryIntervalBounds.lowerBound), retryIntervalBounds.upperBound)
    }

    /// The wait before the next GET stream connection: the retry interval,
    /// doubled for each consecutive failure after the first, up to
    /// ``maxReconnectDelay``.
    static func reconnectDelay(retryInterval: Int, consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 1 else { return retryInterval }
        let doublings = min(consecutiveFailures - 1, 16)
        return min(retryInterval * (1 << doublings), maxReconnectDelay)
    }

    /// The per-host connection limit of ``defaultConfiguration``.
    public static let defaultMaximumConnectionsPerHost = 64

    /// `URLSessionConfiguration.default`'s per-host limit on Apple platforms.
    static let platformDefaultMaximumConnectionsPerHost = 6

    /// The default URLSession configuration: `URLSessionConfiguration.default`
    /// with `httpMaximumConnectionsPerHost` raised to
    /// ``defaultMaximumConnectionsPerHost``.
    ///
    /// Over HTTP/1.1 every request in flight holds a connection until its
    /// response ends, and the GET stream holds one more. A server-to-client
    /// request (sampling, elicitation, roots) arrives on such a stream, and
    /// the reply needs a connection of its own: with
    /// `URLSessionConfiguration.default` (6 per host on Apple platforms), five
    /// concurrent calls that each wait for a reply deadlock.
    public static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = defaultMaximumConnectionsPerHost
        return configuration
    }

    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests. Defaults to
    ///     ``defaultConfiguration``. A custom configuration needs an
    ///     `httpMaximumConnectionsPerHost` above the number of concurrent requests plus one;
    ///     the transport logs a warning when it is at the platform default of 6 or lower.
    ///   - streaming: Whether to enable SSE streaming mode (default: true)
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - protocolVersion: The MCP protocol version to use (default: "2025-11-25")
    ///   - authorizer: Optional ``HTTPClientAuthorizer`` for automatic token acquisition and retries.
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification).
    ///     The `authorizer`'s headers are set after it, for the final URL and method.
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = HTTPClientTransport.defaultConfiguration,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latestHandshake,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        if configuration.httpMaximumConnectionsPerHost <= Self.platformDefaultMaximumConnectionsPerHost {
            logger?.warning(
                "URLSessionConfiguration allows \(configuration.httpMaximumConnectionsPerHost) connections per host; concurrent requests that wait for a server-to-client reply can deadlock. Raise httpMaximumConnectionsPerHost, or use HTTPClientTransport.defaultConfiguration."
            )
        }
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            protocolVersion: protocolVersion,
            authorizer: authorizer,
            requestModifier: requestModifier,
            logger: logger
        )
    }

    internal init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latestHandshake,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streamingSession = StreamingSession(configuration: session.configuration)
        self.streaming = streaming
        self.sseInitializationTimeout = sseInitializationTimeout
        self.protocolVersion = protocolVersion
        self.requestModifier = requestModifier
        self.authorizer = authorizer

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation

        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.http.client",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    /// The wait of the GET stream for a session ID. It ends once: on a
    /// session ID, the timeout, ``disconnect()``, ``useStatelessProtocol(_:)``,
    /// the cancellation of the waiting task, or the release of the transport.
    /// The transport owns it; the waiting task holds it, not the transport.
    private final class SessionIDSignal: @unchecked Sendable {
        enum Outcome { case signalled, timedOut }

        private let lock = NSLock()
        private var ended = false
        private var timedOut = false
        private var waiter: CheckedContinuation<Void, Never>?

        /// Ends the wait, or a later one at once.
        func signal() { end(timedOut: false) }

        /// Waits for ``signal()`` for at most `timeout`.
        func wait(timeout: TimeInterval) async -> Outcome {
            let timer = Task { [self] in
                try await Task.sleep(for: .seconds(timeout))
                end(timedOut: true)
            }
            defer { timer.cancel() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let waiting = lock.withLock { () -> Bool in
                        guard !ended else { return false }
                        waiter = continuation
                        return true
                    }
                    if !waiting { continuation.resume() }
                }
            } onCancel: {
                signal()
            }
            return lock.withLock { timedOut ? .timedOut : .signalled }
        }

        private func end(timedOut: Bool) {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard !ended else { return nil }
                ended = true
                self.timedOut = timedOut
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume()
        }
    }

    /// A weak reference to the transport: the GET stream task holds the
    /// transport only while it uses it, so a transport dropped without
    /// ``disconnect()`` is released.
    private final class WeakReference: @unchecked Sendable {
        // Set once, in init; reading a weak reference is thread-safe.
        weak var transport: HTTPClientTransport?
        init(_ transport: HTTPClientTransport) { self.transport = transport }
    }

    // Trigger the initial session ID signal when a session ID is established
    private func triggerInitialSessionIDSignal() {
        sessionIDSignal.signal()
        logger.debug("✓ Initial session ID signal triggered for SSE task")
    }

    /// Establishes connection with the transport.
    ///
    /// With `streaming`, this starts the standalone GET stream; it opens
    /// once the server has assigned a session ID, or after
    /// ``sseInitializationTimeout``. Call ``disconnect()`` to end the
    /// connection. A transport dropped without it is still released, and its
    /// GET stream stops then.
    ///
    /// - Throws: `MCPError.internalError` after ``disconnect()``: the
    ///   transport serves one connection; use a new one to reconnect.
    public func connect() async throws {
        guard !isConnected else { return }
        // disconnect() finished the stream receive() returns.
        guard !streamingSession.lifetime.isInvalidated else {
            throw MCPError.internalError("Transport disconnected; create a new transport to reconnect")
        }
        isConnected = true

        sessionIDSignal = SessionIDSignal()

        if streaming {
            let reference = WeakReference(self)
            let signal = sessionIDSignal
            let timeout = sseInitializationTimeout
            let logger = logger
            streamingTask = Task {
                await HTTPClientTransport.listenForServerEvents(
                    reference, sessionIDSignal: signal, timeout: timeout, logger: logger)
            }
        }

        logger.debug("HTTP transport connected")
    }

    deinit {
        // A send() in flight holds the transport, so only the GET stream
        // task can be running; a GET it is creating keeps the sessions
        // valid until the task exists.
        streamingTask?.cancel()
        sessionIDSignal.signal()
        messageContinuation.finish()
        if !streamingSession.lifetime.isInvalidated {
            streamingSession.invalidate(along: session)
        }
    }

    /// Disconnects from the transport.
    ///
    /// This ends the connection at once: it stops the GET stream, cancels
    /// the POSTs in flight, invalidates the URL sessions and finishes the
    /// stream ``receive()`` returns. The transport cannot connect again; use
    /// a new one to reconnect.
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        streamingTask?.cancel()
        streamingTask = nil

        // POSTs still in flight, including response streams waiting to
        // resume, end now instead of sleeping on a server-chosen delay.
        for task in inFlightPosts.values { task.cancel() }
        inFlightPosts.removeAll()
        // On Apple platforms a request keeps the sessions valid until its
        // response headers arrive, so end the other POSTs too.
        for task in otherPosts.values { task.cancel() }
        otherPosts.removeAll()
        cancelledBeforeSend.removeAll()

        // A request that is creating its task keeps the sessions valid
        // until it has; later ones fail instead of trapping.
        streamingSession.invalidate(along: session)
        messageContinuation.finish()
        sessionIDSignal.signal()

        logger.debug("HTTP clienttransport disconnected")
    }

    /// Updates the protocol version used for `MCP-Protocol-Version` headers on subsequent requests.
    public func updateNegotiatedProtocolVersion(_ version: String) {
        self.protocolVersion = version
    }

    /// Switches the transport to a stateless revision (2026-07-28 and later):
    /// no session ID and no standalone GET stream.
    public func useStatelessProtocol(_ version: String) {
        protocolVersion = version
        isStateless = true
        sessionID = nil
        streamingTask?.cancel()
        streamingTask = nil
        sessionIDSignal.signal()
    }

    /// Sends data through an HTTP POST request.
    ///
    /// A request's POST, including the resumption of its response stream,
    /// runs until its response arrives, ``disconnect()`` is called, or the
    /// client sends `notifications/cancelled` for it. Any other POST, such as
    /// a notification's, ends when its response arrives or at ``disconnect()``.
    public func send(_ data: Data) async throws {
        try await send(data, additionalHeaders: [:])
    }

    /// Sends data through an HTTP POST request with extra headers, such as
    /// the `Mcp-Param-*` headers of a `tools/call` (SEP-2243).
    ///
    /// A header named here replaces one the transport sets before it, such
    /// as `Mcp-Method`. Applied after it are `Mcp-Session-Id`, which the
    /// transport adds on a connection with a session, the authorizer's
    /// headers and the `requestModifier`.
    public func send(_ data: Data, additionalHeaders: [String: String]) async throws {
        let message = OutgoingMessage(data)
        if let id = message.requestID {
            if let cancelled = cancelledBeforeSend.firstIndex(of: id) {
                cancelledBeforeSend.remove(at: cancelled)
                throw CancellationError()
            }
            let task = Task { try await self.post(message, additionalHeaders: additionalHeaders) }
            inFlightPosts[id] = task
            defer {
                inFlightPosts[id] = nil
                var ended = authorizations.removeValue(forKey: id)
                ended?.resumeWaiters()
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return
        }
        // The client ignores a cancelled request's response: stop reading
        // and resuming its stream.
        if let cancelled = message.cancelledRequestID {
            inFlightPosts[cancelled]?.cancel()
        }
        // In a task of its own, so that disconnect() can end it.
        let key = UUID()
        let task = Task { try await self.post(message, additionalHeaders: additionalHeaders) }
        otherPosts[key] = task
        defer { otherPosts[key] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The idle timeout of `subscriptions/listen` POSTs. A server may send
    /// nothing for a long time on such a stream.
    static let listenIdleTimeout: TimeInterval = 3600

    /// Aborts the POST that carries request `id`, closing its response stream.
    ///
    /// At protocol 2026-07-28 this is how a request is cancelled: the server
    /// sees the client disconnect. When the request's POST has not started
    /// yet, the next ``send(_:)`` of that request throws `CancellationError`
    /// instead of posting it; the transport remembers the most recent such
    /// ids only.
    public func cancelRequest(_ id: ID) {
        let key = id.description
        if let post = inFlightPosts[key] {
            post.cancel()
            return
        }
        guard !cancelledBeforeSend.contains(key) else { return }
        cancelledBeforeSend.append(key)
        if cancelledBeforeSend.count > Self.maxCancelledBeforeSend {
            cancelledBeforeSend.removeFirst()
        }
    }

    /// When the POST of request `id` last finished waiting on the authorizer,
    /// or `nil` if it has not. While the POST waits on the authorizer, for
    /// example for a user who signs in, this waits for it to finish.
    ///
    /// ``Client`` does not count that time against
    /// ``Client/Configuration/discoveryTimeout``.
    func authorizationEnd(of id: ID) async -> ContinuousClock.Instant? {
        let key = id.description
        if authorizations[key]?.active ?? 0 > 0 {
            let waiter = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    guard !Task.isCancelled, authorizations[key]?.active ?? 0 > 0 else {
                        continuation.resume()
                        return
                    }
                    authorizations[key]?.waiters.append((waiter, continuation))
                }
            } onCancel: {
                Task { await self.stopWaitingForAuthorization(waiter, of: key) }
            }
        }
        return authorizations[key]?.lastEnded
    }

    private func stopWaitingForAuthorization(_ waiter: UUID, of key: String) {
        guard let index = authorizations[key]?.waiters.firstIndex(where: { $0.id == waiter }) else { return }
        authorizations[key]?.waiters.remove(at: index).continuation.resume()
    }

    /// The callers of ``authorizationEnd(of:)`` waiting, for every request.
    var authorizationWaiterCount: Int {
        authorizations.values.reduce(0) { $0 + $1.waiters.count }
    }

    /// Runs an authorizer call for the POST of `message`, recorded for
    /// ``authorizationEnd(of:)``.
    private func authorizing<T: Sendable>(_ message: OutgoingMessage, _ body: () async throws -> T) async rethrows -> T {
        guard let id = message.requestID else { return try await body() }
        authorizations[id, default: Authorization()].active += 1
        defer {
            if var state = authorizations[id] {
                state.active -= 1
                state.lastEnded = .now
                if state.active == 0 {
                    state.resumeWaiters()
                }
                authorizations[id] = state
            }
        }
        return try await body()
    }

    private func post(_ message: OutgoingMessage, additionalHeaders: [String: String]) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        if let authorizer {
            do {
                try authorizer.validateEndpointSecurity(for: endpoint)
            } catch {
                throw Self.authorizerError(error)
            }
        }

        if let authorizer {
            try? await authorizing(message) {
                try await authorizer.prepareAuthorization(for: endpoint, session: session)
            }
        }

        var attempts = 0
        var retriedNonce = false
        let operationKey = message.operationKey
        // A stateless request names its version in `_meta`; the header must match.
        let version = message.protocolVersion ?? protocolVersion
        let standardHeaders =
            version.map { Version.profile(for: $0).usesStandardHeaders } == true
            ? Self.standardHeaders(for: message) : [:]

        while true {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue(
                "\(ContentType.json), \(ContentType.sse)",
                forHTTPHeaderField: HTTPHeaderName.accept
            )
            request.addValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.contentType)
            request.httpBody = message.data
            if message.method == SubscriptionsListen.name {
                request.timeoutInterval = Self.listenIdleTimeout
            }

            if let version {
                request.addValue(version, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
            }
            for (name, value) in standardHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            for (name, value) in additionalHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }

            if let sessionID = sessionID, !isStateless {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            }

            request = requestModifier(request)
            try applyAuthorization(to: &request)

            // disconnect() may have run while the authorizer was awaited.
            guard isConnected else {
                throw MCPError.internalError("Transport not connected")
            }
            // What the server answers about: another request may drop or
            // replace the session ID while this one waits.
            let sentSessionID = request.value(forHTTPHeaderField: HTTPHeaderName.sessionID)
            do {
                let (body, response) = try await session.responseBody(for: request, streaming: streamingSession)
                noteResponse(response, to: request)
                try await processResponse(
                    response: response, body: body, request: message, sentSessionID: sentSessionID)
                return
            } catch let authError as HTTPAuthenticationChallengeError {
                guard let authorizer else {
                    throw mapAuthenticationChallengeError(authError)
                }

                let handled: HTTPChallengeResult
                do {
                    handled = try await authorizing(message) {
                        try await authorizer.handleChallenge(
                            statusCode: authError.statusCode,
                            headers: authError.headers,
                            endpoint: endpoint,
                            operationKey: operationKey,
                            sentAuthorization: request.value(forHTTPHeaderField: HTTPHeaderName.authorization),
                            session: session
                        )
                    }
                } catch {
                    throw Self.authorizerError(error)
                }

                // RFC 9449 §9: the authorizer says whether the retry only
                // answers a DPoP nonce challenge, retried once per request.
                if handled.isDPoPNonceRetry {
                    if retriedNonce {
                        throw mapAuthenticationChallengeError(authError)
                    }
                    retriedNonce = true
                } else {
                    attempts += 1
                }

                if handled.retry, attempts < authorizer.maxAuthorizationAttempts {
                    continue
                }

                throw mapAuthenticationChallengeError(authError)
            }
        }
    }

    private func processResponse(
        response: URLResponse, body: ResponseBody, request message: OutgoingMessage, sentSessionID: String?
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""

        if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
            let wasSessionIDNil = (self.sessionID == nil)
            self.sessionID = newSessionID
            if wasSessionIDNil {
                triggerInitialSessionIDSignal()
            }
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        if Self.mayCarryPeerError(httpResponse.statusCode), contentType.contains(ContentType.json) {
            let errorBody = try await body.collect(limit: (1 << 20) + 1)
            if deliverErrorResponse(
                errorBody, contentType: contentType, status: httpResponse.statusCode, request: message,
                sentSessionID: sentSessionID)
            {
                return
            }
        }
        try processHTTPResponse(httpResponse, sentSessionID: sentSessionID)
        guard case 200..<300 = httpResponse.statusCode else { return }

        if contentType.contains(ContentType.sse) {
            logger.trace("Received SSE response, processing in streaming task")
            // The response this stream owes, if the POST carried a request.
            let awaited = message.requestID
            var lastEventID: String?
            var retry: Int?
            var responded = false
            do {
                try await processSSE(
                    body, until: awaited,
                    onEventID: { lastEventID = $0.isEmpty ? nil : $0 },
                    onRetry: { retry = Self.clampedRetryInterval($0) },
                    onResponse: { if $0 == awaited { responded = true } })
            } catch where awaited != nil && lastEventID != nil && !Task.isCancelled && !Self.isOversizedEvent(error) {
                logger.debug("POST SSE stream failed before its response", metadata: ["error": "\(error)"])
            }
            if let awaited, !responded, !Task.isCancelled {
                try await resumeResponseStream(
                    after: lastEventID, retry: retry, awaiting: awaited, request: message)
            }
        } else if contentType.contains(ContentType.json) {
            let buffer = try await body.collect()
            logger.trace("Received JSON response", metadata: ["size": "\(buffer.count)"])
            messageContinuation.yield(buffer)
        } else if httpResponse.statusCode != 202 || message.requestID != nil {
            // 202 Accepted has no body: how a server accepts a notification or a response.
            // A request is owed JSON or SSE.
            logger.warning("Unexpected content type: \(contentType)")
        }
    }

    /// Throws the error of a non-2xx reply to a POST that carried
    /// `sentSessionID` as its `Mcp-Session-Id`.
    private func processHTTPResponse(_ response: HTTPURLResponse, sentSessionID: String?) throws {
        switch response.statusCode {
        case 200..<300:
            return

        case 401:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 403:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 404 where sentSessionID != nil:
            sessionExpired(sentSessionID)
            throw statusError(response, isSessionExpired: true)

        default:
            throw statusError(response)
        }
    }

    /// The ``HTTPStatusError`` of `response`, as the transport throws it.
    private func statusError(_ response: HTTPURLResponse, isSessionExpired: Bool = false) -> MCPError {
        .transportError(
            HTTPStatusError(
                statusCode: response.statusCode, headers: responseHeaders(from: response),
                isSessionExpired: isSessionExpired))
    }

    /// Sets the authorizer's headers for the final URL and method of `request`.
    private func applyAuthorization(to request: inout URLRequest) throws {
        guard let authorizer else { return }
        let headers: [String: String]
        do {
            headers = try authorizer.authorizationHeaders(
                for: request.url ?? endpoint, method: request.httpMethod ?? "POST")
        } catch {
            throw Self.authorizerError(error)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// Shows the authorizer the headers of a response to `request`.
    private func noteResponse(_ response: URLResponse, to request: URLRequest) {
        guard let authorizer, let response = response as? HTTPURLResponse else { return }
        authorizer.didReceiveResponse(
            headers: responseHeaders(from: response), for: request.url ?? endpoint)
    }

    /// An error of the authorizer, as the transport throws it: wrapped in
    /// ``MCPError/transportError(_:)``, except `CancellationError`, which is
    /// thrown as is.
    private static func authorizerError(_ error: Swift.Error) -> Swift.Error {
        error is CancellationError ? error : MCPError.transportError(error)
    }

    private func mapAuthenticationChallengeError(_ error: HTTPAuthenticationChallengeError) -> MCPError {
        .transportError(HTTPStatusError(statusCode: error.statusCode, headers: error.headers))
    }

    private func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
        Self.headers(of: response)
    }

    /// The headers of `response` whose names and values are strings.
    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return headers
    }

    /// `Mcp-Method` and, where the method has one, `Mcp-Name` (SEP-2243).
    private static func standardHeaders(for message: OutgoingMessage) -> [String: String] {
        guard let method = message.method else { return [:] }
        var headers = [MCPRequestHeaders.method: method]
        if let name = message.nameValue {
            headers[MCPRequestHeaders.name] = MCPRequestHeaders.encode(name)
        }
        return headers
    }

    /// Delivers the JSON-RPC error a non-2xx reply carries for the POSTed request.
    ///
    /// Servers at 2026-07-28 answer protocol errors with HTTP 4xx and a
    /// JSON-RPC body. Only an `error` whose ID is the request's ID is
    /// delivered: any other body (a `result`, a placeholder or foreign ID, a
    /// batch) leaves the request to fail with the status error. Returns
    /// `true` when the error was delivered. Callers check
    /// `mayCarryPeerError(_:)` first.
    private func deliverErrorResponse(
        _ body: Data, contentType: String, status: Int, request message: OutgoingMessage, sentSessionID: String?
    ) -> Bool {
        guard contentType.contains(ContentType.json),
            let requestID = message.requestID,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            json["error"] is [String: Any], json["result"] == nil,
            JSONRPCMessageKind.extractID(from: json) == requestID
        else { return false }
        if status == 404 {
            sessionExpired(sentSessionID)
        }
        messageContinuation.yield(body)
        return true
    }

    /// Whether a JSON-RPC error on a reply with `status` is the peer's
    /// answer to the request: a 4xx other than 401 and 403 (authorization),
    /// 408 and 429. Those, and 5xx, report that the server could not answer
    /// (a server shutting down answers 503 with `connectionClosed`), so they
    /// fail the request with the status error even when the body has a
    /// JSON-RPC error for it.
    private static func mayCarryPeerError(_ status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 403, 408, 429].contains(status)
    }

    /// Ends the session after a 404 to a POST that carried `sentSessionID`
    /// (2025-11-25 transports, session management): drops the session ID and
    /// stops the GET stream, which belonged to the session. Does nothing for
    /// a request without a session ID, or when another reply already dropped
    /// the session ID or a new session replaced it.
    private func sessionExpired(_ sentSessionID: String?) {
        guard let sentSessionID else { return }
        logger.warning("Session has expired")
        guard sessionID == sentSessionID else { return }
        sessionID = nil
        streamingTask?.cancel()
        streamingTask = nil
    }

    /// Whether `error` reports a 400, 404 or 405 reply without a JSON-RPC
    /// answer for the request: how a server that serves only the handshake
    /// refuses a request without a session.
    package static func isSessionlessRefusal(_ error: Swift.Error) -> Bool {
        guard case .transportError(let underlying) = error as? MCPError,
            let status = underlying as? HTTPStatusError, !status.isSessionExpired
        else { return false }
        return [400, 404, 405].contains(status.statusCode)
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - SSE

    /// What the GET stream loop reads from the transport before each step:
    /// `nil` once the transport is disconnected.
    private func listenState() -> (hasSessionID: Bool, retryInterval: Int)? {
        isConnected ? (sessionID != nil, retryInterval) : nil
    }

    /// The standalone GET stream loop. It holds `reference`'s transport only
    /// for one step (building the GET, reading its response's status, one
    /// event), never while it waits for a session ID, for the authorizer or
    /// the response headers, sleeps before reconnecting or waits for the
    /// next event, so a transport dropped without ``disconnect()`` is
    /// released; the loop then ends.
    private static func listenForServerEvents(
        _ reference: WeakReference, sessionIDSignal: SessionIDSignal, timeout: TimeInterval, logger: Logger
    ) async {
        guard let initial = await reference.transport?.listenState() else { return }

        if !initial.hasSessionID {
            logger.debug("⏳ Waiting for session ID to be set (timeout: \(timeout)s)...")

            let startTime = Date()
            if await sessionIDSignal.wait(timeout: timeout) == .timedOut {
                logger.warning("⏱️ Timeout waiting for session ID (\(timeout)s). SSE stream will proceed anyway.")
            } else if await reference.transport?.sessionID != nil {
                let elapsed = Date().timeIntervalSince(startTime)
                logger.debug("✓ Session ID received after \(Int(elapsed * 1000))ms, proceeding with SSE connection")
            }
        } else {
            logger.debug("✓ Session ID already available, proceeding with SSE connection immediately")
        }

        var isFirstAttempt = true
        var attemptCount = 0
        // Failed connections and streams that close without an event in a
        // row; each one after the first doubles the wait.
        var consecutiveFailures = 0
        var sessionExpired = false

        logger.debug("🔄 Starting SSE retry loop", metadata: [
            "isCancelled": "\(Task.isCancelled)"
        ])

        while !Task.isCancelled, let state = await reference.transport?.listenState() {
            attemptCount += 1
            logger.debug("🔄 SSE retry loop iteration", metadata: [
                "attempt": "\(attemptCount)",
                "isFirstAttempt": "\(isFirstAttempt)"
            ])

            do {
                if !isFirstAttempt {
                    let delayMs = reconnectDelay(
                        retryInterval: state.retryInterval, consecutiveFailures: consecutiveFailures)
                    logger.debug("⏳ Waiting before SSE reconnection", metadata: ["retryMs": "\(delayMs)"])
                    try await Task.sleep(for: .milliseconds(delayMs))
                    logger.debug("✓ Wait complete, reconnecting now")
                }
                isFirstAttempt = false

                logger.debug("📡 Calling connectToEventStream (attempt #\(attemptCount))")

                let receivedEvents = try await connectToEventStream(reference, logger: logger)
                consecutiveFailures = receivedEvents ? 0 : consecutiveFailures + 1

                // `nil` once the transport is released or disconnected.
                let willRetryAfter = await reference.transport?.listenState().map {
                    "\(reconnectDelay(retryInterval: $0.retryInterval, consecutiveFailures: consecutiveFailures))ms"
                }
                logger.info("🔌 SSE stream closed gracefully, will reconnect", metadata: [
                    "attempt": "\(attemptCount)",
                    "willRetryAfter": "\(willRetryAfter ?? "none")"
                ])
            } catch {
                consecutiveFailures += 1
                if !Task.isCancelled {
                    logger.error("❌ SSE connection error (attempt #\(attemptCount)): \(error)")
                } else {
                    logger.debug("⏹️ SSE task cancelled")
                }
                // The stream belonged to the session the server ended.
                if case .transportError(let status as HTTPStatusError) = error as? MCPError, status.isSessionExpired {
                    sessionExpired = true
                    break
                }
            }

            logger.debug("🔄 End of retry loop iteration", metadata: [
                "isCancelled": "\(Task.isCancelled)"
            ])
        }

        // Why the loop ended. disconnect(), a 405 and the switch to a
        // stateless revision cancel it; so does the release of the transport.
        let reason =
            reference.transport == nil
            ? "released" : sessionExpired ? "sessionExpired" : Task.isCancelled ? "cancelled" : "disconnected"
        logger.debug("⏹️ SSE retry loop exited", metadata: [
            "reason": "\(reason)",
            "totalAttempts": "\(attemptCount)"
        ])
    }

    /// Opens the standalone GET stream and reads it until it ends, or until
    /// `reference`'s transport is released. Returns whether any event arrived.
    private static func connectToEventStream(_ reference: WeakReference, logger: Logger) async throws -> Bool {
        guard let stream = try await openStandaloneStream(reference, logger: logger) else { return false }

        logger.debug("📥 Starting SSE event processing")
        var eventCount = 0
        do {
            for try await event in stream.serverSentEvents {
                eventCount += 1

                if Task.isCancelled {
                    logger.debug("⏹️ SSE processing cancelled", metadata: ["eventsProcessed": "\(eventCount)"])
                    break
                }

                guard await reference.transport?.receiveStandaloneEvent(event) != nil else {
                    logger.debug("⏹️ Transport released, closing the SSE stream")
                    stream.cancel()
                    break
                }
            }
        } catch is ServerSentEventParser.LineTooLong {
            // A resumption would replay the same event: the next connection
            // opens a fresh stream instead, and the event is lost.
            await reference.transport?.dropStandaloneResumePoint()
            throw MCPError.internalError(Self.sseLineTooLong)
        } catch is ServerSentEventParser.EventTooLong {
            await reference.transport?.dropStandaloneResumePoint()
            throw MCPError.internalError(Self.sseEventTooLong)
        }

        logger.debug("✓ SSE event stream completed", metadata: ["eventsProcessed": "\(eventCount)"])
        return eventCount > 0
    }

    /// Opens the standalone GET stream: its body once the server accepted
    /// it, `nil` when the transport is not connected or was released. It
    /// holds `reference`'s transport only while it reads or records state,
    /// not while it waits for the authorizer or the response headers.
    private static func openStandaloneStream(_ reference: WeakReference, logger: Logger) async throws -> ResponseBody? {
        guard let resumeFrom = try await reference.transport?.standaloneStreamStart() else {
            logger.debug("⚠️ Skipping connectToEventStream - transport not connected")
            return nil
        }
        guard
            let reply = try await openEventStream(
                reference, lastEventID: resumeFrom.lastEventID, protocolVersion: resumeFrom.protocolVersion)
        else { return nil }
        guard try await reference.transport?.acceptStandaloneStream(reply) != nil else {
            logger.debug("⏹️ Transport released, closing the SSE stream")
            reply.stream.cancel()
            return nil
        }
        return reply.stream
    }

    /// Checks the endpoint for the standalone GET stream and reads what its
    /// GET resumes from: `nil` when the transport is not connected.
    private func standaloneStreamStart() throws -> (lastEventID: String?, protocolVersion: String?)? {
        guard isConnected else { return nil }

        if let authorizer {
            do {
                try authorizer.validateEndpointSecurity(for: endpoint)
            } catch {
                throw Self.authorizerError(error)
            }
        }

        if let lastEventID = lastEventID {
            logger.info("→ Resuming SSE stream with Last-Event-ID", metadata: ["lastEventID": "\(lastEventID)"])
        } else {
            logger.info("→ Connecting to SSE stream (no last event ID to resume from)")
        }
        return (lastEventID, protocolVersion)
    }

    /// Records the reply to the standalone GET: its session ID, or why the
    /// server refused the stream, which it throws.
    private func acceptStandaloneStream(_ reply: EventStreamReply) throws {
        guard reply.statusCode == 200 else {
            reply.stream.cancel()
            if reply.statusCode == 405 {
                self.streamingTask?.cancel()
            }
            // The session ID stays: the next request carries it, gets the
            // 404 the server must send for it, and reports the expiry to
            // its caller.
            if reply.statusCode == 404, reply.sentSessionID != nil {
                logger.warning("Session has expired")
                throw reply.statusError(isSessionExpired: true)
            }
            // The server no longer has the event to resume from: the next
            // connection opens a fresh stream instead of repeating the ID.
            if reply.statusCode == 400, lastEventID != nil {
                lastEventID = nil
            }
            throw reply.statusError()
        }

        if let newSessionID = reply.sessionID {
            let wasSessionIDNil = (self.sessionID == nil)
            self.sessionID = newSessionID
            if wasSessionIDNil {
                triggerInitialSessionIDSignal()
            }
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }
    }

    /// Forgets the standalone stream's last event ID after an event too
    /// large to read, so that the next GET does not replay it.
    private func dropStandaloneResumePoint() {
        lastEventID = nil
    }

    /// Handles one event of the standalone GET stream, as ``processSSE(_:until:onEventID:onRetry:onResponse:)``
    /// does: records its ID and retry interval and yields its message.
    private func receiveStandaloneEvent(_ event: ServerSentEvent) {
        logger.trace(
            "SSE event received",
            metadata: [
                "type": "\(event.event ?? "message")",
                "id": "\(event.id ?? "none")",
            ]
        )

        // An empty `id` resets the last event ID.
        if let eventID = event.id {
            lastEventID = eventID.isEmpty ? nil : eventID
            logger.debug("Stored event ID for resumability", metadata: ["eventID": "\(eventID)"])
        }

        if let retry = event.retry {
            retryInterval = Self.clampedRetryInterval(retry)
            logger.debug("SSE retry interval updated", metadata: ["retryMs": "\(retry)"])
        }

        if !event.data.isEmpty, let data = event.data.data(using: .utf8) {
            messageContinuation.yield(data)
        }
    }

    /// The reply to a GET for an SSE stream.
    private struct EventStreamReply: Sendable {
        let stream: ResponseBody
        let statusCode: Int
        let headers: [String: String]
        /// The `Mcp-Session-Id` header.
        let sessionID: String?
        /// The `Mcp-Session-Id` the answered GET carried.
        let sentSessionID: String?

        /// The ``HTTPStatusError`` of the reply, as the transport throws it.
        func statusError(isSessionExpired: Bool = false) -> MCPError {
            .transportError(HTTPStatusError(statusCode: statusCode, headers: headers, isSessionExpired: isSessionExpired))
        }
    }

    /// What a GET for an SSE stream uses of the transport while it waits.
    private var eventStreamInputs: (
        endpoint: URL, session: URLSession, streamingSession: StreamingSession,
        authorizer: (any HTTPClientAuthorizer)?
    ) {
        (endpoint, session, streamingSession, authorizer)
    }

    /// A GET for an SSE stream with the transport's current headers.
    private func eventStreamRequest(lastEventID: String?, protocolVersion: String?) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.addValue(ContentType.sse, forHTTPHeaderField: HTTPHeaderName.accept)
        request.addValue("no-cache", forHTTPHeaderField: HTTPHeaderName.cacheControl)
        if let protocolVersion {
            request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
        }
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
        }
        if let lastEventID {
            request.addValue(lastEventID, forHTTPHeaderField: HTTPHeaderName.lastEventID)
        }
        request = requestModifier(request)
        try applyAuthorization(to: &request)

        // disconnect() may have run while the authorizer was awaited.
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }
        return request
    }

    /// Sends a GET for an SSE stream, resuming after `lastEventID` when
    /// given. A 401 or 403 goes to the authorizer, as for a POST, and the
    /// GET is retried while it handles the challenge.
    ///
    /// It holds `reference`'s transport only while it builds each GET, not
    /// while it waits for the authorizer or the response headers, and
    /// returns `nil` when the transport was released.
    private static func openEventStream(
        _ reference: WeakReference, lastEventID: String?, protocolVersion: String?
    ) async throws -> EventStreamReply? {
        guard let inputs = await reference.transport?.eventStreamInputs else { return nil }
        if let authorizer = inputs.authorizer {
            try? await authorizer.prepareAuthorization(for: inputs.endpoint, session: inputs.session)
        }
        var attempts = 0
        var retriedNonce = false
        while true {
            guard
                let request = try await reference.transport?.eventStreamRequest(
                    lastEventID: lastEventID, protocolVersion: protocolVersion)
            else { return nil }
            let (stream, response) = try await inputs.session.responseBody(
                for: request, streaming: inputs.streamingSession)
            guard let httpResponse = response as? HTTPURLResponse else {
                stream.cancel()
                throw MCPError.internalError("Invalid HTTP response")
            }
            let headers = Self.headers(of: httpResponse)
            inputs.authorizer?.didReceiveResponse(headers: headers, for: request.url ?? inputs.endpoint)
            guard let authorizer = inputs.authorizer, httpResponse.statusCode == 401 || httpResponse.statusCode == 403
            else {
                return EventStreamReply(
                    stream: stream, statusCode: httpResponse.statusCode, headers: headers,
                    sessionID: httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID),
                    sentSessionID: request.value(forHTTPHeaderField: HTTPHeaderName.sessionID))
            }
            stream.cancel()
            let failure = MCPError.transportError(
                HTTPStatusError(statusCode: httpResponse.statusCode, headers: headers))
            let handled: HTTPChallengeResult
            do {
                handled = try await authorizer.handleChallenge(
                    statusCode: httpResponse.statusCode,
                    headers: headers,
                    endpoint: inputs.endpoint,
                    operationKey: nil,
                    sentAuthorization: request.value(forHTTPHeaderField: HTTPHeaderName.authorization),
                    session: inputs.session
                )
            } catch {
                throw Self.authorizerError(error)
            }
            // RFC 9449 §9: a DPoP nonce retry is allowed once per GET, as for a POST.
            if handled.isDPoPNonceRetry {
                if retriedNonce {
                    throw failure
                }
                retriedNonce = true
            } else {
                attempts += 1
            }
            guard handled.retry, attempts < authorizer.maxAuthorizationAttempts else {
                throw failure
            }
        }
    }

    /// The most GET resumptions of one POST stream in a row without a new
    /// message before its request fails.
    static let maxStreamResumptions = 10

    /// Resumes a POST stream that ended before its response (2025-11-25
    /// resumability, SEP-1699): a GET with the stream's own last event ID,
    /// repeated while the server closes the stream again. Without an event
    /// ID, or when the server refuses the GET, the request fails with an
    /// error instead of waiting forever. Revisions without sessions
    /// (2026-07-28) have no resumability: the request fails at once.
    private func resumeResponseStream(
        after eventID: String?, retry: Int?, awaiting id: String, request message: OutgoingMessage
    ) async throws {
        let requestData = message.data
        let version = message.protocolVersion ?? protocolVersion
        guard !isStateless, version.map({ Version.profile(for: $0).usesSessions }) ?? true else {
            deliverStreamLoss(for: requestData, reason: "The server closed the response stream without a response")
            return
        }
        var lastEventID = eventID
        var retry = retry
        var attempts = 0
        // The event IDs the client has seen: the points it resumed from and
        // those of the messages the resumed streams delivered.
        var seenEventIDs: Set<String> = []
        while let resumeFrom = lastEventID, attempts < Self.maxStreamResumptions {
            guard isConnected, !Task.isCancelled else { return }
            attempts += 1
            seenEventIDs.insert(resumeFrom)
            try await Task.sleep(for: .milliseconds(retry ?? retryInterval))
            logger.debug(
                "Resuming a response stream", metadata: ["lastEventID": "\(resumeFrom)", "attempt": "\(attempts)"])

            let reply: EventStreamReply
            do {
                // Never `nil`: this call holds the transport.
                guard
                    let opened = try await Self.openEventStream(
                        WeakReference(self), lastEventID: resumeFrom, protocolVersion: version)
                else { return }
                reply = opened
            } catch where !Task.isCancelled && !(error is MCPError) && !(error is CancellationError) {
                // A dropped connection is when resuming matters. Refusals,
                // authorization failures and a closed transport are MCPErrors
                // and still fail the request.
                logger.debug("Resuming a response stream failed", metadata: ["error": "\(error)"])
                continue
            }
            guard reply.statusCode == 200 else {
                reply.stream.cancel()
                logger.warning(
                    "The server refused to resume a response stream",
                    metadata: ["status": "\(reply.statusCode)"])
                break
            }
            var responded = false
            var progressed = false
            do {
                try await processSSE(
                    reply.stream, until: id,
                    onEventID: { lastEventID = $0.isEmpty ? nil : $0 },
                    onRetry: { retry = Self.clampedRetryInterval($0) },
                    onMessage: {
                        if let current = lastEventID, seenEventIDs.insert(current).inserted { progressed = true }
                    },
                    onResponse: { if $0 == id { responded = true } })
            } catch {
                if Task.isCancelled { return }
                // The replay would fail the same way.
                if Self.isOversizedEvent(error) { throw error }
                logger.debug("Resumed response stream failed", metadata: ["error": "\(error)"])
            }
            if responded { return }
            // A server that polls (SEP-1699) closes streams that delivered
            // messages: only resumptions in a row without a new one count.
            // A new event ID alone is no progress, as each resumption is
            // primed, and neither is a message under an event ID seen
            // before, which a server that ignores Last-Event-ID replays.
            if progressed { attempts = 0 }
        }
        // A cancelled read can end the last attempt's stream without an
        // error: a cancelled request or a closed transport is no loss.
        guard isConnected, !Task.isCancelled else { return }
        deliverStreamLoss(
            for: requestData,
            reason: eventID != nil
                ? "The response stream could not be resumed"
                : "The server closed the response stream without a response or an event ID to resume from")
    }

    /// Fails the request of a response stream that cannot be resumed.
    private func deliverStreamLoss(for requestData: Data, reason: String) {
        guard let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
            let id = request["id"]
        else { return }
        let error: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": MCPError.internalError(nil).code, "message": reason],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: error) else { return }
        logger.warning("\(reason)")
        messageContinuation.yield(data)
    }

    /// The errors of an SSE line or event over the parser's limits.
    static let sseLineTooLong = "SSE line longer than 16 MiB"
    static let sseEventTooLong = "SSE event data longer than 16 MiB"

    /// Whether `error` is an SSE line or event over the parser's limits: a
    /// resumed stream would replay it and fail the same way.
    static func isOversizedEvent(_ error: Swift.Error) -> Bool {
        guard case .internalError(let detail?) = error as? MCPError else { return false }
        return detail == sseLineTooLong || detail == sseEventTooLong
    }

    /// Reads SSE events and yields their messages. `onEventID` and
    /// `onRetry` see each event's `id` (empty when the event resets it) and
    /// `retry`, `onMessage` each message, `onResponse` the ID of each
    /// response. With `until`, reading
    /// stops once that response is delivered. Messages are only parsed for
    /// their ID when `until` or `onResponse` needs it. Returns whether any
    /// event arrived. A line or event over the parser's limits throws
    /// ``sseLineTooLong`` or ``sseEventTooLong``.
    @discardableResult
    private func processSSE(
        _ stream: ResponseBody,
        until responseID: String? = nil,
        onEventID: (String) -> Void = { _ in },
        onRetry: (Int) -> Void = { _ in },
        onMessage: () -> Void = {},
        onResponse: ((String) -> Void)? = nil
    ) async throws -> Bool {
        logger.debug("📥 Starting SSE event processing")
        var eventCount = 0
        var hadDataEvent = false

        do {
            for try await event in stream.serverSentEvents {
                eventCount += 1

                if Task.isCancelled {
                    logger.debug("⏹️ SSE processing cancelled", metadata: ["eventsProcessed": "\(eventCount)"])
                    break
                }

                logger.trace(
                    "SSE event received",
                    metadata: [
                        "type": "\(event.event ?? "message")",
                        "id": "\(event.id ?? "none")",
                    ]
                )

                // An empty `id` resets the last event ID.
                if let eventID = event.id {
                    onEventID(eventID)
                    logger.debug("Stored event ID for resumability", metadata: ["eventID": "\(eventID)"])
                }

                if let retry = event.retry {
                    onRetry(retry)
                    logger.debug("SSE retry interval updated", metadata: ["retryMs": "\(retry)"])
                }

                if !event.data.isEmpty, let data = event.data.data(using: .utf8) {
                    hadDataEvent = true
                    onMessage()
                    var delivered: String?
                    if responseID != nil || onResponse != nil,
                        case .response(let id) = JSONRPCMessageKind(data: data)
                    {
                        onResponse?(id)
                        delivered = id
                    }
                    messageContinuation.yield(data)
                    if let responseID, delivered == responseID {
                        stream.cancel()
                        break
                    }
                }
            }
        } catch is ServerSentEventParser.LineTooLong {
            throw MCPError.internalError(Self.sseLineTooLong)
        } catch is ServerSentEventParser.EventTooLong {
            throw MCPError.internalError(Self.sseEventTooLong)
        }

        logger.debug("✓ SSE event stream completed", metadata: ["eventsProcessed": "\(eventCount)", "hadData": "\(hadDataEvent)"])
        return eventCount > 0
    }
}

/// The parts of an outgoing JSON-RPC message the transport reads, parsed
/// once per send.
struct OutgoingMessage: Sendable {
    let data: Data
    /// A request's ID, rendered like ``JSONRPCMessageKind`` IDs; `nil` for
    /// notifications, responses and batches.
    let requestID: String?
    /// The method name, as sent.
    let method: String?
    /// The `Mcp-Name` value: `params.name`, `params.uri` or `params.taskId`
    /// by method.
    let nameValue: String?
    /// `params._meta["io.modelcontextprotocol/protocolVersion"]`.
    let protocolVersion: String?
    /// The `requestId` of a `notifications/cancelled` message.
    let cancelledRequestID: String?

    /// The trimmed method name; the operation key for authorization.
    var operationKey: String? {
        let trimmed = method?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    init(_ data: Data) {
        self.data = data
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let method = json?["method"] as? String
        let params = json?["params"] as? [String: Any]
        self.method = method
        self.nameValue = method.flatMap {
            MCPRequestHeaders.nameValue(
                method: $0, name: params?["name"] as? String, uri: params?["uri"] as? String,
                taskID: params?["taskId"] as? String)
        }
        self.requestID = json.flatMap { json in
            json["method"] is String ? JSONRPCMessageKind.extractID(from: json) : nil
        }
        self.protocolVersion = (params?["_meta"] as? [String: Any])?[MetaKey.protocolVersion] as? String
        self.cancelledRequestID =
            method == CancelledNotification.name && json?["id"] == nil
            ? JSONRPCMessageKind.extractID(from: ["id": params?["requestId"] as Any]) : nil
    }
}
