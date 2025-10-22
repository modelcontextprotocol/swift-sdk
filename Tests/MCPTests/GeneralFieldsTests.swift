import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.JSONSerialization

@testable import MCP

@Suite("General Fields")
struct GeneralFieldsTests {
    private struct Payload: Codable, Hashable, Sendable {
        let message: String
    }

    private enum TestMethod: Method {
        static let name = "test.general"
        typealias Parameters = Payload
        typealias Result = Payload
    }

    @Test("Encoding includes meta and custom fields")
    func testEncodingGeneralFields() throws {
        let meta = try MetaFields(values: ["vendor.example/request-id": .string("abc123")])
        let general = GeneralFields(meta: meta, additional: ["custom": .int(5)])

        let request = Request<TestMethod>(
            id: 42,
            method: TestMethod.name,
            params: Payload(message: "hello"),
            generalFields: general
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/request-id"] as? String == "abc123")
        #expect(json?["custom"] as? Int == 5)
    }

    @Test("Decoding restores general fields")
    func testDecodingGeneralFields() throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 7,
            "method": TestMethod.name,
            "params": ["message": "hi"],
            "_meta": ["vendor.example/session": "s42"],
            "custom-data": ["value": 1],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(Request<TestMethod>.self, from: data)

        let metaValue = decoded.generalFields.meta?.dictionary["vendor.example/session"]
        #expect(metaValue == .string("s42"))
        #expect(decoded.generalFields.additional["custom-data"] == .object(["value": .int(1)]))
    }

    @Test("Reserved fields are ignored when encoding extras")
    func testReservedFieldsIgnored() throws {
        let general = GeneralFields(
            meta: nil,
            additional: ["method": .string("override"), "custom": .bool(true)]
        )

        let request = Request<TestMethod>(
            id: 1,
            method: TestMethod.name,
            params: Payload(message: "ping"),
            generalFields: general
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["method"] as? String == TestMethod.name)
        #expect(json?["custom"] as? Bool == true)

        let decoded = try JSONDecoder().decode(Request<TestMethod>.self, from: data)
        #expect(decoded.generalFields.additional["method"] == nil)
        #expect(decoded.generalFields.additional["custom"] == .bool(true))
    }

    @Test("Invalid meta key is rejected")
    func testInvalidMetaKey() {
        #expect(throws: GeneralFieldError.invalidMetaKey("invalid key")) {
            _ = try MetaFields(values: ["invalid key": .int(1)])
        }
    }

    @Test("Response encoding includes general fields")
    func testResponseGeneralFields() throws {
        let meta = try MetaFields(values: ["vendor.example/status": .string("partial")])
        let general = GeneralFields(meta: meta, additional: ["progress": .int(50)])
        let response = Response<TestMethod>(
            id: 99,
            result: .success(Payload(message: "ok")),
            general: general
        )

        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/status"] as? String == "partial")
        #expect(json?["progress"] as? Int == 50)

        let decoded = try JSONDecoder().decode(Response<TestMethod>.self, from: data)
        #expect(decoded.general.additional["progress"] == .int(50))
        #expect(
            decoded.general.meta?.dictionary["vendor.example/status"]
                == .string("partial")
        )
    }

    @Test("Tool encoding and decoding with general fields")
    func testToolGeneralFields() throws {
        let meta = try MetaFields(values: [
            "vendor.example/outputTemplate": .string("ui://widget/kanban-board.html")
        ])
        let general = GeneralFields(
            meta: meta,
            additional: ["openai/toolInvocation/invoking": .string("Displaying the board")]
        )

        let tool = Tool(
            name: "kanban-board",
            title: "Kanban Board",
            description: "Display kanban widget",
            inputSchema: try Value(["type": "object"]),
            general: general
        )

        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(
            metaObject?["vendor.example/outputTemplate"] as? String
                == "ui://widget/kanban-board.html")
        #expect(json?["openai/toolInvocation/invoking"] as? String == "Displaying the board")

        let decoded = try JSONDecoder().decode(Tool.self, from: data)
        #expect(
            decoded.general.additional["openai/toolInvocation/invoking"]
                == .string("Displaying the board"))
        #expect(
            decoded.general.meta?.dictionary["vendor.example/outputTemplate"]
                == .string("ui://widget/kanban-board.html")
        )
    }

    @Test("Resource content encodes meta")
    func testResourceContentGeneralFields() throws {
        let meta = try MetaFields(values: [
            "openai/widgetPrefersBorder": .bool(true)
        ])
        let general = GeneralFields(
            meta: meta,
            additional: ["openai/widgetDomain": .string("https://chatgpt.com")]
        )

        let content = Resource.Content.text(
            "<div>Widget</div>",
            uri: "ui://widget/kanban-board.html",
            mimeType: "text/html",
            general: general
        )

        let data = try JSONEncoder().encode(content)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let metaObject = json?["_meta"] as? [String: Any]

        #expect(metaObject?["openai/widgetPrefersBorder"] as? Bool == true)
        #expect(json?["openai/widgetDomain"] as? String == "https://chatgpt.com")

        let decoded = try JSONDecoder().decode(Resource.Content.self, from: data)
        #expect(
            decoded.general.meta?.dictionary["openai/widgetPrefersBorder"] == .bool(true))
        #expect(decoded.general.additional["openai/widgetDomain"] == .string("https://chatgpt.com"))
    }
}
