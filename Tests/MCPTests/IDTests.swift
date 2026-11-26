import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.UUID

@testable import MCP

@Suite("ID Tests")
struct IDTests {
    @Test("String ID initialization and encoding")
    func testStringID() throws {
        let id: ID = "test-id"
        #expect(id.description == "test-id")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(id)
        let decoded = try decoder.decode(ID.self, from: data)
        #expect(decoded == id)
    }

    @Test("Number ID initialization and encoding")
    func testNumberID() throws {
        let id: ID = 42
        #expect(id.description == "42")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(id)
        let decoded = try decoder.decode(ID.self, from: data)
        #expect(decoded == id)
    }

    @Test("Random ID generation uses monotonic integers")
    func testRandomID() throws {
        let id1 = ID.random
        let id2 = ID.random
        #expect(id1 != id2, "Random IDs should be unique")

        guard case .number(let n1) = id1, case .number(let n2) = id2 else {
            Issue.record("Random ID should be number type")
            return
        }
        #expect(n2 > n1)

        let encoder = JSONEncoder()
        let data = try encoder.encode(id1)
        let json = String(data: data, encoding: .utf8)
        #expect(json == String(n1), "Encoded random ID should be a bare JSON number")
    }

    @Test("Random UUID ID generation")
    func testRandomUUIDID() throws {
        let id1 = ID.randomUUID
        let id2 = ID.randomUUID
        #expect(id1 != id2, "UUID IDs should be unique")

        if case .string(let str) = id1 {
            #expect(!str.isEmpty)
            #expect(UUID(uuidString: str) != nil)
        } else {
            Issue.record("randomUUID ID should be string type")
        }
    }
}
