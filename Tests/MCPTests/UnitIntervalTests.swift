import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("UnitInterval Tests")
struct UnitIntervalTests {
    @Test("Valid literal initialization")
    func testValidLiteralInitialization() throws {
        let zero: UnitInterval = 0.0
        #expect(zero.doubleValue == 0.0)

        let half: UnitInterval = 0.5
        #expect(half.doubleValue == 0.5)

        let one: UnitInterval = 1.0
        #expect(one.doubleValue == 1.0)

        let quarter: UnitInterval = 0.25
        #expect(quarter.doubleValue == 0.25)
    }

    @Test("Valid failable initialization with runtime values")
    func testValidFailableInitialization() throws {
        // Test with runtime computed values to force use of failable initializer
        let values = [0.0, 0.5, 1.0, 0.25]

        for value in values {
            let computed = value * 1.0  // Force runtime computation
            let interval = UnitInterval(computed)
            #expect(interval != nil)
            #expect(interval!.doubleValue == value)
        }
    }

    @Test("Invalid failable initialization")
    func testInvalidFailableInitialization() throws {
        // Test with runtime computed values to force use of failable initializer
        let invalidValues = [-0.1, 1.1, 100.0, -100.0]

        for value in invalidValues {
            let computed = value * 1.0  // Force runtime computation
            let interval = UnitInterval(computed)
            #expect(interval == nil)
        }
    }

    @Test("Boundary and edge case values")
    func testBoundaryAndEdgeCaseValues() throws {
        // Test exact boundary values
        let exactZero = 0.0 * 1.0
        let zero = UnitInterval(exactZero)
        #expect(zero != nil)

        let exactOne = 1.0 * 1.0
        let one = UnitInterval(exactOne)
        #expect(one != nil)

        // Test machine precision boundaries
        let justAboveZero = Double.ulpOfOne * 1.0
        let aboveZero = UnitInterval(justAboveZero)
        #expect(aboveZero != nil)

        let justBelowOne = (1.0 - Double.ulpOfOne) * 1.0
        let belowOne = UnitInterval(justBelowOne)
        #expect(belowOne != nil)

        // Test very small positive value
        let tinyValue = 1e-10 * 1.0
        let tiny = UnitInterval(tinyValue)
        #expect(tiny != nil)
        #expect(tiny!.doubleValue == 1e-10)

        // Test value very close to 1
        let almostOneValue = 0.9999999999 * 1.0
        let almostOne = UnitInterval(almostOneValue)
        #expect(almostOne != nil)
        #expect(almostOne!.doubleValue == 0.9999999999)
    }

    @Test("Float literal initialization")
    func testFloatLiteralInitialization() throws {
        let zero: UnitInterval = 0.0
        #expect(zero.doubleValue == 0.0)

        let half: UnitInterval = 0.5
        #expect(half.doubleValue == 0.5)

        let one: UnitInterval = 1.0
        #expect(one.doubleValue == 1.0)

        let quarter: UnitInterval = 0.25
        #expect(quarter.doubleValue == 0.25)
    }

    @Test("Integer literal initialization")
    func testIntegerLiteralInitialization() throws {
        let zero: UnitInterval = 0
        #expect(zero.doubleValue == 0.0)

        let one: UnitInterval = 1
        #expect(one.doubleValue == 1.0)
    }

    @Test("Comparable conformance")
    func testComparable() throws {
        let zero: UnitInterval = 0.0
        let quarter: UnitInterval = 0.25
        let half: UnitInterval = 0.5
        let one: UnitInterval = 1.0

        #expect(zero < quarter)
        #expect(quarter < half)
        #expect(half < one)
        #expect(zero < one)

        #expect(!(quarter < zero))
        #expect(!(half < quarter))
        #expect(!(one < half))

        #expect(zero <= quarter)
        #expect(quarter <= half)
        #expect(half <= one)
        #expect(zero <= zero)

        #expect(quarter > zero)
        #expect(half > quarter)
        #expect(one > half)

        #expect(quarter >= zero)
        #expect(half >= quarter)
        #expect(one >= half)
        #expect(one >= one)
    }

    @Test("Equality and hashing")
    func testEqualityAndHashing() throws {
        let half1: UnitInterval = 0.5
        let half2: UnitInterval = 0.5
        let quarter: UnitInterval = 0.25

        #expect(half1 == half2)
        #expect(half1 != quarter)
        #expect(half1.hashValue == half2.hashValue)
    }

    @Test("String description")
    func testStringDescription() throws {
        let zero: UnitInterval = 0.0
        #expect(zero.description == "0.0")

        let half: UnitInterval = 0.5
        #expect(half.description == "0.5")

        let one: UnitInterval = 1.0
        #expect(one.description == "1.0")

        let quarter: UnitInterval = 0.25
        #expect(quarter.description == "0.25")
    }

    @Test("JSON encoding and decoding")
    func testJSONCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original: UnitInterval = 0.75

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(UnitInterval.self, from: data)

        #expect(decoded == original)
        #expect(decoded.doubleValue == 0.75)
    }

    @Test("JSON decoding with invalid values")
    func testJSONDecodingInvalidValues() throws {
        let decoder = JSONDecoder()

        // Test negative value
        let negativeJSON = "-0.5".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try decoder.decode(UnitInterval.self, from: negativeJSON)
        }

        // Test value greater than 1
        let tooLargeJSON = "1.5".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try decoder.decode(UnitInterval.self, from: tooLargeJSON)
        }
    }

    @Test("JSON encoding produces expected format")
    func testJSONEncodingFormat() throws {
        let encoder = JSONEncoder()

        let half: UnitInterval = 0.5
        let data = try encoder.encode(half)
        let jsonString = String(data: data, encoding: .utf8)

        #expect(jsonString == "0.5")
    }

    @Test("Double value property")
    func testDoubleValueProperty() throws {
        let values = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]

        for value in values {
            let computed = value * 1.0  // Force runtime computation
            if let interval = UnitInterval(computed) {
                #expect(interval.doubleValue == value)
            } else {
                #expect(Bool(false), "UnitInterval(\(value)) should succeed")
            }
        }
    }
}
