import Foundation
import Testing

@testable import MCP

@Suite("Value JSON String Tests")
struct ValueDecodingTests {
    @Test("Data-URL-looking strings stay strings in nested JSON")
    func dataURLStringsStayStrings() throws {
        let strings = [
            "data:text/plain,Hello%20World",
            "data:text/plain;base64,SGVsbG8=",
            "data:application/octet-stream;base64,AAEC/w==",
        ]
        let expected = Value.object(["values": .array(strings.map(Value.string))])
        let json = try JSONEncoder().encode(expected)
        #expect(try JSONDecoder().decode(Value.self, from: json) == expected)
    }

    @Test("Explicit data encoding does not change how generic JSON strings decode")
    func explicitDataNeedsAnExplicitType() throws {
        let data = Value.data(mimeType: "application/octet-stream", Data([0, 1, 2]))
        let json = try JSONEncoder().encode(data)
        let string = try JSONDecoder().decode(String.self, from: json)
        #expect(string == "data:application/octet-stream;base64,AAEC")
        #expect(try JSONDecoder().decode(Value.self, from: json) == .string(string))
        let parsed = try #require(Data.parseDataURL(string))
        #expect(parsed.mimeType == "application/octet-stream")
        #expect(parsed.data == Data([0, 1, 2]))
    }

    @Test("Tool text content survives Value erasure")
    func toolTextContentSurvivesValueErasure() throws {
        let text = "data:text/plain,Hello%20World"
        let result = CallTool.Result(content: [
            .text(text: text, annotations: nil, _meta: nil)
        ])
        let erased = try Value(result)
        let recovered = try JSONDecoder().decode(
            CallTool.Result.self,
            from: JSONEncoder().encode(erased)
        )
        guard case .text(let recoveredText, _, _) = recovered.content.first else {
            Issue.record("Expected text content")
            return
        }
        #expect(recoveredText == text)
    }
}
