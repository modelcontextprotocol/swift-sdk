import Foundation
import Testing

@testable import MCP

@Suite("Request Header Tests")
struct RequestHeadersTests {
    @Test("Values are sent as-is or Base64-wrapped", arguments: [
        ("us-west1", "us-west1"),
        ("us west 1", "us west 1"),
        ("Hello, 世界", "=?base64?SGVsbG8sIOS4lueVjA==?="),
        (" padded ", "=?base64?IHBhZGRlZCA=?="),
        ("\tindented", "=?base64?CWluZGVudGVk?="),
        ("line1\nline2", "=?base64?bGluZTEKbGluZTI=?="),
        ("", "=?base64??="),
        ("=?base64?abc?=", "=?base64?PT9iYXNlNjQ/YWJjPz0=?="),
    ])
    func testEncode(value: String, header: String) {
        #expect(MCPRequestHeaders.encode(value) == header)
        #expect(MCPRequestHeaders.decode(header) == value)
    }

    @Test("Decoding trims whitespace and treats unwrapped values as literal", arguments: [
        ("  echo  ", "echo"),
        ("SGVsbG8=", "SGVsbG8="),
        ("=?base64?SGVsbG8=", "=?base64?SGVsbG8="),
        ("SGVsbG8=?=", "SGVsbG8=?="),
        (" =?base64?SGVsbG8=?= ", "Hello"),
    ])
    func testDecodeLiteral(header: String, value: String) {
        #expect(MCPRequestHeaders.decode(header) == value)
    }

    @Test("Malformed Base64 does not decode", arguments: [
        "=?base64?SGVsbG8?=",
        "=?base64?SGVs!!!bG8=?=",
        "=?base64?SGVsbG9=?=",
        "=?base64?/w==?=",
    ])
    func testDecodeMalformed(header: String) {
        #expect(MCPRequestHeaders.decode(header) == nil)
    }

    @Test("Arguments render as header text")
    func testRender() {
        #expect(MCPRequestHeaders.render("a") == "a")
        #expect(MCPRequestHeaders.render(42) == "42")
        #expect(MCPRequestHeaders.render(.double(7)) == "7")
        #expect(MCPRequestHeaders.render(true) == "true")
        #expect(MCPRequestHeaders.render(false) == "false")
        #expect(MCPRequestHeaders.render(.double(3.5)) == nil)
        #expect(MCPRequestHeaders.render(.null) == nil)
        #expect(MCPRequestHeaders.render(["a"]) == nil)
    }

    @Test("x-mcp-header annotations are read through properties")
    func testParameters() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "region": ["type": "string", "x-mcp-header": "Region"],
                "options": [
                    "type": "object",
                    "properties": ["level": ["type": "integer", "x-mcp-header": "Level"]],
                ],
                "query": ["type": "string"],
            ],
        ]
        let parameters = try MCPRequestHeaders.parameters(in: schema)
        #expect(
            parameters == [
                .init(headerName: "Level", path: ["options", "level"], type: "integer"),
                .init(headerName: "Region", path: ["region"], type: "string"),
            ])
        #expect(parameters.map(\.fieldName) == ["Mcp-Param-Level", "Mcp-Param-Region"])
    }

    @Test("Invalid x-mcp-header annotations are rejected", arguments: [
        ["value": ["type": "string", "x-mcp-header": ""]],
        ["value": ["type": "string", "x-mcp-header": 1]],
        ["data": ["type": "object", "x-mcp-header": "Data"]],
        ["items": ["type": "array", "x-mcp-header": "Items"]],
        ["nil": ["type": "null", "x-mcp-header": "Nil"]],
        ["ratio": ["type": "number", "x-mcp-header": "Ratio"]],
        ["a": ["type": "string", "x-mcp-header": "Region"], "b": ["type": "string", "x-mcp-header": "Region"]],
        ["a": ["type": "string", "x-mcp-header": "MyField"], "b": ["type": "string", "x-mcp-header": "myfield"]],
        ["value": ["type": "string", "x-mcp-header": "My Region"]],
        ["value": ["type": "string", "x-mcp-header": "Region:Primary"]],
        ["value": ["type": "string", "x-mcp-header": "Région"]],
        ["value": ["type": "string", "x-mcp-header": "Region\t1"]],
    ] as [[String: Value]])
    func testInvalidAnnotations(properties: [String: Value]) {
        let tool = Tool(name: "t", description: nil, inputSchema: ["type": "object", "properties": .object(properties)])
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) { try tool.headerParameters() }
    }

    @Test("An annotation off the properties chain is rejected", arguments: [
        ["type": "array", "items": ["type": "string", "x-mcp-header": "Item"]],
        ["type": "array", "prefixItems": [["type": "string", "x-mcp-header": "First"]]],
        ["type": "object", "additionalProperties": ["type": "string", "x-mcp-header": "Extra"]],
        ["anyOf": [["type": "string", "x-mcp-header": "Choice"], ["type": "integer"]]],
        ["allOf": [["properties": ["inner": ["type": "string", "x-mcp-header": "Inner"]]]]],
        ["not": ["type": "string", "x-mcp-header": "Not"]],
        ["if": ["type": "string"], "then": ["type": "string", "x-mcp-header": "Then"]],
        ["type": "object", "patternProperties": ["^x": ["type": "string", "x-mcp-header": "Pattern"]]],
    ] as [Value])
    func testUnreachableAnnotations(property: Value) {
        let schema: Value = ["type": "object", "properties": ["value": property]]
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) { try MCPRequestHeaders.parameters(in: schema) }
    }

    @Test("An annotation in $defs, or on the root, is rejected")
    func testDefsAndRootAnnotations() {
        let defs: Value = [
            "type": "object",
            "properties": ["region": ["$ref": "#/$defs/region"]],
            "$defs": ["region": ["type": "string", "x-mcp-header": "Region"]],
        ]
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) { try MCPRequestHeaders.parameters(in: defs) }
        let root: Value = ["type": "string", "x-mcp-header": "Root"]
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) { try MCPRequestHeaders.parameters(in: root) }
    }

    @Test("Values and names that are not subschemas are not read for annotations")
    func testNonSchemaValues() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "x-mcp-header": ["type": "string"],
                "region": [
                    "type": "string", "x-mcp-header": "Region",
                    "default": ["x-mcp-header": "Default"], "enum": [["x-mcp-header": "Enum"]],
                ],
                "list": ["type": "array", "items": ["type": "string"]],
            ],
            "examples": [["x-mcp-header": "Example"]],
        ]
        #expect(try MCPRequestHeaders.parameters(in: schema).map(\.headerName) == ["Region"])
    }

    @Test("An annotation count above the limit is rejected")
    func testAnnotationLimit() throws {
        func schema(_ count: Int) -> Value {
            var properties: [String: Value] = [:]
            for index in 0..<count {
                properties["p\(index)"] = ["type": "string", "x-mcp-header": .string("H\(index)")]
            }
            return ["type": "object", "properties": .object(properties)]
        }
        #expect(try MCPRequestHeaders.parameters(in: schema(MCPRequestHeaders.maxAnnotations)).count == 64)
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) {
            try MCPRequestHeaders.parameters(in: schema(MCPRequestHeaders.maxAnnotations + 1))
        }
    }

    @Test("properties nested deeper than the limit are rejected")
    func testDepthLimit() throws {
        func schema(depth: Int) -> Value {
            var schema: Value = ["type": "object", "properties": ["leaf": ["type": "string", "x-mcp-header": "Leaf"]]]
            for _ in 0..<depth {
                schema = ["type": "object", "properties": ["next": schema]]
            }
            return schema
        }
        #expect(try MCPRequestHeaders.parameters(in: schema(depth: 30)).count == 1)
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) {
            try MCPRequestHeaders.parameters(in: schema(depth: 40))
        }
    }

    @Test("A misplaced annotation is rejected down to maxSchemaDepth and ignored below it")
    func testMisplacedAnnotationDepthLimit() throws {
        func schema(depth: Int) -> Value {
            var schema: Value = ["type": "string", "x-mcp-header": "Deep"]
            for _ in 0..<depth {
                schema = ["type": "array", "items": schema]
            }
            return schema
        }
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) {
            try MCPRequestHeaders.parameters(in: schema(depth: MCPRequestHeaders.maxSchemaDepth))
        }
        // Not inspected, so neither rejected nor mirrored.
        #expect(try MCPRequestHeaders.parameters(in: schema(depth: MCPRequestHeaders.maxSchemaDepth + 1)).isEmpty)
    }

    @Test("Subschemas nested deeper than maxSchemaDepth without annotations stay in stateless tools/list")
    func testDeepSubschemaWithoutAnnotations() async throws {
        var subschema: Value = ["type": "string"]
        for step in 0..<40 {
            subschema = step.isMultiple(of: 2)
                ? ["type": "array", "items": subschema]
                : ["anyOf": [subschema, ["type": "null"]]]
        }
        let schema: Value = ["type": "object", "properties": ["nested": subschema]]
        #expect(try MCPRequestHeaders.parameters(in: schema).isEmpty)

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "deep", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "deep", description: nil, inputSchema: schema)])
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "c", version: "1")
        _ = try await client.connect(transport: clientTransport)
        #expect(try await client.listTools().tools.map(\.name) == ["deep"])
        await client.disconnect()
        await server.stop()
    }

    @Test("Errors name the property path, escaped and truncated, not the annotation")
    func testErrorDescriptions() {
        let forged = "X\r\nInjected: yes"
        let key = String(repeating: "k", count: 300) + "\u{7}"
        let tool = Tool(
            name: "t", description: nil,
            inputSchema: ["type": "object", "properties": [.init(stringLiteral: key): ["type": "string", "x-mcp-header": .string(forged)]]])
        do {
            _ = try tool.headerParameters()
            Issue.record("expected an error")
        } catch {
            let description = "\(error)"
            #expect(!description.contains("Injected"))
            #expect(!description.contains("\r"))
            #expect(!description.unicodeScalars.contains { $0.value < 0x20 })
            #expect(description.count < 220)
        }
        #expect(MCPRequestHeaders.sanitized("a\nb\u{1F600}") == "a?b?")
        #expect(MCPRequestHeaders.sanitized(String(repeating: "x", count: 200)).count == 131)
    }

    @Test("Mcp-Param headers mirror present, non-null arguments")
    func testParameterHeaders() throws {
        let parameters: [MCPRequestHeaders.Parameter] = [
            .init(headerName: "Region", path: ["region"], type: "string"),
            .init(headerName: "Priority", path: ["priority"], type: "integer"),
            .init(headerName: "Verbose", path: ["verbose"], type: "boolean"),
            .init(headerName: "Note", path: ["note"], type: "string"),
            .init(headerName: "Level", path: ["options", "level"], type: "integer"),
        ]
        let arguments: Value = [
            "region": "us west", "priority": 42, "verbose": .null, "note": " x", "options": ["level": 2],
            "query": "unmirrored",
        ]
        #expect(
            MCPRequestHeaders.parameterHeaders(parameters, arguments: arguments) == [
                "Mcp-Param-Region": "us west",
                "Mcp-Param-Priority": "42",
                "Mcp-Param-Note": "=?base64?IHg=?=",
                "Mcp-Param-Level": "2",
            ])
    }
}

@Suite("Repeated request headers")
struct RepeatedRequestHeaderTests {
    private static let listBody =
        #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#

    /// POSTs `tools/list` at 2026-07-28 with `headers` added to a server
    /// that serves it.
    private func post(_ headers: [String: String]) async throws -> HTTPResponse {
        let server = Server(name: "headers", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        var all = ["Content-Type": "application/json", "Accept": "application/json"]
        all.merge(headers) { $1 }
        let response = await transport.handleRequest(
            HTTPRequest(method: "POST", headers: all, body: Data(Self.listBody.utf8)))
        await server.stop()
        return response
    }

    private func errorCode(_ response: HTTPResponse) throws -> Value? {
        try JSONDecoder().decode(Value.self, from: try #require(response.bodyData))
            .objectValue?["error"]?.objectValue?["code"]
    }

    @Test("Keys that differ only in case are joined in key order, whatever the dictionary order")
    func caseVariantKeysAreJoined() {
        var forward: [String: String] = [:]
        forward["mcp-method"] = "a"
        forward["MCP-Method"] = "b"
        var backward: [String: String] = [:]
        backward["MCP-Method"] = "b"
        backward["mcp-method"] = "a"
        for headers in [forward, backward] {
            #expect(HTTPRequest(method: "POST", headers: headers).header("Mcp-Method") == "b, a")
        }
        #expect(HTTPRequest(method: "POST", headers: ["Mcp-Method": "a"]).header("mcp-method") == "a")
    }

    @Test("The headers of one request are served")
    func singleHeaders() async throws {
        let response = try await post([HTTPHeaderName.protocolVersion: "2026-07-28", "Mcp-Method": "tools/list"])
        #expect(response.statusCode == 200)
    }

    @Test(
        "A repeated MCP-Protocol-Version or Mcp-Method is -32020",
        arguments: [
            [HTTPHeaderName.protocolVersion: "2026-07-28, 2026-07-28", "Mcp-Method": "tools/list"],
            ["MCP-Protocol-Version": "2026-07-28", "mcp-protocol-version": "2026-07-28", "Mcp-Method": "tools/list"],
            [HTTPHeaderName.protocolVersion: "2026-07-28", "Mcp-Method": "tools/list, tools/list"],
            [HTTPHeaderName.protocolVersion: "2026-07-28", "mcp-method": "tools/list", "Mcp-Method": "tools/call"],
        ])
    func repeatedHeaders(_ headers: [String: String]) async throws {
        let response = try await post(headers)
        #expect(response.statusCode == 400)
        #expect(try errorCode(response) == -32020)
    }

    @Test("A repeated handshake MCP-Protocol-Version stays -32022")
    func repeatedHandshakeVersion() async throws {
        let response = try await post([HTTPHeaderName.protocolVersion: "2025-11-25, 2025-11-25"])
        #expect(response.statusCode == 400)
        #expect(try errorCode(response) == -32022)
    }
}

@Suite("Header field lines")
struct HeaderFieldLineTests {
    private static let meta =
        #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

    private static func call(_ name: String, arguments: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments),\#(meta)}}"#
    }

    /// The headers of a 2026-07-28 `tools/call` of `name`, then `extra`.
    private static func fields(
        calling name: String, _ extra: [(name: String, value: String)] = []
    ) -> [(name: String, value: String)] {
        [
            ("Content-Type", "application/json"), ("Accept", "application/json"),
            (HTTPHeaderName.protocolVersion, "2026-07-28"), (MCPRequestHeaders.method, "tools/call"),
            (MCPRequestHeaders.name, name),
        ] + extra
    }

    /// Sends `body` with `fields` to a server with a `route` tool that
    /// mirrors `region` into `Mcp-Param-Region`.
    private func post(_ body: String, fields: [(name: String, value: String)]) async throws -> HTTPResponse {
        let server = Server(name: "fields", version: "1", capabilities: .init(tools: .init()))
        let route = Tool(
            name: "route", description: nil,
            inputSchema: ["type": "object", "properties": ["region": ["type": "string", "x-mcp-header": "Region"]]])
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: [route]) }
        await server.withMethodHandler(CallTool.self) { params in .init(content: [.text(text: params.name)]) }
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        let response = await transport.handleRequest(
            HTTPRequest(method: "POST", headerFields: fields, body: Data(body.utf8), path: "/mcp"))
        await server.stop()
        return response
    }

    private func errorCode(_ response: HTTPResponse) throws -> Value? {
        try JSONDecoder().decode(Value.self, from: try #require(response.bodyData))
            .objectValue?["error"]?.objectValue?["code"]
    }

    @Test("Field lines are folded case-insensitively and joined in order; each value stays readable")
    func folding() {
        let request = HTTPRequest(
            method: "POST",
            headerFields: [("Accept", "application/json"), ("X-Tag", "a"), ("x-tag", "b"), ("X-TAG", "c")])
        #expect(request.headers == ["Accept": "application/json", "X-Tag": "a, b, c"])
        #expect(request.header("x-tag") == "a, b, c")
        #expect(request.headerValues("X-Tag") == ["a", "b", "c"])
        #expect(request.headerValues("Accept") == ["application/json"])
        #expect(request.headerValues("Missing") == [])

        let dictionary = HTTPRequest(method: "POST", headers: ["X-Tag": "a, b"])
        #expect(dictionary.headerValues("x-tag") == ["a, b"])
    }

    @Test("One line of each header is served, including a name with a comma")
    func singleLines() async throws {
        for (name, arguments, extra) in [
            ("route", #"{"region":"us"}"#, [(name: "Mcp-Param-Region", value: "us")]),
            ("a,b", "{}", []),
        ] {
            let response = try await post(Self.call(name, arguments: arguments), fields: Self.fields(calling: name, extra))
            #expect(response.statusCode == 200, "\(name)")
        }
    }

    @Test("A repeated single-valued header on separate lines is -32020, even with equal values")
    func repeatedLines() async throws {
        let cases: [(String, [(name: String, value: String)])] = [
            ("protocol version", [(HTTPHeaderName.protocolVersion, "2026-07-28")]),
            ("method", [("mcp-method", "tools/call")]),
            ("name", [("MCP-NAME", "route")]),
            ("parameter", [("Mcp-Param-Region", "us"), ("mcp-param-region", "us")]),
        ]
        for (label, extra) in cases {
            let response = try await post(
                Self.call("route", arguments: #"{"region":"us"}"#), fields: Self.fields(calling: "route", extra))
            #expect(response.statusCode == 400, "\(label)")
            #expect(try errorCode(response) == -32020, "\(label)")
        }
    }
}
