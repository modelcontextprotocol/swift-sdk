import Foundation
import Testing

@testable import MCP

// A request's id must be a string or an integer and not null; `""` is a
// valid id. A message with a `method` and an invalid `id` or `jsonrpc` is
// an invalid request, answered with -32600, never a notification
// (JSON-RPC 2.0 §5; basic/index.mdx "Requests").

/// Ids a request may have, as JSON, with the id the answer echoes.
private let validIDs: [(json: String, echo: Value)] = [
    (#""""#, ""), (#""x""#, "x"), ("0", 0), ("-1", -1), ("9007199254740993", .int(9_007_199_254_740_993)),
]

/// Ids a request may not have, as JSON.
private let invalidIDs = ["1.5", "5.2", "null", "[]", "{}", "true", "1e20"]

/// Requests with a valid id and an invalid `jsonrpc`, as JSON.
private let invalidVersions = [
    #"{"id":1,"method":"tools/list"}"#,
    #"{"jsonrpc":"1.0","id":1,"method":"tools/list"}"#,
    #"{"jsonrpc":null,"id":1,"method":"tools/list"}"#,
]

private func makeServer() async -> Server {
    let server = Server(name: "ids", version: "1.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
    return server
}

private func decode(_ data: Data?) throws -> Value {
    try JSONDecoder().decode(Value.self, from: try #require(data))
}

@Suite("Request ids on a message stream", .timeLimit(.minutes(1)))
struct StreamRequestIDTests {
    private actor Inbox {
        private(set) var values: [Value] = []
        func add(_ value: Value) { values.append(value) }
    }

    /// Sends one raw line to a started server, then a ping, and returns the
    /// messages it sends back other than the ping's answer, once that
    /// answer and `expected` others are in. An answer the receive loop
    /// sends itself precedes the ping's.
    private func replies(to line: String, expected: Int = 1) async throws -> [Value] {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        try await clientEnd.connect()
        let stream = await clientEnd.receive()
        let inbox = Inbox()
        let collector = Task {
            for try await data in stream { await inbox.add(try JSONDecoder().decode(Value.self, from: data)) }
        }
        try await clientEnd.send(Data(line.utf8))
        try await clientEnd.send(Data(#"{"jsonrpc":"2.0","id":"sentinel","method":"ping"}"#.utf8))
        let isSentinel: (Value) -> Bool = { $0.objectValue?["id"] == "sentinel" }
        let deadline = ContinuousClock.now + .seconds(30)
        var values: [Value] = []
        repeat {
            try await Task.sleep(for: .milliseconds(10))
            values = await inbox.values
        } while ContinuousClock.now < deadline
            && !(values.contains(where: isSentinel) && values.count(where: { !isSentinel($0) }) >= expected)
        collector.cancel()
        await clientEnd.disconnect()
        await server.stop()
        return values.filter { !isSentinel($0) }
    }

    @Test("A valid id is echoed", arguments: validIDs.indices)
    func validID(_ index: Int) async throws {
        let (json, echo) = validIDs[index]
        let replies = try await replies(to: #"{"jsonrpc":"2.0","id":\#(json),"method":"tools/list"}"#)
        #expect(replies.count == 1)
        #expect(replies.first?.objectValue?["id"] == echo)
        #expect(replies.first?.objectValue?["result"] != nil)
    }

    @Test("An invalid id gets one -32600 with a null id", arguments: invalidIDs + ["1e400"])
    func invalidID(_ json: String) async throws {
        let replies = try await replies(to: #"{"jsonrpc":"2.0","id":\#(json),"method":"tools/list"}"#)
        #expect(replies.count == 1)
        #expect(replies.first?.objectValue?["id"] == .null)
        #expect(replies.first?.objectValue?["error"]?.objectValue?["code"] == -32600)
    }

    @Test("An invalid jsonrpc gets one -32600 with the request's id", arguments: invalidVersions)
    func invalidVersion(_ line: String) async throws {
        let replies = try await replies(to: line)
        #expect(replies.count == 1)
        #expect(replies.first?.objectValue?["id"] == 1)
        #expect(replies.first?.objectValue?["error"]?.objectValue?["code"] == -32600)
    }

    @Test("A request with a null id does not decode")
    func nullIDRequest() {
        let data = Data(#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Request<ListTools>.self, from: data) }
    }

    @Test("A message with an id does not decode as a notification")
    func notificationWithID() {
        let data = Data(#"{"jsonrpc":"2.0","id":1.5,"method":"notifications/initialized"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Message<InitializedNotification>.self, from: data)
        }
    }

    @Test("A batch with invalid items answers valid requests alongside per-item -32600")
    func batchInvalidItemsKeepValidReplies() async throws {
        let batch =
            #"[{"jsonrpc":"2.0","id":null,"method":"tools/list"},{"jsonrpc":"1.0","id":7,"method":"tools/list"},1,{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#
        let replies = try await replies(to: batch)
        let items = try #require(replies.first?.arrayValue)
        #expect(items.count == 4)
        #expect(items[0].objectValue?["id"] == .null)
        #expect(items[0].objectValue?["error"]?.objectValue?["code"] == -32600)
        #expect(items[1].objectValue?["id"] == 7)
        #expect(items[1].objectValue?["error"]?.objectValue?["code"] == -32600)
        #expect(items[2].objectValue?["id"] == .null)
        #expect(items[2].objectValue?["error"]?.objectValue?["code"] == -32600)
        #expect(items[3].objectValue?["id"] == 2)
        #expect(items[3].objectValue?["result"] != nil)
    }

    @Test("A batch answers requests only: no reply to a notification or a response")
    func batchNotificationsResponsesAndShapes() async throws {
        let batch =
            #"[{"jsonrpc":"2.0","method":"notifications/vendor"},{"jsonrpc":"2.0","id":7},{"jsonrpc":"2.0","id":8,"method":""},{"jsonrpc":"2.0","id":5,"result":{}},{"jsonrpc":"2.0","id":6,"error":{"code":-32603,"message":"x"}},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#
        let replies = try await replies(to: batch)
        #expect(replies.count == 1)
        let items = try #require(replies.first?.arrayValue)
        // The notification and the two responses get nothing; an item with
        // an id but no method is an invalid request; an empty method is a
        // method that does not exist.
        #expect(items.count == 3)
        #expect(items[0].objectValue?["id"] == 7)
        #expect(items[0].objectValue?["error"]?.objectValue?["code"] == -32600)
        #expect(items[1].objectValue?["id"] == 8)
        #expect(items[1].objectValue?["error"]?.objectValue?["code"] == -32601)
        #expect(items[2].objectValue?["id"] == 2)
        #expect(items[2].objectValue?["result"] != nil)
    }

    @Test("A batch of responses gets no reply")
    func batchOfResponses() async throws {
        let batch = #"[{"jsonrpc":"2.0","id":5,"result":{}},{"jsonrpc":"2.0","id":"x","result":{}}]"#
        #expect(try await replies(to: batch, expected: 0).isEmpty)
    }

    @Test("A response in a batch answers the server's pending request")
    @available(*, deprecated, message: "listRoots is deprecated by SEP-2577")
    func batchedResponseResumesRequest() async throws {
        let server = await makeServer()
        let (peer, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        try await peer.connect()
        var messages = await peer.receive().makeAsyncIterator()
        try await peer.send(
            Data(
                #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{}},"clientInfo":{"name":"c","version":"1"}}}"#
                    .utf8))
        #expect(try decode(try await messages.next()).objectValue?["id"] == "init")
        try await peer.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))

        let answered = Inbox()
        let roots = Task {
            for root in try await server.listRoots() { await answered.add(.string(root.uri)) }
        }
        let request = try decode(try await messages.next())
        #expect(request.objectValue?["method"] == .string(ListRoots.name))
        let id = try #require(request.objectValue?["id"])
        let answer = Value.array([
            ["jsonrpc": "2.0", "id": id, "result": ["roots": [["uri": "file:///work", "name": "work"]]]],
            ["jsonrpc": "2.0", "id": "sentinel", "method": "ping"],
        ])
        try await peer.send(try JSONEncoder().encode(answer))

        // The batch's only reply answers the ping.
        let reply = try #require(try decode(try await messages.next()).arrayValue)
        #expect(reply.count == 1)
        #expect(reply.first?.objectValue?["id"] == "sentinel")
        let deadline = ContinuousClock.now + .seconds(5)
        while await answered.values.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await answered.values == ["file:///work"])
        await peer.disconnect()
        // Fails a listRoots call still waiting.
        await server.stop()
        _ = await roots.result
    }
}

@Suite("Request ids over the stateless HTTP transport", .timeLimit(.minutes(1)))
struct StatelessHTTPRequestIDTests {
    private func post(_ body: String, headers extra: [String: String] = [:]) async throws -> HTTPResponse {
        let server = await makeServer()
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        var headers = [
            "Content-Type": "application/json", "Accept": "application/json",
            HTTPHeaderName.protocolVersion: "2025-11-25",
        ]
        headers.merge(extra) { $1 }
        let response = await transport.handleRequest(
            HTTPRequest(method: "POST", headers: headers, body: Data(body.utf8)))
        await server.stop()
        return response
    }

    @Test("A valid id is echoed", arguments: validIDs.indices)
    func validID(_ index: Int) async throws {
        let (json, echo) = validIDs[index]
        let response = try await post(#"{"jsonrpc":"2.0","id":\#(json),"method":"tools/list"}"#)
        #expect(response.statusCode == 200)
        let body = try decode(response.bodyData)
        #expect(body.objectValue?["id"] == echo)
        #expect(body.objectValue?["result"] != nil)
    }

    @Test("An empty string id is served at 2026-07-28")
    func emptyStringStateless() async throws {
        let body =
            #"{"jsonrpc":"2.0","id":"","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        let response = try await post(
            body, headers: [HTTPHeaderName.protocolVersion: "2026-07-28", MCPRequestHeaders.method: "tools/list"])
        #expect(response.statusCode == 200)
        #expect(try decode(response.bodyData).objectValue?["id"] == "")
    }

    @Test("An invalid id gets 400 and -32600 with a null id", arguments: invalidIDs)
    func invalidID(_ json: String) async throws {
        let response = try await post(#"{"jsonrpc":"2.0","id":\#(json),"method":"tools/list"}"#)
        #expect(response.statusCode == 400)
        let body = try decode(response.bodyData)
        #expect(body.objectValue?["id"] == .null)
        #expect(body.objectValue?["error"]?.objectValue?["code"] == -32600)
    }

    @Test("An invalid jsonrpc gets 400 and -32600", arguments: invalidVersions)
    func invalidVersion(_ body: String) async throws {
        let response = try await post(body)
        #expect(response.statusCode == 400)
        let decoded = try decode(response.bodyData)
        #expect(decoded.objectValue?["id"] == 1)
        #expect(decoded.objectValue?["error"]?.objectValue?["code"] == -32600)
    }

    @Test("No jsonrpc and a null id gets 400, not 202")
    func noVersionNullID() async throws {
        let response = try await post(#"{"id":null,"method":"tools/list"}"#)
        #expect(response.statusCode == 400)
        #expect(try decode(response.bodyData).objectValue?["error"]?.objectValue?["code"] == -32600)
    }
}

@Suite("Request ids over the stateful HTTP transport")
struct StatefulHTTPRequestIDTests {
    @Test("An invalid id gets 400 and -32600 with a null id", arguments: invalidIDs)
    func invalidID(_ json: String) async throws {
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: []))
        try await transport.connect()
        let response = await transport.handleRequest(
            HTTPRequest(
                method: "POST",
                headers: ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"],
                body: Data(#"{"jsonrpc":"2.0","id":\#(json),"method":"tools/list"}"#.utf8)))
        #expect(response.statusCode == 400)
        let body = try decode(response.bodyData)
        #expect(body.objectValue?["id"] == .null)
        #expect(body.objectValue?["error"]?.objectValue?["code"] == -32600)
        await transport.disconnect()
    }

    @Test("An invalid jsonrpc gets 400 and -32600 with the request's id", arguments: invalidVersions)
    func invalidVersion(_ line: String) async throws {
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: []))
        try await transport.connect()
        let response = await transport.handleRequest(
            HTTPRequest(
                method: "POST",
                headers: ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"],
                body: Data(line.utf8)))
        #expect(response.statusCode == 400)
        let body = try decode(response.bodyData)
        #expect(body.objectValue?["id"] == 1)
        #expect(body.objectValue?["error"]?.objectValue?["code"] == -32600)
        await transport.disconnect()
    }

    @Test("A cancellation names a request by the id its classification reads", arguments: validIDs.indices)
    func cancelledIDMatchesRequestID(_ index: Int) throws {
        let json = validIDs[index].json
        guard case .request(let requested, _)? = JSONRPCMessageKind(
            data: Data(#"{"jsonrpc":"2.0","id":\#(json),"method":"tools/list"}"#.utf8))
        else {
            Issue.record("not a request")
            return
        }
        let cancelled = JSONRPCMessageKind.cancelledRequestID(
            in: Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(json)}}"#.utf8))
        #expect(cancelled == requested)
    }

    @Test("Classification by the presence of id, not its type")
    func classification() {
        func kind(_ json: String) -> JSONRPCMessageKind? { JSONRPCMessageKind(data: Data(json.utf8)) }
        if case .notification? = kind(#"{"jsonrpc":"2.0","method":"m"}"#) {} else { Issue.record("notification") }
        if case .request(let id, _)? = kind(#"{"jsonrpc":"2.0","id":"","method":"m"}"#) {
            #expect(id == "")
        } else {
            Issue.record("empty string id")
        }
        for id in invalidIDs {
            if case .invalid? = kind(#"{"jsonrpc":"2.0","id":\#(id),"method":"m"}"#) {} else { Issue.record("\(id)") }
        }
        if case .invalid? = kind(#"{"id":1,"method":"m"}"#) {} else { Issue.record("no jsonrpc") }
    }
}
