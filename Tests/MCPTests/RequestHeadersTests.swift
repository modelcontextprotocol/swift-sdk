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
