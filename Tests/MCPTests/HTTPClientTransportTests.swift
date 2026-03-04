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

        override func startLoading() {
            Task {
                do {
                    let (response, data) = try await self.executeHandler(for: request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }

        override func stopLoading() {}

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
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
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
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
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
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
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
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
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
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
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
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
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
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
                #expect(message?.contains("Session expired") ?? false)
                #expect(await transport.sessionID == nil)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        // Skip SSE tests on platforms that don't support streaming
        #if !canImport(FoundationNetworking)
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

                let client = Client(name: "TestClient", version: "1.0.0")

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
                            protocolVersion: Version.latest,
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
                        let result = CallTool.Result(content: [.text(text: "42", annotations: nil, _meta: nil)])
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
                #expect(initResult.protocolVersion == Version.latest)
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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

            @Test("OAuth discovery fails when protected resource metadata is unavailable", .httpClientTransportSetup)
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
                    #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
                } catch {
                    Issue.record("Expected MCPError, got \(error)")
                    throw error
                }

                let protectedResourceMetadataRequests = await tracker.requests
                let fallbackPathMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let fallbackRootMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource")!
                #expect(protectedResourceMetadataRequests == [fallbackPathMetadataURL, fallbackRootMetadataURL])

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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
                    guard case .internalError(let detail) = error else {
                        Issue.record("Expected MCPError.internalError, got \(error)")
                        throw error
                    }
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
        #endif  // !canImport(FoundationNetworking)
    }
#endif  // swift(>=6.1)
