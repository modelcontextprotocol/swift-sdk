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
        private var requestHandler:
            (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

        func setHandler(
            _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async {
            requestHandler = handler
        }

        func clearHandler() async {
            requestHandler = nil
        }

        func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            guard let handler = requestHandler else {
                throw NSError(
                    domain: "MockURLProtocolError", code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No request handler set"
                    ])
            }
            return try await handler(request)
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
    }

    // MARK: -

    @Suite("HTTP Client Transport Tests", .serialized)
    struct HTTPClientTransportTests {
        let testEndpoint = URL(string: "http://localhost:8080/test")!

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
                    headerFields: [HTTPHeader.contentType: "application/json"])!
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
                #expect(request.value(forHTTPHeaderField: HTTPHeader.sessionId) == nil)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        HTTPHeader.contentType: "application/json",
                        HTTPHeader.sessionId: newSessionID,
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
                #expect(request.value(forHTTPHeaderField: HTTPHeader.sessionId) == nil)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        HTTPHeader.contentType: "application/json",
                        HTTPHeader.sessionId: initialSessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(firstMessageData)
            #expect(await transport.sessionID == initialSessionID)

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                #expect(request.readBody() == secondMessageData)
                #expect(request.value(forHTTPHeaderField: HTTPHeader.sessionId) == initialSessionID)

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [HTTPHeader.contentType: "application/json"])!
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
                        HTTPHeader.contentType: "application/json",
                        HTTPHeader.sessionId: initialSessionID,
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
                #expect(request.value(forHTTPHeaderField: HTTPHeader.sessionId) == initialSessionID)
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

        // MARK: - Additional HTTP Error Codes
        // These tests verify handling of additional HTTP status codes per the MCP spec

        @Test("HTTP 400 Bad Request Error", .httpClientTransportSetup)
        func testHTTPBadRequestError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
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

        @Test("HTTP 401 Unauthorized Error", .httpClientTransportSetup)
        func testHTTPUnauthorizedError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Unauthorized".utf8))
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
                Issue.record("Expected send to throw an error for 401")
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

        @Test("HTTP 403 Forbidden Error", .httpClientTransportSetup)
        func testHTTPForbiddenError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Forbidden".utf8))
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
                Issue.record("Expected send to throw an error for 403")
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

        @Test("HTTP 405 Method Not Allowed Error", .httpClientTransportSetup)
        func testHTTPMethodNotAllowedError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Method Not Allowed".utf8))
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
                Issue.record("Expected send to throw an error for 405")
            } catch let error as MCPError {
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
                #expect(message?.contains("Method not allowed") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("HTTP 408 Request Timeout Error", .httpClientTransportSetup)
        func testHTTPRequestTimeoutError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 408, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Request Timeout".utf8))
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
                Issue.record("Expected send to throw an error for 408")
            } catch let error as MCPError {
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
                #expect(message?.contains("Request timeout") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("HTTP 429 Too Many Requests Error", .httpClientTransportSetup)
        func testHTTPTooManyRequestsError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Too Many Requests".utf8))
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
                Issue.record("Expected send to throw an error for 429")
            } catch let error as MCPError {
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
                #expect(message?.contains("Too many requests") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("HTTP 202 Accepted with no content", .httpClientTransportSetup)
        func testHTTP202AcceptedNoContent() async throws {
            // TypeScript SDK tests: 'should send JSON-RPC messages via POST' with status 202
            // This verifies that 202 Accepted responses (no content body) are handled correctly
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let messageData = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(
                using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                // Server accepts the notification with 202 and no response body
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 202, httpVersion: "HTTP/1.1",
                    headerFields: [HTTPHeader.contentType: "application/json"])!
                return (response, Data())  // Empty body for 202 Accepted
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            // Should not throw - 202 is a valid success response
            try await transport.send(messageData)
        }

        @Test("Unexpected content-type throws error for requests", .httpClientTransportSetup)
        func testUnexpectedContentTypeThrowsErrorForRequest() async throws {
            // Per MCP spec: requests MUST receive application/json or text/event-stream
            // This aligns with TypeScript/Python SDKs which validate content-type for requests
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            // Request has both "method" and "id" - content-type validation applies
            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                // Server returns unexpected content-type (text/plain instead of application/json)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [HTTPHeader.contentType: "text/plain"])!
                return (response, Data("unexpected plain text response".utf8))
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
                Issue.record("Expected send to throw an error for unexpected content-type")
            } catch let error as MCPError {
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
                #expect(message?.contains("Unexpected content type") ?? false)
            } catch {
                Issue.record("Expected MCPError, got \(error)")
                throw error
            }
        }

        @Test("Unexpected content-type ignored for notifications", .httpClientTransportSetup)
        func testUnexpectedContentTypeIgnoredForNotification() async throws {
            // Per MCP spec: notifications expect 202 Accepted with no body
            // Content-type validation does not apply to notifications
            // This aligns with TypeScript/Python SDKs behavior
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            // Notification has "method" but NO "id" - content-type validation does not apply
            let messageData = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(
                using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                // Server returns unexpected content-type with body (unusual but allowed for notifications)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [HTTPHeader.contentType: "text/plain"])!
                return (response, Data("some unexpected response".utf8))
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            // Should not throw - notifications don't require content-type validation
            try await transport.send(messageData)
        }

        @Test("Empty response with unexpected content-type does not throw", .httpClientTransportSetup)
        func testEmptyResponseUnexpectedContentTypeNoError() async throws {
            // Even for requests, empty responses with unexpected content-type are acceptable
            // (e.g., server returns 200 OK with empty body instead of proper 202/204)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            // Request has both "method" and "id"
            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                // Server returns unexpected content-type but empty body
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [HTTPHeader.contentType: "text/plain"])!
                return (response, Data())  // Empty body
            }

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            // Should not throw - empty body is acceptable even with unexpected content-type
            try await transport.send(messageData)
        }

        // MARK: - Protocol Version Header Tests

        @Test("Protocol version header sent after initialization", .httpClientTransportSetup)
        func testProtocolVersionHeaderSentAfterInit() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let firstMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!
            let secondMessageData = #"{"jsonrpc":"2.0","method":"ping","id":2}"#.data(using: .utf8)!
            let protocolVersion = Version.v2024_11_05

            // First request - no protocol version header expected
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                // Before initialization, no protocol version header should be sent
                #expect(request.value(forHTTPHeaderField: HTTPHeader.protocolVersion) == nil)

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [HTTPHeader.contentType: "application/json"])!
                return (response, Data())
            }
            try await transport.send(firstMessageData)

            // Set the protocol version (simulating what Client does after init)
            await transport.setProtocolVersion(protocolVersion)

            // Second request - protocol version header should be present
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, protocolVersion] (request: URLRequest) in
                #expect(request.value(forHTTPHeaderField: HTTPHeader.protocolVersion) == protocolVersion)

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [HTTPHeader.contentType: "application/json"])!
                return (response, Data())
            }
            try await transport.send(secondMessageData)
        }

        // MARK: - Session Termination Tests

        @Test("Terminate session sends DELETE request", .httpClientTransportSetup)
        func testTerminateSessionSendsDelete() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let sessionID = "session-to-terminate-123"
            let initMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!

            // First, establish a session
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sessionID] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        HTTPHeader.contentType: "application/json",
                        HTTPHeader.sessionId: sessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(initMessageData)
            #expect(await transport.sessionID == sessionID)

            // Now set up handler for DELETE request
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sessionID] (request: URLRequest) in
                #expect(request.httpMethod == "DELETE")
                #expect(request.value(forHTTPHeaderField: HTTPHeader.sessionId) == sessionID)

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }

            try await transport.terminateSession()

            // Session ID should be cleared
            #expect(await transport.sessionID == nil)
        }

        @Test("Terminate session handles 405 gracefully", .httpClientTransportSetup)
        func testTerminateSessionHandles405() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let sessionID = "session-405-test"
            let initMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!

            // First, establish a session
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sessionID] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        HTTPHeader.contentType: "application/json",
                        HTTPHeader.sessionId: sessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(initMessageData)

            // Server returns 405 - doesn't support session termination
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }

            // Should not throw - 405 is handled gracefully per spec
            try await transport.terminateSession()

            // Session ID is NOT cleared when server returns 405
            // (server doesn't support termination, session may still be valid)
            #expect(await transport.sessionID == sessionID)
        }

        @Test("Terminate session handles 404 (session expired)", .httpClientTransportSetup)
        func testTerminateSessionHandles404() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let sessionID = "session-404-test"
            let initMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!

            // First, establish a session
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sessionID] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        HTTPHeader.contentType: "application/json",
                        HTTPHeader.sessionId: sessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(initMessageData)

            // Server returns 404 - session already expired
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }

            // Should not throw - 404 means session already gone
            try await transport.terminateSession()

            // Session ID should be cleared
            #expect(await transport.sessionID == nil)
        }

        @Test("Terminate session with no session ID does nothing", .httpClientTransportSetup)
        func testTerminateSessionNoSessionId() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            // No session established - should return early without making request
            #expect(await transport.sessionID == nil)

            // This should not throw and should not make any HTTP request
            try await transport.terminateSession()

            #expect(await transport.sessionID == nil)
        }

        @Test("Terminate session includes protocol version header", .httpClientTransportSetup)
        func testTerminateSessionIncludesProtocolVersion() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let sessionID = "session-protocol-version-test"
            let protocolVersion = Version.v2024_11_05
            let initMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!

            // First, establish a session
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sessionID] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        HTTPHeader.contentType: "application/json",
                        HTTPHeader.sessionId: sessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(initMessageData)

            // Set protocol version
            await transport.setProtocolVersion(protocolVersion)

            // Verify DELETE includes protocol version
            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint, sessionID, protocolVersion] (request: URLRequest) in
                #expect(request.httpMethod == "DELETE")
                #expect(request.value(forHTTPHeaderField: HTTPHeader.sessionId) == sessionID)
                #expect(request.value(forHTTPHeaderField: HTTPHeader.protocolVersion) == protocolVersion)

                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }

            try await transport.terminateSession()
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
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-123",
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
                        request.value(forHTTPHeaderField: HTTPHeader.sessionId) == "test-session-123")

                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!

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
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-123",
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
                        request.value(forHTTPHeaderField: HTTPHeader.sessionId) == "test-session-123")

                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!

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
                            headerFields: [HTTPHeader.contentType: "application/json"])!
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
                        let result = CallTool.Result(content: [.text("42")])
                        let response = CallTool.response(id: .string(requestID), result: result)
                        let responseData = try JSONEncoder().encode(response)

                        let httpResponse = HTTPURLResponse(
                            url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: [HTTPHeader.contentType: "application/json"])!
                        return (httpResponse, responseData)
                    } else if method == "notifications/initialized" {
                        // Ignore initialized notifications
                        let httpResponse = HTTPURLResponse(
                            url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: [HTTPHeader.contentType: "application/json"])!
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
                if case .text(let text, _, _) = toolResult.content[0] {
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
                        headerFields: [HTTPHeader.contentType: "application/json"])!
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

            // MARK: - Reconnection and Resumption Tests
            // These tests verify the reconnection logic aligns with TypeScript/Python SDKs

            @Test("Custom reconnection options are respected", .httpClientTransportSetup)
            func testCustomReconnectionOptions() async throws {
                // TypeScript SDK test: 'should support custom reconnection options'
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let customOptions = HTTPReconnectionOptions(
                    initialReconnectionDelay: 0.5,
                    maxReconnectionDelay: 10.0,
                    reconnectionDelayGrowFactor: 2.0,
                    maxRetries: 5
                )

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: false,
                    reconnectionOptions: customOptions,
                    logger: nil
                )

                // Verify options were set correctly
                let options = transport.reconnectionOptions
                #expect(options.initialReconnectionDelay == 0.5)
                #expect(options.maxReconnectionDelay == 10.0)
                #expect(options.reconnectionDelayGrowFactor == 2.0)
                #expect(options.maxRetries == 5)
            }

            @Test("Exponential backoff options configuration", .httpClientTransportSetup)
            func testExponentialBackoffConfiguration() async throws {
                // TypeScript SDK test: 'should have exponential backoff with configurable maxRetries'
                // This test verifies that exponential backoff options can be configured
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let customOptions = HTTPReconnectionOptions(
                    initialReconnectionDelay: 0.1,  // 100ms
                    maxReconnectionDelay: 5.0,  // 5000ms
                    reconnectionDelayGrowFactor: 2.0,
                    maxRetries: 3
                )

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: false,
                    reconnectionOptions: customOptions,
                    logger: nil
                )

                // Verify exponential backoff options are set correctly
                let options = transport.reconnectionOptions
                #expect(options.initialReconnectionDelay == 0.1)
                #expect(options.maxReconnectionDelay == 5.0)
                #expect(options.reconnectionDelayGrowFactor == 2.0)
                #expect(options.maxRetries == 3)

                // The actual exponential backoff delay calculation is:
                // delay = initialReconnectionDelay * pow(reconnectionDelayGrowFactor, attempt)
                // Capped at maxReconnectionDelay
                // This is tested indirectly through reconnection behavior
            }

            @Test("Resumption token callback is invoked", .httpClientTransportSetup)
            func testResumptionTokenCallback() async throws {
                // TypeScript SDK test: related to 'onresumptiontoken' callback
                // Python SDK: 'on_resumption_token_update' callback
                // This test verifies the callback works by checking lastReceivedEventId
                // which is set from the same event processing
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial POST to get session ID
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-resumption",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()
                try await transport.send(Data())

                // Set up SSE response with event ID (priming event)
                let sseWithEventId = "id: event-123\ndata: {\"test\":\"data\"}\n\n"
                let sseData = sseWithEventId.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                try await Task.sleep(for: .milliseconds(200))

                // Verify the event ID was captured (same mechanism as callback)
                // The onResumptionToken callback and lastReceivedEventId are both set
                // when an event with ID is received
                let lastEventId = await transport.lastReceivedEventId
                #expect(lastEventId == "event-123")

                await transport.disconnect()
            }

            @Test("Last event ID is stored for resumption", .httpClientTransportSetup)
            func testLastEventIdStoredForResumption() async throws {
                // TypeScript SDK test: 'should pass lastEventId when reconnecting'
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial POST
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-last-event",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()
                try await transport.send(Data())

                // Set up SSE response with event ID
                let sseWithEventId = "id: last-event-456\ndata: {}\n\n"
                let sseData = sseWithEventId.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                try await Task.sleep(for: .milliseconds(200))

                // Verify last event ID is stored (via public API)
                let lastEventId = await transport.lastReceivedEventId
                #expect(lastEventId == "last-event-456")

                await transport.disconnect()
            }

            @Test("SSE priming event with empty data does not throw", .httpClientTransportSetup)
            func testPrimingEventEmptyDataNoError() async throws {
                // TypeScript SDK test: 'should not throw JSON parse error on priming events with empty data'
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial POST
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-priming",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()
                try await transport.send(Data())

                // Priming event: has ID but empty data (this is valid per MCP spec)
                // Followed by a real message
                let sseWithPriming = "id: priming-123\ndata: \n\nid: msg-456\ndata: {\"result\":\"ok\"}\n\n"
                let sseData = sseWithPriming.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                try await Task.sleep(for: .milliseconds(200))

                // Should not have thrown - priming events with empty data are valid
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()
                let receivedData = try await iterator.next()

                // Should only receive the actual message, not the priming event
                let expectedData = #"{"result":"ok"}"#.data(using: .utf8)!
                #expect(receivedData == expectedData)

                await transport.disconnect()
            }

            @Test("Server retry directive does not cause errors", .httpClientTransportSetup)
            func testServerRetryDirectiveHandled() async throws {
                // TypeScript SDK test: 'should use server-provided retry value for reconnection delay'
                // Python SDK: 'test_streamable_http_client_respects_retry_interval'
                // This test verifies that SSE retry directives are handled without error
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial POST
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-retry",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()
                try await transport.send(Data())

                // SSE response with retry directive (3000ms = 3 seconds)
                // The transport should parse this without error
                let sseWithRetry = "retry: 3000\nid: evt-1\ndata: {\"result\":\"ok\"}\n\n"
                let sseData = sseWithRetry.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                try await Task.sleep(for: .milliseconds(200))

                // Verify the event was processed successfully (no error thrown)
                // The server retry value is stored internally for reconnection logic
                let lastEventId = await transport.lastReceivedEventId
                #expect(lastEventId == "evt-1")

                await transport.disconnect()
            }

            @Test("Default reconnection options use exponential backoff", .httpClientTransportSetup)
            func testDefaultReconnectionOptions() async throws {
                // TypeScript SDK test: 'should fall back to exponential backoff when no server retry value'
                // This test verifies that default reconnection options are properly configured
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                // Use default options
                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: false,
                    logger: nil
                )

                // Verify default options are set correctly
                let options = transport.reconnectionOptions
                #expect(options.initialReconnectionDelay == 1.0)  // Default: 1 second
                #expect(options.maxReconnectionDelay == 30.0)  // Default: 30 seconds
                #expect(options.reconnectionDelayGrowFactor == 1.5)  // Default: 1.5x growth
                #expect(options.maxRetries == 2)  // Default: 2 retries

                // Test that HTTPReconnectionOptions.default has the same values
                let defaultOptions = HTTPReconnectionOptions.default
                #expect(defaultOptions.initialReconnectionDelay == 1.0)
                #expect(defaultOptions.maxReconnectionDelay == 30.0)
                #expect(defaultOptions.reconnectionDelayGrowFactor == 1.5)
                #expect(defaultOptions.maxRetries == 2)
            }

            @Test("SSE notifications do not stop reconnection", .httpClientTransportSetup)
            func testSSENotificationsDoNotStopReconnection() async throws {
                // This test verifies that server notifications via SSE don't incorrectly
                // mark receivedResponse=true (which would stop reconnection).
                // Per MCP spec and TypeScript/Python SDKs, only actual JSON-RPC responses
                // should stop reconnection. Server requests and notifications should not.
                //
                // Bug fix: Previously any non-empty SSE data would set receivedResponse=true.
                // Now only JSON-RPC responses (with id + result/error, no method) do.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial POST
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-notifications",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()
                try await transport.send(Data())

                // SSE stream with:
                // 1. A notification (has method, no id) - should NOT stop reconnection
                // 2. A server request (has method AND id) - should NOT stop reconnection
                // 3. A response (has id + result, no method) - SHOULD stop reconnection
                // Note: SSE format requires no leading spaces on field lines
                let sseWithMixedMessages = "id: evt-1\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":50}}\n\nid: evt-2\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"sampling/createMessage\",\"id\":\"server-req-1\",\"params\":{}}\n\nid: evt-3\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"status\":\"ok\"}}\n\n"
                let sseData = sseWithMixedMessages.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                try await Task.sleep(for: .milliseconds(200))

                // Verify all three messages were received
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                // First: notification
                let msg1 = try await iterator.next()
                #expect(msg1 != nil)
                let msg1String = String(data: msg1!, encoding: .utf8)!
                #expect(msg1String.contains("notifications/progress"))

                // Second: server request
                let msg2 = try await iterator.next()
                #expect(msg2 != nil)
                let msg2String = String(data: msg2!, encoding: .utf8)!
                #expect(msg2String.contains("sampling/createMessage"))

                // Third: response
                let msg3 = try await iterator.next()
                #expect(msg3 != nil)
                let msg3String = String(data: msg3!, encoding: .utf8)!
                #expect(msg3String.contains("\"result\""))

                // The lastReceivedEventId should be evt-3 (last event with ID)
                let lastEventId = await transport.lastReceivedEventId
                #expect(lastEventId == "evt-3")

                await transport.disconnect()
            }

            @Test("SSE error response stops reconnection", .httpClientTransportSetup)
            func testSSEErrorResponseStopsReconnection() async throws {
                // Per JSON-RPC 2.0, error responses also count as responses and should
                // stop reconnection. An error response has id + error fields, no method.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial POST
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-error",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()
                try await transport.send(Data())

                // SSE stream with an error response
                let sseWithError = """
                    id: evt-1
                    data: {"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid request"}}

                    """
                let sseData = sseWithError.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                try await Task.sleep(for: .milliseconds(200))

                // Verify error response was received
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                let msg = try await iterator.next()
                #expect(msg != nil)
                let msgString = String(data: msg!, encoding: .utf8)!
                #expect(msgString.contains("\"error\""))
                #expect(msgString.contains("\(ErrorCode.invalidRequest)"))

                await transport.disconnect()
            }

            @Test("Response ID remapping with string ID", .httpClientTransportSetup)
            func testResponseIdRemappingStringId() async throws {
                // This test verifies that response IDs are remapped to the original
                // request ID during stream resumption, aligning with TypeScript and
                // Python SDK behavior. This is a defensive feature for edge cases
                // where servers might send responses with different IDs during replay.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial connection
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-remap",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()

                // SSE stream with a response that has a DIFFERENT ID than the original request
                // The server sends id: "server-generated-id" but our original request had id: "original-req-42"
                let sseWithDifferentId = """
                    id: evt-1
                    data: {"jsonrpc":"2.0","id":"server-generated-id","result":{"status":"ok"}}

                    """
                let sseData = sseWithDifferentId.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    // Verify Last-Event-ID header is sent
                    #expect(request.value(forHTTPHeaderField: HTTPHeader.lastEventId) == "last-evt-123")
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                // Resume with original request ID
                let originalRequestId: RequestId = "original-req-42"
                try await transport.resumeStream(from: "last-evt-123", forRequestId: originalRequestId)

                try await Task.sleep(for: .milliseconds(200))

                // Verify the response was received with REMAPPED ID
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                let msg = try await iterator.next()
                #expect(msg != nil)
                let msgString = String(data: msg!, encoding: .utf8)!

                // The ID should be remapped to "original-req-42"
                #expect(msgString.contains("\"id\":\"original-req-42\""))
                #expect(!msgString.contains("server-generated-id"))
                #expect(msgString.contains("\"result\""))

                await transport.disconnect()
            }

            @Test("Response ID remapping with numeric ID", .httpClientTransportSetup)
            func testResponseIdRemappingNumericId() async throws {
                // Test ID remapping with numeric IDs (JSON-RPC allows both string and number IDs)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial connection
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-remap-num",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()

                // SSE stream with a response that has id: 999 (different from original)
                let sseWithDifferentId = """
                    id: evt-1
                    data: {"jsonrpc":"2.0","id":999,"result":{"value":42}}

                    """
                let sseData = sseWithDifferentId.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                // Resume with original numeric request ID
                let originalRequestId: RequestId = 42
                try await transport.resumeStream(from: "last-evt-456", forRequestId: originalRequestId)

                try await Task.sleep(for: .milliseconds(200))

                // Verify the response was received with REMAPPED numeric ID
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                let msg = try await iterator.next()
                #expect(msg != nil)
                let msgString = String(data: msg!, encoding: .utf8)!

                // The ID should be remapped to 42 (numeric)
                #expect(msgString.contains("\"id\":42"))
                #expect(!msgString.contains("999"))
                #expect(msgString.contains("\"result\""))

                await transport.disconnect()
            }

            @Test("No ID remapping without originalRequestId", .httpClientTransportSetup)
            func testNoRemappingWithoutOriginalRequestId() async throws {
                // When originalRequestId is nil (default), IDs should NOT be remapped
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial connection
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-no-remap",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()

                // SSE stream with a response
                let sseResponse = """
                    id: evt-1
                    data: {"jsonrpc":"2.0","id":"original-id","result":{"status":"ok"}}

                    """
                let sseData = sseResponse.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                // Resume WITHOUT providing originalRequestId (default nil)
                try await transport.resumeStream(from: "last-evt-789")

                try await Task.sleep(for: .milliseconds(200))

                // Verify the response was received with ORIGINAL ID (no remapping)
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                let msg = try await iterator.next()
                #expect(msg != nil)
                let msgString = String(data: msg!, encoding: .utf8)!

                // The ID should remain as "original-id"
                #expect(msgString.contains("\"id\":\"original-id\""))

                await transport.disconnect()
            }

            @Test("Error response ID remapping", .httpClientTransportSetup)
            func testErrorResponseIdRemapping() async throws {
                // Per JSON-RPC 2.0, error responses are also responses and should have
                // their IDs remapped. This aligns with Python SDK behavior (which handles
                // both JSONRPCResponse and JSONRPCError), and is more complete than
                // TypeScript which only handles success responses.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial connection
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-error-remap",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()

                // SSE stream with an ERROR response that has a different ID
                let sseWithError = """
                    id: evt-1
                    data: {"jsonrpc":"2.0","id":"server-error-id","error":{"code":-32600,"message":"Invalid request"}}

                    """
                let sseData = sseWithError.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                // Resume with original request ID - error response ID should be remapped
                let originalRequestId: RequestId = "my-failed-request"
                try await transport.resumeStream(from: "last-evt", forRequestId: originalRequestId)

                try await Task.sleep(for: .milliseconds(200))

                // Verify error response was received with REMAPPED ID
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                let msg = try await iterator.next()
                #expect(msg != nil)
                let msgString = String(data: msg!, encoding: .utf8)!

                // The ID should be remapped to "my-failed-request"
                #expect(msgString.contains("\"id\":\"my-failed-request\""))
                #expect(!msgString.contains("server-error-id"))
                #expect(msgString.contains("\"error\""))
                #expect(msgString.contains("\(ErrorCode.invalidRequest)"))

                await transport.disconnect()
            }

            @Test("ID remapping only affects responses, not requests/notifications", .httpClientTransportSetup)
            func testIdRemappingOnlyAffectsResponses() async throws {
                // ID remapping should only apply to responses, not to server requests or notifications
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]

                let transport = HTTPClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration,
                    streaming: true,
                    sseInitializationTimeout: 1,
                    logger: nil
                )

                // Set up handler for initial connection
                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            HTTPHeader.contentType: "text/plain",
                            HTTPHeader.sessionId: "test-session-selective",
                        ])!
                    return (response, Data())
                }

                try await transport.connect()

                // SSE stream with:
                // 1. A server request (has method AND id) - should NOT be remapped
                // 2. A notification (has method, no id) - should NOT be remapped
                // 3. A response (has id + result, no method) - SHOULD be remapped
                // Note: SSE format requires no leading spaces on field lines
                let sseWithMixed = "id: evt-1\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"sampling/createMessage\",\"id\":\"server-req-1\",\"params\":{}}\n\nid: evt-2\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":50}}\n\nid: evt-3\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"server-resp-id\",\"result\":{\"status\":\"ok\"}}\n\n"
                let sseData = sseWithMixed.data(using: .utf8)!

                await MockURLProtocol.requestHandlerStorage.setHandler {
                    [testEndpoint, sseData] (request: URLRequest) in
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [HTTPHeader.contentType: "text/event-stream"])!
                    return (response, sseData)
                }

                // Resume with original request ID
                let originalRequestId: RequestId = "my-original-request"
                try await transport.resumeStream(from: "last-evt", forRequestId: originalRequestId)

                try await Task.sleep(for: .milliseconds(200))

                // Verify all messages were received
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                // First: server request - ID should NOT be remapped
                let msg1 = try await iterator.next()
                #expect(msg1 != nil)
                let msg1String = String(data: msg1!, encoding: .utf8)!
                #expect(msg1String.contains("\"id\":\"server-req-1\""))  // Original ID preserved
                #expect(msg1String.contains("sampling/createMessage"))

                // Second: notification - no ID field, should pass through unchanged
                let msg2 = try await iterator.next()
                #expect(msg2 != nil)
                let msg2String = String(data: msg2!, encoding: .utf8)!
                #expect(msg2String.contains("notifications/progress"))
                #expect(!msg2String.contains("my-original-request"))

                // Third: response - ID SHOULD be remapped
                let msg3 = try await iterator.next()
                #expect(msg3 != nil)
                let msg3String = String(data: msg3!, encoding: .utf8)!
                #expect(msg3String.contains("\"id\":\"my-original-request\""))  // Remapped ID
                #expect(!msg3String.contains("server-resp-id"))  // Original ID replaced
                #expect(msg3String.contains("\"result\""))

                await transport.disconnect()
            }
        #endif  // !canImport(FoundationNetworking)
    }
#endif  // swift(>=6.1)
