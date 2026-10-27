import Foundation
import Testing

@testable import MCP

@Suite("Value Tests")
struct ValueTests {
    private let ambiguousJSONStringSamples = [
        "data:text/plain,Hello%20World",
        "data:text/plain,Hello World",
        "data:text/plain;base64,SGVsbG8=",
        "data:,",
        "data:text/plain;base64,%%%%",
        "data:text/plain;base64",
        "data:text/plain,%E2%9C%93",
        "data:text/plain,こんにちは%20🌍",
        "data:application/octet-stream;base64,AAEC/w==",
    ]

    @Test("A data-URL-looking JSON string decodes as Value.string")
    func literalDataURLJSONStringDecodesAsString() throws {
        // Use literal JSON bytes so this test exercises Value.init(from:) without using
        // JSONEncoder to construct the input.
        let json = Data(#""data:text/plain,Hello%20World""#.utf8)
        let decoded = try JSONDecoder().decode(Value.self, from: json)

        guard case .string(let value) = decoded else {
            Issue.record("Expected Value.string; JSON strings must not be inferred as Value.data")
            return
        }

        #expect(value == "data:text/plain,Hello%20World")
        #expect(value.utf8.elementsEqual("data:text/plain,Hello%20World".utf8))
    }

    @Test("Data-URL-looking JSON string variants never infer Value.data")
    func dataURLLookingStringsDecodeAsStrings() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for string in ambiguousJSONStringSamples {
            let json = try encoder.encode(string)
            let decoded = try decoder.decode(Value.self, from: json)

            guard case .string(let decodedString) = decoded else {
                Issue.record(
                    "Expected Value.string for JSON string \(String(reflecting: string)); generic JSON decoding must not infer Value.data"
                )
                continue
            }

            #expect(decodedString == string)
            #expect(decodedString.utf8.elementsEqual(string.utf8))
        }
    }

    @Test("Nested data-URL-looking JSON strings remain strings")
    func nestedDataURLLookingStringsRemainStrings() throws {
        let expected = Value.object([
            "array": .array(ambiguousJSONStringSamples.map(Value.string)),
            "object": .object(
                Dictionary(
                    uniqueKeysWithValues: ambiguousJSONStringSamples.enumerated().map {
                        ("value\($0.offset)", Value.string($0.element))
                    }
                )
            ),
        ])

        let json = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(Value.self, from: json)

        #expect(decoded == expected)
    }

    @Test("JSON strings round trip without changing type or spelling")
    func stringsRoundTripWithoutChangingTypeOrSpelling() throws {
        let strings = [
            "",
            "ordinary text",
            "slashes / and percent spelling %20 stay text",
            "Unicode: café ✓ 🌍",
        ] + ambiguousJSONStringSamples
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for string in strings {
            let decoded = try decoder.decode(Value.self, from: encoder.encode(string))
            let reencoded = try encoder.encode(decoded)

            #expect(decoded == .string(string))
            #expect(try decoder.decode(String.self, from: reencoded) == string)
            #expect(try decoder.decode(Value.self, from: reencoded) == .string(string))
        }
    }

    @Test("Explicit data values retain data-URL encoding")
    func explicitDataValuesRetainDataURLEncoding() throws {
        let value = Value.data(
            mimeType: "application/octet-stream",
            Data([0x00, 0x01, 0x02, 0xff])
        )

        let json = try JSONEncoder().encode(value)
        let encodedString = try JSONDecoder().decode(String.self, from: json)

        #expect(encodedString == "data:application/octet-stream;base64,AAEC/w==")
    }

    @Test("A data URL on the JSON wire carries no implicit Value.data tag")
    func encodedDataURLDecodesGenericallyAsString() throws {
        let explicitData = Value.data(
            mimeType: "application/octet-stream",
            Data([0x00, 0x01, 0x02, 0xff])
        )

        // Value.data intentionally encodes as a JSON string. Once encoded, its JSON is
        // indistinguishable from an ordinary string containing the same data URL.
        let json = try JSONEncoder().encode(explicitData)
        let decoded = try JSONDecoder().decode(Value.self, from: json)

        #expect(decoded == .string("data:application/octet-stream;base64,AAEC/w=="))
    }

    @Test("Typed text content remains text through Value erasure")
    func typedTextContentRemainsTextThroughValueErasure() throws {
        let original = "data:text/plain,Hello%20World"
        let result = CallTool.Result(content: [
            .text(text: original, annotations: nil, _meta: nil)
        ])

        // MCP explicitly tags this value as text. The SDK erases typed results to Value before
        // sending them, so generic string decoding must not reinterpret the text as binary data.
        let erased = try Value(result)
        let json = try JSONEncoder().encode(erased)
        let recovered = try JSONDecoder().decode(CallTool.Result.self, from: json)

        #expect(recovered.content.count == 1)
        guard case .text(let text, _, _) = recovered.content.first else {
            Issue.record("Expected typed text content")
            return
        }
        #expect(text == original)
        #expect(text.utf8.elementsEqual(original.utf8))
    }

    @Test("Typed image and audio content retain explicit fields")
    func typedBinaryContentRetainsExplicitFields() throws {
        let cases: [(content: Tool.Content, fields: [String: String])] = [
            (
                .image(
                    data: "SGVsbG8=",
                    mimeType: "image/png",
                    annotations: nil,
                    _meta: nil
                ),
                ["type": "image", "data": "SGVsbG8=", "mimeType": "image/png"]
            ),
            (
                .audio(
                    data: "UklGRg==",
                    mimeType: "audio/wav",
                    annotations: nil,
                    _meta: nil
                ),
                ["type": "audio", "data": "UklGRg==", "mimeType": "audio/wav"]
            ),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for testCase in cases {
            let json = try encoder.encode(testCase.content)
            #expect(try decoder.decode([String: String].self, from: json) == testCase.fields)
            #expect(try decoder.decode(Tool.Content.self, from: json) == testCase.content)
        }
    }
}
