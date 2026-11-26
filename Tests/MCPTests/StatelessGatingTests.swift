import Foundation
import Testing

@testable import MCP

// Gating stateless requests (2026-07-28), the versions a server serves,
// error text sent to peers, and the stateful and stateless HTTP transports'
// handling of requests that do not belong to them.

private let meta =
    #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"NAME","version":"1"}}"#

private func call(id: Int, client: String = "c") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo",\#(meta.replacingOccurrences(of: "NAME", with: client))}}"#
}

private actor Calls {
    var count = 0
    var clients: [String?] = []
    func record(_ client: String?) {
        count += 1
        clients.append(client)
    }
}

private func makeServer(_ calls: Calls, configuration: Server.Configuration = .default) async -> Server {
    let server = Server(
        name: "gated", version: "1", capabilities: .init(tools: .init()), configuration: configuration)
    await server.withMethodHandler(CallTool.self) { _ in
        await calls.record(Server.currentHandlerContext?.clientInfo?.name)
        return .init(content: [])
    }
    return server
}

/// Sends `message` through `transport` and returns the next reply.
private func exchange(_ transport: MockTransport, _ message: String) async throws -> Value {
    let before = await transport.sentData.count
    await transport.queue(data: Data(message.utf8))
    let deadline = ContinuousClock.now + .seconds(30)
    while await transport.sentData.count <= before {
        guard ContinuousClock.now < deadline else {
            Issue.record("No reply to \(message)")
            return .null
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    return try JSONDecoder().decode(Value.self, from: await transport.sentData[before])
}

@Suite("Stateless request gating")
struct StatelessGatingTests {
    @Test("An initialize hook without a stateless hook refuses stateless requests with -32022")
    func initializeHookRefusesStateless() async throws {
        let calls = Calls()
        let server = await makeServer(calls)
        let transport = MockTransport()
        try await server.start(transport: transport) { _, _ in
            throw MCPError.invalidRequest("This client is not allowed")
        }
        defer { Task { await server.stop() } }

        let reply = try await exchange(transport, call(id: 1))
        expectWire(
            reply,
            matches: try wireJSON(
                #"{"id":1,"error":{"code":-32022,"data":{"supported":["2025-11-25","2025-06-18","2025-03-26","2024-11-05"],"requested":"2026-07-28"}}}"#
            ))
        let discover = try await exchange(
            transport,
            #"{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{\#(meta)}}"#)
        expectWire(discover, matches: try wireJSON(#"{"id":2,"error":{"code":-32022}}"#))
        #expect(await calls.count == 0)
    }

    @Test("A stateless hook runs before each stateless request and can refuse it")
    func statelessHookGates() async throws {
        let calls = Calls()
        let server = await makeServer(calls)
        let transport = MockTransport()
        try await server.start(
            transport: transport,
            initializeHook: { _, _ in },
            statelessRequestHook: { info, _ in
                guard info?.name == "allowed" else { throw MCPError.invalidRequest("This client is not allowed") }
                #expect(Server.currentHandlerContext?.isStateless == true)
            })
        defer { Task { await server.stop() } }

        let refused = try await exchange(transport, call(id: 3, client: "other"))
        expectWire(refused, matches: try wireJSON(#"{"id":3,"error":{"code":-32600}}"#))
        #expect(refused.objectValue?["error"]?.objectValue?["message"]?.stringValue?.contains("not allowed") == true)
        let allowed = try await exchange(transport, call(id: 4, client: "allowed"))
        expectWire(allowed, matches: try wireJSON(#"{"id":4,"result":{"content":[]}}"#))
        #expect(await calls.clients == ["allowed"])
    }

    @Test("Without hooks stateless requests are served")
    func servedWithoutHooks() async throws {
        let calls = Calls()
        let server = await makeServer(calls, configuration: .strict)
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let reply = try await exchange(transport, call(id: 5))
        expectWire(reply, matches: try wireJSON(#"{"id":5,"result":{}}"#))
        #expect(await calls.count == 1)
    }

    @Test("A handshake revision in _meta that the server does not serve is -32022")
    func unservedHandshakeRevision() async throws {
        let calls = Calls()
        let server = await makeServer(
            calls, configuration: .init(protocolVersions: ["2026-07-28", "2025-11-25"]))
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let reply = try await exchange(
            transport,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18"}}}"#
        )
        expectWire(reply, matches: try wireJSON(#"{"id":6,"error":{"code":-32022,"data":{"requested":"2025-06-18"}}}"#))
    }

    @Test("A server without handshake revisions refuses initialize and handshake requests")
    func noHandshakeRevisions() async throws {
        let calls = Calls()
        let server = await makeServer(calls, configuration: .init(protocolVersions: ["2026-07-28"]))
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let initialize = try await exchange(
            transport,
            #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        )
        expectWire(initialize, matches: try wireJSON(#"{"id":7,"error":{"code":-32022}}"#))
        let handshake = try await exchange(
            transport,
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"echo","_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25"}}}"#
        )
        expectWire(handshake, matches: try wireJSON(#"{"id":8,"error":{"code":-32022}}"#))
        #expect(await calls.count == 0)
    }

    @Test(
        "A server without handshake revisions answers a request without a _meta version with -32602",
        arguments: [
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/clientCapabilities":{}}}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"echo"}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"subscriptions/listen","params":{"notifications":{}}}"#,
        ])
    func missingMetaVersion(_ message: String) async throws {
        let calls = Calls()
        let server = await makeServer(calls, configuration: .init(protocolVersions: ["2026-07-28"]))
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let reply = try await exchange(transport, message)
        expectWire(
            reply,
            matches: try wireJSON(#"{"id":9,"error":{"code":-32602,"data":{"supported":["2026-07-28"]}}}"#))
        #expect(await calls.count == 0)
    }

    @Test("A dual-era server keeps reading a request without a _meta version as the handshake era")
    func missingMetaVersionDualEra() async throws {
        let calls = Calls()
        let server = await makeServer(calls)
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let discover = try await exchange(
            transport, #"{"jsonrpc":"2.0","id":10,"method":"server/discover","params":{}}"#)
        expectWire(discover, matches: try wireJSON(#"{"id":10,"error":{"code":-32601}}"#))
        let call = try await exchange(
            transport, #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"echo"}}"#)
        #expect(call.objectValue?["result"] != nil)
    }

    @Test(
        "The stateless HTTP transport lists the server's versions in -32022",
        arguments: ["2025-11-25", "2099-01-01"])
    func transportListsServedVersions(_ version: String) async throws {
        let calls = Calls()
        let server = await makeServer(calls, configuration: .init(protocolVersions: ["2026-07-28"]))
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            HTTPRequest(
                method: "POST",
                headers: [
                    "Content-Type": "application/json", "Accept": "application/json",
                    HTTPHeaderName.protocolVersion: version,
                ],
                body: Data(#"{"jsonrpc":"2.0","id":15,"method":"tools/list","params":{}}"#.utf8)))
        #expect(response.statusCode == 400)
        let body = try JSONDecoder().decode(Value.self, from: try #require(response.bodyData))
        let error = body.objectValue?["error"]?.objectValue
        #expect(error?["code"] == -32022)
        #expect(error?["data"]?.objectValue?["supported"] == ["2026-07-28"])
    }

    @Test("Over HTTP without a version header, a missing _meta version is 400 on a stateless-only server")
    func missingMetaVersionHTTP() async throws {
        let calls = Calls()
        let server = await makeServer(calls, configuration: .init(protocolVersions: ["2026-07-28"]))
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            HTTPRequest(
                method: "POST", headers: ["Content-Type": "application/json", "Accept": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}"#.utf8)))
        #expect(response.statusCode == 400)
        let body = try JSONDecoder().decode(Value.self, from: try #require(response.bodyData))
        expectWire(
            body, matches: try wireJSON(#"{"id":12,"error":{"code":-32602,"data":{"supported":["2026-07-28"]}}}"#))
    }

    @Test(
        "A progressToken that is not a string or an integer is -32602 in both eras",
        arguments: ["null", "true", "{}", "[]", "1.5"], [true, false])
    func invalidProgressToken(_ token: String, stateless: Bool) async throws {
        let calls = Calls()
        let server = await makeServer(calls)
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let envelope =
            stateless
            ? #","io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}"#
            : ""
        let reply = try await exchange(
            transport,
            #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"echo","_meta":{"progressToken":\#(token)\#(envelope)}}}"#
        )
        expectWire(reply, matches: try wireJSON(#"{"id":13,"error":{"code":-32602}}"#))
        #expect(await calls.count == 0)
    }

    @Test("A string or integer progressToken is served", arguments: [#""t""#, "7"])
    func validProgressToken(_ token: String) async throws {
        let calls = Calls()
        let server = await makeServer(calls)
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let reply = try await exchange(
            transport,
            #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"echo","_meta":{"progressToken":\#(token)}}}"#
        )
        #expect(reply.objectValue?["result"] != nil)
        #expect(await calls.count == 1)
    }

    @Test("Undecodable parameters name the member, not Swift types")
    func decodingErrorsAreSanitized() async throws {
        let calls = Calls()
        let server = await makeServer(calls)
        let transport = MockTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let reply = try await exchange(
            transport, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"arguments":{}}}"#)
        let message = try #require(reply.objectValue?["error"]?.objectValue?["message"]?.stringValue)
        #expect(message == "Invalid params: Invalid params for tools/call: missing params.name")
        for leaked in ["CodingKeys", "Swift", "Parameters", "debugDescription"] {
            #expect(!message.contains(leaked))
        }
        let typed = try await exchange(
            transport, #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":7}}"#)
        #expect(
            typed.objectValue?["error"]?.objectValue?["message"]?.stringValue
                == "Invalid params: Invalid params for tools/call: wrong type at params.name")
    }

    @Test("A server/discover result with unknown cache hints still decodes")
    func lenientDiscoverResult() throws {
        let json = #"{"supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":"x","cacheScope":"team"}"#
        let result = try JSONDecoder().decode(ServerDiscover.Result.self, from: Data(json.utf8))
        #expect(result.ttlMs == nil)
        #expect(result.cacheScope == "team")
    }
}

// MARK: - HTTP

private func post(
    _ body: String, sessionID: String? = nil, version: String? = nil, origin: String? = nil,
    accept: String = "application/json, text/event-stream", authorization: String? = nil
) -> HTTPRequest {
    var headers = ["Content-Type": "application/json", "Accept": accept]
    if let sessionID { headers[HTTPHeaderName.sessionID] = sessionID }
    if let version {
        headers[HTTPHeaderName.protocolVersion] = version
        // The standard request headers of 2026-07-28 (SEP-2243).
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
            let method = object["method"] as? String
        {
            headers["Mcp-Method"] = method
            if let name = (object["params"] as? [String: Any])?["name"] as? String {
                headers["Mcp-Name"] = name
            }
        }
    }
    if let origin { headers["Origin"] = origin }
    if let authorization { headers[HTTPHeaderName.authorization] = authorization }
    return HTTPRequest(method: "POST", headers: headers, body: Data(body.utf8), path: "/mcp")
}

private func json(_ response: HTTPResponse) throws -> Value {
    try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
}

private let initialize =
    #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#

/// The next message the transport hands to the server; fails after two seconds.
private func nextIncoming(_ iterator: inout AsyncThrowingStream<Data, Swift.Error>.Iterator) async throws -> Value {
    let timeout = Task {
        try await Task.sleep(for: .seconds(2))
        Issue.record("No message reached the server")
    }
    defer { timeout.cancel() }
    let data = try #require(try await iterator.next())
    return try JSONDecoder().decode(Value.self, from: data)
}

/// The result of `task`, or `nil` with a recorded issue when it has not
/// finished after 30 seconds (the task is then cancelled).
private func resultInTime<T: Sendable, Failure: Error>(
    of task: Task<T, Failure>
) async -> Result<T, Failure>? {
    let timer = Task { () -> Bool in
        guard (try? await Task.sleep(for: .seconds(30))) != nil else { return false }
        task.cancel()
        return true
    }
    let result = await task.result
    timer.cancel()
    if await timer.value {
        Issue.record("Not finished within 30 seconds")
        return nil
    }
    return result
}

private actor CancellationObserved {
    var didStart = false
    var didCancel = false
    func started() { didStart = true }
    func cancelled() { didCancel = true }
}

/// Waits up to 30 seconds for `condition`.
private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Condition not met within 30 seconds")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Answers every request with 418 and the context's supported versions, newest first.
private struct SupportedVersionsEcho: HTTPRequestValidator {
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        .data(Data(context.supportedProtocolVersions.sorted(by: >).joined(separator: ",").utf8), statusCode: 418)
    }
}

@Suite("Stateful transport and stateless requests")
struct StatefulStatelessBoundaryTests {
    @Test("A stateless version in _meta alone is -32022 on a session")
    func metaOnlyStatelessVersion() async throws {
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: []))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let initResponse = await transport.handleRequest(post(initialize))
        let sessionID = try #require(initResponse.headers[HTTPHeaderName.sessionID])
        _ = try await nextIncoming(&incoming)

        let response = await transport.handleRequest(
            post(call(id: 1), sessionID: sessionID, version: "2025-11-25"))
        #expect(response.statusCode == 400)
        expectWire(try json(response), matches: try wireJSON(#"{"id":1,"error":{"code":-32022}}"#))
        #expect(response.headers[HTTPHeaderName.sessionID] == sessionID)

        // A requester that does not hold the session does not learn it.
        let stranger = await transport.handleRequest(post(call(id: 2), version: "2026-07-28"))
        #expect(stranger.statusCode == 400)
        #expect(stranger.headers[HTTPHeaderName.sessionID] == nil)
    }

    @Test("An empty _meta version on a session reaches the server and is -32602")
    func emptyMetaVersion() async throws {
        let server = Server(name: "empty", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: []))
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let initResponse = await transport.handleRequest(post(initialize))
        let sessionID = try #require(initResponse.headers[HTTPHeaderName.sessionID])

        let body =
            #"{"jsonrpc":"2.0","id":"e","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        let response = await transport.handleRequest(post(body, sessionID: sessionID, version: "2025-11-25"))
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected the request to reach the server, got \(response.statusCode)")
            return
        }
        let reply = Task { () throws -> String in
            var text = ""
            for try await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains(#""id":"e""#) { break }
            }
            return text
        }
        let text = try #require(await resultInTime(of: reply)).get()
        let line = try #require(text.split(separator: "\n").first { $0.contains(#""id":"e""#) })
        let message = try JSONDecoder().decode(Value.self, from: Data(line.dropFirst("data: ".count).utf8))
        expectWire(message, matches: try wireJSON(#"{"id":"e","error":{"code":-32602}}"#))
    }

    @Test("A stateless request still goes through the origin check")
    func statelessRequestIsValidated() async throws {
        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [OriginValidator.localhost()]))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let response = await transport.handleRequest(
            post(call(id: 3), version: "2026-07-28", origin: "https://attacker.example"))
        #expect(response.statusCode == 403)
    }

    @Test("A stateless request is validated against the handshake revisions")
    func statelessRequestContextVersions() async throws {
        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [SupportedVersionsEcho()]))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let response = await transport.handleRequest(post(call(id: 4), version: "2026-07-28"))
        #expect(response.statusCode == 418)
        let echoed = response.bodyData.map { String(decoding: $0, as: UTF8.self) }
        #expect(echoed == Version.handshake.joined(separator: ","))
    }

    @Test("A refused initialize leaves no session")
    func refusedInitializeDropsSession() async throws {
        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [SessionValidator()]))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let first = await transport.handleRequest(post(initialize))
        let sessionID = try #require(first.headers[HTTPHeaderName.sessionID])
        _ = try await nextIncoming(&incoming)
        try await transport.send(
            Data(#"{"jsonrpc":"2.0","id":"init","error":{"code":-32600,"message":"This client is not allowed"}}"#.utf8))

        let after = await transport.handleRequest(
            post(#"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}}"#, sessionID: sessionID))
        #expect(after.statusCode == 400)

        let again = await transport.handleRequest(post(initialize))
        #expect(again.statusCode == 200)
        #expect(again.headers[HTTPHeaderName.sessionID] != nil)
        #expect(again.headers[HTTPHeaderName.sessionID] != sessionID)
    }
}

@Suite("Stateless transport exchanges")
struct StatelessTransportExchangeTests {
    private func makeTransport(_ validators: [any HTTPRequestValidator] = []) async throws
        -> StatelessHTTPServerTransport
    {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: validators))
        try await transport.connect()
        return transport
    }

    @Test("notifications/cancelled reaches the request with the same id and Authorization")
    func cancellationNeedsMatchingAuthorization() async throws {
        let transport = try await makeTransport()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let pending = Task { await transport.handleRequest(post(call(id: 1), version: "2026-07-28", authorization: "Bearer a")) }
        let forwarded = try await nextIncoming(&incoming)
        let internalID = try #require(forwarded.objectValue?["id"]?.stringValue)

        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        // Another client, and an unauthenticated one, cannot cancel it.
        #expect(await transport.handleRequest(post(cancel, authorization: "Bearer b")).statusCode == 202)
        #expect(await transport.handleRequest(post(cancel)).statusCode == 202)
        #expect(await transport.handleRequest(post(cancel, authorization: "Bearer a")).statusCode == 202)

        let delivered = try await nextIncoming(&incoming)
        #expect(delivered.objectValue?["method"]?.stringValue == "notifications/cancelled")
        #expect(delivered.objectValue?["params"]?.objectValue?["requestId"]?.stringValue == internalID)
        pending.cancel()
    }

    @Test("Cancelling a pending JSON reply cancels the request in the server")
    func adapterCancellationAbandonsRequest() async throws {
        let transport = try await makeTransport()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let pending = Task {
            await transport.handleRequest(post(call(id: 2), version: "2026-07-28", accept: "application/json"))
        }
        let forwarded = try await nextIncoming(&incoming)
        let internalID = try #require(forwarded.objectValue?["id"]?.stringValue)
        pending.cancel()

        let cancelled = try await nextIncoming(&incoming)
        #expect(cancelled.objectValue?["params"]?.objectValue?["requestId"]?.stringValue == internalID)
        #expect(await pending.value.statusCode == 503)
    }

    @Test("An honored notifications/cancelled ends a JSON exchange with 202")
    func cancellationEndsJSONExchange() async throws {
        let transport = try await makeTransport()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let pending = Task {
            await transport.handleRequest(
                post(call(id: 4), version: "2026-07-28", accept: "application/json", authorization: "Bearer a"))
        }
        let forwarded = try await nextIncoming(&incoming)
        let internalID = try #require(forwarded.objectValue?["id"]?.stringValue)

        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":4}}"#
        #expect(await transport.handleRequest(post(cancel, authorization: "Bearer a")).statusCode == 202)
        let response = try #require(await resultInTime(of: pending)).get()
        #expect(response.statusCode == 202)
        #expect(response.bodyData == nil)

        // The server is told once; a late response for the request is dropped.
        let delivered = try await nextIncoming(&incoming)
        #expect(delivered.objectValue?["params"]?.objectValue?["requestId"]?.stringValue == internalID)
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":"\#(internalID)","result":{"content":[]}}"#.utf8))
    }

    @Test("An honored notifications/cancelled ends an SSE exchange's stream normally")
    func cancellationEndsSSEExchange() async throws {
        let transport = try await makeTransport()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let pending = Task {
            await transport.handleRequest(post(call(id: 5), version: "2026-07-28", authorization: "Bearer a"))
        }
        let forwarded = try await nextIncoming(&incoming)
        let internalID = try #require(forwarded.objectValue?["id"]?.stringValue)
        try await transport.send(
            Data(#"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"x"}}"#.utf8),
            relatedRequestID: .string(internalID))
        guard case .stream(let stream, _) = await pending.value else {
            Issue.record("Expected an SSE stream")
            return
        }

        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#
        #expect(await transport.handleRequest(post(cancel, authorization: "Bearer a")).statusCode == 202)
        let reader = Task {
            var text = ""
            for try await chunk in stream { text += String(decoding: chunk, as: UTF8.self) }
            return text
        }
        let text = try #require(await resultInTime(of: reader)).get()
        #expect(text.contains("notifications/message"))
        #expect(!text.contains(#""result""#))
    }

    @Test("notifications/cancelled matches the id by value, not by its text")
    func cancellationMatchesIDType() async throws {
        let transport = try await makeTransport()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let number = Task { await transport.handleRequest(post(call(id: 1), version: "2026-07-28", authorization: "Bearer a")) }
        let numberID = try #require(try await nextIncoming(&incoming).objectValue?["id"]?.stringValue)
        let string = Task {
            await transport.handleRequest(
                post(call(id: 1).replacingOccurrences(of: #""id":1"#, with: #""id":"1""#),
                    version: "2026-07-28", authorization: "Bearer a"))
        }
        let stringID = try #require(try await nextIncoming(&incoming).objectValue?["id"]?.stringValue)
        defer {
            number.cancel()
            string.cancel()
        }

        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        #expect(await transport.handleRequest(post(cancel, authorization: "Bearer a")).statusCode == 202)
        #expect(try #require(await resultInTime(of: number)).get().statusCode == 202)
        let delivered = try await nextIncoming(&incoming)
        #expect(delivered.objectValue?["params"]?.objectValue?["requestId"]?.stringValue == numberID)
        #expect(numberID != stringID)
    }

    @Test("A request cancelled with notifications/cancelled stops its handler and returns")
    func cancellationStopsHandler() async throws {
        let observed = CancellationObserved()
        let server = Server(name: "cancel", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            await observed.started()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await observed.cancelled()
                throw error
            }
            return .init(content: [])
        }
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []))
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let pending = Task {
            await transport.handleRequest(
                post(call(id: 6), version: "2026-07-28", accept: "application/json", authorization: "Bearer a"))
        }
        try await waitUntil { await observed.didStart }
        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":6}}"#
        #expect(await transport.handleRequest(post(cancel, authorization: "Bearer a")).statusCode == 202)

        let response = try #require(await resultInTime(of: pending)).get()
        #expect(response.statusCode == 202)
        try await waitUntil { await observed.didCancel }
    }

    @Test("A slow client's stream keeps the newest messages and the response")
    func boundedBuffering() async throws {
        let transport = try await makeTransport()
        defer { Task { await transport.disconnect() } }
        var incoming = await transport.receive().makeAsyncIterator()

        let pending = Task { await transport.handleRequest(post(call(id: 3), version: "2026-07-28")) }
        let forwarded = try await nextIncoming(&incoming)
        let internalID = try #require(forwarded.objectValue?["id"]?.stringValue)
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"x"}}"#.utf8)
        try await transport.send(notification, relatedRequestID: .string(internalID))
        guard case .stream(let stream, _) = await pending.value else {
            Issue.record("Expected an SSE stream")
            return
        }
        for _ in 0..<3000 {
            try await transport.send(notification, relatedRequestID: .string(internalID))
        }
        try await transport.send(
            Data(#"{"jsonrpc":"2.0","id":"\#(internalID)","result":{"content":[]}}"#.utf8))

        var chunks: [String] = []
        for try await chunk in stream { chunks.append(String(decoding: chunk, as: UTF8.self)) }
        // Two bounded stages: the request's queue and the response stream.
        #expect(chunks.count <= 2 * StatelessHTTPServerTransport.maxBufferedMessages + 1)
        #expect(chunks.last?.contains(#""result""#) == true)
    }

    @Test("A GET answered by a validator is served; any other GET is 405")
    func getRunsAnsweringValidators() async throws {
        let prm = ProtectedResourceMetadataValidator(
            metadata: OAuthProtectedResourceServerMetadata(
                resource: "https://mcp.example.com/mcp",
                authorizationServers: [URL(string: "https://as.example.com")!]))
        let transport = try await makeTransport([prm])
        defer { Task { await transport.disconnect() } }

        let document = await transport.handleRequest(
            HTTPRequest(method: "GET", headers: [:], path: "/.well-known/oauth-protected-resource/mcp"))
        #expect(document.statusCode == 200)
        let other = await transport.handleRequest(HTTPRequest(method: "GET", headers: [:], path: "/mcp"))
        #expect(other.statusCode == 405)
    }
}

@Suite("Server configuration coding")
struct ServerConfigurationCodingTests {
    @Test("A configuration encoded before protocol versions still decodes")
    func decodesOldConfiguration() throws {
        let configuration = try JSONDecoder().decode(
            Server.Configuration.self, from: Data(#"{"strict":true}"#.utf8))
        #expect(configuration == Server.Configuration(strict: true))
    }

    @Test("A configuration round-trips")
    func roundTrips() throws {
        let configuration = Server.Configuration(
            strict: true, protocolVersions: Version.handshake,
            cacheHints: ["tools/list": CacheHint(ttlMs: 1000, scope: .public)],
            defaultCacheHint: CacheHint(ttlMs: 5, scope: .private))
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(Server.Configuration.self, from: data) == configuration)
    }
}
