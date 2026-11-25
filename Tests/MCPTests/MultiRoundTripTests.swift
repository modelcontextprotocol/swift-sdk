import Foundation
import Testing

@testable import MCP

// MARK: - Helpers

/// A server with a `confirm` tool that asks for a confirmation, a `rounds`
/// tool that asks twice, and a `prompt` prompt that asks for a topic.
private func makeRoundTripServer(
    protection: RequestStateProtection? = .ephemeral(),
    calls: Counter = Counter()
) async -> Server {
    let server = Server(
        name: "mrtr", version: "1.0",
        capabilities: .init(prompts: .init(), resources: .init(), tools: .init()),
        requestStateProtection: protection)
    await server.withMethodHandler(CallTool.self) { params in
        await calls.increment()
        let responses = params.inputResponses ?? [:]
        switch params.name {
        case "confirm":
            guard let answer = responses["confirm"]?.elicitation else {
                return .inputRequired(
                    ["confirm": .elicitation(message: "Proceed?")], requestState: "pending:\(params.name)")
            }
            return .init(content: [.text(text: "\(answer.action.rawValue) \(params.requestState ?? "-")")])
        case "rounds":
            if params.requestState == "two", let root = responses["roots"]?.roots?.first {
                return .init(content: [.text(text: "root \(root.uri)")])
            }
            if params.requestState == "one", responses["model"]?.sampling != nil {
                return .inputRequired(["roots": .listRoots], requestState: "two")
            }
            return .inputRequired(
                ["model": .sampling(.init(messages: [.user(.text("Hi"))], maxTokens: 10))], requestState: "one")
        case "both":
            var result = CallTool.Result(content: [.text(text: "done")])
            result.inputRequests = ["confirm": .elicitation(message: "Proceed?")]
            return result
        case "forever":
            return .inputRequired(requestState: "again")
        case "empty":
            return .inputRequired([:])
        default:
            throw MCPError.invalidParams("Unknown tool \(params.name)")
        }
    }
    await server.withMethodHandler(GetPrompt.self) { params in
        guard let topic = params.inputResponses?["topic"]?.elicitation?.content?["topic"]?.stringValue else {
            return .inputRequired(["topic": .elicitation(message: "Topic?")])
        }
        return .init(messages: [.user(.text(text: "About \(topic)"))])
    }
    await server.withMethodHandler(ReadResource.self) { params in
        guard params.inputResponses?["ok"]?.elicitation?.action == .accept else {
            return .inputRequired(["ok": .elicitation(message: "Read \(params.uri)?")])
        }
        return .init(contents: [.text("secret", uri: params.uri)])
    }
    return server
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Recorder<Element: Sendable> {
    private(set) var values: [Element] = []
    func record(_ value: Element) { values.append(value) }
}

/// A client method the SDK does not know, asked for as an input request.
private enum Approve: MCP.Method {
    static let name = "example/approve"

    struct Parameters: Hashable, Codable, Sendable {
        let taskId: String
        let src: String
    }

    typealias Result = Value
}

private func connect(
    _ server: Server,
    mode: Client.ProtocolMode = .automatic,
    capabilities: Client.Capabilities = .init(sampling: .init(), elicitation: .init(), roots: .init()),
    multiRoundTrip: Client.Configuration.MultiRoundTrip = .init(),
    configure: (Client) async -> Void = { _ in }
) async throws -> Client {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(
        name: "probe", version: "1.0", capabilities: capabilities,
        configuration: .init(protocolMode: mode, multiRoundTrip: multiRoundTrip))
    await configure(client)
    try await client.connect(transport: clientTransport)
    return client
}

/// Registers handlers that answer every input request.
@available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
private func answerEverything(_ client: Client, elicitations: Counter = Counter()) async {
    await client.withElicitationHandler { _ in
        await elicitations.increment()
        return .init(action: .accept, content: ["topic": "swift"])
    }
    await client.withSamplingHandler { _ in
        .init(model: "test", role: .assistant, content: .text("Hello"))
    }
    await client.withRootsHandler { [Root(uri: "file:///work", name: "work")] }
}

private func text(_ result: CallTool.Result) -> String? {
    if case .text(let text, _, _)? = result.content.first { return text }
    return nil
}

// MARK: - Wire format

@Suite("Multi Round-Trip Wire Format")
struct MultiRoundTripWireTests {
    @Test("Input requests encode as method and params")
    func testInputRequestCoding() throws {
        let requests: [String: InputRequest] = [
            "name": .elicitation(message: "Name?"),
            "model": .sampling(.init(messages: [.user(.text("Hi"))], maxTokens: 5)),
            "roots": .listRoots,
        ]
        let value = try Value(requests)
        #expect(value.objectValue?["name"]?.objectValue?["method"] == "elicitation/create")
        #expect(value.objectValue?["model"]?.objectValue?["method"] == "sampling/createMessage")
        #expect(value.objectValue?["roots"] == ["method": "roots/list", "params": [:]])
        #expect(try [String: InputRequest](decoding: value) == requests)

        // A method the SDK does not know as an input request is kept.
        #expect(
            try InputRequest(decoding: ["method": "tools/call", "params": [:]])
                == .unknown(method: "tools/call", params: [:]))
    }

    @Test("Input responses decode by shape")
    func testInputResponseShapes() throws {
        let responses = try [String: InputResponse](
            decoding: [
                "a": ["action": "accept", "content": ["name": "Ada"]],
                "b": ["role": "assistant", "content": ["type": "text", "text": "Hi"], "model": "m"],
                "c": ["roots": [["uri": "file:///x"]]],
            ])
        #expect(responses["a"]?.elicitation?.content?["name"] == "Ada")
        #expect(responses["b"]?.sampling?.model == "m")
        #expect(responses["c"]?.roots?.first?.uri == "file:///x")
        // Plain results on the wire.
        #expect(try Value(responses["a"]!) == ["action": "accept", "content": ["name": "Ada"]])
    }

    @Test("Input-required results carry resultType and no content")
    func testInputRequiredResultCoding() throws {
        let result = CallTool.Result.inputRequired(["x": .listRoots], requestState: "s")
        #expect(result.resultType == .inputRequired)
        let value = try Value(result)
        #expect(
            value == [
                "resultType": "input_required", "inputRequests": ["x": ["method": "roots/list", "params": [:]]],
                "requestState": "s",
            ])
        let decoded = try CallTool.Result(decoding: value)
        #expect(decoded == result)
        #expect(decoded.content.isEmpty)

        // A result without resultType is complete.
        let complete = try CallTool.Result(decoding: ["content": []])
        #expect(complete.resultType == .complete)
        #expect(try Value(complete).objectValue?["resultType"] == nil)
        #expect(try CallTool.Result(decoding: ["resultType": "complete", "content": []]) == CallTool.Result())

        let prompt = try GetPrompt.Result(decoding: ["resultType": "input_required", "requestState": "p"])
        #expect(prompt.resultType == .inputRequired && prompt.messages.isEmpty)
        let resource = try ReadResource.Result(decoding: ["resultType": "input_required"])
        #expect(resource.resultType == .inputRequired && resource.inputRequests == nil)
    }

    @Test("Params carry inputResponses and requestState; null responses are rejected")
    func testParameterCoding() throws {
        let params = CallTool.Parameters(
            name: "t", inputResponses: ["a": .elicitation(.init(action: .decline))], requestState: "s")
        let value = try Value(params)
        #expect(value.objectValue?["inputResponses"] == ["a": ["action": "decline"]])
        #expect(value.objectValue?["requestState"] == "s")
        #expect(try CallTool.Parameters(decoding: value) == params)

        #expect(throws: DecodingError.self) {
            try CallTool.Parameters(decoding: ["name": "t", "inputResponses": .null])
        }
        #expect(throws: DecodingError.self) {
            try GetPrompt.Parameters(decoding: ["name": "p", "inputResponses": ["a": 1]])
        }
    }
}

// MARK: - Request state

@Suite("Request State Protection")
struct RequestStateTests {
    private let key = Data(repeating: 7, count: 32)
    private let other = Data(repeating: 9, count: 32)

    @Test("The AES-GCM codec round-trips and rejects modified tokens")
    func testCodec() throws {
        let codec = try AESGCMRequestStateCodec(keys: [key])
        let token = try codec.seal(Data("hello".utf8))
        #expect(token.hasPrefix("v1."))
        #expect(!token.contains("hello"))
        #expect(try codec.unseal(token) == Data("hello".utf8))
        #expect(try codec.seal(Data("hello".utf8)) != token)

        var tampered = Array(token)
        tampered[tampered.count - 3] = tampered[tampered.count - 3] == "A" ? "B" : "A"
        #expect(throws: InvalidRequestState.self) { try codec.unseal(String(tampered)) }
        #expect(throws: InvalidRequestState.self) { try codec.unseal(token + "-TAMPERED") }
        #expect(throws: InvalidRequestState.self) { try codec.unseal("v2." + token.dropFirst(3)) }
        #expect(throws: InvalidRequestState.self) { try codec.unseal("garbage") }
    }

    @Test("Keys rotate: every key unseals, the first seals")
    func testRotation() throws {
        let old = try AESGCMRequestStateCodec(keys: [key])
        let token = try old.seal(Data("x".utf8))
        let rotated = try AESGCMRequestStateCodec(keys: [other, key])
        #expect(try rotated.unseal(token) == Data("x".utf8))
        let retired = try AESGCMRequestStateCodec(keys: [other])
        #expect(throws: InvalidRequestState.self) { try retired.unseal(token) }
        #expect(try old.unseal(try AESGCMRequestStateCodec(keys: [key, other]).seal(Data("y".utf8))) == Data("y".utf8))

        #expect(throws: MCPError.self) { try AESGCMRequestStateCodec(keys: []) }
        #expect(throws: MCPError.self) { try AESGCMRequestStateCodec(keys: [Data(count: 16)]) }
        #expect(throws: MCPError.self) { try AESGCMRequestStateCodec(keys: [key, key]) }
    }

    @Test("Sealed state is bound to the request, the time window, the audience and the principal")
    func testBindings() throws {
        let principal: @Sendable (Server.HandlerContext) -> String? = { $0.clientInfo?.name }
        let protection = try RequestStateProtection(keys: [key], timeToLive: .seconds(60), principal: principal)
        let boundary = RequestStateBoundary(protection: protection, audience: "srv")
        let alice = Server.HandlerContext(id: 1, httpContext: nil, clientInfo: .init(name: "alice", version: "1"))
        let bob = Server.HandlerContext(id: 2, httpContext: nil, clientInfo: .init(name: "bob", version: "1"))
        func bound(_ target: String, _ arguments: Value) -> () -> RequestStateBoundary.Binding {
            { RequestStateBoundary.binding(target: target, arguments: arguments) }
        }
        let binding = bound("t", ["a": 1, "b": "x"])
        let now = Date()
        let token = try boundary.seal("state", method: CallTool.name, binding: binding(), context: alice, now: now)

        #expect(try boundary.unseal(token, method: CallTool.name, binding: binding, context: alice, now: now).state == "state")
        // Argument order does not matter.
        #expect(
            try boundary.unseal(token, method: CallTool.name, binding: bound("t", ["b": "x", "a": 1]), context: alice, now: now)
                .state == "state")

        func reason(_ body: () throws -> RequestStateBoundary.Verified) -> String? {
            do {
                _ = try body()
                return nil
            } catch {
                return (error as? InvalidRequestState)?.reason
            }
        }
        #expect(reason { try boundary.unseal(token, method: GetPrompt.name, binding: binding, context: alice, now: now) } == "request binding")
        #expect(reason { try boundary.unseal(token, method: CallTool.name, binding: bound("u", ["a": 1, "b": "x"]), context: alice, now: now) } == "request binding")
        #expect(reason { try boundary.unseal(token, method: CallTool.name, binding: bound("t", ["a": 2, "b": "x"]), context: alice, now: now) } == "request binding")
        #expect(reason { try boundary.unseal(token, method: CallTool.name, binding: binding, context: alice, now: now + 61) } == "expired")
        #expect(reason { try boundary.unseal(token, method: CallTool.name, binding: binding, context: alice, now: now - 120) } == "issued in the future")
        #expect(reason { try boundary.unseal(token, method: CallTool.name, binding: binding, context: bob, now: now) } == "principal")
        let elsewhere = RequestStateBoundary(protection: protection, audience: "other")
        #expect(reason { try elsewhere.unseal(token, method: CallTool.name, binding: binding, context: alice, now: now) } == "audience")
    }

    @Test("Each token has its own id and expiry; the binding is computed only for an authentic token")
    func testTokenIDs() throws {
        let boundary = RequestStateBoundary(protection: try RequestStateProtection(keys: [key]), audience: "srv")
        let binding = RequestStateBoundary.binding(target: "t", arguments: [:])
        let first = try boundary.unseal(
            try boundary.seal("s", method: CallTool.name, binding: binding, context: nil), method: CallTool.name,
            binding: { binding }, context: nil)
        let second = try boundary.unseal(
            try boundary.seal("s", method: CallTool.name, binding: binding, context: nil), method: CallTool.name,
            binding: { binding }, context: nil)
        #expect(first.tokenID != second.tokenID)
        #expect(first.expiry.timeIntervalSinceNow > 590)

        var computed = 0
        #expect(throws: InvalidRequestState.self) {
            try boundary.unseal("v1.garbage", method: CallTool.name, binding: {
                computed += 1
                return binding
            }, context: nil)
        }
        #expect(computed == 0)
    }
}

// MARK: - Server and client

@Suite("Multi Round-Trip Requests")
struct MultiRoundTripTests {
    @Test("The client fulfills input requests and retries until complete (2026-07-28)")
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func testClientLoop() async throws {
        let calls = Counter()
        let elicitations = Counter()
        let server = await makeRoundTripServer(calls: calls)
        let client = try await connect(server) { await answerEverything($0, elicitations: elicitations) }
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(await client.isStateless)

        let content = try await client.callTool(name: "confirm").content
        // The handler sees the plaintext state it wrote.
        #expect(content == [.text(text: "accept pending:confirm")])
        #expect(await calls.value == 2)
        #expect(await elicitations.value == 1)

        let rounds = try await client.send(CallTool.request(.init(name: "rounds"))).value
        #expect(text(rounds) == "root file:///work")
        #expect(await calls.value == 5)

        let prompt = try await client.getPrompt(name: "p")
        #expect(prompt.messages == [.user(.text(text: "About swift"))])
        let contents = try await client.readResource(uri: "test://doc").contents
        #expect(contents == [.text("secret", uri: "test://doc")])
    }

    @Test("The server seals requestState and rejects modified state")
    func testSealedState() async throws {
        let server = await makeRoundTripServer()
        let client = try await connect(server, multiRoundTrip: .init(isEnabled: false))
        defer { Task { await client.disconnect(); await server.stop() } }

        let first = try await client.send(CallTool.request(.init(name: "confirm"))).value
        #expect(first.resultType == .inputRequired)
        let sealed = try #require(first.requestState)
        #expect(sealed.hasPrefix("v1.") && !sealed.contains("pending"))
        #expect(first.inputRequests?["confirm"] == .elicitation(message: "Proceed?"))

        let answer: [String: InputResponse] = ["confirm": .elicitation(.init(action: .accept))]
        let second = try await client.send(
            CallTool.request(.init(name: "confirm", inputResponses: answer, requestState: sealed))
        ).value
        #expect(text(second) == "accept pending:confirm")

        for forged in [sealed + "x", "pending:confirm"] {
            await #expect(throws: MCPError.invalidParams("Invalid or expired requestState")) {
                _ = try await client.send(
                    CallTool.request(.init(name: "confirm", inputResponses: answer, requestState: forged))
                ).value
            }
        }
        // State minted for one tool fails for another.
        await #expect(throws: MCPError.invalidParams("Invalid or expired requestState")) {
            _ = try await client.send(
                CallTool.request(.init(name: "rounds", inputResponses: answer, requestState: sealed))
            ).value
        }
        // The convenience method does not hide an input-required result.
        await #expect(throws: MCPError.self) { _ = try await client.callTool(name: "confirm") }
    }

    @Test("Without protection the state crosses the wire as written")
    func testUnprotectedState() async throws {
        let server = await makeRoundTripServer(protection: nil)
        let client = try await connect(server, multiRoundTrip: .init(isEnabled: false))
        defer { Task { await client.disconnect(); await server.stop() } }
        let result = try await client.send(CallTool.request(.init(name: "confirm"))).value
        #expect(result.requestState == "pending:confirm")
    }

    @Test("Input requests the client cannot fulfill fail with -32021")
    func testMissingCapabilities() async throws {
        let server = await makeRoundTripServer()
        let client = try await connect(server, capabilities: .init(sampling: .init()))
        defer { Task { await client.disconnect(); await server.stop() } }
        do {
            _ = try await client.callTool(name: "confirm")
            Issue.record("Expected -32021")
        } catch let error as MCPError {
            #expect(error.code == -32021)
            #expect(error.data == ["requiredCapabilities": ["elicitation": ["form": [:]]]])
        }
    }

    @Test(
        "A form elicitation needs form elicitation: a URL-only client gets -32021, an empty declaration is form",
        arguments: [Client.ProtocolMode.automatic, .handshake])
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func testFormElicitationCapability(mode: Client.ProtocolMode) async throws {
        let server = await makeRoundTripServer()
        let urlOnly = try await connect(
            server, mode: mode, capabilities: .init(elicitation: .init(form: nil, url: .init()))
        ) { await answerEverything($0) }
        await #expect {
            _ = try await urlOnly.callTool(name: "confirm")
        } throws: { error in
            let error = error as? MCPError
            return error?.code == -32021
                && error?.data == ["requiredCapabilities": ["elicitation": ["form": [:]]]]
        }
        await urlOnly.disconnect()
        await server.stop()

        for elicitation in [Client.Capabilities.Elicitation(), .init(form: nil, url: nil), .init(url: .init())] {
            let server = await makeRoundTripServer()
            let client = try await connect(server, mode: mode, capabilities: .init(elicitation: elicitation)) {
                await answerEverything($0)
            }
            let content = try await client.callTool(name: "confirm").content
            #expect(content == [.text(text: "accept pending:confirm", annotations: nil, _meta: nil)], "\(elicitation)")
            await client.disconnect()
            await server.stop()
        }
    }

    /// A server whose `speak` tool asks for an elicitation of an unknown mode.
    private func makeUnknownModeServer() async -> Server {
        let server = Server(name: "mrtr", version: "1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { params in
            if params.inputResponses?["voice"] != nil {
                return .init(content: [.text(text: "answered", annotations: nil, _meta: nil)])
            }
            return .inputRequired(
                ["voice": .elicitation(.unknown(mode: .init(rawValue: "voice"), ["message": "Say it"]))],
                requestState: "s")
        }
        return server
    }

    @Test("An elicitation of an unknown mode needs only the elicitation capability")
    func testUnknownModeCapability() async throws {
        // A client without elicitation is told to declare it, with no sub-capability.
        let server = await makeUnknownModeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        try await clientEnd.connect()
        var incoming = await clientEnd.receive().makeAsyncIterator()
        func next() async throws -> Value { try JSONDecoder().decode(Value.self, from: try #require(try await incoming.next())) }
        try await clientEnd.send(
            Data(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{}},"clientInfo":{"name":"raw","version":"1"}}}"#
                    .utf8))
        _ = try await next()
        try await clientEnd.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await clientEnd.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"speak"}}"#.utf8))
        let error = try await next().objectValue?["error"]?.objectValue
        #expect(error?["code"] == -32021)
        #expect(error?["data"] == ["requiredCapabilities": ["elicitation": [:]]])
        await clientEnd.disconnect()
        await server.stop()
    }

    @Test(
        "An elicitation of an unknown mode reaches a client with only URL elicitation",
        arguments: [Client.ProtocolMode.automatic, .handshake])
    func testUnknownModeEndToEnd(mode: Client.ProtocolMode) async throws {
        let server = await makeUnknownModeServer()
        let client = try await connect(
            server, mode: mode, capabilities: .init(elicitation: .init(form: nil, url: .init()))
        ) {
            await $0.withElicitationHandler { _ in .init(action: .decline) }
        }
        let content = try await client.callTool(name: "speak").content
        #expect(content == [.text(text: "answered", annotations: nil, _meta: nil)])
        await client.disconnect()
        await server.stop()
    }

    @Test(
        "An input request of an unknown method reaches the client's handler for it, and its result the tool",
        arguments: [Client.ProtocolMode.automatic, .handshake])
    func testUnknownInputRequestEndToEnd(mode: Client.ProtocolMode) async throws {
        let server = Server(name: "mrtr", version: "1.0", capabilities: .init(tools: .init()))
        let request: Value = ["taskId": "t1", "src": "data:,hi"]
        let response: Value = ["approved": true, "note": "data:,ok"]
        await server.withMethodHandler(CallTool.self) { params in
            guard let answer = params.inputResponses?["approve"] else {
                return .inputRequired(["approve": .unknown(method: Approve.name, params: request)])
            }
            // The result reaches the tool as the client's handler returned it.
            return .init(content: [.text(text: answer == .unknown(response) ? "kept" : "\(answer)", annotations: nil, _meta: nil)])
        }
        let received = Recorder<Approve.Parameters>()
        let client = try await connect(server, mode: mode, capabilities: .init()) { client in
            await client.withMethodHandler(Approve.self) { params in
                await received.record(params)
                return response
            }
        }
        let content = try await client.callTool(name: "approve").content
        #expect(content == [.text(text: "kept", annotations: nil, _meta: nil)])
        #expect(await received.values == [.init(taskId: "t1", src: "data:,hi")])
        await client.disconnect()
        await server.stop()
    }

    @Test(
        "A data: URL string in a sampling prompt and its result is kept as written",
        arguments: [Client.ProtocolMode.automatic, .handshake])
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func testDataURLStringsInKnownKinds(mode: Client.ProtocolMode) async throws {
        let server = Server(name: "mrtr", version: "1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { params in
            guard let sampled = params.inputResponses?["model"]?.sampling else {
                return .inputRequired(["model": .sampling(.init(messages: [.user(.text("data:,hello"))], maxTokens: 10))])
            }
            guard case .single(.text(let text)) = sampled.content else { throw MCPError.internalError("Not text") }
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
        }
        let prompts = Recorder<Sampling.Message.Content>()
        let client = try await connect(server, mode: mode) { client in
            await client.withSamplingHandler { params in
                await prompts.record(params.messages[0].content)
                return .init(model: "test", role: .assistant, content: .text("data:,hi"))
            }
        }
        let content = try await client.callTool(name: "sample").content
        #expect(content == [.text(text: "data:,hi", annotations: nil, _meta: nil)])
        #expect(await prompts.values == [.text("data:,hello")])
        await client.disconnect()
        await server.stop()
    }

    @Test("A result with content and input requests is a server error")
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func testContentAndInput() async throws {
        let server = await makeRoundTripServer()
        let client = try await connect(server) { await answerEverything($0) }
        defer { Task { await client.disconnect(); await server.stop() } }
        await #expect(throws: MCPError.self) { _ = try await client.callTool(name: "both") }
        do {
            _ = try await client.callTool(name: "both")
        } catch let error as MCPError {
            #expect(error.code == -32603)
        }
    }

    @Test(
        "An input-required result with nothing to answer is a server error",
        arguments: [Client.ProtocolMode.automatic, .handshake])
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func testEmptyInputRequests(mode: Client.ProtocolMode) async throws {
        let calls = Counter()
        let server = await makeRoundTripServer(calls: calls)
        let client = try await connect(server, mode: mode) { await answerEverything($0) }
        defer { Task { await client.disconnect(); await server.stop() } }
        await #expect {
            _ = try await client.callTool(name: "empty")
        } throws: { error in
            (error as? MCPError)?.code == -32603
        }
        // Refused at once: no round is retried.
        #expect(await calls.value == 1)
    }

    @Test("The client gives up after the configured rounds")
    func testMaxRounds() async throws {
        let calls = Counter()
        let server = await makeRoundTripServer(calls: calls)
        let client = try await connect(server, multiRoundTrip: .init(maxRounds: 3))
        defer { Task { await client.disconnect(); await server.stop() } }
        await #expect(throws: MCPError.self) { _ = try await client.callTool(name: "forever") }
        #expect(await calls.value == 4)
    }

    @Test("A missing client handler fails the call")
    func testMissingHandler() async throws {
        let server = await makeRoundTripServer()
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }
        await #expect(throws: MCPError.methodNotFound("No handler registered for elicitation/create")) {
            _ = try await client.callTool(name: "confirm")
        }
    }

    @Test("For handshake clients the server fulfills input requests itself")
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func testLegacyBridge() async throws {
        let calls = Counter()
        let elicitations = Counter()
        let server = await makeRoundTripServer(calls: calls)
        let client = try await connect(server, mode: .handshake) {
            await answerEverything($0, elicitations: elicitations)
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(await !client.isStateless)

        let content = try await client.callTool(name: "confirm").content
        #expect(content == [.text(text: "accept pending:confirm")])
        #expect(await calls.value == 2)
        #expect(await elicitations.value == 1)

        let rounds = try await client.send(CallTool.request(.init(name: "rounds"))).value
        #expect(text(rounds) == "root file:///work")
        let prompt = try await client.getPrompt(name: "p")
        #expect(prompt.messages == [.user(.text(text: "About swift"))])

        // State sent by a handshake client is not part of its protocol and is dropped.
        let forged = try await client.send(
            CallTool.request(
                .init(
                    name: "confirm", inputResponses: ["confirm": .elicitation(.init(action: .decline))],
                    requestState: "forged"))
        ).value
        #expect(text(forged) == "accept pending:confirm")
    }

    @Test("The server bridge stops after the round limit")
    func testLegacyBridgeLimit() async throws {
        let calls = Counter()
        let server = await makeRoundTripServer(calls: calls)
        let client = try await connect(server, mode: .handshake)
        defer { Task { await client.disconnect(); await server.stop() } }
        await #expect(throws: MCPError.self) { _ = try await client.callTool(name: "forever") }
        #expect(await calls.value == MRTR.maxRounds)
    }

    @Test("A consume hook rejects a replayed requestState")
    func testReplayRejected() async throws {
        let seen = TokenLedger()
        let protection = try RequestStateProtection(
            keys: [Data(repeating: 7, count: 32)], consume: { id, _ in await seen.insert(id) })
        let server = await makeRoundTripServer(protection: protection)
        let client = try await connect(server, multiRoundTrip: .init(isEnabled: false))
        defer { Task { await client.disconnect(); await server.stop() } }

        let first = try await client.send(CallTool.request(.init(name: "confirm"))).value
        let state = try #require(first.requestState)
        let answer: [String: InputResponse] = ["confirm": .elicitation(.init(action: .accept))]
        let retry = try await client.send(
            CallTool.request(.init(name: "confirm", inputResponses: answer, requestState: state))
        ).value
        #expect(text(retry) == "accept pending:confirm")
        await #expect {
            _ = try await client.send(
                CallTool.request(.init(name: "confirm", inputResponses: answer, requestState: state))
            ).value
        } throws: { error in
            (error as? MCPError)?.code == -32602
        }
    }

    @Test("A consume hook that throws fails the round with -32603, not as a replay")
    func testConsumeFailure() async throws {
        struct StoreDown: Error {}
        let protection = try RequestStateProtection(
            keys: [Data(repeating: 7, count: 32)], consume: { _, _ in throw StoreDown() })
        let server = await makeRoundTripServer(protection: protection)
        let client = try await connect(server, multiRoundTrip: .init(isEnabled: false))
        defer { Task { await client.disconnect(); await server.stop() } }

        let first = try await client.send(CallTool.request(.init(name: "confirm"))).value
        let state = try #require(first.requestState)
        let answer: [String: InputResponse] = ["confirm": .elicitation(.init(action: .accept))]
        await #expect {
            _ = try await client.send(
                CallTool.request(.init(name: "confirm", inputResponses: answer, requestState: state))
            ).value
        } throws: { error in
            (error as? MCPError)?.code == -32603
        }
    }

    @Test("The client refuses a result with more input requests than the limit, before any handler runs")
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func testInputRequestLimit() async throws {
        let server = Server(name: "many", version: "1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            var requests: [String: InputRequest] = [:]
            for index in 0..<17 { requests["e\(index)"] = .elicitation(message: "Q\(index)?") }
            return .inputRequired(requests, requestState: "s")
        }
        let elicitations = Counter()
        let client = try await connect(server) { await answerEverything($0, elicitations: elicitations) }
        defer { Task { await client.disconnect(); await server.stop() } }

        await #expect {
            _ = try await client.callTool(name: "t")
        } throws: { error in
            (error as? MCPError)?.code == -32603
        }
        #expect(await elicitations.value == 0)
    }

    @Test("cancelRequest during a round cancels the running input handlers")
    func testCancelDuringRound() async throws {
        let server = await makeRoundTripServer()
        let started = Counter()
        let cancelled = Counter()
        let client = try await connect(server) { client in
            await client.withElicitationHandler { _ in
                await started.increment()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await cancelled.increment()
                    throw error
                }
                return .init(action: .accept)
            }
        }
        defer { Task { await client.disconnect(); await server.stop() } }

        let context = try await client.send(CallTool.request(.init(name: "confirm")))
        for _ in 0..<400 where await started.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await client.cancelRequest(context.requestID)
        await #expect(throws: (any Error).self) { _ = try await context.value }
        for _ in 0..<400 where await cancelled.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await cancelled.value == 1)
    }

    @Test("cancelRequest right after send ends the exchange before any round")
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func testCancelBeforeFirstResponse() async throws {
        let server = await makeRoundTripServer()
        let elicitations = Counter()
        let client = try await connect(server) { await answerEverything($0, elicitations: elicitations) }
        defer { Task { await client.disconnect(); await server.stop() } }

        let context = try await client.send(CallTool.request(.init(name: "confirm")))
        try await client.cancelRequest(context.requestID)
        await #expect(throws: (any Error).self) { _ = try await context.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await elicitations.value == 0)
    }

    @Test("disconnect cancels the input handlers of a round in progress")
    func testDisconnectCancelsRound() async throws {
        let server = await makeRoundTripServer()
        let started = Counter()
        let cancelled = Counter()
        let client = try await connect(server) { client in
            await client.withElicitationHandler { _ in
                await started.increment()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await cancelled.increment()
                    throw error
                }
                return .init(action: .accept)
            }
        }
        let context = try await client.send(CallTool.request(.init(name: "confirm")))
        for _ in 0..<400 where await started.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await client.disconnect()
        await #expect(throws: (any Error).self) { _ = try await context.value }
        for _ in 0..<400 where await cancelled.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await cancelled.value == 1)
        await server.stop()
    }

    @Test("The handshake bridge waits between state-only rounds")
    func testBridgeBackoff() async throws {
        let calls = Counter()
        let server = Server(name: "poll", version: "1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            await calls.increment()
            if await calls.value < 3 { return .inputRequired(requestState: "working") }
            return .init(content: [.text(text: "done")])
        }
        let client = try await connect(server, mode: .handshake)
        defer { Task { await client.disconnect(); await server.stop() } }

        let start = ContinuousClock.now
        let content = try await client.callTool(name: "job").content
        #expect(content == [.text(text: "done")])
        #expect(ContinuousClock.now - start >= .milliseconds(150))
        #expect(await calls.value == 3)
    }

    @Test("The handshake bridge checks client capabilities without strict mode")
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func testBridgeChecksCapabilities() async throws {
        let server = await makeRoundTripServer()
        let samplings = Counter()
        let client = try await connect(server, mode: .handshake, capabilities: .init(roots: .init())) { client in
            await client.withSamplingHandler { _ in
                await samplings.increment()
                return .init(model: "test", role: .assistant, content: .text("Hello"))
            }
        }
        defer { Task { await client.disconnect(); await server.stop() } }

        await #expect {
            _ = try await client.callTool(name: "rounds")
        } throws: { error in
            (error as? MCPError)?.code == -32021
        }
        #expect(await samplings.value == 0)
    }

    @Test("A client error to a bridged request fails the call with -32603")
    func testBridgeClientError() async throws {
        let server = await makeRoundTripServer()
        let client = try await connect(server, mode: .handshake) { client in
            await client.withElicitationHandler { _ in throw MCPError.invalidParams("no UI") }
        }
        defer { Task { await client.disconnect(); await server.stop() } }

        await #expect {
            _ = try await client.callTool(name: "confirm")
        } throws: { error in
            guard let error = error as? MCPError, error.code == -32603 else { return false }
            return error.localizedDescription.contains(CreateElicitation.name)
        }
    }

    @Test("Cancelling a bridged call withdraws its input request and calls the handler no more")
    func testBridgeCancellation() async throws {
        let calls = Counter()
        let server = await makeRoundTripServer(calls: calls)
        let cancellations = CancelLog()
        let started = Counter()
        // The client may run this handler in its receive loop, so it is
        // released once the call is cancelled.
        let (gate, open) = AsyncStream<Void>.makeStream()
        let client = try await connect(server, mode: .handshake) { client in
            await client.withElicitationHandler { _ in
                await started.increment()
                for await _ in gate { break }
                return .init(action: .accept)
            }
            await client.onNotification(CancelledNotification.self) { message in
                await cancellations.add(message.params.requestId)
            }
        }
        defer { Task { await client.disconnect(); await server.stop() } }

        let context = try await client.send(CallTool.request(.init(name: "confirm")))
        for _ in 0..<400 where await started.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await client.cancelRequest(context.requestID)
        try await Task.sleep(for: .milliseconds(50))
        open.yield()
        for _ in 0..<400 where await cancellations.ids.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await cancellations.ids.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await calls.value == 1)
    }

    @Test(
        "A bridged call cancelled before it asks for input sends no input request",
        .timeLimit(.minutes(1)))
    func testBridgeCancelledBeforeAsking() async throws {
        let (server, progress) = await makeLateAskingServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let peer = RawPeer(clientEnd)
        try await peer.start()
        try await peer.initialize(capabilities: #"{"elicitation":{}}"#)

        try await peer.send(#"{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"late"}}"#)
        for _ in 0..<1000 where await progress.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await peer.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"call"}}"#)
        for _ in 0..<1000 where await progress.returned == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await progress.returned == 1)
        try await Task.sleep(for: .milliseconds(100))
        try await peer.sync("after-return")

        let elicitation = await peer.first(within: .milliseconds(100)) {
            $0.objectValue?["method"]?.stringValue == CreateElicitation.name
        }
        #expect(elicitation == nil)
        await peer.stop()
        await server.stop()
    }

    @Test(
        "A bridged input request withdrawn while it is being sent is followed by notifications/cancelled",
        .timeLimit(.minutes(1)))
    func testBridgeWithdrawWhileSending() async throws {
        let (server, progress) = await makeLateAskingServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let peer = RawPeer(clientEnd)
        try await peer.start()
        try await peer.initialize(capabilities: #"{"elicitation":{}}"#)

        // The handler returns as the cancellation arrives, so the withdraw
        // lands before, during or after the registration of the request.
        let trials = 30
        for trial in 1...trials {
            try await peer.send(
                #"{"jsonrpc":"2.0","id":"call-\#(trial)","method":"tools/call","params":{"name":"gated"}}"#)
            for _ in 0..<1000 where await progress.started < trial { try await Task.sleep(for: .milliseconds(5)) }
            async let cancel: Void = peer.send(
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"call-\#(trial)"}}"#)
            await progress.release()
            try await cancel
            for _ in 0..<1000 where await progress.returned < trial { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await Task.sleep(for: .milliseconds(100))
        try await peer.sync("after-trials")

        func unanswered() async -> [Value] {
            let received = await peer.received
            let withdrawn = Set(
                received.compactMap { message -> Value? in
                    guard message.objectValue?["method"]?.stringValue == CancelledNotification.name else { return nil }
                    return message.objectValue?["params"]?.objectValue?["requestId"]
                })
            return received.compactMap { message -> Value? in
                guard message.objectValue?["method"]?.stringValue == CreateElicitation.name,
                    let id = message.objectValue?["id"], !withdrawn.contains(id)
                else { return nil }
                return id
            }
        }
        for _ in 0..<400 where await !unanswered().isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await unanswered() == [], "input requests sent and never withdrawn")
        #expect(await progress.returned == trials)
        await peer.stop()
        await server.stop()
    }

    @Test("A batched call that needs bridged input does not block the connection")
    func testBatchedBridge() async throws {
        let server = await makeRoundTripServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        try await clientEnd.connect()
        defer { Task { await clientEnd.disconnect(); await server.stop() } }
        var incoming = await clientEnd.receive().makeAsyncIterator()

        func next() async throws -> Value { try JSONDecoder().decode(Value.self, from: try #require(try await incoming.next())) }
        try await clientEnd.send(
            Data(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{}},"clientInfo":{"name":"raw","version":"1"}}}"#
                    .utf8))
        _ = try await next()
        try await clientEnd.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await clientEnd.send(
            Data(#"[{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"confirm"}}]"#.utf8))
        let elicitation = try await next()
        #expect(elicitation.objectValue?["method"]?.stringValue == CreateElicitation.name)
        let id = String(decoding: try JSONEncoder().encode(try #require(elicitation.objectValue?["id"])), as: UTF8.self)
        try await clientEnd.send(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"action":"accept"}}"#.utf8))
        let batch = try await next()
        #expect(batch.arrayValue?.first?.objectValue?["id"] == 2)
        #expect(batch.arrayValue?.first?.objectValue?["result"] != nil)
    }
}

private actor TokenLedger {
    private var seen: Set<String> = []
    func insert(_ id: String) -> Bool { seen.insert(id).inserted }
}

private actor CancelLog {
    private(set) var ids: [ID?] = []
    func add(_ id: ID?) { ids.append(id) }
}

private actor AskProgress {
    private(set) var started = 0
    private(set) var returned = 0
    private var released = 0
    func start() { started += 1 }
    func finish() { returned += 1 }
    func release() { released += 1 }
    func isReleased(_ round: Int) -> Bool { released >= round }
}

/// A server whose tools ignore cancellation and then ask for an
/// elicitation: `late` once its call is cancelled, `gated` once the test
/// calls `release()`.
private func makeLateAskingServer() async -> (Server, AskProgress) {
    let progress = AskProgress()
    let server = Server(name: "late", version: "1.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(CallTool.self) { params in
        if params.inputResponses != nil {
            return .init(content: [.text(text: "answered", annotations: nil, _meta: nil)])
        }
        await progress.start()
        let round = await progress.started
        switch params.name {
        case "late":
            for _ in 0..<1000 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        default:
            for _ in 0..<1000 where await !progress.isReleased(round) { try? await Task.sleep(for: .microseconds(100)) }
        }
        await progress.finish()
        return .inputRequired(["confirm": .elicitation(message: "Proceed?")])
    }
    return (server, progress)
}
