import Foundation
import Testing

@testable import MCP

@Suite("Modern Protocol 2026-07-28")
struct ModernProtocolTests {
    @Test("SEP-2243 custom parameter headers must match schema values")
    func customParameterHeadersValidateAgainstBody() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "result": ["tools": [[
                "name": "lookup", "inputSchema": [
                    "properties": ["tenant": ["type": "string", "x-mcp-header": "Tenant"]],
                    "required": ["tenant"],
                ],
            ]]],
        ] as [String: Any])
        let schemas = try #require(MCPToolHeaderSupport.schemaMap(from: response))
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "lookup", "arguments": ["tenant": "acme"]],
        ] as [String: Any])
        let valid = HTTPRequest(method: "POST", headers: ["mCp-PaRaM-tEnAnT": "acme"], body: body)
        let mismatch = HTTPRequest(method: "POST", headers: ["Mcp-Param-Tenant": "other"], body: body)
        let missing = HTTPRequest(method: "POST", headers: [:], body: body)
        #expect(MCPToolHeaderSupport.validateCall(body: body, request: valid, schemas: schemas) == nil)
        #expect(MCPToolHeaderSupport.validateCall(body: body, request: mismatch, schemas: schemas) != nil)
        #expect(MCPToolHeaderSupport.validateCall(body: body, request: missing, schemas: schemas) != nil)
    }

    @Test("Nested custom parameters and Base64 sentinel literals roundtrip safely")
    func nestedCustomParameterAndSentinelLiteralRoundtrip() throws {
        let literal = "=?base64?literal?="
        let encoded = MCPToolHeaderSupport.encodeHeaderValue(literal)
        #expect(encoded != literal)
        #expect(MCPToolHeaderSupport.decodeHeaderValue(encoded) == literal)
        #expect(MCPToolHeaderSupport.isValidSuffix("Tenant-2"))
        #expect(!MCPToolHeaderSupport.isValidSuffix("Tenant\rInjected"))

        let schema = ["properties": ["settings": [
            "type": "object", "required": ["tenant"],
            "properties": ["tenant": ["type": "string", "x-mcp-header": "Tenant"]],
        ]]] as [String: Any]
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "lookup", "arguments": ["settings": ["tenant": literal]]],
        ] as [String: Any])
        let request = HTTPRequest(method: "POST", headers: ["Mcp-Param-Tenant": encoded], body: body)
        #expect(MCPToolHeaderSupport.validateCall(body: body, request: request, schemas: ["lookup": schema]) == nil)
        #expect(MCPToolHeaderSupport.primitiveString(NSNumber(value: 9_007_199_254_740_991)) == "9007199254740991")
        #expect(MCPToolHeaderSupport.primitiveString(NSNumber(value: 9_007_199_254_740_992)) == nil)
    }

    @Test("Tool schema pages merge per caller without crossing identities")
    func toolSchemaRegistryIsPaginatedAndCallerScoped() throws {
        func listRequest(id: Int, identity: String, cursor: String? = nil) throws -> HTTPRequest {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let body = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params,
            ] as [String: Any])
            return HTTPRequest(method: "POST", body: body, clientIdentity: identity)
        }
        func listResponse(id: Int, tool: String, nextCursor: String? = nil) throws -> Data {
            var result: [String: Any] = [
                "tools": [["name": tool, "inputSchema": ["type": "object", "properties": [:]]]],
            ]
            result["nextCursor"] = nextCursor
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id,
                "result": result,
            ] as [String: Any])
        }
        var registry = MCPToolSchemaRegistry()
        let firstPage = try listRequest(id: 1, identity: "client-a")
        registry.record(responseData: try listResponse(id: 1, tool: "first", nextCursor: "next"), for: firstPage)
        #expect(!registry.isComplete(for: firstPage))
        let secondPage = try listRequest(id: 2, identity: "client-a", cursor: "next")
        registry.record(responseData: try listResponse(id: 2, tool: "second"), for: secondPage)
        #expect(registry.isComplete(for: firstPage))
        let otherCaller = try listRequest(id: 3, identity: "client-b")
        registry.record(responseData: try listResponse(id: 3, tool: "private"), for: otherCaller)
        #expect(Set(registry.schemas(for: firstPage).keys) == ["first", "second"])
        #expect(Set(registry.schemas(for: otherCaller).keys) == ["private"])
        #expect(registry.isComplete(for: otherCaller))
    }

    @Test("Tool schema registry evicts old caller entries at its capacity")
    func toolSchemaRegistryIsBounded() throws {
        var registry = MCPToolSchemaRegistry()
        let response = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1,
            "result": ["tools": [["name": "lookup", "inputSchema": ["type": "object"]]]],
        ] as [String: Any])
        var firstRequest: HTTPRequest?
        var lastRequest: HTTPRequest?
        for index in 0..<257 {
            let body = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": index, "method": "tools/list",
            ] as [String: Any])
            let request = HTTPRequest(method: "POST", body: body, clientIdentity: "client-\(index)")
            if index == 0 { firstRequest = request }
            if index == 256 { lastRequest = request }
            registry.record(responseData: response, for: request)
        }
        #expect(registry.schemas(for: try #require(firstRequest)).isEmpty)
        #expect(!registry.isComplete(for: try #require(firstRequest)))
        #expect(registry.schemas(for: try #require(lastRequest))["lookup"] != nil)
        #expect(registry.isComplete(for: try #require(lastRequest)))
    }

    @Test("Supported versions include modern and legacy")
    func supportedVersionsIncludeModernAndLegacy() {
        #expect(Version.supported.contains("2026-07-28"))
        #expect(Version.supported.contains("2025-11-25"))
        #expect(Version.latest == "2026-07-28")
        #expect(Version.isModern("2026-07-28"))
        #expect(!Version.isModern("2025-11-25"))
        #expect(Version.isLegacy("2025-11-25"))
    }

    @Test("requireSupported rejects unknown modern probes with -32022")
    func requireSupportedRejectsUnknown() throws {
        do {
            try Version.requireSupported("2099-01-01")
            Issue.record("Expected unsupportedProtocolVersion")
        } catch let error as MCPError {
            #expect(error.code == -32022)
            if case .unsupportedProtocolVersion(let requested, let supported) = error {
                #expect(requested == "2099-01-01")
                #expect(supported.contains("2026-07-28"))
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        }
    }

    @Test("Legacy negotiate still returns a legacy version")
    func legacyNegotiate() {
        #expect(Version.negotiate(clientRequestedVersion: "2025-11-25") == "2025-11-25")
        #expect(Version.negotiate(clientRequestedVersion: "2026-07-28") == Version.latestLegacy)
        #expect(Version.negotiate(clientRequestedVersion: "nope") == Version.latestLegacy)
    }

    @Test("ModernRequestMeta reads protocol version from params")
    func modernRequestMeta() {
        let params: Value = .object([
            "_meta": .object([
                ProtocolMetaKey.protocolVersion: .string("2026-07-28"),
                ProtocolMetaKey.clientCapabilities: .object([:]),
            ])
        ])
        #expect(ModernRequestMeta.protocolVersion(from: params) == "2026-07-28")
        #expect(ModernRequestMeta.isModernRequest(params: params))
    }

    @Test("subscriptions/listen acknowledges its request ID")
    func subscriptionsListenAcknowledges() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: true))
        )
        try await server.start(transport: transport)
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": "listen-ack", "method": "subscriptions/listen",
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
                "notifications": ["toolsListChanged": true],
            ],
        ]
        await transport.queue(data: try JSONSerialization.data(withJSONObject: request))
        try await Task.sleep(for: .milliseconds(100))
        let sent = await transport.sentMessages
        #expect(sent.contains { $0.contains(SubscriptionsAcknowledgedNotification.name) })
        #expect(sent.contains { $0.contains("listen-ack") && $0.contains(ProtocolMetaKey.subscriptionId) })
        let acknowledgment = try #require(sent
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["method"] as? String == SubscriptionsAcknowledgedNotification.name })
        let params = try #require(acknowledgment["params"] as? [String: Any])
        let notifications = try #require(params["notifications"] as? [String: Any])
        #expect(notifications["toolsListChanged"] as? Bool == true)
        await server.stop()
    }

    @Test("Modern server requests return missing-required-capability for undeclared features")
    func modernRequestRejectsUndeclaredSamplingCapability() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0",
            configuration: .strict
        )
        try await server.start(transport: transport)
        let context = Server.HandlerContext(
            id: .string("modern-request"),
            httpContext: nil,
            clientCapabilities: .init()
        )

        do {
            try await Server.$currentHandlerContext.withValue(context) {
                _ = try await server.requestSampling(messages: [], maxTokens: 8)
            }
            Issue.record("Expected missingRequiredClientCapability")
        } catch let error as MCPError {
            #expect(error.code == -32021)
            if case .missingRequiredClientCapability(let required) = error {
                #expect(required["sampling"] != nil)
            } else {
                Issue.record("Expected missingRequiredClientCapability, got \(error)")
            }
        }
        await server.stop()
    }

    @Test("ensuringModernCompleteResult adds resultType")
    func ensuringModernCompleteResult() {
        let value: Value = .object(["ok": .bool(true)])
        let enriched = value.ensuringModernCompleteResult(
            serverInfo: ["name": .string("test"), "version": .string("1")]
        )
        guard case .object(let object) = enriched else {
            Issue.record("Expected object")
            return
        }
        #expect(object["resultType"]?.stringValue == "complete")
        guard case .object(let meta) = object["_meta"],
            case .object(let info) = meta[ProtocolMetaKey.serverInfo]
        else {
            Issue.record("Expected serverInfo meta")
            return
        }
        #expect(info["name"]?.stringValue == "test")
    }

    @Test("modern list and read results include caching hints")
    func modernCachingHints() {
        let value: Value = .object(["items": .array([])])
        guard case .object(let result) = value.ensuringModernCompleteResult(cacheHints: true) else {
            Issue.record("Expected object result")
            return
        }
        #expect(result["cacheScope"]?.stringValue == "private")
        #expect(result["ttlMs"]?.intValue == 0)
    }

    @Test("missing client capability error includes required capabilities")
    func missingCapabilityErrorData() throws {
        let error = MCPError.missingRequiredClientCapability(["sampling": .object([:])])
        let encoded = try JSONEncoder().encode(error)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let data = try #require(json["data"] as? [String: Any])
        let capabilities = try #require(data["requiredCapabilities"] as? [String: Any])
        #expect(json["code"] as? Int == -32021)
        #expect(capabilities["sampling"] as? [String: Any] != nil)
    }

    @Test("tool results encode input-required request fields")
    func toolInputRequiredResultEncoding() throws {
        let result = CallTool.Result(
            resultType: .inputRequired,
            inputRequests: ["name": .object(["method": .string("elicitation/create"), "params": .object([:])])],
            requestState: "opaque"
        )
        let encoded = try JSONEncoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["resultType"] as? String == "input_required")
        #expect(json["requestState"] as? String == "opaque")
        #expect(json["inputRequests"] as? [String: Any] != nil)
    }

    @Test("tool input-required result can omit complete-result content")
    func toolInputRequiredResultWithoutContent() throws {
        let data = Data(
            #"{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{}}}}"#.utf8
        )
        let result = try JSONDecoder().decode(CallTool.Result.self, from: data)
        #expect(result.resultType == .inputRequired)
        #expect(result.content.isEmpty)
    }

    @Test("complete tool result still requires content")
    func completeToolResultRequiresContent() throws {
        let data = Data(#"{"resultType":"complete"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CallTool.Result.self, from: data)
        }
    }

    @Test("ensuringModernCompleteResult leaves non-object values unchanged")
    func ensuringModernCompleteResultNonObject() {
        let value: Value = .string("ok")
        let enriched = value.ensuringModernCompleteResult(
            serverInfo: ["name": .string("test"), "version": .string("1")]
        )
        #expect(enriched == value)
    }

    @Test("InputRequiredResult requires resultType when decoding")
    func inputRequiredResultRequiresResultType() throws {
        let data = Data(#"{"requestState":"s1"}"#.utf8)
        do {
            _ = try JSONDecoder().decode(InputRequiredResult.self, from: data)
            Issue.record("Expected decoding to fail without resultType")
        } catch is DecodingError {
            // expected
        }
    }

    @Test("Discover result encodes required fields")
    func discoverResultEncoding() throws {
        let result = Discover.Result(
            supportedVersions: ["2026-07-28", "2025-11-25"],
            capabilities: .init(tools: .init()),
            cacheScope: .private,
            ttlMs: 0
        )
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["resultType"] as? String == "complete")
        #expect(json?["cacheScope"] as? String == "private")
        #expect(json?["ttlMs"] as? Int == 0)
        let versions = json?["supportedVersions"] as? [String]
        #expect(versions?.contains("2026-07-28") == true)
    }

    @Test("server/discover works without initialize")
    func discoverWithoutInitialize() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
            configuration: .strict
        )
        try await server.start(transport: transport)

        let request = Discover.request(
            .init(
                _meta: Metadata(
                    additionalFields: [
                        ProtocolMetaKey.protocolVersion: .string("2026-07-28"),
                        ProtocolMetaKey.clientCapabilities: .object([:]),
                    ]
                )
            )
        )
        try await transport.queue(request: request)
        try await Task.sleep(for: .milliseconds(200))

        let messages = await transport.sentMessages
        #expect(!messages.isEmpty)
        #expect(messages[0].contains("supportedVersions"))
        #expect(messages[0].contains("2026-07-28"))
        #expect(messages[0].contains("\"resultType\":\"complete\"") || messages[0].contains("resultType"))

        await server.stop()
    }

    @Test("Strict modern notification exemption is validated per notification")
    func strictModeDoesNotCarryModernExemptionToOtherNotifications() async throws {
        actor NotificationCounter {
            private(set) var count = 0
            func increment() { count += 1 }
        }

        let transport = MockTransport()
        let counter = NotificationCounter()
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            configuration: .strict
        )
        await server.onNotification(RootsListChangedNotification.self) { _ in
            await counter.increment()
        }
        try await server.start(transport: transport)

        await transport.queue(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "modern-discover",
            "method": Discover.name,
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
            ],
        ] as [String: Any]))
        try await Task.sleep(for: .milliseconds(100))

        await transport.queue(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": RootsListChangedNotification.name,
        ] as [String: Any]))
        try await Task.sleep(for: .milliseconds(100))

        #expect(await counter.count == 0)

        await transport.queue(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "legacy-initialize",
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "legacy", "version": "1"],
            ],
        ] as [String: Any]))
        try await Task.sleep(for: .milliseconds(100))

        await transport.queue(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": RootsListChangedNotification.name,
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2099-01-01",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
            ],
        ] as [String: Any]))
        try await Task.sleep(for: .milliseconds(100))

        #expect(await counter.count == 0)

        await transport.queue(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": RootsListChangedNotification.name,
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
            ],
        ] as [String: Any]))
        try await Task.sleep(for: .milliseconds(100))

        #expect(await counter.count == 1)
        await server.stop()
    }

    @Test("Unsupported protocol version on modern request returns -32022")
    func unsupportedVersionOnRequest() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            configuration: .default
        )
        try await server.start(transport: transport)

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "ping",
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2099-01-01",
                    ProtocolMetaKey.clientCapabilities: [:] as [String: Any],
                ]
            ],
        ]
        await transport.queue(data: try JSONSerialization.data(withJSONObject: request))
        try await Task.sleep(for: .milliseconds(200))

        let messages = await transport.sentMessages
        #expect(!messages.isEmpty)
        #expect(messages[0].contains("-32022") || messages[0].contains("32022"))
        #expect(messages[0].contains("2099-01-01"))

        await server.stop()
    }

    @Test("HTTP 400 unsupported version body includes error.data")
    func httpErrorBodyIncludesUnsupportedVersionData() throws {
        let response = HTTPResponse.error(
            statusCode: 400,
            .unsupportedProtocolVersion(
                requested: "2099-01-01",
                supported: ["2026-07-28", "2025-11-25"]
            )
        )
        #expect(response.statusCode == 400)
        let body = try #require(response.bodyData)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["requested"] as? String == "2099-01-01")
        let supported = try #require(data["supported"] as? [String])
        #expect(supported.contains("2026-07-28"))
    }

    @Test("ProtocolVersionValidator rejects header/body disagreement with HTTP 400")
    func protocolVersionHeaderBodyDisagreement() {
        let validator = ProtocolVersionValidator()
        let request = HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.protocolVersion: "2025-11-25"],
            path: "/"
        )
        let context = HTTPValidationContext(
            httpMethod: "POST",
            bodyProtocolVersion: "2026-07-28",
            supportedProtocolVersions: Version.supported
        )
        let response = validator.validate(request, context: context)
        #expect(response?.statusCode == 400)
        let body = response?.bodyData
        let text = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(text.contains("disagrees") || text.contains("Invalid Request") || text.contains("-32600"))
        #expect(text.contains("2026-07-28"))
    }

    @Test("ProtocolVersionValidator rejects modern header without body meta")
    func protocolVersionModernHeaderRequiresBodyMeta() throws {
        let validator = ProtocolVersionValidator()
        let body = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "ping",
                "params": [:] as [String: Any],
            ] as [String: Any]
        )
        let request = HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.protocolVersion: "2026-07-28"],
            body: body,
            path: "/"
        )
        let context = HTTPValidationContext(
            httpMethod: "POST",
            bodyProtocolVersion: nil,
            supportedProtocolVersions: Version.supported
        )
        let response = validator.validate(request, context: context)
        #expect(response?.statusCode == 400)
        let text = response?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(text.contains("params._meta") || text.contains("protocolVersion"))
    }

    @Test("completeSubscriptionsListen cancels parked listen and is idempotent")
    func completeSubscriptionsListenCancelsParked() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            configuration: .strict
        )
        try await server.start(transport: transport)

        let listenID: ID = 42
        let request = SubscriptionsListen.request(
            id: listenID,
            .init(
                _meta: Metadata(
                    additionalFields: [
                        ProtocolMetaKey.protocolVersion: .string("2026-07-28"),
                        ProtocolMetaKey.clientCapabilities: .object([:]),
                    ]
                ),
                notifications: .init()
            )
        )
        try await transport.queue(request: request)
        try await Task.sleep(for: .milliseconds(100))

        try await server.completeSubscriptionsListen(id: listenID)
        try await Task.sleep(for: .milliseconds(100))

        let messages = await transport.sentMessages
        #expect(messages.contains { $0.contains("\"resultType\":\"complete\"") || $0.contains("resultType") })

        // Unknown / already completed id must not emit another response
        let before = await transport.sentMessages.count
        try await server.completeSubscriptionsListen(id: listenID)
        let after = await transport.sentMessages.count
        #expect(after == before)

        await server.stop()
    }
}


    @Test("closeRequestStream finishes parked listen SSE")
    func closeRequestStreamFinishesListenSSE() async throws {
        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()

        let listenBody = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "listen-1",
                "method": "subscriptions/listen",
                "params": [
                    "_meta": [
                        ProtocolMetaKey.protocolVersion: "2026-07-28",
                        ProtocolMetaKey.clientCapabilities: [:] as [String: Any],
                    ],
                    "notifications": [
                        "toolsListChanged": true,
                        "resourcesListChanged": true,
                        "promptsListChanged": true,
                        "resourceSubscriptions": [] as [String],
                    ],
                ],
            ] as [String: Any]
        )
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.accept: "\(ContentType.json), \(ContentType.sse)",
                HTTPHeaderName.protocolVersion: "2026-07-28",
            ],
            body: listenBody,
            path: "/"
        )
        let response = await transport.handleRequest(request)
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected SSE stream for listen, got \(response)")
            return
        }

        let finished = Task<Bool, Never> {
            do {
                for try await _ in stream {}
                return true
            } catch {
                return true
            }
        }
        await transport.closeRequestStream(for: .string("listen-1"))
        let didFinish = await finished.value
        #expect(didFinish)

        await transport.disconnect()
    }

    @Test("Listen notification filter matches opted-in types only")
    func listenNotificationFilter() {
        let filter = SubscriptionsListen.NotificationFilter(
            toolsListChanged: true,
            resourcesListChanged: false,
            promptsListChanged: true,
            resourceSubscriptions: ["file://a"]
        )
        let tools = Data(#"{"method":"notifications/tools/list_changed"}"#.utf8)
        let prompts = Data(#"{"method":"notifications/prompts/list_changed"}"#.utf8)
        let resources = Data(#"{"method":"notifications/resources/list_changed"}"#.utf8)
        let progress = Data(
            #"{"method":"notifications/progress","params":{"progressToken":1,"progress":0.5}}"#
                .utf8)
        let updatedMatch = Data(
            #"{"method":"notifications/resources/updated","params":{"uri":"file://a"}}"#.utf8)
        let updatedMiss = Data(
            #"{"method":"notifications/resources/updated","params":{"uri":"file://b"}}"#.utf8)

        #expect(
            StatefulHTTPServerTransport.notification(
                "notifications/tools/list_changed", matches: filter, body: tools))
        #expect(
            StatefulHTTPServerTransport.notification(
                "notifications/prompts/list_changed", matches: filter, body: prompts))
        #expect(
            !StatefulHTTPServerTransport.notification(
                "notifications/resources/list_changed", matches: filter, body: resources))
        #expect(
            !StatefulHTTPServerTransport.notification(
                "notifications/progress", matches: filter, body: progress))
        #expect(
            StatefulHTTPServerTransport.notification(
                "notifications/resources/updated", matches: filter, body: updatedMatch))
        #expect(
            !StatefulHTTPServerTransport.notification(
                "notifications/resources/updated", matches: filter, body: updatedMiss))
    }
