import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Value Tests")
struct ValueTests {

    // MARK: - numberValue

    @Test("numberValue returns the underlying Int promoted to Double")
    func numberValueFromInt() {
        #expect(Value.int(0).numberValue == 0.0)
        #expect(Value.int(42).numberValue == 42.0)
        #expect(Value.int(-7).numberValue == -7.0)
    }

    @Test("numberValue returns the underlying Double unchanged")
    func numberValueFromDouble() {
        #expect(Value.double(0.0).numberValue == 0.0)
        #expect(Value.double(0.5).numberValue == 0.5)
        #expect(Value.double(-1.25).numberValue == -1.25)
    }

    @Test("numberValue returns nil for non-numeric cases")
    func numberValueNilForNonNumeric() {
        #expect(Value.null.numberValue == nil)
        #expect(Value.bool(true).numberValue == nil)
        #expect(Value.string("42").numberValue == nil)
        #expect(Value.array([.int(1)]).numberValue == nil)
        #expect(Value.object(["x": .int(1)]).numberValue == nil)
    }

    // MARK: - JSON round-trip

    @Test("numberValue survives a JSON round-trip of a whole-number Double")
    func numberValueSurvivesJSONRoundTripWholeNumber() throws {
        // The motivating case: Value.double(0) encodes as JSON `0`, the
        // decoder picks Int first, so doubleValue is nil but numberValue
        // still returns the number.
        let encoded = try JSONEncoder().encode(Value.double(0))
        let decoded = try JSONDecoder().decode(Value.self, from: encoded)
        #expect(decoded.doubleValue == nil, "whole-number Double round-trips through Int")
        #expect(decoded.intValue == 0)
        #expect(decoded.numberValue == 0.0)
    }

    @Test("numberValue handles a typical coordinate array round-trip")
    func numberValueHandlesCoordinateArrayRoundTrip() throws {
        // [0, 0, 1] is the natural JSON shape for a unit Z direction —
        // the exact case that hits the Int/Double decoding gotcha.
        let original: Value = .array([.double(0), .double(0), .double(1)])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Value.self, from: encoded)
        guard let arr = decoded.arrayValue, arr.count == 3 else {
            Issue.record("expected 3-element array, got \(decoded)")
            return
        }
        #expect(arr[0].numberValue == 0.0)
        #expect(arr[1].numberValue == 0.0)
        #expect(arr[2].numberValue == 1.0)
    }

    @Test("numberValue returns the fractional value when JSON carries a decimal")
    func numberValueHandlesFractional() throws {
        let encoded = try JSONEncoder().encode(Value.double(0.5))
        let decoded = try JSONDecoder().decode(Value.self, from: encoded)
        #expect(decoded.doubleValue == 0.5)
        #expect(decoded.numberValue == 0.5)
    }
}
