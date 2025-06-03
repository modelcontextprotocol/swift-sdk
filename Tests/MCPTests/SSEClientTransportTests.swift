#if swift(>=6.1) && !os(Linux)
    import EventSource
    @preconcurrency import Foundation
    import Logging
    import Testing

    @testable import MCP

    final class MockSSEURLProtocol: URLProtocol, @unchecked Sendable {
        static let requestHandlerStorage = RequestHandlerStorage()
        private var loadingTask: Task<Void, Swift.Error>?

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
            loadingTask = Task {
                do {
                    let (response, data) = try await self.executeHandler(for: request)

                    // For SSE GET requests, we need to simulate a streaming response
                    if request.httpMethod == "GET"
                        && request.value(forHTTPHeaderField: "Accept")?.contains(
                            "text/event-stream") == true
                    {
                        // Send the response headers
                        client?.urlProtocol(
                            self, didReceive: response, cacheStoragePolicy: .notAllowed)

                        // Simulate SSE event data coming in chunks
                        if !data.isEmpty {
                            // Break the data into lines to simulate events coming one by one
                            let dataString = String(data: data, encoding: .utf8) ?? ""
                            let lines = dataString.split(
                                separator: "\n", omittingEmptySubsequences: false)

                            // Simulate delay between events
                            for line in lines {
                                let lineData = Data("\(line)\n".utf8)
                                self.client?.urlProtocol(self, didLoad: lineData)
                                try await Task.sleep(for: .milliseconds(10))
                            }
                        }

                        // Complete the loading
                        self.client?.urlProtocolDidFinishLoading(self)
                    } else {
                        // For regular requests, just deliver the data all at once
                        client?.urlProtocol(
                            self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: data)
                        client?.urlProtocolDidFinishLoading(self)
                    }
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }

        override func stopLoading() {
            // Cancel any ongoing tasks
            loadingTask?.cancel()
            loadingTask = nil
        }
    }

    // MARK: - Test trait

    /// A test trait that automatically manages the mock URL protocol handler for SSE transport tests.
    struct SSETransportTestSetupTrait: TestTrait, TestScoping {
        func provideScope(
            for test: Test, testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            // Clear handler before test
            await MockSSEURLProtocol.requestHandlerStorage.clearHandler()

            do {
                // Execute the test
                try await function()
            } catch {
                // Ensure handler is cleared even if test fails
                await MockSSEURLProtocol.requestHandlerStorage.clearHandler()
                throw error
            }

            // Clear handler after test
            await MockSSEURLProtocol.requestHandlerStorage.clearHandler()
        }
    }

    extension Trait where Self == SSETransportTestSetupTrait {
        static var sseTransportSetup: Self { Self() }
    }

    // MARK: - Test State Management

    actor CapturedRequest {
        private var value: URLRequest?

        func setValue(_ newValue: URLRequest?) {
            value = newValue
        }

        func getValue() -> URLRequest? {
            return value
        }
    }

    actor CapturedRequests {
        private var sseRequest: URLRequest?
        private var postRequest: URLRequest?

        func setSSERequest(_ request: URLRequest?) {
            sseRequest = request
        }

        func setPostRequest(_ request: URLRequest?) {
            postRequest = request
        }

        func getValues() -> (URLRequest?, URLRequest?) {
            return (sseRequest, postRequest)
        }
    }

    // MARK: - Tests

    @Suite("SSE Client Transport Tests", .serialized)
    struct SSEClientTransportTests {
        let testEndpoint = URL(string: "http://localhost:8080/sse")!

        @Test("Connect and receive endpoint event", .sseTransportSetup)
        func testConnectAndReceiveEndpoint() async throws {
            // Setup URLSession with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockSSEURLProtocol.self]

            // Create transport with mocked URLSession
            let transport = SSEClientTransport(
                endpoint: testEndpoint,
                configuration: configuration
            )

            // Setup mock response for the SSE connection
            let endpointEvent = """
                event: endpoint
                data: /messages/123

                """

            await MockSSEURLProtocol.setHandler { request in
                guard request.httpMethod == "GET" else {
                    throw MCPError.internalError("Unexpected request method")
                }

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!

                return (response, Data(endpointEvent.utf8))
            }

            // Connect should receive the endpoint event and complete
            try await transport.connect()

            // Transport should now be connected
            #expect(await transport.isConnected)

            // Disconnect to clean up
            await transport.disconnect()
        }

        @Test("Send message after connection", .sseTransportSetup)
        func testSendMessage() async throws {
            // Setup URLSession with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockSSEURLProtocol.self]

            // Create transport with mocked URLSession
            let transport = SSEClientTransport(
                endpoint: testEndpoint,
                configuration: configuration
            )

            // Configure different responses based on the request
            let messageURL = URL(string: "http://localhost:8080/messages/123")!
            let capturedRequest = CapturedRequest()

            await MockSSEURLProtocol.setHandler { request in
                if request.httpMethod == "GET" {
                    // SSE connection request
                    let response = HTTPURLResponse(
                        url: testEndpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    // Send the endpoint event
                    return (
                        response,
                        Data(
                            """
                            event: endpoint
                            data: /messages/123

                            """.utf8)
                    )
                } else if request.httpMethod == "POST" {
                    // Message request
                    await capturedRequest.setValue(request)
                    let response = HTTPURLResponse(
                        url: messageURL,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data())
                } else {
                    throw MCPError.internalError("Unexpected request method")
                }
            }

            // Connect first
            try await transport.connect()

            // Now send a message
            let messageData = #"{"jsonrpc":"2.0","method":"test","id":1}"#.data(using: .utf8)!
            try await transport.send(messageData)

            // Verify the sent message
            let capturedPostRequest = await capturedRequest.getValue()
            #expect(capturedPostRequest != nil)
            #expect(capturedPostRequest?.url?.path == "/messages/123")
            #expect(capturedPostRequest?.httpMethod == "POST")
            #expect(capturedPostRequest?.readBody() == messageData)
            #expect(
                capturedPostRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json"
            )

            // Disconnect
            await transport.disconnect()
        }

        @Test("Receive message events", .sseTransportSetup)
        func testReceiveMessageEvents() async throws {
            // Setup URLSession with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockSSEURLProtocol.self]

            // Create transport with mocked URLSession
            let transport = SSEClientTransport(
                endpoint: testEndpoint,
                configuration: configuration
            )

            // Configure mock response with both endpoint and message events
            let eventStreamData = """
                event: endpoint
                data: /messages/123

                event: message
                data: {"jsonrpc":"2.0","result":{"content":"Hello"},"id":1}

                event: message
                data: {"jsonrpc":"2.0","result":{"content":"World"},"id":2}

                """

            await MockSSEURLProtocol.setHandler { request in
                guard request.httpMethod == "GET" else {
                    throw MCPError.internalError("Unexpected request method")
                }

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!

                return (response, Data(eventStreamData.utf8))
            }

            // Start receiving before connecting
            let receiverTask = Task {
                var receivedMessages: [Data] = []
                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()

                // Try to get 2 messages
                for _ in 0..<2 {
                    if let message = try await iterator.next() {
                        receivedMessages.append(message)
                    }
                }

                return receivedMessages
            }

            // Connect to trigger the event stream
            try await transport.connect()

            // Wait for messages and check them
            let receivedMessages = try await receiverTask.value

            #expect(receivedMessages.count == 2)

            // Check first message
            let firstMessageString = String(data: receivedMessages[0], encoding: .utf8)
            #expect(firstMessageString?.contains("Hello") == true)

            // Check second message
            let secondMessageString = String(data: receivedMessages[1], encoding: .utf8)
            #expect(secondMessageString?.contains("World") == true)

            // Disconnect
            await transport.disconnect()
        }

        @Test("Authentication token", .sseTransportSetup)
        func testAuthenticationToken() async throws {
            // Setup URLSession with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockSSEURLProtocol.self]

            let testToken = "test-auth-token"

            // Create transport with mocked URLSession and auth token
            let transport = SSEClientTransport(
                endpoint: testEndpoint,
                token: testToken,
                configuration: configuration
            )

            // Keep track of requests to verify auth headers
            let capturedRequests = CapturedRequests()

            await MockSSEURLProtocol.setHandler { request in
                if request.httpMethod == "GET" {
                    await capturedRequests.setSSERequest(request)
                    let response = HTTPURLResponse(
                        url: testEndpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (
                        response,
                        Data(
                            """
                            event: endpoint
                            data: /messages/123

                            """.utf8)
                    )
                } else if request.httpMethod == "POST" {
                    await capturedRequests.setPostRequest(request)
                    let response = HTTPURLResponse(
                        url: URL(string: "http://localhost:8080/messages/123")!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data())
                } else {
                    throw MCPError.internalError("Unexpected request method")
                }
            }

            // Connect and send a message
            try await transport.connect()
            try await transport.send(Data())

            // Verify auth tokens in both requests
            let (sseRequest, postRequest) = await capturedRequests.getValues()
            #expect(sseRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer \(testToken)")
            #expect(
                postRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer \(testToken)")

            await transport.disconnect()
        }

        @Test("HTTP error handling", .sseTransportSetup)
        func testHTTPErrorHandling() async throws {
            // Setup URLSession with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockSSEURLProtocol.self]

            // Create transport with mocked URLSession
            let transport = SSEClientTransport(
                endpoint: testEndpoint,
                configuration: configuration
            )

            // Configure mock to return 404 for SSE connection
            await MockSSEURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!

                return (response, Data("Not Found".utf8))
            }

            // Connection should fail with HTTP error
            do {
                try await transport.connect()
                Issue.record("Connection should have failed with HTTP error")
            } catch let error as MCPError {
                guard case .internalError(let message) = error else {
                    Issue.record("Expected MCPError.internalError, got \(error)")
                    throw error
                }
                #expect(message?.contains("HTTP error: 404") ?? false)
            }
        }

        @Test("URL construction from different endpoint formats", .sseTransportSetup)
        func testURLConstruction() async throws {
            // Setup URLSession with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockSSEURLProtocol.self]

            // Test different endpoint formats
            let testCases = [
                // Relative path without leading slash
                "messages/123",
                // Relative path with leading slash
                "/messages/456",
                // Absolute URL
                "https://api.example.com/messages/789",
            ]

            for endpoint in testCases {
                // Create new transport for each test case
                let transport = SSEClientTransport(
                    endpoint: testEndpoint,
                    configuration: configuration
                )

                // Configure mock to return the current endpoint
                let capturedRequest = CapturedRequest()

                await MockSSEURLProtocol.setHandler { request in
                    if request.httpMethod == "GET" {
                        let response = HTTPURLResponse(
                            url: testEndpoint,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "text/event-stream"]
                        )!

                        return (
                            response,
                            Data(
                                """
                                event: endpoint
                                data: \(endpoint)

                                """.utf8)
                        )
                    } else if request.httpMethod == "POST" {
                        await capturedRequest.setValue(request)
                        let response = HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"]
                        )!
                        return (response, Data())
                    } else {
                        throw MCPError.internalError("Unexpected request method")
                    }
                }

                // Connect and send a test message
                try await transport.connect()
                try await transport.send(Data())

                // Verify the URL construction based on endpoint format
                let capturedPostRequest = await capturedRequest.getValue()
                if endpoint.starts(with: "http") {
                    // For absolute URLs
                    #expect(capturedPostRequest?.url?.absoluteString == endpoint)
                } else {
                    // For relative paths
                    let expectedPath = endpoint.starts(with: "/") ? endpoint : "/\(endpoint)"
                    #expect(capturedPostRequest?.url?.path == expectedPath)
                    #expect(capturedPostRequest?.url?.host == testEndpoint.host)
                    #expect(capturedPostRequest?.url?.scheme == testEndpoint.scheme)
                }

                await transport.disconnect()
            }
        }
    }
#endif  // swift(>=6.1) && !os(Linux)
