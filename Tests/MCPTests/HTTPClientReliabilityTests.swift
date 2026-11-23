@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Retry bounds, reconnection backoff, cancellation of in-flight POSTs, and
// authorization challenges on GET streams.

@Suite("HTTP client retry bounds")
struct HTTPClientRetryBoundsTests {
    @Test("A server's retry value is clamped")
    func clampsRetry() {
        #expect(HTTPClientTransport.clampedRetryInterval(1) == 10)
        #expect(HTTPClientTransport.clampedRetryInterval(3000) == 3000)
        #expect(HTTPClientTransport.clampedRetryInterval(Int.max) == 60_000)
    }

    @Test("Reconnection waits double after each failure past the first, up to a cap")
    func backsOff() {
        #expect(HTTPClientTransport.reconnectDelay(retryInterval: 3000, consecutiveFailures: 0) == 3000)
        #expect(HTTPClientTransport.reconnectDelay(retryInterval: 3000, consecutiveFailures: 1) == 3000)
        #expect(HTTPClientTransport.reconnectDelay(retryInterval: 3000, consecutiveFailures: 2) == 6000)
        #expect(HTTPClientTransport.reconnectDelay(retryInterval: 10, consecutiveFailures: 4) == 80)
        #expect(HTTPClientTransport.reconnectDelay(retryInterval: 3000, consecutiveFailures: 10) == 60_000)
        #expect(HTTPClientTransport.reconnectDelay(retryInterval: 60_000, consecutiveFailures: 1000) == 60_000)
    }

    @Test("The requestId of notifications/cancelled is read as a routing key")
    func cancelledRequestID() {
        func id(_ json: String) -> String? { JSONRPCMessageKind.cancelledRequestID(in: Data(json.utf8)) }
        #expect(id(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"r1"}}"#) == "r1")
        #expect(id(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#) == "7")
        #expect(id(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"requestId":"r1"}}"#) == nil)
        #expect(id(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#) == nil)
    }
}

/// Collects log messages at warning level and above.
final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    var messages: [String] { lock.withLock { captured } }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        guard level >= .warning else { return }
        lock.withLock { captured.append(message.description) }
    }
}

@Suite("HTTP status error descriptions")
struct HTTPStatusErrorDescriptionTests {
    @Test("A logged status error names the response headers without their values")
    func debugDescriptionOmitsHeaderValues() {
        let status = HTTPStatusError(
            statusCode: 401,
            headers: ["Set-Cookie": "session=secret-cookie", "WWW-Authenticate": #"Bearer realm="secret-realm""#])
        let error = MCPError.transportError(status)
        for text in [String(reflecting: error), "\(error)", String(reflecting: status), "\(status)"] {
            #expect(!text.contains("secret"), "\(text)")
            #expect(text.contains("Set-Cookie"))
        }
        #expect(
            String(reflecting: status)
                == #"HTTPStatusError(statusCode: 401, isSessionExpired: false, headers: ["Set-Cookie", "WWW-Authenticate"])"#)
        #expect(status.value(forHeader: "set-cookie") == "session=secret-cookie")
    }
}

@Suite("HTTP client connection limit warning")
struct HTTPClientConnectionLimitTests {
    @Test("A configuration at the platform's default connection limit is reported")
    func warnsAtPlatformDefault() {
        let handler = CapturingLogHandler()
        let logger = Logger(label: "test", factory: { _ in handler })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        _ = HTTPClientTransport(
            endpoint: URL(string: "http://127.0.0.1:9/mcp")!, configuration: configuration, logger: logger)
        #expect(handler.messages.contains { $0.contains("connections per host") })
    }

    @Test("The default configuration is not reported")
    func silentByDefault() {
        let handler = CapturingLogHandler()
        let logger = Logger(label: "test", factory: { _ in handler })
        _ = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:9/mcp")!, logger: logger)
        #expect(handler.messages.isEmpty)
    }
}

#if swift(>=6.1)

    private actor RecordedRequests {
        private(set) var all: [URLRequest] = []
        private var waiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func append(_ request: URLRequest) {
            all.append(request)
            let ready = waiters.filter { count(of: $0.method) >= $0.count }
            waiters.removeAll { count(of: $0.method) >= $0.count }
            for waiter in ready { waiter.continuation.resume() }
        }

        var gets: [URLRequest] { all.filter { $0.httpMethod == "GET" } }

        /// Returns once the mock has received `count` requests with `method`.
        func waitFor(_ count: Int, _ method: String) async {
            guard self.count(of: method) < count else { return }
            await withCheckedContinuation { waiters.append((method, count, $0)) }
        }

        /// Whether a GET arrives within `limit`.
        func receivesGET(within limit: Duration) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if !gets.isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        private func count(of method: String) -> Int {
            all.filter { $0.httpMethod == method }.count
        }
    }

    /// An authorizer whose token changes after each challenge it handles.
    private final class ChallengeCountingAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        private let lock = NSLock()
        private var token = "old"
        private var challenges: [Int] = []
        private var sent: [String?] = []

        var maxAuthorizationAttempts: Int { 3 }
        var handledChallenges: [Int] { lock.withLock { challenges } }
        /// The `Authorization` value of each challenged request.
        var sentAuthorizations: [String?] { lock.withLock { sent } }

        func validateEndpointSecurity(for endpoint: URL) throws {}

        func authorizationHeaders(for url: URL, method: String) throws -> [String: String] {
            lock.withLock { ["Authorization": "Bearer \(token)"] }
        }

        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            lock.withLock {
                challenges.append(statusCode)
                token = "new"
            }
            return true
        }

        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
            sentAuthorization: String?, session: URLSession
        ) async throws -> HTTPChallengeResult {
            lock.withLock { sent.append(sentAuthorization) }
            return HTTPChallengeResult(
                retry: try await handleChallenge(
                    statusCode: statusCode, headers: headers, endpoint: endpoint, operationKey: operationKey,
                    session: session))
        }
    }

    /// An authorizer that throws `CancellationError` at one stage, as one
    /// whose authorization flow the user cancelled does.
    private final class CancellingAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        enum Stage: Sendable { case validate, headers, challenge }

        let stage: Stage
        init(_ stage: Stage) { self.stage = stage }

        var maxAuthorizationAttempts: Int { 3 }

        func validateEndpointSecurity(for endpoint: URL) throws {
            if stage == .validate { throw CancellationError() }
        }

        func authorizationHeaders(for url: URL, method: String) throws -> [String: String] {
            if stage == .headers { throw CancellationError() }
            return ["Authorization": "Bearer t"]
        }

        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            if stage == .challenge { throw CancellationError() }
            return false
        }
    }

    /// Fails the test when `operation` takes longer than `limit`.
    private func finishes<T: Sendable>(
        within limit: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Yields each message logged at debug level and above to `sink`.
    private struct StreamingLogHandler: LogHandler {
        let sink: AsyncStream<String>.Continuation
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .debug

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(
            level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
            source: String, file: String, function: String, line: UInt
        ) {
            sink.yield(message.description)
        }
    }

    /// Returns once a POST stream ended without its response. The transport
    /// logs this just before it waits to resume the stream, without
    /// suspending in between, so a call to the transport runs during the wait.
    private func waitForStreamEnd(_ messages: AsyncStream<String>) async {
        for await message in messages where message.contains("SSE event stream completed") { return }
    }

    @Suite("HTTP client reliability", .serialized)
    struct HTTPClientReliabilityTests {
        let endpoint = URL(string: "http://127.0.0.1:9/mcp")!
        let request = Data(#"{"jsonrpc":"2.0","id":"r1","method":"tools/call","params":{"name":"slow"}}"#.utf8)
        let response = #"{"jsonrpc":"2.0","id":"r1","result":{"content":[]}}"#

        func sse(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> (HTTPURLResponse, Data) {
            var fields = ["Content-Type": "text/event-stream", "Mcp-Session-Id": "s1"]
            fields.merge(headers) { _, new in new }
            return (
                HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!,
                Data(body.utf8)
            )
        }

        func makeTransport(
            streaming: Bool = false, sseInitializationTimeout: TimeInterval = 0.05,
            authorizer: (any HTTPClientAuthorizer)? = nil, logger: Logger? = nil
        ) -> (HTTPClientTransport, String) {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            configuration.httpMaximumConnectionsPerHost = HTTPClientTransport.defaultMaximumConnectionsPerHost
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: streaming,
                sseInitializationTimeout: sseInitializationTimeout, authorizer: authorizer, logger: logger)
            return (transport, key)
        }

        /// A transport whose log messages arrive on the returned stream.
        func makeLoggingTransport() -> (HTTPClientTransport, String, AsyncStream<String>) {
            let (messages, sink) = AsyncStream<String>.makeStream()
            let logger = Logger(label: "mcp.test.reliability") { _ in StreamingLogHandler(sink: sink) }
            let (transport, key) = makeTransport(logger: logger)
            return (transport, key, messages)
        }

        func firstMessage(_ transport: HTTPClientTransport) async throws -> String? {
            for try await data in await transport.receive() {
                return String(decoding: data, as: UTF8.self)
            }
            return nil
        }

        @Test("Disconnect ends a response stream waiting a server-chosen delay to resume", .timeLimit(.minutes(1)))
        func disconnectEndsResumptionWait() async throws {
            let (transport, key, logs) = makeLoggingTransport()
            let requests = RecordedRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return sse("id: e1\nretry: 9223372036854775807\ndata: \n\n")
            }
            try await transport.connect()
            let send = Task { [request] in try? await transport.send(request) }
            await waitForStreamEnd(logs)
            await transport.disconnect()
            let ended = try await finishes(within: .seconds(5)) { await send.value; return true }
            #expect(ended == true)
            #expect(await requests.gets.isEmpty)
        }

        @Test("notifications/cancelled stops reading and resuming the cancelled request's stream", .timeLimit(.minutes(1)))
        func cancelledNotificationStopsPost() async throws {
            let (transport, key, logs) = makeLoggingTransport()
            let requests = RecordedRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                if let body = request.httpBodyStreamData(), String(decoding: body, as: UTF8.self).contains("cancelled") {
                    return (
                        HTTPURLResponse(url: endpoint, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!,
                        Data()
                    )
                }
                return sse("id: e1\nretry: 30000\ndata: \n\n")
            }
            try await transport.connect()
            let send = Task { [request] in try await transport.send(request) }
            await waitForStreamEnd(logs)
            let cancel = Data(
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"r1"}}"#.utf8)
            try await transport.send(cancel)
            let outcome = try await finishes(within: .seconds(5)) { () -> String in
                do {
                    try await send.value
                    return "returned"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return "\(error)"
                }
            }
            #expect(outcome == "cancelled")
            #expect(await requests.gets.isEmpty)
            await transport.disconnect()
        }

        @Test("Repeated GET stream failures back off")
        func getStreamBacksOff() async throws {
            let (transport, key) = makeTransport(streaming: true)
            let requests = RecordedRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                if await requests.gets.count == 1 {
                    return sse("id: g1\nretry: 10\ndata: \n\n")
                }
                return sse("", status: 500)
            }
            try await transport.connect()
            try await Task.sleep(for: .seconds(2))
            await transport.disconnect()
            // Without backoff a 10 ms retry gives well over a hundred GETs.
            let count = await requests.gets.count
            #expect(count >= 3)
            #expect(count <= 15)
        }

        @Test("A GET resume refused with 400 is followed by a fresh GET", .timeLimit(.minutes(1)))
        func clearsLastEventIDAfter400() async throws {
            let (transport, key) = makeTransport(streaming: true)
            let requests = RecordedRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                if request.value(forHTTPHeaderField: "Last-Event-ID") != nil {
                    return sse("", status: 400)
                }
                return sse("id: g1\nretry: 10\ndata: \n\n")
            }
            try await transport.connect()
            await requests.waitFor(3, "GET")
            await transport.disconnect()
            let ids = await requests.gets.map { $0.value(forHTTPHeaderField: "Last-Event-ID") }
            #expect(ids.prefix(3) == [nil, "g1", nil])
        }

        @Test(
            "A GET stream that fails on a line over the limit reconnects without its Last-Event-ID",
            .timeLimit(.minutes(1)))
        func getStreamDropsEventIDAfterOversizedLine() async throws {
            let (transport, key) = makeTransport(streaming: true)
            let requests = RecordedRequests()
            // A resumption after g1 would replay the same line.
            let body =
                "id: g1\nretry: 10\ndata: \n\ndata: "
                + String(repeating: "a", count: ServerSentEventParser.maxLineLength) + "\n\n"
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return sse(body)
            }
            try await transport.connect()
            await requests.waitFor(2, "GET")
            await transport.disconnect()
            let ids = await requests.gets.map { $0.value(forHTTPHeaderField: "Last-Event-ID") }
            #expect(ids.prefix(2) == [nil, nil])
        }

        @Test("A 401 on the GET stream goes to the authorizer and the GET is retried", .timeLimit(.minutes(1)))
        func getStreamHandlesChallenge() async throws {
            let authorizer = ChallengeCountingAuthorizer()
            let (transport, key) = makeTransport(streaming: true, authorizer: authorizer)
            let requests = RecordedRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                    return sse("", status: 401, headers: ["WWW-Authenticate": #"Bearer error="invalid_token""#])
                }
                return sse("id: g1\nretry: 10000\ndata: \n\n")
            }
            try await transport.connect()
            await requests.waitFor(2, "GET")
            await transport.disconnect()
            let auth = await requests.gets.map { $0.value(forHTTPHeaderField: "Authorization") }
            #expect(authorizer.handledChallenges == [401])
            #expect(authorizer.sentAuthorizations == ["Bearer old"])
            #expect(auth.prefix(2) == ["Bearer old", "Bearer new"])
        }

        @Test("A 202 without a body is quiet for a notification, not for a request or another content type")
        func acceptedWithoutBodyIsQuiet() async throws {
            let handler = CapturingLogHandler()
            let (transport, key) = makeTransport(logger: Logger(label: "mcp.test.accepted") { _ in handler })
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let body = request.httpBodyStreamData().map { String(decoding: $0, as: UTF8.self) } ?? ""
                let accepted = body.contains("initialized") || body.contains("ping")
                let (status, fields) = accepted ? (202, [:]) : (200, ["Content-Type": "text/plain"])
                return (
                    HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!,
                    Data()
                )
            }
            try await transport.connect()
            // Streamable HTTP: a server that accepts a notification answers 202 with no body.
            try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            #expect(handler.messages.isEmpty)
            try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#.utf8))
            #expect(handler.messages == ["Unexpected content type: text/plain"])
            // A request is owed JSON or SSE: its 202 leaves it waiting.
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":"p1","method":"ping"}"#.utf8))
            #expect(handler.messages == ["Unexpected content type: text/plain", "Unexpected content type: "])
            await transport.disconnect()
        }

        @Test("A 401 on a POST gives the authorizer the Authorization the POST carried", .timeLimit(.minutes(1)))
        func postChallengePassesSentAuthorization() async throws {
            let authorizer = ChallengeCountingAuthorizer()
            let (transport, key) = makeTransport(authorizer: authorizer)
            await IsolatedMockURLProtocol.setHandler(key: key) { [response] request in
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                    return sse("", status: 401, headers: ["WWW-Authenticate": #"Bearer error="invalid_token""#])
                }
                return sse("data: \(response)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            #expect(try await firstMessage(transport) == response)
            #expect(authorizer.sentAuthorizations == ["Bearer old"])
            await transport.disconnect()
        }

        @Test("A 405 to a POST does not stop the GET stream of the session that follows", .timeLimit(.minutes(1)))
        func postMethodNotAllowedKeepsGetStream() async throws {
            let (transport, key) = makeTransport(streaming: true, sseInitializationTimeout: 30)
            let requests = RecordedRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                if request.httpMethod == "GET" { return sse("id: g1\nretry: 10000\ndata: \n\n") }
                let body = request.httpBodyStreamData().map { String(decoding: $0, as: UTF8.self) } ?? ""
                if body.contains("server/discover") {
                    return (
                        HTTPURLResponse(url: endpoint, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: [:])!,
                        Data()
                    )
                }
                return (
                    HTTPURLResponse(
                        url: endpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json", "Mcp-Session-Id": "s1"])!,
                    Data(#"{"jsonrpc":"2.0","id":"i1","result":{}}"#.utf8)
                )
            }
            try await transport.connect()
            // A handshake-only server refusing the sessionless discovery.
            await #expect(throws: MCPError.self) {
                try await transport.send(Data(#"{"jsonrpc":"2.0","id":"d1","method":"server/discover"}"#.utf8))
            }
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":"i1","method":"initialize"}"#.utf8))
            #expect(await requests.receivesGET(within: .seconds(10)))
            #expect(await requests.gets.first?.value(forHTTPHeaderField: "Mcp-Session-Id") == "s1")
            await transport.disconnect()
        }

        @Test(
            "A 404 on the GET stream stops the stream, and the next request reports the expiry",
            .timeLimit(.minutes(1)))
        func getNotFoundExpiresSession() async throws {
            let (messages, sink) = AsyncStream<String>.makeStream()
            let logger = Logger(label: "mcp.test.reliability") { _ in StreamingLogHandler(sink: sink) }
            let (transport, key) = makeTransport(streaming: true, sseInitializationTimeout: 30, logger: logger)
            let requests = RecordedRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { [response] request in
                await requests.append(request)
                // The first GET ends at once; the server then forgets the session.
                let forgotten = await requests.gets.count >= 2
                if request.httpMethod == "POST" { return forgotten ? sse("", status: 404) : sse("data: \(response)\n\n") }
                return forgotten ? sse("", status: 404) : sse("id: g1\nretry: 10\ndata: \n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            await requests.waitFor(2, "GET")
            let logged = try await finishes(within: .seconds(5)) {
                for await message in messages where message.contains("SSE connection error") { return message }
                return ""
            }
            #expect(logged?.contains("isSessionExpired: true") == true)
            // Without the fix the GET is retried within about 20 ms.
            try await Task.sleep(for: .milliseconds(500))
            #expect(await requests.gets.count == 2)
            // The next request carries the session and reports its expiry.
            #expect(await transport.sessionID == "s1")
            do {
                try await transport.send(request)
                Issue.record("Expected the session to have expired")
            } catch MCPError.transportError(let status as HTTPStatusError) {
                #expect(status.isSessionExpired)
            }
            #expect(await requests.all.last?.value(forHTTPHeaderField: "Mcp-Session-Id") == "s1")
            #expect(await transport.sessionID == nil)
            await transport.disconnect()
        }

        @Test(
            "A CancellationError from the authorizer is thrown as is",
            .timeLimit(.minutes(1)),
            arguments: [
                ("validate", "POST"), ("headers", "POST"), ("challenge", "POST"),
                ("challenge", "stateless POST"), ("challenge", "resumption GET"),
            ])
        func authorizerCancellation(stage: String, path: String) async throws {
            let stages: [String: CancellingAuthorizer.Stage] = [
                "validate": .validate, "headers": .headers, "challenge": .challenge,
            ]
            let (transport, key) = makeTransport(authorizer: CancellingAuthorizer(stages[stage]!))
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                if path == "resumption GET", request.httpMethod == "POST" {
                    return sse("id: e1\nretry: 10\ndata: \n\n")
                }
                return sse("", status: 401, headers: ["WWW-Authenticate": #"Bearer error="invalid_token""#])
            }
            try await transport.connect()
            let message =
                path == "stateless POST"
                ? Data(
                    #"{"jsonrpc":"2.0","id":"r1","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
                        .utf8)
                : request
            await #expect(throws: CancellationError.self) { try await transport.send(message) }
            await transport.disconnect()
        }

        @Test("A 401 on a response stream's resumption GET goes to the authorizer")
        func resumptionHandlesChallenge() async throws {
            let authorizer = ChallengeCountingAuthorizer()
            let (transport, key) = makeTransport(authorizer: authorizer)
            await IsolatedMockURLProtocol.setHandler(key: key) { [response] request in
                if request.httpMethod == "POST" { return sse("id: e1\nretry: 10\ndata: \n\n") }
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                    return sse("", status: 401)
                }
                return sse("id: e2\ndata: \(response)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            #expect(try await firstMessage(transport) == response)
            #expect(authorizer.handledChallenges == [401])
            #expect(authorizer.sentAuthorizations == ["Bearer old"])
            await transport.disconnect()
        }
    }

    extension URLRequest {
        /// The body of a request, which URLProtocol sees as a stream.
        fileprivate func httpBodyStreamData() -> Data? {
            if let httpBody { return httpBody }
            guard let stream = httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

#endif

#if swift(>=6.1)
    @Suite("HTTP client listen requests")
    struct HTTPClientListenTimeoutTests {
        @Test("A subscriptions/listen POST has a long idle timeout; other POSTs keep the default")
        func listenTimeout() async throws {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            let endpoint = URL(string: "http://127.0.0.1:9/mcp")!
            let timeouts = TimeoutLog()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await timeouts.add(request.timeoutInterval)
                return (
                    HTTPURLResponse(url: endpoint, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!,
                    Data()
                )
            }
            let transport = HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: false)
            try await transport.connect()
            try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            try await transport.send(
                Data(#"{"jsonrpc":"2.0","id":1,"method":"subscriptions/listen","params":{"notifications":{}}}"#.utf8))
            #expect(await timeouts.values == [60, HTTPClientTransport.listenIdleTimeout])
            await transport.disconnect()
        }
    }

    private actor TimeoutLog {
        private(set) var values: [TimeInterval] = []
        func add(_ value: TimeInterval) { values.append(value) }
    }
#endif
