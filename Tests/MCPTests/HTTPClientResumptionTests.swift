@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// A POST stream that ends before its response is resumed with a GET carrying
// that stream's last event ID (2025-11-25 resumability, SEP-1699).

#if swift(>=6.1)

    private actor Requests {
        private(set) var all: [URLRequest] = []
        func append(_ request: URLRequest) { all.append(request) }
        var gets: [URLRequest] { all.filter { $0.httpMethod == "GET" } }
    }

    @Suite("HTTP client response stream resumption", .serialized)
    struct HTTPClientResumptionTests {
        let endpoint = URL(string: "http://127.0.0.1:9/mcp")!
        let request = Data(#"{"jsonrpc":"2.0","id":"r1","method":"tools/call","params":{"name":"slow"}}"#.utf8)
        let response = #"{"jsonrpc":"2.0","id":"r1","result":{"content":[]}}"#
        let log = #"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"x"}}"#

        func sse(_ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
            (
                HTTPURLResponse(
                    url: endpoint, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream", "Mcp-Session-Id": "s1"])!,
                Data(body.utf8)
            )
        }

        func makeTransport() -> (HTTPClientTransport, String) {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            return (HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: false), key)
        }

        /// The first `count` messages the transport delivers.
        func messages(_ transport: HTTPClientTransport, _ count: Int) async throws -> [String] {
            var out: [String] = []
            for try await data in await transport.receive() {
                out.append(String(decoding: data, as: UTF8.self))
                if out.count == count { break }
            }
            return out
        }

        @Test("The response arrives through a GET with the stream's own Last-Event-ID")
        func resumes() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { [response] request in
                await requests.append(request)
                if request.httpMethod == "POST" {
                    return sse("id: post-1\nretry: 10\ndata: \n\n")
                }
                return sse("id: post-2\ndata: \(response)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            #expect(try await messages(transport, 1) == [response])

            let gets = await requests.gets
            #expect(gets.count == 1)
            #expect(gets.first?.value(forHTTPHeaderField: "Last-Event-ID") == "post-1")
            #expect(gets.first?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            await transport.disconnect()
        }

        @Test("A stream that carried a notification is still resumed")
        func resumesAfterData() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { [log, response] request in
                await requests.append(request)
                if request.httpMethod == "POST" {
                    return sse("id: post-1\nretry: 10\ndata: \n\nid: post-2\ndata: \(log)\n\n")
                }
                return sse("id: post-3\ndata: \(response)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            #expect(try await messages(transport, 2) == [log, response])
            #expect(await requests.gets.first?.value(forHTTPHeaderField: "Last-Event-ID") == "post-2")
            await transport.disconnect()
        }

        @Test("Resumption repeats while the server closes the stream again")
        func resumesRepeatedly() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { [response] request in
                await requests.append(request)
                switch (request.httpMethod, request.value(forHTTPHeaderField: "Last-Event-ID")) {
                case ("POST", _): return sse("id: e1\nretry: 10\ndata: \n\n")
                case (_, "e1"): return sse("id: e2\nretry: 10\ndata: \n\n")
                default: return sse("data: \(response)\n\n")
                }
            }
            try await transport.connect()
            try await transport.send(request)
            #expect(try await messages(transport, 1) == [response])
            #expect(await requests.gets.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["e1", "e2"])
            await transport.disconnect()
        }

        @Test("Without an event ID the request fails instead of waiting")
        func failsWithoutEventID() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return sse("retry: 10\ndata: \n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            let delivered = try await messages(transport, 1)
            let error = try JSONSerialization.jsonObject(with: Data(delivered[0].utf8)) as? [String: Any]
            #expect(error?["id"] as? String == "r1")
            #expect((error?["error"] as? [String: Any])?["code"] as? Int == -32603)
            #expect(await requests.gets.isEmpty)
            await transport.disconnect()
        }

        @Test("A refused resumption fails the request")
        func failsWhenRefused() async throws {
            let (transport, key) = makeTransport()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                if request.httpMethod == "POST" { return sse("id: e1\nretry: 10\ndata: \n\n") }
                return sse("", status: 400)
            }
            try await transport.connect()
            try await transport.send(request)
            let delivered = try await messages(transport, 1)
            #expect(delivered[0].contains("could not be resumed"))
            await transport.disconnect()
        }

        @Test("The request fails after the most resumptions", .timeLimit(.minutes(1)))
        func failsAfterMaxResumptions() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                // Every stream ends with a new event ID and no response.
                let count = await requests.all.count
                return sse("id: e\(count)\nretry: 10\ndata: \n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            let delivered = try await messages(transport, 1)
            let error = try JSONSerialization.jsonObject(with: Data(delivered[0].utf8)) as? [String: Any]
            #expect(error?["id"] as? String == "r1")
            #expect((error?["error"] as? [String: Any])?["code"] as? Int == -32603)
            #expect(delivered[0].contains("could not be resumed"))
            #expect(await requests.gets.count == HTTPClientTransport.maxStreamResumptions)
            await transport.disconnect()
        }

        @Test("Resumptions that deliver messages do not use up the most resumptions", .timeLimit(.minutes(1)))
        func resumesPastMaxWhileMessagesArrive() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            let max = HTTPClientTransport.maxStreamResumptions
            await IsolatedMockURLProtocol.setHandler(key: key) { [log, response] request in
                await requests.append(request)
                if request.httpMethod == "POST" { return sse("id: e0\nretry: 10\ndata: \n\n") }
                // Each stream delivers a notification and ends, as a polling server's do.
                let gets = await requests.gets.count
                if gets <= max + 1 { return sse("id: g\(gets)\nretry: 10\ndata: \(log)\n\n") }
                return sse("data: \(response)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            let delivered = try await messages(transport, max + 2)
            #expect(delivered.last == response)
            #expect(await requests.gets.count == max + 2)
            await transport.disconnect()
        }

        @Test("Resumptions that replay the same message use up the most resumptions", .timeLimit(.minutes(1)))
        func replayedMessageIsNoProgress() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { [log] request in
                await requests.append(request)
                // The server ignores Last-Event-ID: every stream is the same.
                return sse("id: e1\nretry: 10\ndata: \n\nid: e2\ndata: \(log)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            var failure: String?
            for try await data in await transport.receive() {
                let message = String(decoding: data, as: UTF8.self)
                if message.contains("could not be resumed") {
                    failure = message
                    break
                }
            }
            #expect(failure != nil)
            #expect(await requests.gets.count == HTTPClientTransport.maxStreamResumptions)
            await transport.disconnect()
        }

        @Test("A resumption GET that fails to connect is retried")
        func resumesAfterFailedGET() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { [response] request in
                await requests.append(request)
                if request.httpMethod == "POST" { return sse("id: e1\nretry: 10\ndata: \n\n") }
                if await requests.gets.count == 1 { throw URLError(.networkConnectionLost) }
                return sse("data: \(response)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            #expect(try await messages(transport, 1) == [response])
            #expect(await requests.gets.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["e1", "e1"])
            await transport.disconnect()
        }

        @Test("A stream cut in the middle of an event resumes from the event before it")
        func resumesBeforeCutEvent() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { [response] request in
                await requests.append(request)
                if request.httpMethod == "POST" {
                    // The body ends inside the event that carries the response.
                    return sse("id: e1\nretry: 10\ndata: \n\nid: e2\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"r1\"")
                }
                return sse("id: e2\ndata: \(response)\n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            #expect(try await messages(transport, 1) == [response])
            #expect(await requests.gets.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["e1"])
            await transport.disconnect()
        }

        @Test("An empty id resets the event ID to resume from")
        func emptyIDResets() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return sse("id: e1\nretry: 10\ndata: \n\nid:\ndata: \n\n")
            }
            try await transport.connect()
            try await transport.send(request)
            let delivered = try await messages(transport, 1)
            let error = try JSONSerialization.jsonObject(with: Data(delivered[0].utf8)) as? [String: Any]
            #expect(error?["id"] as? String == "r1")
            #expect((error?["error"] as? [String: Any])?["code"] as? Int == -32603)
            #expect(await requests.gets.isEmpty)
            await transport.disconnect()
        }

        @Test("A line over the limit fails the request without resuming", .timeLimit(.minutes(1)))
        func oversizedLineIsNotResumed() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            let line = "data: " + String(repeating: "a", count: ServerSentEventParser.maxLineLength) + "\n\n"
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return sse("id: e1\nretry: 10\ndata: \n\n" + line)
            }
            try await transport.connect()
            await #expect {
                try await transport.send(request)
            } throws: { error in
                (error as? MCPError) == .internalError("SSE line longer than 16 MiB")
            }
            #expect(await requests.all.count == 1)
            await transport.disconnect()
        }

        @Test("At 2026-07-28 a stream that ends early fails without a GET")
        func statelessDoesNotResume() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return sse("id: e1\nretry: 10\ndata: \n\n")
            }
            try await transport.connect()
            await transport.useStatelessProtocol("2026-07-28")
            try await transport.send(request)
            let delivered = try await messages(transport, 1)
            let error = try JSONSerialization.jsonObject(with: Data(delivered[0].utf8)) as? [String: Any]
            #expect(error?["id"] as? String == "r1")
            #expect((error?["error"] as? [String: Any])?["code"] as? Int == -32603)
            #expect(await requests.gets.isEmpty)
            await transport.disconnect()
        }

        @Test("A request that names 2026-07-28 in _meta is not resumed before the switch")
        func statelessRequestDoesNotResume() async throws {
            let (transport, key) = makeTransport()
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return sse("id: e1\nretry: 10\ndata: \n\n")
            }
            try await transport.connect()
            try await transport.send(
                Data(
                    #"{"jsonrpc":"2.0","id":"r1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
                        .utf8))
            let delivered = try await messages(transport, 1)
            #expect(delivered[0].contains("without a response"))
            #expect(await requests.gets.isEmpty)
            await transport.disconnect()
        }

        @Test("A request cancelled during its last resumption does not fail", .timeLimit(.minutes(1)))
        func cancelledDuringLastResumption() async throws {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            let logger = Logger(label: "mcp.test.resumption") { _ in CancelOnEventIDLogHandler(eventID: "last") }
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false, logger: logger)
            let requests = Requests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                let gets = await requests.gets.count
                guard gets == HTTPClientTransport.maxStreamResumptions else {
                    return sse("id: e\(gets)\nretry: 10\ndata: \n\n")
                }
                // The request is cancelled at the first event, and the read
                // ends at the next one without an error.
                return sse("id: last\ndata: \n\nid: after\ndata: \n\n")
            }
            try await transport.connect()
            try? await transport.send(request)
            #expect(await requests.gets.count == HTTPClientTransport.maxStreamResumptions)
            await transport.disconnect()
            var delivered: [String] = []
            for try await data in await transport.receive() { delivered.append(String(decoding: data, as: UTF8.self)) }
            #expect(delivered.isEmpty)
        }
    }

    /// Cancels the task that logs an event's ID when it is `eventID`, as a
    /// `notifications/cancelled` sent while that event is read would.
    private struct CancelOnEventIDLogHandler: LogHandler {
        let eventID: String
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
            guard metadata?["eventID"] == .string(eventID) else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

#endif
