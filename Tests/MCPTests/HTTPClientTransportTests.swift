@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    // MARK: - Test trait

    /// A test trait that automatically manages the mock URL protocol handler for HTTP client transport tests.
    struct HTTPClientTransportTestSetupTrait: TestTrait, TestScoping {
        func provideScope(
            for test: Test, testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            // Clear handler before test
            await MockURLProtocol.requestHandlerStorage.clearHandler()

            // Execute the test
            try await function()

            // Clear handler after test
            await MockURLProtocol.requestHandlerStorage.clearHandler()
        }
    }

    extension Trait where Self == HTTPClientTransportTestSetupTrait {
        static var httpClientTransportSetup: Self { Self() }
    }

    // MARK: - Mock Handler Registry Actor

    actor RequestHandlerStorage {
        var requestHandler:
            (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
        private var callCounts: [URL: Int] = [:]

        func setHandler(
            _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) {
            requestHandler = handler
        }

        func clearHandler() {
            requestHandler = nil
            callCounts = [:]
        }

        func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            guard let handler = requestHandler else {
                throw NSError(
                    domain: "MockURLProtocolError", code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No request handler set"
                    ])
            }
            if let url = request.url {
                callCounts[url, default: 0] += 1
            }
            return try await handler(request)
        }

        func callCount(for url: URL) -> Int {
            callCounts[url, default: 0]
        }
    }

    // MARK: - Helper Methods

    extension URLRequest {
        fileprivate func readBody() -> Data? {
            if let httpBodyData = self.httpBody {
                return httpBodyData
            }

            guard let bodyStream = self.httpBodyStream else { return nil }
            bodyStream.open()
            defer { bodyStream.close() }

            let bufferSize: Int = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            var data = Data()
            while bodyStream.hasBytesAvailable {
                let bytesRead = bodyStream.read(buffer, maxLength: bufferSize)
                data.append(buffer, count: bytesRead)
            }
            return data
        }
    }

    // MARK: - Mock URL Protocol

    final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        static let requestHandlerStorage = RequestHandlerStorage()

        static func setHandler(
            _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async {
            await requestHandlerStorage.setHandler { request in
                try await handler(request)
            }
        }

        func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            return try await Self.requestHandlerStorage.executeHandler(for: request)
        }

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        /// Set by `stopLoading()`. swift-corelibs-foundation traps when a
        /// protocol calls its client for a task it already cancelled, so each
        /// callback checks it first. The lock is not held during a callback:
        /// corelibs can call `stopLoading()` from its work queue while a
        /// callback waits for that queue.
        private let stateLock = NSLock()
        private var stopped = false

        private var isStopped: Bool { stateLock.withLock { stopped } }

        override func startLoading() {
            let loader = SendableURLProtocol(self)
            Task { await loader.value.load() }
        }

        private func load() async {
            do {
                let (response, data) = try await executeHandler(for: request)
                guard !isStopped else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                guard !isStopped else { return }
                client?.urlProtocol(self, didLoad: data)
                guard !isStopped else { return }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !isStopped else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {
            stateLock.withLock { stopped = true }
        }

        static func verifyCallCounts(
            _ expected: [URL: Int],
            sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            for (url, expectedCount) in expected {
                let actual = await requestHandlerStorage.callCount(for: url)
                #expect(
                    actual == expectedCount,
                    "Expected \(expectedCount) call(s) to \(url.lastPathComponent), got \(actual)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }

    // MARK: -

    @Suite("HTTP Client Transport Tests", .serialized)
    struct HTTPClientTransportTests {
        let testEndpoint = URL(string: "https://localhost:8080/test")!

        @Test("Connect and Disconnect", .httpClientTransportSetup)
        func testConnectAndDisconnect() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )

            try await transport.connect()
            await transport.disconnect()
        }

        @Test("Send and Receive JSON Response", .httpClientTransportSetup)
        func testSendAndReceiveJSON() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let messageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!
            let responseData = #"{"jsonrpc":"2.0","result":{},"id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                #expect(request.url == testEndpoint)
                #expect(request.httpMethod == "POST")
                #expect(request.readBody() == messageData)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(
                    request.value(forHTTPHeaderField: "Accept")
                        == "application/json, text/event-stream"
                )

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, responseData)
            }

            try await transport.send(messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let receivedData = try await iterator.next()

            #expect(receivedData == responseData)
        }

        @Test("A request cancelled before its POST starts is not sent", .httpClientTransportSetup)
        func testCancelBeforeSend() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let transport = HTTPClientTransport(
                endpoint: testEndpoint, configuration: configuration, streaming: false, logger: nil)
            try await transport.connect()
            defer { Task { await transport.disconnect() } }

            await MockURLProtocol.requestHandlerStorage.setHandler { [testEndpoint] _ in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, Data(#"{"jsonrpc":"2.0","result":{},"id":7}"#.utf8))
            }
            let request = Data(#"{"jsonrpc":"2.0","method":"tools/list","id":7}"#.utf8)

            await transport.cancelRequest(.number(7))
            await #expect(throws: CancellationError.self) { try await transport.send(request) }
            #expect(await MockURLProtocol.requestHandlerStorage.callCount(for: testEndpoint) == 0)

            // The cancellation applies to one send only.
            try await transport.send(request)
            #expect(await MockURLProtocol.requestHandlerStorage.callCount(for: testEndpoint) == 1)
        }

        @Test("Send and Receive Session ID", .httpClientTransportSetup)
        func testSendAndReceiveSessionID() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let messageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!
            let newSessionID = "session-12345"

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == nil)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": newSessionID,
                    ])!
                return (response, Data())
            }

            try await transport.send(messageData)

            let storedSessionID = await transport.sessionID
            #expect(storedSessionID == newSessionID)
        }

        @Test("Send With Existing Session ID", .httpClientTransportSetup)
        func testSendWithExistingSessionID() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let initialSessionID = "existing-session-abc"
            let firstMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(
                using: .utf8)!
            let secondMessageData = #"{"jsonrpc":"2.0","method":"ping","id":2}"#.data(
                using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                #expect(request.readBody() == firstMessageData)
                #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == nil)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": initialSessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(firstMessageData)
            #expect(await transport.sessionID == initialSessionID)

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                #expect(request.readBody() == secondMessageData)
                #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == initialSessionID)

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, Data())
            }
            try await transport.send(secondMessageData)

            #expect(await transport.sessionID == initialSessionID)
        }

        @Test("HTTP 404 Not Found Error", .httpClientTransportSetup)
        func testHTTPNotFoundError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":3}"#.data(using: .utf8)!

            // Set up the handler BEFORE creating the transport
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Not Found".utf8))
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            do {
                try await transport.send(messageData)
                Issue.record("Expected send to throw an error for 404")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let message: String? = underlying.localizedDescription
                #expect(message?.contains("Endpoint not found") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("HTTP 500 Server Error", .httpClientTransportSetup)
        func testHTTPServerError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":4}"#.data(using: .utf8)!

            // Set up the handler BEFORE creating the transport
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Server Error".utf8))
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            do {
                try await transport.send(messageData)
                Issue.record("Expected send to throw an error for 500")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let message: String? = underlying.localizedDescription
                #expect(message?.contains("Server error: 500") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("HTTP 400 Bad Request Error", .httpClientTransportSetup)
        func testHTTPBadRequestError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":40}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (_: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Bad Request".utf8))
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            do {
                try await transport.send(messageData)
                Issue.record("Expected send to throw an error for 400")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let message: String? = underlying.localizedDescription
                #expect(message?.contains("Bad request") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("HTTP 401 Unauthorized Error Without OAuth", .httpClientTransportSetup)
        func testHTTPUnauthorizedErrorWithoutOAuth() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":41}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (_: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "WWW-Authenticate": "Bearer scope=\"files:read\""
                    ])!
                return (response, Data())
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            do {
                try await transport.send(messageData)
                Issue.record("Expected send to throw an error for 401 without OAuth")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let message: String? = underlying.localizedDescription
                #expect((underlying as? HTTPStatusError)?.statusCode == 401)
                #expect((underlying as? HTTPStatusError)?.value(forHeader: "www-authenticate") == #"Bearer scope="files:read""#)
                #expect(message?.contains("Authentication required") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("HTTP 403 Forbidden Error Without OAuth", .httpClientTransportSetup)
        func testHTTPForbiddenErrorWithoutOAuth() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":42}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (_: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint,
                    statusCode: 403,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "WWW-Authenticate":
                            "Bearer error=\"insufficient_scope\", scope=\"files:write\""
                    ])!
                return (response, Data())
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            do {
                try await transport.send(messageData)
                Issue.record("Expected send to throw an error for 403 without OAuth")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let message: String? = underlying.localizedDescription
                #expect(message?.contains("Access forbidden") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("OAuth scope step-up retries after 403 insufficient_scope", .httpClientTransportSetup)
        func testOAuthStepUpRetryAfter403InsufficientScope() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let testEndpoint = URL(string: "https://localhost:8080/step-up")!
            let resourceMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-protected-resource/step-up")!
            let asMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
            let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
            let finalResponseData = #"{"jsonrpc":"2.0","result":{"ok":true},"id":43}"#.data(
                using: .utf8)!

            actor CallTracker {
                var tokenCalls = 0

                func nextTokenCall() -> Int {
                    tokenCalls += 1
                    return tokenCalls
                }
            }
            let tracker = CallTracker()

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [tracker, testEndpoint, resourceMetadataURL, asMetadataURL, tokenEndpointURL, finalResponseData] request in
                guard let url = request.url else {
                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Missing request URL"])
                }

                switch url {
                case testEndpoint:
                    switch request.value(forHTTPHeaderField: "Authorization") {
                    case nil:
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 401,
                            httpVersion: "HTTP/1.1",
                            headerFields: [
                                "WWW-Authenticate":
                                    "Bearer resource_metadata=\"\(resourceMetadataURL.absoluteString)\", scope=\"files:read\""
                            ])!
                        return (response, Data())

                    case "Bearer access-token-read":
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 403,
                            httpVersion: "HTTP/1.1",
                            headerFields: [
                                "WWW-Authenticate":
                                    "Bearer error=\"insufficient_scope\", scope=\"files:write\", resource_metadata=\"\(resourceMetadataURL.absoluteString)\", error_description=\"Additional file write permission required\""
                            ])!
                        return (response, Data())

                    case "Bearer access-token-read-write":
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, finalResponseData)

                    default:
                        throw NSError(
                            domain: "MockURLProtocolError",
                            code: 0,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Unexpected Authorization value: \(request.value(forHTTPHeaderField: "Authorization") ?? "<none>")"
                            ])
                    }

                case resourceMetadataURL:
                    let metadata =
                        #"{ "authorization_servers": ["https://localhost:8080/auth"], "scopes_supported": ["files:read","files:write"] }"#
                        .data(using: .utf8)!
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, metadata)

                case asMetadataURL:
                    let metadata = #"{ "issuer": "https://localhost:8080/auth", "token_endpoint": "https://localhost:8080/oauth/token" }"#
                        .data(using: .utf8)!
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, metadata)

                case tokenEndpointURL:
                    let tokenCall = await tracker.nextTokenCall()
                    let body = String(data: request.readBody() ?? Data(), encoding: .utf8) ?? ""
                    #expect(body.contains("grant_type=client_credentials"))
                    #expect(body.contains("client_id=test-client"))
                    #expect(body.contains("resource=https%3A%2F%2Flocalhost%3A8080%2Fstep-up"))

                    if tokenCall == 1 {
                        #expect(body.contains("scope=files%3Aread"))
                        let tokenResponse =
                            #"{ "access_token": "access-token-read", "token_type": "Bearer", "expires_in": 3600 }"#
                            .data(using: .utf8)!
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, tokenResponse)
                    }

                    #expect(tokenCall == 2)
                    #expect(body.contains("scope=files%3Aread%20files%3Awrite"))
                    let tokenResponse =
                        #"{ "access_token": "access-token-read-write", "token_type": "Bearer", "expires_in": 3600 }"#
                        .data(using: .utf8)!
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, tokenResponse)

                default:
                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected URL: \(url.absoluteString)"
                        ])
                }
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: .init(authentication: .none(clientID: "test-client"))),
                logger: nil
            )

            try await transport.connect()
            let messageData = #"{"jsonrpc":"2.0","method":"ping","id":43}"#.data(using: .utf8)!
            try await transport.send(messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == finalResponseData)
            #expect(await tracker.tokenCalls == 2)

            await transport.disconnect()
        }

        @Test("OAuth scope upgrade tracking is scoped per operation", .httpClientTransportSetup)
        func testOAuthScopeUpgradeTrackingPerOperation() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let testEndpoint = URL(string: "https://localhost:8080/operation-tracking")!
            let resourceMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-protected-resource/operation-tracking")!
            let asMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
            let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
            let finalResponseData = #"{"jsonrpc":"2.0","result":{"ok":true},"id":62}"#.data(
                using: .utf8)!

            actor CallTracker {
                var tokenCalls = 0
                var opAForbiddenCalls = 0
                var opBForbiddenCalls = 0

                func nextTokenCall() -> Int {
                    tokenCalls += 1
                    return tokenCalls
                }

                func incrementOpAForbiddenCalls() {
                    opAForbiddenCalls += 1
                }

                func incrementOpBForbiddenCalls() {
                    opBForbiddenCalls += 1
                }
            }
            let tracker = CallTracker()

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [tracker, testEndpoint, resourceMetadataURL, asMetadataURL, tokenEndpointURL, finalResponseData] request in
                guard let url = request.url else {
                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Missing request URL"])
                }

                switch url {
                case testEndpoint:
                    let body = String(data: request.readBody() ?? Data(), encoding: .utf8) ?? ""
                    let isOperationA = body.contains(#""method":"tools/callA""#)
                    let isOperationB = body.contains(#""method":"tools/callB""#)
                    let authorization = request.value(forHTTPHeaderField: "Authorization")

                    if authorization == nil {
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 401,
                            httpVersion: "HTTP/1.1",
                            headerFields: [
                                "WWW-Authenticate":
                                    "Bearer resource_metadata=\"\(resourceMetadataURL.absoluteString)\", scope=\"files:read\""
                            ])!
                        return (response, Data())
                    }

                    if isOperationA {
                        if authorization == "Bearer access-token-read"
                            || authorization == "Bearer access-token-read-write"
                        {
                            await tracker.incrementOpAForbiddenCalls()
                            let response = HTTPURLResponse(
                                url: url,
                                statusCode: 403,
                                httpVersion: "HTTP/1.1",
                                headerFields: [
                                    "WWW-Authenticate":
                                        "Bearer error=\"insufficient_scope\", scope=\"files:write\", resource_metadata=\"\(resourceMetadataURL.absoluteString)\""
                                ])!
                            return (response, Data())
                        }

                        throw NSError(
                            domain: "MockURLProtocolError",
                            code: 0,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Unexpected Authorization for opA: \(authorization ?? "<none>")"
                            ])
                    }

                    if isOperationB {
                        if authorization == "Bearer access-token-read-write" {
                            await tracker.incrementOpBForbiddenCalls()
                            let response = HTTPURLResponse(
                                url: url,
                                statusCode: 403,
                                httpVersion: "HTTP/1.1",
                                headerFields: [
                                    "WWW-Authenticate":
                                        "Bearer error=\"insufficient_scope\", scope=\"files:write\", resource_metadata=\"\(resourceMetadataURL.absoluteString)\""
                                ])!
                            return (response, Data())
                        }

                        if authorization == "Bearer access-token-opb" {
                            let response = HTTPURLResponse(
                                url: url,
                                statusCode: 200,
                                httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!
                            return (response, finalResponseData)
                        }

                        throw NSError(
                            domain: "MockURLProtocolError",
                            code: 0,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Unexpected Authorization for opB: \(authorization ?? "<none>")"
                            ])
                    }

                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected request body: \(body)"
                        ])

                case resourceMetadataURL:
                    let metadata =
                        #"{ "authorization_servers": ["https://localhost:8080/auth"], "scopes_supported": ["files:read","files:write"] }"#
                        .data(using: .utf8)!
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, metadata)

                case asMetadataURL:
                    let metadata = #"{ "issuer": "https://localhost:8080/auth", "token_endpoint": "https://localhost:8080/oauth/token" }"#
                        .data(using: .utf8)!
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, metadata)

                case tokenEndpointURL:
                    let tokenCall = await tracker.nextTokenCall()
                    let body = String(data: request.readBody() ?? Data(), encoding: .utf8) ?? ""
                    #expect(body.contains("grant_type=client_credentials"))
                    #expect(body.contains("client_id=test-client"))
                    #expect(
                        body.contains(
                            "resource=https%3A%2F%2Flocalhost%3A8080%2Foperation-tracking")
                    )

                    switch tokenCall {
                    case 1:
                        #expect(body.contains("scope=files%3Aread"))
                        let tokenResponse =
                            #"{ "access_token": "access-token-read", "token_type": "Bearer", "expires_in": 3600 }"#
                            .data(using: .utf8)!
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, tokenResponse)

                    case 2:
                        #expect(body.contains("scope=files%3Aread%20files%3Awrite"))
                        let tokenResponse =
                            #"{ "access_token": "access-token-read-write", "token_type": "Bearer", "expires_in": 3600 }"#
                            .data(using: .utf8)!
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, tokenResponse)

                    case 3:
                        #expect(body.contains("scope=files%3Aread%20files%3Awrite"))
                        let tokenResponse =
                            #"{ "access_token": "access-token-opb", "token_type": "Bearer", "expires_in": 3600 }"#
                            .data(using: .utf8)!
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, tokenResponse)

                    default:
                        throw NSError(
                            domain: "MockURLProtocolError",
                            code: 0,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Unexpected token call count: \(tokenCall)"
                            ])
                    }

                default:
                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected URL: \(url.absoluteString)"
                        ])
                }
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: .init(
                    authentication: .none(clientID: "test-client"),
                    retryPolicy: .init(maxAuthorizationAttempts: 8, maxScopeUpgradeAttempts: 1)
                )),
                logger: nil
            )

            try await transport.connect()

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            let operationAData = #"{"jsonrpc":"2.0","method":"tools/callA","id":61}"#.data(
                using: .utf8)!
            do {
                try await transport.send(operationAData)
                Issue.record("Expected operation A to fail after scope-upgrade retry limit")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let message: String? = underlying.localizedDescription
                #expect(message?.contains("Access forbidden") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            let operationBData = #"{"jsonrpc":"2.0","method":"tools/callB","id":62}"#.data(
                using: .utf8)!
            try await transport.send(operationBData)

            let received = try await iterator.next()
            #expect(received == finalResponseData)

            #expect(await tracker.tokenCalls == 3)
            #expect(await tracker.opAForbiddenCalls == 2)
            #expect(await tracker.opBForbiddenCalls == 1)

            await transport.disconnect()
        }

        @Test("Session Expired Error (404 with Session ID)", .httpClientTransportSetup)
        func testSessionExpiredError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let initialSessionID = "expired-session-xyz"
            let firstMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(
                using: .utf8)!
            let secondMessageData = #"{"jsonrpc":"2.0","method":"ping","id":2}"#.data(
                using: .utf8)!

            // Set up the first handler BEFORE creating the transport
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, initialSessionID] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": initialSessionID,
                    ])!
                return (response, Data())
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            try await transport.send(firstMessageData)
            #expect(await transport.sessionID == initialSessionID)

            // Set up the second handler for the 404 response
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, initialSessionID] (request: URLRequest) in
                #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == initialSessionID)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Not Found".utf8))
            }

            do {
                try await transport.send(secondMessageData)
                Issue.record("Expected send to throw session expired error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let message: String? = underlying.localizedDescription
                #expect((underlying as? HTTPStatusError)?.isSessionExpired == true)
                #expect(message?.contains("Session expired") ?? false)
                #expect(await transport.sessionID == nil)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("Receive Server-Sent Event (SSE)", .httpClientTransportSetup)
        func testReceiveSSE() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: true,
                sseInitializationTimeout: 1,
                logger: nil
            )

            let eventString = "id: event1\ndata: {\"key\":\"value\"}\n\n"
            let sseEventData = eventString.data(using: .utf8)!

            // First, set up a handler for the initial POST that will provide a session ID
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "text/plain",
                        "Mcp-Session-Id": "test-session-123",
                    ])!
                return (response, Data())
            }

            // Connect and send a dummy message to get the session ID
            try await transport.connect()
            try await transport.send(Data())

            // Now set up the handler for the SSE GET request
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sseEventData] (request: URLRequest) in  // sseEventData is now empty Data()
                #expect(request.url == testEndpoint)
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
                #expect(
                    request.value(forHTTPHeaderField: "MCP-Session-Id") == "test-session-123")

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"])!

                return (response, sseEventData)  // Will return empty Data for SSE
            }

            try await Task.sleep(for: .milliseconds(100))

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            let expectedData = #"{"key":"value"}"#.data(using: .utf8)!
            let receivedData = try await iterator.next()

            #expect(receivedData == expectedData)

            await transport.disconnect()
        }

        @Test("Receive Server-Sent Event (SSE) (CR-NL)", .httpClientTransportSetup)
        func testReceiveSSE_CRNL() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: true,
                sseInitializationTimeout: 1,
                logger: nil
            )

            let eventString = "id: event1\r\ndata: {\"key\":\"value\"}\r\n\n"
            let sseEventData = eventString.data(using: .utf8)!

            // First, set up a handler for the initial POST that will provide a session ID
            // Use text/plain to prevent its (empty) body from being yielded to messageStream
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "text/plain",
                        "Mcp-Session-Id": "test-session-123",
                    ])!
                return (response, Data())
            }

            // Connect and send a dummy message to get the session ID
            try await transport.connect()
            try await transport.send(Data())

            // Now set up the handler for the SSE GET request
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sseEventData] (request: URLRequest) in
                #expect(request.url == testEndpoint)
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
                #expect(
                    request.value(forHTTPHeaderField: "MCP-Session-Id") == "test-session-123")

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"])!

                return (response, sseEventData)
            }

            try await Task.sleep(for: .milliseconds(100))

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            let expectedData = #"{"key":"value"}"#.data(using: .utf8)!
            let receivedData = try await iterator.next()

            #expect(receivedData == expectedData)

            await transport.disconnect()
        }

        @Test(
            "Client with HTTP Transport complete flow", .httpClientTransportSetup,
            .timeLimit(.minutes(1)))
        func testClientFlow() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )

            let client = Client(name: "TestClient", version: "1.0.0", configuration: .handshake)

            // Use an actor to track request sequence
            actor RequestTracker {
                enum RequestType {
                    case initialize
                    case callTool
                }

                private(set) var lastRequest: RequestType?

                func setRequest(_ type: RequestType) {
                    lastRequest = type
                }

                func getLastRequest() -> RequestType? {
                    return lastRequest
                }
            }

            let tracker = RequestTracker()

            // Setup mock responses
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, tracker] (request: URLRequest) in
                switch request.httpMethod {
                case "GET":
                    #expect(
                        request.allHTTPHeaderFields?["Accept"]?.contains("text/event-stream")
                            == true)
                case "POST":
                    #expect(
                        request.allHTTPHeaderFields?["Accept"]?.contains("application/json")
                            == true
                    )
                default:
                    Issue.record(
                        "Unsupported HTTP method \(String(describing: request.httpMethod))")
                }

                #expect(request.url == testEndpoint)

                let bodyData = request.readBody()

                guard let bodyData = bodyData,
                    let json = try JSONSerialization.jsonObject(with: bodyData)
                        as? [String: Any],
                    let method = json["method"] as? String
                else {
                    throw NSError(
                        domain: "MockURLProtocolError", code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid JSON-RPC message \(#file):\(#line)"
                        ])
                }

                if method == "initialize" {
                    await tracker.setRequest(.initialize)

                    let requestID = json["id"] as! String
                    let result = Initialize.Result(
                        protocolVersion: Version.latestHandshake,
                        capabilities: .init(tools: .init()),
                        serverInfo: .init(name: "Mock Server", version: "0.0.1"),
                        instructions: nil
                    )
                    let response = Initialize.response(id: .string(requestID), result: result)
                    let responseData = try JSONEncoder().encode(response)

                    let httpResponse = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (httpResponse, responseData)
                } else if method == "tools/call" {
                    // Verify initialize was called first
                    if let lastRequest = await tracker.getLastRequest(),
                        lastRequest != .initialize
                    {
                        #expect(Bool(false), "Initialize should be called before callTool")
                    }

                    await tracker.setRequest(.callTool)

                    let params = json["params"] as? [String: Any]
                    let toolName = params?["name"] as? String
                    #expect(toolName == "calculator")

                    let requestID = json["id"] as! String
                    let result = CallTool.Result(content: [.text(text: "42")])
                    let response = CallTool.response(id: .string(requestID), result: result)
                    let responseData = try JSONEncoder().encode(response)

                    let httpResponse = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (httpResponse, responseData)
                } else if method == "notifications/initialized" {
                    // Ignore initialized notifications
                    let httpResponse = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (httpResponse, Data())
                } else {
                    throw NSError(
                        domain: "MockURLProtocolError", code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected request method: \(method) \(#file):\(#line)"
                        ])
                }
            }

            // Step 1: Initialize client
            let initResult = try await client.connect(transport: transport)
            #expect(initResult.protocolVersion == Version.latestHandshake)
            #expect(initResult.capabilities.tools != nil)

            // Step 2: Call a tool
            let toolResult = try await client.callTool(name: "calculator")
            #expect(toolResult.content.count == 1)
            if case let .text(text, _, _) = toolResult.content[0] {
                #expect(text == "42")
            } else {
                #expect(Bool(false), "Expected text content")
            }

            // Step 3: Verify request sequence
            #expect(await tracker.getLastRequest() == .callTool)

            // Step 4: Disconnect
            await client.disconnect()
        }

        @Test("Request modifier functionality", .httpClientTransportSetup)
        func testRequestModifier() async throws {
            let testEndpoint = URL(string: "https://api.example.com/mcp")!
            let testToken = "test-bearer-token-12345"

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, testToken] (request: URLRequest) in
                // Verify the Authorization header was added by the requestModifier
                #expect(
                    request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testToken)")

                // Return a successful response
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, Data())
            }

            // Create transport with requestModifier that adds Authorization header
            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                requestModifier: { request in
                    var modifiedRequest = request
                    modifiedRequest.addValue(
                        "Bearer \(testToken)", forHTTPHeaderField: "Authorization")
                    return modifiedRequest
                },
                logger: nil
            )

            try await transport.connect()

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":5}"#.data(using: .utf8)!

            try await transport.send(messageData)
            await transport.disconnect()
        }

        @Test("OAuth client credentials performs discovery and retries after 401", .httpClientTransportSetup)
        func testOAuthClientCredentialsRetryAfter401() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthClientCredentialsRetryAfter401()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth scope selection falls back to scopes_supported when challenge scope is absent", .httpClientTransportSetup)
        func testOAuthScopeSelectionFallsBackToScopesSupportedWhenChallengeScopeMissing()
            async throws
        {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthScopeSelectionFallsBackToScopesSupported()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth omits scope parameter when challenge scope and scopes_supported are unavailable", .httpClientTransportSetup)
        func testOAuthScopeSelectionOmitsScopeWhenNoHintsAvailable() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthScopeOmittedWhenNoHints()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth includes canonical resource in both authorization and token requests", .httpClientTransportSetup)
        func testOAuthResourceParameterIncludedInAuthorizationAndTokenRequests() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthResourceParameterInAuthorizationAndToken()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth rejects authorization when AS metadata omits code_challenge_methods_supported",
            .httpClientTransportSetup
        )
        func testOAuthRejectsAuthorizationWithoutPKCEMetadata() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationWithoutPKCEMetadata()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth rejects authorization when AS metadata lacks PKCE S256 support",
            .httpClientTransportSetup
        )
        func testOAuthRejectsAuthorizationWithoutS256PKCE() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationWithoutS256PKCE()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth rejects authorization response redirect URI mismatch",
            .httpClientTransportSetup
        )
        func testOAuthRejectsAuthorizationResponseRedirectMismatch() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationResponseRedirectMismatch()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth rejects authorization response state mismatch",
            .httpClientTransportSetup
        )
        func testOAuthRejectsAuthorizationResponseStateMismatch() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationResponseStateMismatch()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth sends access token only via Authorization header", .httpClientTransportSetup)
        func testOAuthDoesNotSendAccessTokenInBodyOrQuery() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthAccessTokenOnlyViaAuthorizationHeader()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth sends Bearer Authorization header on every request in a logical session", .httpClientTransportSetup)
        func testOAuthUsesAuthorizationHeaderForEveryRequestInSession() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthAuthorizationHeaderForEveryRequestInSession()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            try await transport.send(scenario.messageData)
            let receivedFirst = try await iterator.next()
            #expect(receivedFirst == scenario.expectedResponseData)

            try await transport.send(scenario.secondMessageData!)
            let receivedSecond = try await iterator.next()
            #expect(receivedSecond == scenario.secondExpectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth streaming GET requests use Authorization header and not query token", .httpClientTransportSetup)
        func testOAuthStreamingGETUsesAuthorizationHeaderOnly() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthStreamingGETUsesAuthorizationHeaderOnly()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                sseInitializationTimeout: scenario.sseInitializationTimeout!,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await transport.disconnect()
        }

        @Test("OAuth rejects non-Bearer token_type for MCP resource requests", .httpClientTransportSetup)
        func testOAuthRejectsNonBearerTokenType() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsNonBearerTokenType()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(underlying as? OAuthAuthorizationError == .tokenResponseInvalid)
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth token endpoint failures redact raw response body", .httpClientTransportSetup)
        func testOAuthTokenEndpointFailureRedactsResponseBody() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthTokenEndpointFailureRedactsResponseBody()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth rejects non-HTTPS token endpoint from AS metadata", .httpClientTransportSetup)
        func testOAuthRejectsNonHTTPSTokenEndpoint() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsNonHTTPSTokenEndpoint()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth allows loopback http authorization server endpoints when explicitly enabled",
            .httpClientTransportSetup
        )
        func testOAuthAllowsLoopbackHTTPAuthorizationServerEndpointsWhenEnabled() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthAllowsLoopbackHTTPAuthorizationServerEndpoints()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)
            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth accessTokenProvider receives SDK discovery context", .httpClientTransportSetup)
        func testOAuthAccessTokenProviderReceivesDiscoveryContext() async throws {
            let (scenario, providerTracker) = await MockURLProtocol.requestHandlerStorage
                .configureOAuthAccessTokenProviderReceivesDiscoveryContext()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            let capturedContext = await providerTracker.capturedContext
            #expect(capturedContext != nil)
            #expect(capturedContext?.statusCode == 401)
            #expect(capturedContext?.endpoint == scenario.testEndpoint)
            #expect(capturedContext?.resource == scenario.testEndpoint)
            #expect(capturedContext?.authorizationServer == URL(string: "https://localhost:8080/auth"))
            #expect(capturedContext?.tokenEndpoint == URL(string: "https://localhost:8080/oauth/token"))
            #expect(capturedContext?.challengedScope == "files:read files:write")
            #expect(Set(capturedContext?.scopesSupported ?? []) == Set(["files:read", "files:write"]))
            #expect(capturedContext?.requestedScopes == Set(["files:read", "files:write"]))

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth discovery uses resource_metadata URL from WWW-Authenticate when present", .httpClientTransportSetup)
        func testOAuthDiscoveryUsesHeaderResourceMetadataWhenPresent() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthDiscoveryUsesHeaderResourceMetadata()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth discovery falls back to well-known metadata URLs in required order", .httpClientTransportSetup)
        func testOAuthDiscoveryFallbackWellKnownOrder() async throws {
            let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
                .configureOAuthDiscoveryFallbackWellKnownOrder()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            let metadataRequests = await tracker.requests
            let fallbackPathMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
            let fallbackRootMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-protected-resource")!
            #expect(metadataRequests == [fallbackPathMetadataURL, fallbackRootMetadataURL])

            await transport.disconnect()
        }

        @Test("Without any metadata, OAuth falls back to the server root endpoints (2025-03-26)", .httpClientTransportSetup)
        func testOAuthDiscoveryFailsWhenMetadataUnavailable() async throws {
            let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
                .configureOAuthDiscoveryFailsWhenMetadataUnavailable()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to fail when PRM discovery fails")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            let requests = await tracker.requests
            let fallbackPathMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
            let fallbackRootMetadataURL = URL(
                string: "https://localhost:8080/.well-known/oauth-protected-resource")!
            #expect(Array(requests.prefix(2)) == [fallbackPathMetadataURL, fallbackRootMetadataURL])
            // No metadata anywhere: registration goes to the server root.
            #expect(requests.last == URL(string: "https://localhost:8080/register")!)

            await transport.disconnect()
        }

        @Test("OAuth authorization server metadata discovery tries path issuer URLs in RFC order", .httpClientTransportSetup)
        func testOAuthAuthorizationServerMetadataDiscoveryOrderForPathIssuer() async throws {
            let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
                .configureOAuthASMetadataDiscoveryOrderForPathIssuer()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            let requests = await tracker.requests
            let asMetadataOAuthInsertedURL = URL(
                string: "https://localhost:8080/.well-known/oauth-authorization-server/tenant1")!
            let asMetadataOIDCInsertedURL = URL(
                string: "https://localhost:8080/.well-known/openid-configuration/tenant1")!
            let asMetadataOIDCAppendedURL = URL(
                string: "https://localhost:8080/tenant1/.well-known/openid-configuration")!
            #expect(requests == [asMetadataOAuthInsertedURL, asMetadataOIDCInsertedURL, asMetadataOIDCAppendedURL])

            await transport.disconnect()
        }

        @Test("OAuth authorization server metadata discovery tries root issuer URLs in RFC order", .httpClientTransportSetup)
        func testOAuthAuthorizationServerMetadataDiscoveryOrderForRootIssuer() async throws {
            let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
                .configureOAuthASMetadataDiscoveryOrderForRootIssuer()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            let requests = await tracker.requests
            let asMetadataOAuthURL = URL(
                string: "https://localhost:8080/.well-known/oauth-authorization-server")!
            let asMetadataOIDCURL = URL(
                string: "https://localhost:8080/.well-known/openid-configuration")!
            #expect(requests == [asMetadataOAuthURL, asMetadataOIDCURL])

            await transport.disconnect()
        }

        @Test("OAuth registration prefers CIMD when AS advertises support", .httpClientTransportSetup)
        func testOAuthRegistrationPrefersCIMDWhenAdvertised() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthRegistrationPrefersCIMDWhenAdvertised()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth pre-registration uses static client credentials without dynamic registration", .httpClientTransportSetup)
        func testOAuthPreRegistrationUsesStaticCredentialsWithoutDynamicRegistration() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthPreRegistrationUsesStaticCredentials()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth registration falls back to dynamic registration when CIMD is not advertised", .httpClientTransportSetup)
        func testOAuthRegistrationFallsBackToDynamicRegistrationWhenCIMDNotAdvertised() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthRegistrationFallsBackToDynamicRegistrationCIMDNotAdvertised()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth registration falls back to dynamic registration when CIMD capability is absent", .httpClientTransportSetup)
        func testOAuthRegistrationFallsBackToDynamicRegistrationWhenCIMDCapabilityMissing() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthRegistrationFallsBackToDynamicRegistrationCIMDCapabilityMissing()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth registration surfaces actionable error when no supported mechanism is available", .httpClientTransportSetup)
        func testOAuthRegistrationMissingMechanismReturnsActionableError() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthRegistrationMissingMechanismReturnsActionableError()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth CIMD rejects non-HTTPS client_id URL when AS advertises support", .httpClientTransportSetup)
        func testOAuthCIMDRejectsNonHTTPSClientIDURL() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthCIMDRejectsNonHTTPSClientIDURL()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth rejects insecure MCP endpoint URL", .httpClientTransportSetup)
        func testOAuthRejectsInsecureMCPEndpointURL() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthRejectsInsecureMCPEndpointURL()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth rejects non-loopback http redirect URI", .httpClientTransportSetup)
        func testOAuthRejectsNonLoopbackHTTPRedirectURI() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthRejectsNonLoopbackHTTPRedirectURI()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            do {
                try await transport.send(scenario.messageData)
                Issue.record("Expected send to throw an error")
            } catch let error as MCPError {
                guard case .transportError(let underlying) = error else {
                    Issue.record("Expected MCPError.transportError, got \(error)")
                    throw error
                }
                let detail: String? = underlying.localizedDescription
                #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                for unexpected in scenario.unexpectedErrorSubstrings {
                    #expect(detail?.contains(unexpected) == false)
                }
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("OAuth PRM cache is invalidated when resource_metadata URL changes between challenges", .httpClientTransportSetup)
        func testOAuthPRMCacheInvalidatedOnResourceMetadataURLChange() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthPRMCacheInvalidatedOnResourceMetadataURLChange()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            try await transport.send(scenario.messageData)
            let receivedFirst = try await iterator.next()
            #expect(receivedFirst == scenario.expectedResponseData)

            try await transport.send(scenario.secondMessageData!)
            let receivedSecond = try await iterator.next()
            #expect(receivedSecond == scenario.secondExpectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth token request uses PRM resource field as resource indicator",
            .httpClientTransportSetup)
        func testOAuthResourceUsesPRMResourceField() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthResourceUsesPRMResourceField()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth tries second authorization server when first returns no metadata",
            .httpClientTransportSetup)
        func testOAuthSecondAuthorizationServerTriedWhenFirstFails() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthSecondAuthorizationServerTriedWhenFirstFails()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth re-registers client after client_secret_expires_at has passed",
            .httpClientTransportSetup)
        func testOAuthReRegistersAfterClientSecretExpiry() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthReRegistersAfterClientSecretExpiry()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            try await transport.send(scenario.messageData)
            let receivedFirst = try await iterator.next()
            #expect(receivedFirst == scenario.expectedResponseData)

            try await transport.send(scenario.secondMessageData!)
            let receivedSecond = try await iterator.next()
            #expect(receivedSecond == scenario.secondExpectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth skips AS metadata with wrong issuer and uses next URL variant",
            .httpClientTransportSetup)
        func testOAuthIssuerMismatchTriesNextURLVariant() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthIssuerMismatchTriesNextURLVariant()

            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: scenario.streaming,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
                logger: nil
            )

            try await transport.connect()
            try await transport.send(scenario.messageData)

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            #expect(received == scenario.expectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test(
            "OAuth proactively refreshes token when within proactive refresh window",
            .httpClientTransportSetup)
        func testOAuthProactiveTokenRefreshWithinWindow() async throws {
            let scenario = await MockURLProtocol.requestHandlerStorage
                .configureOAuthProactiveTokenRefreshWithinWindow()

            let storage = InMemoryTokenStorage()
            let transport = HTTPClientTransport(
                endpoint: scenario.testEndpoint,
                configuration: MockResponses.ephemeralConfiguration(),
                streaming: false,
                authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration, tokenStorage: storage),
                logger: nil
            )

            try await transport.connect()

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            try await transport.send(scenario.messageData)
            let receivedFirst = try await iterator.next()
            #expect(receivedFirst == scenario.expectedResponseData)

            // 200 s later the 300 s token is within its renewal window.
            let token = try #require(storage.load())
            storage.save(
                OAuthAccessToken(
                    value: token.value, tokenType: token.tokenType, expiresAt: Date().addingTimeInterval(100),
                    scopes: token.scopes, authorizationServer: token.authorizationServer,
                    refreshToken: token.refreshToken, clientID: token.clientID))

            try await transport.send(scenario.secondMessageData!)
            let receivedSecond = try await iterator.next()
            #expect(receivedSecond == scenario.secondExpectedResponseData)

            await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
            await transport.disconnect()
        }

        @Test("Send With Protocol Version Header", .httpClientTransportSetup)
        func testProtocolVersionHeader() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let protocolVersion = "2025-11-25"
            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                protocolVersion: protocolVersion,
                logger: nil
            )
            try await transport.connect()

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":6}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, protocolVersion] (request: URLRequest) in
                // Verify the protocol version header is present
                #expect(
                    request.value(forHTTPHeaderField: "MCP-Protocol-Version")
                        == protocolVersion)

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, Data())
            }

            try await transport.send(messageData)
            await transport.disconnect()
        }
    }

    /// Opens once; every wait returns after that.
    actor AuthorizerGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    /// An authorizer that suspends in `prepareAuthorization` or in
    /// `handleChallenge` until its gate opens, as one refreshing a token does.
    final class SuspendingAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        enum Stage { case prepare, challenge }

        let maxAuthorizationAttempts = 3
        let stage: Stage
        let gate = AuthorizerGate()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()

        init(suspendingIn stage: Stage) { self.stage = stage }

        func validateEndpointSecurity(for endpoint: URL) throws {}
        func authorizationHeaders(for url: URL, method: String) throws -> [String: String] {
            ["Authorization": "Bearer t"]
        }
        func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
            guard stage == .prepare else { return }
            enteredContinuation.yield()
            await gate.wait()
        }
        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            guard stage == .challenge else { return false }
            enteredContinuation.yield()
            await gate.wait()
            return true
        }
    }

    /// Never answers and never calls its client.
    private final class SilentURLProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    /// Reports two responses for one request, each with half of a JSON-RPC
    /// response that is valid only when the halves are joined.
    private final class TwoResponsesURLProtocol: URLProtocol, @unchecked Sendable {
        /// Set by `stopLoading()`, as in `IsolatedMockURLProtocol`: the
        /// client cancels the task at the second response, and corelibs traps
        /// on a call for a cancelled task.
        private let stateLock = NSLock()
        private var stopped = false
        private var isStopped: Bool { stateLock.withLock { stopped } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"jsonrpc":"2.0","#.utf8))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard !isStopped else { return }
            client?.urlProtocol(self, didLoad: Data(#""id":"r1","result":{}}"#.utf8))
            guard !isStopped else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { stateLock.withLock { stopped = true } }
    }

    /// Answers a request with the first half of a JSON-RPC response and keeps
    /// the body open; it never calls its client again.
    private final class PartialBodyURLProtocol: URLProtocol, @unchecked Sendable {
        /// Yields once a POST's partial body has been sent.
        static let (postBodyStarted, postBodyStartedContinuation) = AsyncStream<Void>.makeStream()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"jsonrpc":"2.0","id":"r1","#.utf8))
            if request.httpMethod == "POST" { Self.postBodyStartedContinuation.yield() }
        }
        override func stopLoading() {}
    }

    @Suite("HTTP client transport sessions")
    struct HTTPClientTransportSessionTests {
        let endpoint = URL(string: "http://127.0.0.1:9/mcp")!
        let request = Data(#"{"jsonrpc":"2.0","id":"r1","method":"tools/list"}"#.utf8)

        func makeTransport(
            authorizer: (any HTTPClientAuthorizer)? = nil,
            _ handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async -> HTTPClientTransport {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            await IsolatedMockURLProtocol.setHandler(key: key, handler)
            return HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false, authorizer: authorizer)
        }

        func reply(_ status: Int) -> (HTTPURLResponse, Data) {
            (HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }

        @Test(
            "A request whose authorizer is awaited across disconnect() fails instead of trapping",
            arguments: [SuspendingAuthorizer.Stage.prepare, .challenge])
        func disconnectDuringAuthorization(stage: SuspendingAuthorizer.Stage) async throws {
            let authorizer = SuspendingAuthorizer(suspendingIn: stage)
            let transport = await makeTransport(authorizer: authorizer) { [self] _ in
                reply(stage == .challenge ? 401 : 202)
            }
            try await transport.connect()
            let send = Task { [request] in try await transport.send(request) }
            for await _ in authorizer.entered { break }
            await transport.disconnect()
            await authorizer.gate.open()
            let result = await outcome(within: .seconds(5)) { try await send.value }
            #expect(result.error is MCPError)
        }

        @Test("connect() after disconnect() throws instead of losing messages")
        func reconnect() async throws {
            let transport = await makeTransport { [self] _ in reply(202) }
            let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
            try await transport.connect()
            try await transport.send(notification)
            await transport.disconnect()
            await #expect(throws: MCPError.self) { try await transport.connect() }
        }

        @Test("disconnect() ends a notification's POST that waits for its response")
        func disconnectEndsNotificationPost() async throws {
            let gate = AuthorizerGate()
            let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
            let transport = await makeTransport { [self] _ in
                enteredContinuation.yield()
                await gate.wait()
                return reply(202)
            }
            let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
            try await transport.connect()
            let send = Task { try await transport.send(notification) }
            for await _ in entered { break }
            await transport.disconnect()
            let result = await outcome(within: .seconds(5)) { try await send.value }
            await gate.open()
            #expect(result.error != nil)
        }

        @Test("A response body requested from a cancelled task fails promptly")
        func cancelledBeforeStart() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SilentURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let streaming = StreamingSession(configuration: configuration)
            defer { streaming.invalidate(along: session) }
            let task = Task { [endpoint] in
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await session.responseBody(for: URLRequest(url: endpoint), streaming: streaming)
            }
            let result = await outcome(within: .seconds(2)) { try await task.value }
            #expect(result.error != nil)
        }

        @Test("A response body read from a task cancelled while it arrives throws instead of ending early")
        func cancelledDuringBody() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PartialBodyURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let streaming = StreamingSession(configuration: configuration)
            defer { streaming.invalidate(along: session) }
            let (responded, respondedContinuation) = AsyncStream<Void>.makeStream()
            let read = Task { [endpoint] in
                let (body, _) = try await session.responseBody(for: URLRequest(url: endpoint), streaming: streaming)
                respondedContinuation.yield()
                return try await body.collect()
            }
            for await _ in responded { break }
            read.cancel()
            let result = await outcome(within: .seconds(5)) { try await read.value }
            #if canImport(FoundationNetworking)
                #expect(result.error is CancellationError)
            #else
                // `URLSession.AsyncBytes` throws its own error.
                #expect(result.error != nil, "\(result)")
            #endif
        }

        @Test("A request cancelled while its JSON response arrives delivers no part of it")
        func cancelledDuringJSONResponse() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PartialBodyURLProtocol.self]
            let transport = HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: false)
            try await transport.connect()
            let send = Task { [request] in try await transport.send(request) }
            for await _ in PartialBodyURLProtocol.postBodyStarted { break }
            send.cancel()
            let result = await outcome(within: .seconds(5)) { try await send.value }
            #expect(result.error != nil)
            await transport.disconnect()
            var delivered: [String] = []
            for try await data in await transport.receive() { delivered.append(String(decoding: data, as: UTF8.self)) }
            #expect(delivered.isEmpty)
        }

        #if canImport(FoundationNetworking)
            @Test("A second response for one request fails it instead of joining the bodies")
            func secondResponse() async throws {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [TwoResponsesURLProtocol.self]
                let transport = HTTPClientTransport(
                    endpoint: endpoint, configuration: configuration, streaming: false)
                try await transport.connect()
                let result = await outcome(within: .seconds(5)) { [request] in try await transport.send(request) }
                #expect(result.error != nil)
                await transport.disconnect()
            }

            @Test("A transport dropped without disconnect() releases its streaming session")
            func droppedTransportReleasesSession() async throws {
                weak var delegate: StreamingSessionDelegate?
                do {
                    let transport = await makeTransport { [endpoint] _ in
                        (
                            HTTPURLResponse(
                                url: endpoint, statusCode: 202, httpVersion: "HTTP/1.1",
                                headerFields: ["Mcp-Session-Id": "s1"])!, Data()
                        )
                    }
                    delegate = await transport.streamingSession.delegate
                    #expect(delegate != nil)
                    try await transport.connect()
                    try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
                }
                for _ in 0..<200 where delegate != nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(delegate == nil)
            }
        #endif
    }

    // A transport the application drops without calling disconnect() is
    // released, and its GET stream stops.

    /// One test's server: answers POSTs with `postStatus` and each GET as
    /// `getReply` says, and counts the GETs.
    private final class ReleaseTestServer: @unchecked Sendable {
        enum Reply {
            /// An empty reply with this status.
            case status(Int)
            /// A 200 SSE stream with this body, then the end of the stream.
            case events(String)
            /// A 200 SSE stream that stays open; ``write(_:)`` sends on it.
            case open
            /// No response: the GET waits for its headers until the client
            /// stops it. Counted as an open stream.
            case silent
        }

        let key = UUID().uuidString
        private let postStatus: Int
        private let getReply: @Sendable (Int) -> Reply
        private let lock = NSLock()
        private var gets = 0
        private var streams: [ObjectIdentifier: ReleaseTestProtocol] = [:]
        private var closed = 0

        init(postStatus: Int = 202, getReply: @escaping @Sendable (Int) -> Reply) {
            self.postStatus = postStatus
            self.getReply = getReply
            ReleaseTestProtocol.register(self)
        }

        var getCount: Int { lock.withLock { gets } }
        var openStreamCount: Int { lock.withLock { streams.count } }
        /// The open streams the client has closed.
        var closedStreamCount: Int { lock.withLock { closed } }

        func makeTransport(streaming: Bool, sseInitializationTimeout: TimeInterval = 10) -> HTTPClientTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReleaseTestProtocol.self]
            configuration.httpAdditionalHeaders = [ReleaseTestProtocol.keyHeader: key]
            return HTTPClientTransport(
                endpoint: URL(string: "http://127.0.0.1:9/mcp")!,
                session: URLSession(configuration: configuration),
                streaming: streaming,
                sseInitializationTimeout: sseInitializationTimeout)
        }

        /// Writes `text` on every open stream.
        func write(_ text: String) {
            let open = lock.withLock { Array(streams.values) }
            for stream in open { stream.write(Data(text.utf8)) }
        }

        fileprivate func start(_ loading: ReleaseTestProtocol) {
            guard loading.request.httpMethod == "GET" else {
                loading.reply(status: postStatus, contentType: "application/json", body: nil)
                return
            }
            let reply = lock.withLock { () -> Reply in
                gets += 1
                return getReply(gets)
            }
            switch reply {
            case .status(let status):
                loading.reply(status: status, contentType: "application/json", body: nil)
            case .events(let body):
                loading.reply(status: 200, contentType: "text/event-stream", body: Data(body.utf8))
            case .open:
                lock.withLock { streams[ObjectIdentifier(loading)] = loading }
                loading.reply(status: 200, contentType: "text/event-stream", body: nil, finish: false)
            case .silent:
                lock.withLock { streams[ObjectIdentifier(loading)] = loading }
            }
        }

        fileprivate func stopped(_ loading: ReleaseTestProtocol) {
            lock.withLock {
                if streams.removeValue(forKey: ObjectIdentifier(loading)) != nil { closed += 1 }
            }
        }
    }

    private final class ReleaseTestProtocol: URLProtocol, @unchecked Sendable {
        static let keyHeader = "X-Release-Test-Key"

        private final class Registry: @unchecked Sendable {
            let lock = NSLock()
            var servers: [String: ReleaseTestServer] = [:]
        }
        private static let registry = Registry()

        static func register(_ server: ReleaseTestServer) {
            registry.lock.withLock { registry.servers[server.key] = server }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        /// Set by `stopLoading()`: swift-corelibs-foundation traps when a
        /// protocol calls its client for a task it already cancelled. The lock
        /// is not held during a callback.
        private let stateLock = NSLock()
        private var stopped = false
        private var server: ReleaseTestServer?

        private var isStopped: Bool { stateLock.withLock { stopped } }

        override func startLoading() {
            let key = request.value(forHTTPHeaderField: Self.keyHeader) ?? ""
            guard let server = Self.registry.lock.withLock({ Self.registry.servers[key] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            stateLock.withLock { self.server = server }
            server.start(self)
        }

        override func stopLoading() {
            let server = stateLock.withLock { () -> ReleaseTestServer? in
                stopped = true
                return self.server
            }
            server?.stopped(self)
        }

        func reply(status: Int, contentType: String, body: Data?, finish: Bool = true) {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType])!
            guard !isStopped else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body { write(body) }
            guard finish, !isStopped else { return }
            client?.urlProtocolDidFinishLoading(self)
        }

        func write(_ data: Data) {
            guard !isStopped else { return }
            client?.urlProtocol(self, didLoad: data)
        }
    }

    /// Holds a transport weakly, to see when it is released.
    private final class WeakTransport: @unchecked Sendable {
        weak var transport: HTTPClientTransport?
        init(_ transport: HTTPClientTransport?) { self.transport = transport }

        /// Whether the transport is released within `limit`.
        func isReleased(within limit: Duration = .seconds(5)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + limit
            while clock.now < deadline {
                if transport == nil { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return transport == nil
        }
    }

    /// Whether `condition` holds within `limit`.
    private func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Suite("HTTP client transport release")
    struct HTTPClientTransportReleaseTests {
        @Test("A connected transport dropped without disconnect() is released and ends its message stream")
        func releasedWithoutStreaming() async throws {
            let server = ReleaseTestServer { _ in .status(405) }
            var transport: HTTPClientTransport? = server.makeTransport(streaming: false)
            try await transport?.connect()
            let messages = try #require(await transport?.receive())
            let reference = WeakTransport(transport)
            transport = nil

            #expect(await reference.isReleased())
            let ended = await outcome(within: .seconds(5)) {
                for try await _ in messages {}
            }
            #expect(!ended.didTimeOut)
            #expect(server.getCount == 0)
        }

        @Test("A transport waiting for a session ID is released, and sends no GET")
        func releasedWhileWaitingForSessionID() async throws {
            let server = ReleaseTestServer { _ in .status(405) }
            var transport: HTTPClientTransport? = server.makeTransport(
                streaming: true, sseInitializationTimeout: 0.3)
            try await transport?.connect()
            let reference = WeakTransport(transport)
            transport = nil

            #expect(await reference.isReleased())
            // Past the session ID timeout.
            try await Task.sleep(for: .milliseconds(600))
            #expect(server.getCount == 0)
        }

        @Test("A transport reading an open GET stream is released, closes the stream and sends no further GET")
        func releasedWithOpenStream() async throws {
            let server = ReleaseTestServer { _ in .open }
            var transport: HTTPClientTransport? = server.makeTransport(
                streaming: true, sseInitializationTimeout: 0.05)
            try await transport?.connect()
            let messages = try #require(await transport?.receive())
            #expect(await eventually { server.openStreamCount == 1 })

            // The stream is read: an event's message arrives.
            let notification = #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#
            server.write("data: \(notification)\n\n")
            let received = await outcome(within: .seconds(5)) { () -> Data? in
                var iterator = messages.makeAsyncIterator()
                return try await iterator.next()
            }
            guard case .returned(let message) = received else {
                Issue.record("No message from the GET stream: \(received)")
                await transport?.disconnect()
                return
            }
            #expect(message.map { String(decoding: $0, as: UTF8.self) } == notification)

            let reference = WeakTransport(transport)
            // No further event: the release itself closes the stream.
            transport = nil

            #expect(await reference.isReleased())
            #expect(await eventually { server.closedStreamCount == 1 })
            let gets = server.getCount
            try await Task.sleep(for: .milliseconds(500))
            #expect(server.getCount == gets)
            #expect(gets == 1)
        }

        @Test("A transport waiting to reconnect its GET stream is released and sends no further GET")
        func releasedDuringBackoff() async throws {
            // The first stream sets a short retry interval and ends; later GETs fail.
            let server = ReleaseTestServer { attempt in
                attempt == 1 ? .events("retry: 50\n\n") : .status(500)
            }
            var transport: HTTPClientTransport? = server.makeTransport(
                streaming: true, sseInitializationTimeout: 0.05)
            try await transport?.connect()
            #expect(await eventually { server.getCount >= 2 })

            let reference = WeakTransport(transport)
            transport = nil

            #expect(await reference.isReleased())
            let gets = server.getCount
            // Longer than the next waits of the backoff (50, 100 and 200 ms).
            try await Task.sleep(for: .milliseconds(700))
            #expect(server.getCount == gets)
        }

        @Test("A transport waiting for the headers of its GET stream is released and stops the GET")
        func releasedWhileAwaitingHeaders() async throws {
            let server = ReleaseTestServer { _ in .silent }
            var transport: HTTPClientTransport? = server.makeTransport(
                streaming: true, sseInitializationTimeout: 0.05)
            try await transport?.connect()
            #expect(await eventually { server.openStreamCount == 1 })

            let reference = WeakTransport(transport)
            transport = nil

            // Well within the request timeout (60 s), which would otherwise
            // end the wait.
            #expect(await reference.isReleased())
            #expect(await eventually { server.closedStreamCount == 1 })
            let gets = server.getCount
            try await Task.sleep(for: .milliseconds(300))
            #expect(server.getCount == gets)
            #expect(gets == 1)
        }

        @Test(
            "A client whose connect fails disconnects its transport and is released",
            arguments: [Client.Configuration.default, .handshake])
        func failedConnectReleasesTransport(configuration: Client.Configuration) async throws {
            let server = ReleaseTestServer(postStatus: 500) { _ in .open }
            var transport: HTTPClientTransport? = server.makeTransport(
                streaming: true, sseInitializationTimeout: 0.05)
            var client: Client? = Client(name: "test", version: "1.0", configuration: configuration)
            do {
                let connecting = try #require(transport)
                await #expect(throws: (any Swift.Error).self) {
                    try await client?.connect(transport: connecting)
                }
            }

            // The client is kept: it no longer holds the transport.
            let reference = WeakTransport(transport)
            transport = nil
            #expect(await reference.isReleased())
            #expect(await eventually { server.openStreamCount == 0 })

            weak var released: Client?
            released = client
            client = nil
            #expect(await eventually { released == nil })
        }
    }
#endif  // swift(>=6.1)
