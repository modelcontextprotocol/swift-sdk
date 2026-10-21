import Foundation
import Testing

@testable import MCP

@Suite("Raw JSON Value Tests")
struct RawJSONValueTests {
    @Test("Objects preserve order, duplicates, and scalar-exact keys")
    func exactObjectMembers() throws {
        let data = #"{"\u00e9":1,"é":2,"e\u0301":3,"same":4,"same":5}"#.data(using: .utf8)!
        let value = try RawJSONValue.decode(data)
        let object = try #require(value.objectValue)

        #expect(object.members.count == 5)
        #expect(object.members.map(\.value) == [
            .number("1"), .number("2"), .number("3"), .number("4"), .number("5"),
        ])
        #expect(object.members[0].key.unicodeScalars.map(\.value) == [0xE9])
        #expect(object.members[1].key.unicodeScalars.map(\.value) == [0xE9])
        #expect(object.members[2].key.unicodeScalars.map(\.value) == [0x65, 0x301])
        #expect(object.values(forExactKey: "é") == [.number("1"), .number("2")])
        #expect(object.values(forExactKey: "e\u{301}") == [.number("3")])
        #expect(object.values(forExactKey: "same") == [.number("4"), .number("5")])
        #expect(object.uniqueValue(forExactKey: "same") == nil)
        #expect(RawJSONValue.string("é") != RawJSONValue.string("e\u{301}"))
    }

    @Test("Escapes decode semantically without normalizing or coercing data URLs")
    func stringsRemainStrings() throws {
        let json = #"""
            ["é","\u00e9","e\u0301","/","\/","data:,A%20brief%20note",
             "d\u0061ta:text/plain;base64,SGVsbG8="]
            """#
        let data = json.data(using: .utf8)!
        let value = try RawJSONValue.decode(data)
        guard case .array(let values) = value else {
            Issue.record("Expected an array")
            return
        }

        #expect(values[0] == values[1])
        #expect(values[0] != values[2])
        #expect(values[3] == values[4])
        #expect(values[5] == .string("data:,A%20brief%20note"))
        #expect(values[6] == .string("data:text/plain;base64,SGVsbG8="))
        #expect(values.allSatisfy { value in
            if case .data = value { return false }
            return true
        })
    }

    @Test("Numbers retain their exact JSON lexemes", arguments: [
        "0", "-0", "1", "1.0", "1e+10", "1E-10", "123456789012345678901234567890",
    ])
    func numberLexemes(number: String) throws {
        let value = try RawJSONValue.decode(Data(number.utf8))
        #expect(value == .number(number))
        #expect(try value.encodedData() == Data(number.utf8))
    }

    @Test("Malformed JSON is rejected", arguments: [
        "", "01", "-", "1.", ".1", "1e", "+1", "NaN", "Infinity", "[", "{\"a\":1", "true false",
        "\"\\uD800\"", "\"\\uDC00\"", "\"\\uD800\\u0041\"", "\"\\uZZZZ\"",
    ])
    func malformedJSON(json: String) {
        #expect(throws: (any Error).self) {
            try RawJSONValue.decode(Data(json.utf8))
        }
    }

    @Test("Invalid UTF-8 and raw controls are rejected")
    func invalidStrings() {
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(Data([0x22, 0xC3, 0x28, 0x22]))
        }
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(Data([0x22, 0x0A, 0x22]))
        }

        var malformedBatch = Data(#"[{"value":""#.utf8)
        malformedBatch.append(contentsOf: [0xC3, 0x28])
        malformedBatch.append(contentsOf: Data(#""}]"#.utf8))
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.batchElementRanges(in: malformedBatch)
        }
    }

    @Test("Decoded string limits count Unicode output, not escape spelling")
    func decodedStringBounds() throws {
        let oneByte = limits(maximumStringBytes: 1)
        #expect(try RawJSONValue.decode(Data(#""\u0061""#.utf8), limits: oneByte) == .string("a"))

        let twoBytes = limits(maximumStringBytes: 2)
        #expect(try RawJSONValue.decode(Data(#""\u00e9""#.utf8), limits: twoBytes) == .string("é"))

        let fourBytes = limits(maximumStringBytes: 4)
        #expect(try RawJSONValue.decode(Data(#""\uD83D\uDE00""#.utf8), limits: fourBytes) == .string("😀"))

        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(Data(#""\u00e9""#.utf8), limits: oneByte)
        }
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(Data(#""e\u0301""#.utf8), limits: twoBytes)
        }
    }

    @Test("Container depth and entry limits are consistent")
    func structuralBounds() throws {
        let noContainers = limits(maximumDepth: 0)
        #expect(try RawJSONValue.decode(Data("0".utf8), limits: noContainers) == .number("0"))
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(Data("[]".utf8), limits: noContainers)
        }

        let oneContainer = limits(maximumDepth: 1)
        #expect(try RawJSONValue.decode(Data("[]".utf8), limits: oneContainer) == .array([]))
        #expect(try RawJSONValue.decode(Data("[0]".utf8), limits: oneContainer) == .array([.number("0")]))
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(Data("[[]]".utf8), limits: oneContainer)
        }

        let oneEntry = limits(maximumContainerEntries: 1)
        #expect(try RawJSONValue.decode(Data("[0]".utf8), limits: oneEntry) == .array([.number("0")]))
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(Data("[0,1]".utf8), limits: oneEntry)
        }
    }

    @Test("Document size is checked before parsing")
    func documentBound() throws {
        let data = Data(" [0] ".utf8)
        let decoded = try RawJSONValue.decode(
            data,
            limits: limits(maximumDocumentBytes: data.count)
        )
        #expect(decoded == .array([.number("0")]))
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.decode(data, limits: limits(maximumDocumentBytes: data.count - 1))
        }
    }

    @Test("A cancelled parse fails before copying or decoding input")
    func cancellation() async {
        let data = Data(repeating: 0x20, count: 8 * 1024 * 1024) + Data("null".utf8)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try RawJSONValue.decode(data)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("A cancelled routing scan propagates cancellation")
    func routingCancellation() async {
        let data = Data(
            #"{"jsonrpc":"2.0","id":1,"params":{"payload":"value"},"method":"raw"}"#.utf8
        )
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try RawJSONValue.requestRoute(
                in: data,
                rawAwareMethods: ["raw"],
                maximumIDBytes: 128
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Programmatic data is bounded before base64 encoding")
    func programmaticDataBound() throws {
        let value = RawJSONValue.data(mimeType: "application/octet-stream", Data(repeating: 0xAB, count: 100))
        #expect(throws: RawJSONError.self) {
            try value.encodedData(limits: limits(maximumStringBytes: 32))
        }

        let encoded = try value.encodedData(limits: limits(maximumStringBytes: 512))
        let decoded = try RawJSONValue.decode(encoded, limits: limits(maximumStringBytes: 512))
        guard case .string(let string) = decoded else {
            Issue.record("Programmatic data must encode as a JSON string")
            return
        }
        #expect(string.hasPrefix("data:application/octet-stream;base64,"))
    }

    @Test("Exact values round-trip without losing duplicate members")
    func exactRoundTrip() throws {
        let original = try RawJSONValue.decode(
            Data(#"{"a":1,"a":2,"é":"literal","e\u0301":"decomposed","n":1e+02}"#.utf8)
        )
        let encoded = try original.encodedData()
        #expect(try RawJSONValue.decode(encoded) == original)
    }

    @Test("Batch element splitting ignores delimiters inside nested strings")
    func batchElementRanges() throws {
        let data = Data(#"[ {"text":",]}","nested":[1,{"quote":"\""}]}, true, 1e2 ]"#.utf8)
        let ranges = try RawJSONValue.batchElementRanges(in: data)
        #expect(ranges.count == 3)
        #expect(try RawJSONValue.decode(data.subdata(in: ranges[0])).objectValue != nil)
        #expect(try RawJSONValue.decode(data.subdata(in: ranges[1])) == .bool(true))
        #expect(try RawJSONValue.decode(data.subdata(in: ranges[2])) == .number("1e2"))
    }

    @Test("Batch splitting rejects malformed JSON", arguments: [
        "[1 2]", #"[{"x":"\q"}]"#, #"[{"x":1]]"#,
    ])
    func malformedBatchSplitting(json: String) {
        #expect(throws: RawJSONError.self) {
            try RawJSONValue.batchElementRanges(in: Data(json.utf8))
        }
    }

    private func limits(
        maximumDocumentBytes: Int = 1024,
        maximumStringBytes: Int = 128,
        maximumDepth: Int = 8,
        maximumContainerEntries: Int = 64
    ) -> RawJSONLimits {
        RawJSONLimits(
            maximumDocumentBytes: maximumDocumentBytes,
            maximumStringBytes: maximumStringBytes,
            maximumDepth: maximumDepth,
            maximumContainerEntries: maximumContainerEntries
        )
    }
}
