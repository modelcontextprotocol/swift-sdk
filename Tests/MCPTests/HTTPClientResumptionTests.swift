@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// A POST stream that ends before its response is resumed with a GET carrying
// that stream's last event ID (2025-11-25 resumability, SEP-1699).

#if swift(>=6.1) && !os(Linux)

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
    }

#endif
