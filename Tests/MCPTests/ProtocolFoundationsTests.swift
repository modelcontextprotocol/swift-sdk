import Foundation
import Testing

@testable import MCP

private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
}

@Suite("MCPError Wire Format Tests")
struct MCPErrorWireTests {
    @Test("New protocol error codes")
    func testCodes() {
        #expect(MCPError.headerMismatch(nil).code == -32020)
        #expect(MCPError.missingRequiredClientCapabilities(.init()).code == -32021)
        #expect(MCPError.unsupportedProtocolVersion(supported: []).code == -32022)
        #expect(MCPError.resourceNotFound(uri: "x://y").code == -32602)
    }

    @Test("Resource not found carries data.uri")
    func testResourceNotFound() throws {
        let object = try json(MCPError.resourceNotFound(uri: "test://missing"))
        #expect(object["code"] as? Int == -32602)
        #expect((object["data"] as? [String: Any])?["uri"] as? String == "test://missing")

        let decoded = try decode(MCPError.self, object)
        #expect(decoded == .resourceNotFound(uri: "test://missing"))
    }

    @Test("Legacy -32002 with data.uri decodes as resource not found")
    func testLegacyResourceNotFound() throws {
        let decoded = try decode(
            MCPError.self,
            ["code": -32002, "message": "Resource not found", "data": ["uri": "a://b"]])
        guard case .resourceNotFound(let uri, _) = decoded else {
            Issue.record("Expected resourceNotFound, got \(decoded)")
            return
        }
        #expect(uri == "a://b")
    }

    @Test("Invalid params without uri stays invalid params")
    func testInvalidParamsDecode() throws {
        let decoded = try decode(
            MCPError.self, ["code": -32602, "message": "Invalid params", "data": ["detail": "bad"]])
        #expect(decoded == .invalidParams("bad"))
    }

    @Test("Unsupported protocol version round-trips supported and requested")
    func testUnsupportedProtocolVersion() throws {
        let error = MCPError.unsupportedProtocolVersion(
            supported: ["2026-07-28", "2025-11-25"], requested: "2099-01-01")
        let object = try json(error)
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["supported"] as? [String] == ["2026-07-28", "2025-11-25"])
        #expect(data["requested"] as? String == "2099-01-01")
        #expect(try decode(MCPError.self, object) == error)
    }

    @Test("Missing capability carries requiredCapabilities")
    func testMissingCapability() throws {
        let required = Client.Capabilities(sampling: .init())
        let object = try json(MCPError.missingRequiredClientCapabilities(required))
        let data = try #require(object["data"] as? [String: Any])
        #expect((data["requiredCapabilities"] as? [String: Any])?["sampling"] != nil)

        guard case .missingRequiredClientCapabilities(let decoded, _) = try decode(MCPError.self, object)
        else {
            Issue.record("Expected missingRequiredClientCapabilities")
            return
        }
        #expect(decoded.sampling != nil)
    }

    @Test("Header mismatch round-trips")
    func testHeaderMismatch() throws {
        let error = MCPError.headerMismatch("Mcp-Method does not match")
        #expect(try decode(MCPError.self, json(error)) == error)
    }

    @Test("Server error keeps its message and data")
    func testServerErrorData() throws {
        let error = MCPError.serverError(code: -32010, message: "busy", data: ["retryAfter": 5])
        let object = try json(error)
        #expect(object["message"] as? String == "busy")
        #expect(try decode(MCPError.self, object) == error)
    }

    @Test("-32000 and -32001 from the wire are server errors")
    func testImplementationDefinedCodes() throws {
        for code in [-32000, -32001] {
            let decoded = try decode(MCPError.self, ["code": code, "message": "custom"])
            #expect(decoded == .serverError(code: code, message: "custom"))
        }
    }

    @Test("-32021 without readable requiredCapabilities keeps its data")
    func testMissingCapabilitiesWithoutPayload() throws {
        let bare = try decode(MCPError.self, ["code": -32021, "message": "Needs sampling"])
        #expect(bare == .serverError(code: -32021, message: "Needs sampling"))
        #expect(bare.code == -32021)

        let malformed = try decode(
            MCPError.self,
            ["code": -32021, "message": "Needs sampling", "data": ["requiredCapabilities": "sampling"]])
        #expect(
            malformed
                == .serverError(code: -32021, message: "Needs sampling", data: ["requiredCapabilities": "sampling"]))

        let readable = try decode(
            MCPError.self,
            ["code": -32021, "message": "Needs sampling", "data": ["requiredCapabilities": ["sampling": [String: Any]()]]])
        #expect(readable == .missingRequiredClientCapabilities(.init(sampling: .init()), message: "Needs sampling"))
    }

    @Test("URL elicitation required round-trips")
    func testURLElicitationRequired() throws {
        let error = MCPError.urlElicitationRequired(
            message: "Sign in",
            elicitations: [.init(elicitationId: "e1", url: "https://example.com", message: "m")])
        #expect(try decode(MCPError.self, json(error)) == error)
    }

    @Test(
        "Errors round-trip with and without a detail",
        arguments: [
            MCPError.parseError(nil), .parseError("x"), .invalidRequest(nil), .invalidRequest("x"),
            .methodNotFound(nil), .methodNotFound("x"), .invalidParams(nil), .invalidParams("x"),
            .internalError(nil), .internalError("x"),
            .headerMismatch(nil), .headerMismatch("x"), .resourceNotFound(uri: "a://b"),
            .resourceNotFound(uri: "a://b", message: "Gone"),
            .missingRequiredClientCapabilities(.init(sampling: .init())),
            .missingRequiredClientCapabilities(.init(), message: "Needs sampling"),
        ])
    func testRoundTrip(error: MCPError) throws {
        let decoded = try decode(MCPError.self, json(error))
        #expect(decoded == error)
        #expect(decoded.errorDescription == error.errorDescription)
    }

    @Test("A peer message without data.detail is not repeated in the description")
    func testPeerMessageWithoutDetail() throws {
        let bare = try decode(MCPError.self, ["code": -32601, "message": "Method not found"])
        #expect(bare == .methodNotFound(nil))

        let prefixed = try decode(MCPError.self, ["code": -32601, "message": "Method not found: x/y"])
        #expect(prefixed == .methodNotFound("x/y"))
        #expect(prefixed.errorDescription == "Method not found: x/y")

        let custom = try decode(MCPError.self, ["code": -32601, "message": "Unknown method x/y"])
        #expect(custom == .methodNotFound("Unknown method x/y"))

        let internalError = try decode(MCPError.self, ["code": -32603, "message": "Internal error: boom"])
        #expect(internalError == .internalError("boom"))
        #expect(internalError.errorDescription == "Internal error: boom")
    }

    @Test("Error data sends data: URL strings as given")
    func testErrorDataKeepsDataURLStrings() throws {
        let uri = "data:,abc"
        let missing = MCPError.missingRequiredClientCapabilities(
            .init(experimental: ["x": .string(uri)]))
        let required = try #require(
            (json(missing)["data"] as? [String: Any])?["requiredCapabilities"] as? [String: Any])
        #expect((required["experimental"] as? [String: Any])?["x"] as? String == uri)

        let elicitation = MCPError.urlElicitationRequired(
            message: "m", elicitations: [.init(elicitationId: "e", url: uri, message: "m")])
        let items = try #require(
            (json(elicitation)["data"] as? [String: Any])?["elicitations"] as? [[String: Any]])
        #expect(items.first?["url"] as? String == uri)
    }

    @Test("Server error data from a message decoder still holds data: URLs as data")
    func testServerErrorDataURL() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.valuePreservesStrings] = true
        let error = try decoder.decode(
            MCPError.self,
            from: Data(#"{"code":-32010,"message":"m","data":{"u":"data:,hi"}}"#.utf8))
        #expect(
            error == .serverError(
                code: -32010, message: "m", data: ["u": .data(mimeType: "text/plain", Data("hi".utf8))]))
    }
}

@Suite("Envelope _meta Tests")
struct EnvelopeMetaTests {
    @Test("Request _meta is sent as params._meta")
    func testRequestMetaEncoded() throws {
        var meta = Metadata()
        meta.protocolVersion = Version.v2026_07_28
        let request = ListTools.request(.init(), _meta: meta)

        let params = try #require(try json(request)["params"] as? [String: Any])
        let encodedMeta = try #require(params["_meta"] as? [String: Any])
        #expect(encodedMeta[MetaKey.protocolVersion] as? String == Version.v2026_07_28)
    }

    @Test("Empty parameters with _meta encode as an object")
    func testEmptyParamsWithMeta() throws {
        let request = Ping.request(_meta: Metadata(additionalFields: ["k": "v"]))
        let params = try #require(try json(request)["params"] as? [String: Any])
        #expect((params["_meta"] as? [String: Any])?["k"] as? String == "v")
    }

    @Test("Parameter-level _meta wins on conflict and keys are merged")
    func testMetaMerge() throws {
        let params = CallTool.Parameters(
            name: "t", meta: Metadata(additionalFields: ["shared": "params", "own": 1]))
        let request = CallTool.request(
            params, _meta: Metadata(additionalFields: ["shared": "request", "extra": true]))

        let encoded = try #require(try json(request)["params"] as? [String: Any])
        let meta = try #require(encoded["_meta"] as? [String: Any])
        #expect(meta["shared"] as? String == "params")
        #expect(meta["own"] as? Int == 1)
        #expect(meta["extra"] as? Bool == true)
    }

    @Test("Decoding fills request _meta from params")
    func testRequestMetaDecoded() throws {
        let decoded = try decode(
            Request<ListTools>.self,
            [
                "jsonrpc": "2.0", "id": 1, "method": "tools/list",
                "params": ["_meta": [MetaKey.logLevel: "warning"]],
            ])
        #expect(decoded._meta?.logLevel == .warning)

        let bare = try decode(
            Request<ListTools>.self, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect(bare._meta == nil)
    }

    @Test("Notification _meta round-trips")
    func testNotificationMeta() throws {
        var message = ToolListChangedNotification.message()
        message._meta = Metadata(additionalFields: [MetaKey.subscriptionID: 7])
        let params = try #require(try json(message)["params"] as? [String: Any])
        #expect((params["_meta"] as? [String: Any])?[MetaKey.subscriptionID] as? Int == 7)

        let decoded = try JSONDecoder().decode(
            Message<ToolListChangedNotification>.self, from: JSONEncoder().encode(message))
        #expect(decoded._meta?[MetaKey.subscriptionID] == 7)
    }

    @Test("Strings that look like data URLs are sent as given when _meta is merged")
    func testDataURLStringsSurviveMetaMerge() throws {
        let uri = "data:text/plain,hello%20world"
        let request = ReadResource.request(
            .init(uri: uri), _meta: Metadata(additionalFields: [MetaKey.protocolVersion: "2026-07-28"]))
        let params = try #require(try json(request)["params"] as? [String: Any])
        #expect(params["uri"] as? String == uri)
        #expect((params["_meta"] as? [String: Any])?[MetaKey.protocolVersion] as? String == "2026-07-28")

        let base64 = "data:image/png;base64,iVBORw0KGgo="
        let call = CallTool.request(
            .init(name: "t", arguments: ["image": .string(base64)]),
            _meta: Metadata(additionalFields: ["k": "v"]))
        let callParams = try #require(try json(call)["params"] as? [String: Any])
        #expect((callParams["arguments"] as? [String: Any])?["image"] as? String == base64)
    }

    @Test("Type-erased requests and responses keep data: URL strings")
    func testTypeErasedHopsKeepDataURLStrings() throws {
        let uri = "data:,abc"
        let request = try AnyRequest(ReadResource.request(.init(uri: uri)))
        #expect((try json(request)["params"] as? [String: Any])?["uri"] as? String == uri)

        let response = try AnyResponse(
            CallTool.response(id: 1, result: .init(content: [.text(text: "data:,hello")])))
        let content = (try json(response)["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "data:,hello")
    }

    @Test("A Value result still decodes data: URLs as data for the caller")
    func testPendingValueResult() async throws {
        let result: Value = try await withCheckedThrowingContinuation { continuation in
            AnyPendingRequest(PendingRequest<Value>(continuation: continuation))
                .resume(returning: Value.object(["u": .string("data:,hi")]))
        }
        #expect(result == ["u": .data(mimeType: "text/plain", Data("hi".utf8))])
    }

    @Test("Typed _meta accessors")
    func testMetaAccessors() throws {
        var meta = Metadata()
        meta.clientCapabilities = Client.Capabilities(roots: .init(listChanged: true))
        meta.clientInfo = Client.Info(name: "c", version: "1")
        meta.serverInfo = Server.Info(name: "s", version: "2")
        meta.logLevel = .error

        let decoded = try JSONDecoder().decode(Metadata.self, from: JSONEncoder().encode(meta))
        #expect(decoded.clientCapabilities?.roots?.listChanged == true)
        #expect(decoded.clientInfo?.name == "c")
        #expect(decoded.serverInfo?.version == "2")
        #expect(decoded.logLevel == .error)

        meta.clientInfo = Client.Info(name: "c", version: "1", icons: [Icon(src: "data:,abc")])
        let info = try #require(json(meta)[MetaKey.clientInfo] as? [String: Any])
        #expect((info["icons"] as? [[String: Any]])?.first?["src"] as? String == "data:,abc")

        meta.clientInfo = nil
        #expect(meta[MetaKey.clientInfo] == nil)
        #expect(Metadata(additionalFields: [MetaKey.clientCapabilities: "bad"]).clientCapabilities == nil)
    }
}

@Suite("Capability Extensions Tests")
struct CapabilityExtensionsTests {
    @Test("Server capabilities encode extensions and experimental")
    func testServerExtensions() throws {
        let capabilities = Server.Capabilities(
            tools: .init(),
            experimental: ["feature": ["enabled": true]],
            extensions: ["io.modelcontextprotocol/tasks": [:]])
        let object = try json(capabilities)
        #expect((object["extensions"] as? [String: Any])?["io.modelcontextprotocol/tasks"] != nil)
        #expect(try JSONDecoder().decode(Server.Capabilities.self, from: JSONEncoder().encode(capabilities)) == capabilities)
    }

    @Test("Client capabilities accept object-valued experimental entries")
    func testClientExperimentalObjects() throws {
        let decoded = try decode(
            Client.Capabilities.self,
            ["experimental": ["x": ["nested": 1]], "extensions": ["ext/a": ["v": 2]]])
        #expect(decoded.experimental?["x"]?.objectValue?["nested"] == 1)
        #expect(decoded.extensions?["ext/a"]?.objectValue?["v"] == 2)
    }
}

@Suite("Result Type and Cache Hint Tests")
struct ResultTypeAndCacheTests {
    @Test("Cache hints are omitted when unset")
    func testCacheHintsOmitted() throws {
        let object = try json(ListTools.Result(tools: []))
        #expect(object["ttlMs"] == nil)
        #expect(object["cacheScope"] == nil)
    }

    @Test("Cache hints round-trip on every cacheable result")
    func testCacheHintsRoundTrip() throws {
        let tools = ListTools.Result(tools: [], ttlMs: 60_000, cacheScope: .public)
        #expect(try JSONDecoder().decode(ListTools.Result.self, from: JSONEncoder().encode(tools)) == tools)
        let object = try json(tools)
        #expect(object["ttlMs"] as? Int == 60_000)
        #expect(object["cacheScope"] as? String == "public")

        let prompts = ListPrompts.Result(prompts: [], ttlMs: 0, cacheScope: .private)
        #expect(try JSONDecoder().decode(ListPrompts.Result.self, from: JSONEncoder().encode(prompts)) == prompts)
        let resources = ListResources.Result(resources: [], ttlMs: 1, cacheScope: .private)
        #expect(try JSONDecoder().decode(ListResources.Result.self, from: JSONEncoder().encode(resources)) == resources)
        let templates = ListResourceTemplates.Result(templates: [], ttlMs: 2, cacheScope: .public)
        #expect(
            try JSONDecoder().decode(ListResourceTemplates.Result.self, from: JSONEncoder().encode(templates))
                == templates)
        let read = ReadResource.Result(contents: [], ttlMs: 3, cacheScope: .private)
        #expect(try JSONDecoder().decode(ReadResource.Result.self, from: JSONEncoder().encode(read)) == read)
    }

    @Test("Unknown cache scopes and out-of-range TTLs do not fail a result")
    func testLenientCacheHints() throws {
        let unknown = try decode(ListTools.Result.self, ["tools": [], "cacheScope": "team", "ttlMs": 1500.9])
        #expect(unknown.cacheScope == CacheScope(rawValue: "team"))
        #expect(unknown.ttlMs == 1500)

        for bad: Any in [-5, "soon", 1e300, ["x": 1]] {
            let result = try decode(ListTools.Result.self, ["tools": [], "ttlMs": bad, "cacheScope": 3])
            #expect(result.ttlMs == nil)
            #expect(result.cacheScope == nil)
        }
        #expect(CacheScope.public.rawValue == "public")
        #expect(CacheScope.private == "private")
    }

    @Test("Result type defaults to complete")
    func testResultType() throws {
        #expect(Value.object([:]).resultType == .complete)
        #expect(Value.object(["resultType": "input_required"]).resultType == .inputRequired)
        #expect(try JSONDecoder().decode(ResultType.self, from: JSONEncoder().encode(ResultType.inputRequired)) == .inputRequired)
        #expect(ResultType.complete.rawValue == "complete")
    }
}
