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
                #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": newSessionID,
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
                #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": initialSessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(firstMessageData)
            #expect(await transport.sessionID == initialSessionID)

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                #expect(request.readBody() == secondMessageData)
                #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == initialSessionID)

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

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":3}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Not Found".utf8))
            }

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

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let messageData = #"{"jsonrpc":"2.0","method":"test","id":4}"#.data(using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Server Error".utf8))
            }

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

            let transport = HTTPClientTransport(
                endpoint: testEndpoint,
                configuration: configuration,
                streaming: false,
                logger: nil
            )
            try await transport.connect()

            let initialSessionID = "expired-session-xyz"
            let firstMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(
                using: .utf8)!
            let secondMessageData = #"{"jsonrpc":"2.0","method":"ping","id":2}"#.data(
                using: .utf8)!

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                let response = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": initialSessionID,
                    ])!
                return (response, Data())
            }
            try await transport.send(firstMessageData)
            #expect(await transport.sessionID == initialSessionID)

            await MockURLProtocol.requestHandlerStorage.setHandler {
                [testEndpoint] (request: URLRequest) in
                #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == initialSessionID)
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
                        request.value(forHTTPHeaderField: "Mcp-Session-Id") == "test-session-123")

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
                        request.value(forHTTPHeaderField: "Mcp-Session-Id") == "test-session-123")

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
        #endif  // !canImport(FoundationNetworking)

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
                        request.allHTTPHeaderFields?["Accept"]?.contains("application/json") == true
                    )
                default:
                    Issue.record(
                        "Unsupported HTTP method \(String(describing: request.httpMethod))")
                }

                #expect(request.url == testEndpoint)

                let bodyData = request.readBody()

                guard let bodyData = bodyData,
                    let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                    let method = json["method"] as? String
                else {
                    throw NSError(
                        domain: "MockURLProtocolError", code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Invalid JSON-RPC message \(#file):\(#line)"
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
                    if let lastRequest = await tracker.getLastRequest(), lastRequest != .initialize
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

            // Execute the complete flow
            try await client.connect(transport: transport)

            // Step 1: Initialize client
            let initResult = try await client.initialize()
            #expect(initResult.protocolVersion == Version.latest)
            #expect(initResult.capabilities.tools != nil)

            // Step 2: Call a tool
            let toolResult = try await client.callTool(name: "calculator")
            #expect(toolResult.content.count == 1)
            if case let .text(text) = toolResult.content[0] {
                #expect(text == "42")
            } else {
                #expect(Bool(false), "Expected text content")
            }

            // Step 3: Verify request sequence
            #expect(await tracker.getLastRequest() == .callTool)

            // Step 4: Disconnect
            await client.disconnect()
        }
    }
#endif  // swift(>=6.1)
