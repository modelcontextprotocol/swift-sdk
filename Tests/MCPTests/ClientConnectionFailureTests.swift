@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Error bodies on non-2xx replies, and how `.automatic` tells a server that
// serves only the handshake from a failure.

/// A transport that records sent methods, answers nothing by itself, and
/// fails sends of selected methods with a given error.
private actor ScriptedTransport: Transport {
    nonisolated let logger = Logger(label: "scripted", factory: { _ in SwiftLogNoOpLogHandler() })
    private var failures: [String: Swift.Error] = [:]
    private(set) var sent: [[String: Value]] = []
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func fail(_ method: String, with error: Swift.Error) { failures[method] = error }

    func connect() async throws {}
    func disconnect() async { continuation.finish() }
    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }

    func send(_ data: Data) async throws {
        let message = try JSONDecoder().decode(Value.self, from: data).objectValue ?? [:]
        sent.append(message)
        if let method = message["method"]?.stringValue, let error = failures[method] { throw error }
    }

    var methods: [String] { sent.compactMap { $0["method"]?.stringValue } }

    /// Waits until `count` messages were sent and returns the last one.
    func message(_ count: Int) async throws -> [String: Value] {
        for _ in 0..<400 where sent.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(sent.dropFirst(count - 1).first)
    }

    func reply(to message: [String: Value], _ body: String) throws {
        let id = try #require(message["id"])
        let idJSON = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        continuation.yield(Data(#"{"jsonrpc":"2.0","id":\#(idJSON),\#(body)}"#.utf8))
    }
}

private let initializeResult =
    #""result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"old","version":"0"}}"#

@Suite("Automatic connection failures")
struct AutomaticConnectionFailureTests {
    private func client(timeout: Duration? = .seconds(10), mode: Client.ProtocolMode = .automatic) -> Client {
        Client(
            name: "probe", version: "1.0",
            configuration: .init(protocolMode: mode, discoveryTimeout: timeout))
    }

    @Test("A transport error on server/discover is rethrown without initialize")
    func rethrowsTransportErrors() async throws {
        let transport = ScriptedTransport()
        await transport.fail("server/discover", with: MCPError.transportError(HTTPStatusError(statusCode: 429)))
        let client = client()
        await #expect {
            _ = try await client.connect(transport: transport)
        } throws: { error in
            guard case .transportError(let underlying) = error as? MCPError else { return false }
            return (underlying as? HTTPStatusError)?.statusCode == 429
        }
        #expect(await transport.methods == ["server/discover"])
        await client.disconnect()
    }

    @Test("An authorization failure on server/discover is rethrown")
    func rethrowsAuthorizationFailures() async throws {
        let transport = ScriptedTransport()
        await transport.fail("server/discover", with: MCPError.transportError(HTTPStatusError(statusCode: 401)))
        let client = client()
        await #expect(throws: MCPError.self) { _ = try await client.connect(transport: transport) }
        #expect(await transport.methods == ["server/discover"])
        await client.disconnect()
    }

    @Test(
        "An HTTP 400, 404 or 405 refusal falls back to initialize",
        arguments: [400, 404, 405])
    func fallsBackOnRefusal(status: Int) async throws {
        let transport = ScriptedTransport()
        await transport.fail("server/discover", with: MCPError.transportError(HTTPStatusError(statusCode: status)))
        let client = client()
        let connecting = Task { try await client.connect(transport: transport) }
        let initialize = try await transport.message(2)
        #expect(initialize["method"] == "initialize")
        try await transport.reply(to: initialize, initializeResult)
        #expect(try await connecting.value.serverInfo?.name == "old")
        await client.disconnect()
    }

    @Test("An unanswered server/discover falls back to initialize after the timeout")
    func fallsBackOnTimeout() async throws {
        let transport = ScriptedTransport()
        let client = client(timeout: .milliseconds(50))
        let connecting = Task { try await client.connect(transport: transport) }
        #expect(try await transport.message(1)["method"] == "server/discover")
        let initialize = try await transport.message(2)
        #expect(initialize["method"] == "initialize")
        try await transport.reply(to: initialize, initializeResult)
        #expect(try await connecting.value.serverInfo?.name == "old")
        #expect(await !client.isStateless)
        await client.disconnect()
    }

    @Test("A late answer to a timed-out server/discover is ignored")
    func ignoresLateAnswer() async throws {
        let transport = ScriptedTransport()
        let client = client(timeout: .milliseconds(50))
        let connecting = Task { try await client.connect(transport: transport) }
        let discover = try await transport.message(1)
        let initialize = try await transport.message(2)
        try await transport.reply(
            to: discover,
            #""result":{"supportedVersions":["2026-07-28"],"capabilities":{},"resultType":"complete"}"#)
        try await transport.reply(to: initialize, initializeResult)
        #expect(try await connecting.value.protocolVersion == Version.v2025_11_25)
        #expect(await !client.isStateless)
        await client.disconnect()
    }

    @Test("A failing initialize after discovery is not sent again")
    func failingInitializeIsNotRepeated() async throws {
        let transport = ScriptedTransport()
        let client = client()
        let connecting = Task { try await client.connect(transport: transport) }
        // Ends a connect that would wait for a second initialize answer.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(2))
            await client.disconnect()
        }
        defer { watchdog.cancel() }

        let discover = try await transport.message(1)
        try await transport.reply(
            to: discover,
            #""result":{"supportedVersions":["2025-11-25"],"capabilities":{},"resultType":"complete"}"#)
        let initialize = try await transport.message(2)
        #expect(initialize["method"] == "initialize")
        try await transport.reply(to: initialize, #""error":{"code":-32000,"message":"Refused"}"#)

        await #expect {
            _ = try await connecting.value
        } throws: { error in
            (error as? MCPError)?.code == -32000
        }
        #expect(await transport.methods == ["server/discover", "initialize"])
        await client.disconnect()
    }

    @Test("A pinned revision is not retried with another on -32022")
    func pinnedRevisionIsNotRetried() async throws {
        let transport = ScriptedTransport()
        let client = client(mode: .stateless(Version.v2026_07_28))
        let connecting = Task { try await client.connect(transport: transport) }
        let discover = try await transport.message(1)
        try await transport.reply(
            to: discover,
            #""error":{"code":-32022,"message":"Unsupported","data":{"supported":["2026-07-28"]}}"#)
        await #expect(throws: MCPError.self) { _ = try await connecting.value }
        #expect(await transport.methods == ["server/discover"])
        await client.disconnect()
    }

    @Test("A pinned revision the server does not list is not replaced")
    func pinnedRevisionIsNotReplaced() async throws {
        let transport = ScriptedTransport()
        let client = client(mode: .stateless("2027-01-01"))
        let connecting = Task { try await client.connect(transport: transport) }
        let discover = try await transport.message(1)
        try await transport.reply(
            to: discover,
            #""result":{"supportedVersions":["2026-07-28"],"capabilities":{},"resultType":"complete"}"#)
        await #expect {
            _ = try await connecting.value
        } throws: { error in
            guard case .unsupportedProtocolVersion(let supported, let requested) = error as? MCPError else {
                return false
            }
            return supported == ["2026-07-28"] && requested == "2027-01-01"
        }
        #expect(await !client.isStateless)
        await client.disconnect()
    }
}

@Suite("Client configuration coding")
struct ClientConfigurationCodingTests {
    @Test("A configuration encoded before protocol modes still decodes")
    func decodesOldConfiguration() throws {
        let configuration = try JSONDecoder().decode(
            Client.Configuration.self, from: Data(#"{"strict":true}"#.utf8))
        #expect(configuration.strict)
        #expect(configuration.protocolMode == .automatic)
        #expect(configuration.logLevel == nil)
        #expect(configuration.discoveryTimeout == .seconds(10))
    }

    @Test("A configuration round-trips, including a nil discovery timeout")
    func roundTrips() throws {
        for configuration in [
            Client.Configuration(protocolMode: .automatic, logLevel: .info, discoveryTimeout: nil),
            Client.Configuration(strict: true, protocolMode: .stateless("2026-07-28"), discoveryTimeout: .seconds(2)),
        ] {
            let data = try JSONEncoder().encode(configuration)
            #expect(try JSONDecoder().decode(Client.Configuration.self, from: data) == configuration)
        }
    }
}

@Suite("Outgoing message fields")
struct OutgoingMessageTests {
    @Test("A request's fields are read in one pass")
    func readsRequest() {
        let message = OutgoingMessage(
            Data(
                #"{"jsonrpc":"2.0","id":7,"method":" tools/call ","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
                    .utf8))
        #expect(message.requestID == "7")
        #expect(message.method == " tools/call ")
        #expect(message.operationKey == "tools/call")
        #expect(message.protocolVersion == "2026-07-28")
        #expect(message.cancelledRequestID == nil)
    }

    @Test("Responses, notifications and cancellations are not requests")
    func readsOthers() {
        let response = OutgoingMessage(Data(#"{"jsonrpc":"2.0","id":"a","result":{}}"#.utf8))
        #expect(response.requestID == nil)
        #expect(response.method == nil)
        let cancelled = OutgoingMessage(
            Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"r1"}}"#.utf8))
        #expect(cancelled.requestID == nil)
        #expect(cancelled.cancelledRequestID == "r1")
        let read = OutgoingMessage(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"file:///a","name":"x"}}"#.utf8))
        #expect(read.nameValue == "file:///a")
        let call = OutgoingMessage(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo"}}"#.utf8))
        #expect(call.nameValue == "echo")
        let batch = OutgoingMessage(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8))
        #expect(batch.requestID == nil)
    }
}

#if swift(>=6.1)
    @Suite("HTTP error bodies")
    struct HTTPErrorBodyTests {
        let endpoint = URL(string: "http://127.0.0.1:9/mcp")!
        let request = Data(#"{"jsonrpc":"2.0","id":"r1","method":"tools/call","params":{"name":"x"}}"#.utf8)

        func makeTransport(
            _ handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async -> HTTPClientTransport {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            await IsolatedMockURLProtocol.setHandler(key: key, handler)
            return HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: false)
        }

        func reply(_ status: Int, _ body: String, session: String? = nil) -> (HTTPURLResponse, Data) {
            var headers = ["Content-Type": "application/json"]
            headers["Mcp-Session-Id"] = session
            return (
                HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                Data(body.utf8)
            )
        }

        @Test("An error with another request's ID fails the request with the status")
        func foreignIDFails() async throws {
            let transport = await makeTransport { _ in
                reply(400, #"{"jsonrpc":"2.0","id":"server-error","error":{"code":-32600,"message":"Bad"}}"#)
            }
            try await transport.connect()
            await #expect {
                try await transport.send(request)
            } throws: { error in
                guard case .transportError(let underlying) = error as? MCPError else { return false }
                return (underlying as? HTTPStatusError)?.statusCode == 400
            }
            await transport.disconnect()
        }

        @Test("A result on a non-2xx reply is not delivered")
        func resultOnErrorStatusFails() async throws {
            let transport = await makeTransport { _ in
                reply(500, #"{"jsonrpc":"2.0","id":"r1","result":{"content":[]}}"#)
            }
            try await transport.connect()
            await #expect(throws: MCPError.self) { try await transport.send(request) }
            await transport.disconnect()
        }

        @Test("An error for the request is delivered")
        func matchingErrorIsDelivered() async throws {
            let body = #"{"jsonrpc":"2.0","id":"r1","error":{"code":-32602,"message":"Bad params"}}"#
            let transport = await makeTransport { _ in reply(400, body) }
            try await transport.connect()
            try await transport.send(request)
            var iterator = await transport.receive().makeAsyncIterator()
            #expect(try await iterator.next() == Data(body.utf8))
            await transport.disconnect()
        }

        @Test(
            "An error for the request on a 408, 429 or 5xx fails with the status",
            arguments: [408, 429, 500, 503])
        func unavailableStatusFails(status: Int) async throws {
            let transport = await makeTransport { _ in
                reply(status, #"{"jsonrpc":"2.0","id":"r1","error":{"code":-32000,"message":"Connection closed"}}"#)
            }
            try await transport.connect()
            await #expect {
                try await transport.send(request)
            } throws: { error in
                guard case .transportError(let underlying) = error as? MCPError else { return false }
                return (underlying as? HTTPStatusError)?.statusCode == status
            }
            await transport.disconnect()
        }

        @Test("A 503 with a JSON-RPC error on server/discover is rethrown without initialize")
        func unavailableDiscoverIsRethrown() async throws {
            actor Methods {
                private(set) var sent: [String] = []
                func append(_ method: String) { sent.append(method) }
            }
            let methods = Methods()
            let transport = await makeTransport { request in
                let message = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [String: Any] ?? [:]
                await methods.append(message["method"] as? String ?? "")
                let id = message["id"] as? String ?? ""
                return reply(
                    503, #"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":-32000,"message":"Connection closed"}}"#)
            }
            let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))

            await #expect {
                try await client.connect(transport: transport)
            } throws: { error in
                guard case .transportError(let underlying) = error as? MCPError else { return false }
                return (underlying as? HTTPStatusError)?.statusCode == 503
            }
            #expect(await methods.sent == [ServerDiscover.name])
            await client.disconnect()
        }

        static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }

        @Test("A notification's non-2xx reply fails with the status")
        func notificationErrorFails() async throws {
            let transport = await makeTransport { _ in
                reply(400, #"{"jsonrpc":"2.0","id":"r1","error":{"code":-32600,"message":"Bad"}}"#)
            }
            try await transport.connect()
            await #expect(throws: MCPError.self) {
                try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            }
            await transport.disconnect()
        }

        @Test("A 404 clears the session ID with or without an error body for the request")
        func notFoundClearsSession() async throws {
            for body in [
                #"{"jsonrpc":"2.0","id":"r1","error":{"code":-32001,"message":"Session not found"}}"#,
                #"{"jsonrpc":"2.0","id":"server-error","error":{"code":-32001,"message":"Session not found"}}"#,
            ] {
                let transport = await makeTransport { request in
                    if request.value(forHTTPHeaderField: "Mcp-Session-Id") == nil {
                        return reply(200, #"{"jsonrpc":"2.0","id":"r0","result":{}}"#, session: "s1")
                    }
                    return reply(404, body)
                }
                try await transport.connect()
                try await transport.send(Data(#"{"jsonrpc":"2.0","id":"r0","method":"ping"}"#.utf8))
                #expect(await transport.sessionID == "s1")
                try? await transport.send(request)
                #expect(await transport.sessionID == nil)
                await transport.disconnect()
            }
        }
    }
#endif

#if swift(>=6.1)
    /// Never answers `server/discover`, answers `initialize`, and records
    /// when the `server/discover` request is stopped.
    private final class UnansweredDiscoverProtocol: URLProtocol {
        actor State {
            private(set) var discoverStopped = false
            func stopped() { discoverStopped = true }
        }
        static let state = State()

        private var isDiscover = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let message = (try? JSONSerialization.jsonObject(with: body())) as? [String: Any] ?? [:]
            let method = message["method"] as? String
            isDiscover = method == ServerDiscover.name
            guard !isDiscover else { return }
            var status = 202
            var data = Data()
            if method == Initialize.name, let id = message["id"] as? String {
                status = 200
                data = Data(
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"old","version":"0"}}}"#
                        .utf8)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            guard isDiscover else { return }
            let state = Self.state
            Task { await state.stopped() }
        }

        private func body() -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    @Suite("Discovery timeout over HTTP", .timeLimit(.minutes(1)))
    struct DiscoveryTimeoutHTTPTests {
        @Test("A timed-out server/discover closes its POST")
        func closesTimedOutDiscover() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UnansweredDiscoverProtocol.self]
            let transport = HTTPClientTransport(
                endpoint: URL(string: "http://127.0.0.1:9/mcp")!, configuration: configuration,
                streaming: false)
            let client = Client(
                name: "probe", version: "1.0",
                configuration: .init(protocolMode: .automatic, discoveryTimeout: .milliseconds(100)))

            let result = try await client.connect(transport: transport)
            #expect(result.protocolVersion == Version.v2025_11_25)
            // A loaded machine (a simulator in CI) can take over a second.
            let deadline = ContinuousClock.now + .seconds(10)
            while await !UnansweredDiscoverProtocol.state.discoverStopped, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await UnansweredDiscoverProtocol.state.discoverStopped)
            await client.disconnect()
        }

        // A user who takes longer than `discoveryTimeout` to sign in must not
        // be asked to sign in again, nor be moved to the handshake.
        @Test("Signing in does not count against the discovery timeout")
        func signInOutlastsDiscoveryTimeout() async throws {
            let host = "\(UUID().uuidString).answering.test"
            let authorizer = SlowSignInAuthorizer(signIn: .seconds(2))
            let client = Client(
                name: "probe", version: "1.0",
                configuration: .init(protocolMode: .automatic, discoveryTimeout: .seconds(1)))

            let result = try await client.connect(
                transport: ChallengedDiscoverProtocol.transport(host: host, authorizer: authorizer))
            #expect(result.protocolVersion == Version.v2026_07_28)
            #expect(authorizer.challenges == 1)
            #expect(ChallengedDiscoverProtocol.state.methods(of: host) == [ServerDiscover.name])
            await client.disconnect()
        }

        @Test("The discovery timeout starts again after signing in")
        func timeoutAfterSignIn() async throws {
            let host = "\(UUID().uuidString).silent.test"
            let authorizer = SlowSignInAuthorizer(signIn: .seconds(2))
            let client = Client(
                name: "probe", version: "1.0",
                configuration: .init(protocolMode: .automatic, discoveryTimeout: .seconds(1)))

            // The server never answers the authorized server/discover.
            let result = try await client.connect(
                transport: ChallengedDiscoverProtocol.transport(host: host, authorizer: authorizer))
            #expect(result.protocolVersion == Version.v2025_11_25)
            #expect(authorizer.challenges == 1)
            await client.disconnect()
        }

        @Test("A sign-in that fails after the deadline fails connect without falling back to initialize")
        func failedSignInAfterDeadlineThrows() async throws {
            let host = "\(UUID().uuidString).answering.test"
            let authorizer = SlowSignInAuthorizer(signIn: .seconds(2), succeeds: false)
            let client = Client(
                name: "probe", version: "1.0",
                configuration: .init(protocolMode: .automatic, discoveryTimeout: .seconds(1)))

            await #expect(throws: (any Swift.Error).self) {
                try await client.connect(
                    transport: ChallengedDiscoverProtocol.transport(host: host, authorizer: authorizer))
            }
            #expect(authorizer.challenges == 1)
            #expect(ChallengedDiscoverProtocol.state.methods(of: host).isEmpty)
            await client.disconnect()
        }

        // The sign-in ignores cancellation, so only the discovery timer's
        // cancellation handler can end its wait.
        @Test("Cancelling connect during sign-in stops waiting promptly")
        func cancellingConnectDuringSignIn() async throws {
            let host = "\(UUID().uuidString).answering.test"
            let authorizer = SlowSignInAuthorizer(untilReleased: true)
            let transport = ChallengedDiscoverProtocol.transport(host: host, authorizer: authorizer)
            let client = Client(
                name: "probe", version: "1.0",
                configuration: .init(protocolMode: .automatic, discoveryTimeout: .seconds(1)))

            let connecting = Task { try await client.connect(transport: transport) }
            // The discovery timer passes its deadline and waits for the sign-in.
            var deadline = ContinuousClock.now + .seconds(10)
            while await transport.authorizationWaiterCount == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await transport.authorizationWaiterCount == 1)
            connecting.cancel()

            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    _ = try? await connecting.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(finished)
            deadline = ContinuousClock.now + .seconds(5)
            while await transport.authorizationWaiterCount > 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await transport.authorizationWaiterCount == 0)
            #expect(authorizer.signInsEnded == 0)
            authorizer.release()
            await client.disconnect()
        }
    }

    /// Signs in on a 401 after `signIn`, like a user at a browser, then
    /// authorizes every request when `succeeds` is `true`. With
    /// `untilReleased`, the sign-in ignores cancellation and lasts until
    /// ``release()``.
    private final class SlowSignInAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        private struct SignInDenied: LocalizedError {
            var errorDescription: String? { "User cancelled sign-in" }
        }

        private let lock = NSLock()
        private let signIn: Duration
        private let succeeds: Bool
        private let untilReleased: Bool
        private var signedIn = false
        private var challengeCount = 0
        private var endedCount = 0
        private var released = false
        private var pendingRelease: CheckedContinuation<Void, Never>?

        init(signIn: Duration = .zero, succeeds: Bool = true, untilReleased: Bool = false) {
            self.signIn = signIn
            self.succeeds = succeeds
            self.untilReleased = untilReleased
        }

        var challenges: Int { lock.withLock { challengeCount } }
        /// Sign-ins that returned or threw.
        var signInsEnded: Int { lock.withLock { endedCount } }
        var maxAuthorizationAttempts: Int { 2 }

        /// Ends a sign-in of `untilReleased`.
        func release() {
            let pending = lock.withLock {
                released = true
                defer { pendingRelease = nil }
                return pendingRelease
            }
            pending?.resume()
        }

        func validateEndpointSecurity(for endpoint: URL) throws {}

        func authorizationHeaders(for url: URL, method: String) throws -> [String: String] {
            lock.withLock { signedIn ? ["Authorization": "Bearer signed-in"] : [:] }
        }

        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            lock.withLock { challengeCount += 1 }
            defer { lock.withLock { endedCount += 1 } }
            if untilReleased {
                await withCheckedContinuation { continuation in
                    let now = lock.withLock {
                        if !released { pendingRelease = continuation }
                        return released
                    }
                    if now { continuation.resume() }
                }
            } else {
                try await Task.sleep(for: signIn)
            }
            guard succeeds else { throw SignInDenied() }
            lock.withLock { signedIn = true }
            return true
        }
    }

    /// Answers 401 to a request without credentials. With them, hosts ending
    /// in `.silent.test` never answer `server/discover`; others serve
    /// 2026-07-28, and all answer `initialize`.
    private final class ChallengedDiscoverProtocol: URLProtocol {
        final class State: @unchecked Sendable {
            private let lock = NSLock()
            private var authorized: [String: [String]] = [:]
            func record(_ method: String, host: String) { lock.withLock { authorized[host, default: []].append(method) } }
            /// The methods of authorized requests to `host`.
            func methods(of host: String) -> [String] { lock.withLock { authorized[host] ?? [] } }
        }
        static let state = State()

        static func transport(host: String, authorizer: any HTTPClientAuthorizer) -> HTTPClientTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChallengedDiscoverProtocol.self]
            return HTTPClientTransport(
                endpoint: URL(string: "http://\(host)/mcp")!, configuration: configuration, streaming: false,
                authorizer: authorizer)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let host = request.url?.host ?? ""
            guard request.value(forHTTPHeaderField: "Authorization") != nil else {
                return reply(401, headers: ["WWW-Authenticate": "Bearer"])
            }
            let message = (try? JSONSerialization.jsonObject(with: body())) as? [String: Any] ?? [:]
            let method = message["method"] as? String ?? ""
            let id = message["id"] as? String ?? ""
            Self.state.record(method, host: host)
            switch method {
            case ServerDiscover.name where host.hasSuffix(".silent.test"):
                return
            case ServerDiscover.name:
                reply(
                    200,
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"supportedVersions":["2026-07-28"],"capabilities":{},"resultType":"complete"}}"#
                )
            case Initialize.name:
                reply(
                    200,
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"old","version":"0"}}}"#
                )
            default:
                reply(202)
            }
        }

        override func stopLoading() {}

        private func reply(_ status: Int, _ body: String = "", headers: [String: String] = [:]) {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(headers) { $1 })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        private func body() -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }
#endif
