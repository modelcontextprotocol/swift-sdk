import Foundation
import Testing

@testable import MCP

/// Decodes `json` as `T`, and returns `T` with its encoding as a `Value`.
private func roundTrip<T: Codable>(_ type: T.Type, _ json: String) throws -> (T, Value) {
    let decoded = try JSONDecoder().decode(T.self, from: Data(json.utf8))
    let encoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(decoded))
    return (decoded, encoded)
}

private func value(_ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

@Suite("Unknown kinds")
struct UnknownKindTests {
    private let block = #"{"type":"hologram","uri":"holo://1","frames":[1,2],"_meta":{"k":"v"}}"#

    @Test("A tool content block of an unknown type is kept and re-encoded as received")
    func toolContent() throws {
        let (content, encoded) = try roundTrip(Tool.Content.self, block)
        guard case .unknown(let type, let body) = content else {
            Issue.record("Expected an unknown block, got \(content)")
            return
        }
        #expect(type == "hologram")
        #expect(body == (try value(block)))
        #expect(encoded == (try value(block)))
    }

    @Test("An unknown block does not fail the result that carries it")
    func callToolResult() throws {
        let json = #"{"content":[{"type":"text","text":"hi"},\#(block)]}"#
        let (result, _) = try roundTrip(CallTool.Result.self, json)
        #expect(result.content.count == 2)
        #expect(result.content.last == .unknown(type: "hologram", try value(block)))
    }

    @Test("A constructed unknown block is encoded with its type")
    func constructedBlock() throws {
        let content = Tool.Content.unknown(type: "hologram", ["uri": "holo://1"])
        let encoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(content))
        #expect(encoded == ["type": "hologram", "uri": "holo://1"])
    }

    @Test("Prompt, sampling and tool result blocks keep unknown types")
    func otherBlocks() throws {
        let expected = try value(block)
        let (prompt, promptEncoded) = try roundTrip(Prompt.Message.Content.self, block)
        #expect(prompt == .unknown(type: "hologram", expected))
        #expect(promptEncoded == expected)
        let (sampling, samplingEncoded) = try roundTrip(Sampling.Message.Content.ContentBlock.self, block)
        #expect(sampling == .unknown(type: "hologram", expected))
        #expect(samplingEncoded == expected)
        let (toolResult, toolResultEncoded) = try roundTrip(Sampling.ToolResultContent.ContentBlock.self, block)
        #expect(toolResult == .unknown(type: "hologram", expected))
        #expect(toolResultEncoded == expected)
    }

    @Test("A tool can return an unknown block, and the client receives it")
    func endToEnd() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let body: Value = ["type": "hologram", "uri": "holo://1"]
        await server.withMethodHandler(CallTool.self) { _ in
            .init(content: [.unknown(type: "hologram", body)])
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "c", version: "1")
        try await client.connect(transport: clientTransport)
        let (content, _) = try await client.callTool(name: "show")
        #expect(content == [.unknown(type: "hologram", body)])
        await client.disconnect()
        await server.stop()
    }

    @Test("An input request of an unknown method is kept")
    func inputRequest() throws {
        let json = #"{"method":"tasks/approve","params":{"taskId":"t1"}}"#
        let (request, encoded) = try roundTrip(InputRequest.self, json)
        #expect(request == .unknown(method: "tasks/approve", params: ["taskId": "t1"]))
        #expect(request.method == "tasks/approve")
        #expect(encoded == (try value(json)))
        #expect(request.isSupported(by: .init()))
    }

    @Test("An input response of an unknown shape is kept")
    func inputResponse() throws {
        let json = #"{"approved":true}"#
        let (response, encoded) = try roundTrip(InputResponse.self, json)
        #expect(response == .unknown(["approved": true]))
        #expect(encoded == (try value(json)))
        #expect(try InputResponse(method: "tasks/approve", result: ["approved": true]) == .unknown(["approved": true]))
        let (sampling, _) = try roundTrip(
            InputResponse.self, #"{"role":"assistant","content":{"type":"text","text":"hi"},"model":"m"}"#)
        #expect(sampling.sampling != nil)
    }

    @Test("An input response that shares a key with a known kind but not its schema is kept")
    func inputResponseSharedKey() throws {
        for json in [#"{"action":3}"#, #"{"content":"x","other":1}"#, #"{"model":true}"#, #"{"roots":"all"}"#] {
            let (response, encoded) = try roundTrip(InputResponse.self, json)
            #expect(response == .unknown(try value(json)), "\(json)")
            #expect(encoded == (try value(json)))
        }
        // One such response does not fail the parameters that carry it.
        let params = try CallTool.Parameters(
            decoding: ["name": "t", "inputResponses": ["a": ["action": 3], "b": ["action": "accept"]]])
        #expect(params.inputResponses?["a"] == .unknown(["action": 3]))
        #expect(params.inputResponses?["b"]?.elicitation?.action == .accept)
        let (roots, _) = try roundTrip(InputResponse.self, #"{"roots":[{"uri":"file:///x"}]}"#)
        #expect(roots.roots?.first?.uri == "file:///x")
    }

    @Test("Unknown blocks keep data: URL strings as written")
    func unknownBlockDataURL() throws {
        let json = #"{"type":"hologram","src":"data:,hi","frames":["data:text/plain,a%20b"],"_meta":{"k":"data:,x"}}"#
        let preserved = try JSONDecoder().decode(Value.Preserved.self, from: Data(json.utf8)).value
        #expect(preserved.objectValue?["src"] == .string("data:,hi"))

        func check<T: Codable>(_ type: T.Type, _ json: String) throws -> T {
            let decoded = try JSONDecoder().decode(T.self, from: Data(json.utf8))
            let encoded = try JSONEncoder().encode(decoded)
            let expected = try JSONDecoder().decode(Value.Preserved.self, from: Data(json.utf8)).value
            #expect(try JSONDecoder().decode(Value.Preserved.self, from: encoded).value == expected, "\(T.self)")
            return decoded
        }
        #expect(try check(Tool.Content.self, json) == .unknown(type: "hologram", preserved))
        #expect(try check(Prompt.Message.Content.self, json) == .unknown(type: "hologram", preserved))
        #expect(try check(Sampling.Message.Content.ContentBlock.self, json) == .unknown(type: "hologram", preserved))
        #expect(try check(Sampling.ToolResultContent.ContentBlock.self, json) == .unknown(type: "hologram", preserved))
        let mode = #"{"mode":"voice","message":"Say it","prompt":"data:,hi"}"#
        let params = try check(CreateElicitation.Parameters.self, mode)
        #expect(params == .unknown(mode: .init(rawValue: "voice"), ["mode": "voice", "message": "Say it", "prompt": "data:,hi"]))
    }

    @Test("A tool's unknown block with a data: URL string reaches the client as written")
    func unknownBlockDataURLEndToEnd() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let body: Value = ["type": "hologram", "src": "data:,hi"]
        await server.withMethodHandler(CallTool.self) { _ in
            .init(content: [.unknown(type: "hologram", body)])
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "c", version: "1")
        try await client.connect(transport: clientTransport)
        let (content, _) = try await client.callTool(name: "show")
        #expect(content == [.unknown(type: "hologram", body)])
        await client.disconnect()
        await server.stop()
    }

    @Test("Elicitation parameters of an unknown mode are kept")
    func elicitationMode() throws {
        let json = #"{"mode":"voice","message":"Say it","language":"en"}"#
        let (params, encoded) = try roundTrip(CreateElicitation.Parameters.self, json)
        #expect(params == .unknown(mode: .init(rawValue: "voice"), try value(json)))
        #expect(encoded == (try value(json)))
        // The SDK cannot know the sub-capability of a mode it does not know:
        // any elicitation declaration is enough, and a missing one is named
        // without a sub-capability.
        let request = InputRequest.elicitation(params)
        let both = Client.Capabilities(elicitation: .init(form: .init(), url: .init()))
        let urlOnly = Client.Capabilities(elicitation: .init(form: nil, url: .init()))
        let supported = [both, urlOnly, .init()].map { request.isSupported(by: $0) }
        #expect(supported == [true, true, false])
        var missing = Client.Capabilities()
        request.require(in: &missing)
        #expect(missing.elicitation == .init(form: nil, url: nil))
        #expect(try Value(missing) == ["elicitation": [:]])
        let (form, _) = try roundTrip(
            CreateElicitation.Parameters.self, #"{"message":"m","requestedSchema":{"type":"object","properties":{}}}"#)
        guard case .form = form else {
            Issue.record("Expected a form, got \(form)")
            return
        }
    }
}

@Suite("MCPError.Code")
struct MCPErrorCodeTests {
    @Test("Every error has its code")
    func codes() {
        #expect(MCPError.invalidParams(nil).errorCode == .invalidParams)
        #expect(MCPError.resourceNotFound(uri: "a").errorCode == .invalidParams)
        #expect(MCPError.unsupportedProtocolVersion(supported: []).errorCode == .unsupportedProtocolVersion)
        #expect(MCPError.serverError(code: -32050, message: "m").errorCode == -32050)
        #expect(MCPError.Code.urlElicitationRequired.rawValue == -32042)
    }

    @Test("A code matches in a catch clause")
    func catchByCode() {
        do {
            throw MCPError.serverError(code: -32050, message: "Quota exceeded")
        } catch MCPError.Code.unsupportedProtocolVersion {
            Issue.record("Matched another code")
        } catch MCPError.Code(rawValue: -32050) {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("A code without a case decodes as a server error")
    func unknownCode() throws {
        let error = try JSONDecoder().decode(
            MCPError.self, from: Data(#"{"code":-32077,"message":"New","data":{"a":1}}"#.utf8))
        #expect(error == .serverError(code: -32077, message: "New", data: ["a": 1]))
        #expect(error.errorCode == -32077)
    }
}
