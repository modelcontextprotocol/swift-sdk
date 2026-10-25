import Foundation
import Testing

@testable import MCP

@Suite("Server-sent event parser")
struct ServerSentEventParserTests {
    /// Parses `text` and returns the events, including the one `finish()` returns.
    func events(_ text: String) throws -> [ServerSentEvent] {
        try events(Array(text.utf8))
    }

    func events(_ bytes: [UInt8]) throws -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for byte in bytes {
            if let event = try parser.consume(byte) { events.append(event) }
        }
        if let event = parser.finish() { events.append(event) }
        return events
    }

    @Test("Fields, a leading space and the event type")
    func fields() throws {
        #expect(
            try events("event: message\nid: 7\ndata: {\"a\":1}\nretry: 1500\n\n")
                == [ServerSentEvent(id: "7", event: "message", data: #"{"a":1}"#, retry: 1500)])
        // Only one leading space is dropped; no colon means an empty value.
        #expect(try events("data:  two\n\n") == [ServerSentEvent(data: " two")])
        #expect(try events("data\n\n") == [ServerSentEvent(data: "")])
    }

    @Test("Data lines are joined with line feeds")
    func multilineData() throws {
        #expect(try events("data: a\ndata: b\ndata:\n\n") == [ServerSentEvent(data: "a\nb\n")])
        #expect(try events("data:\ndata:\n\n") == [ServerSentEvent(data: "\n")])
    }

    @Test("CR, LF and CR LF end lines")
    func lineEndings() throws {
        let expected = [ServerSentEvent(data: "x"), ServerSentEvent(data: "y")]
        #expect(try events("data: x\r\n\r\ndata: y\r\n\r\n") == expected)
        #expect(try events("data: x\r\rdata: y\r\r") == expected)
        #expect(try events("data: x\n\ndata: y\n\n") == expected)
        // A CR LF split across reads is one line ending.
        var parser = ServerSentEventParser()
        for byte in Array("data: x\r".utf8) { #expect(try parser.consume(byte) == nil) }
        #expect(try parser.consume(0x0A) == nil)
        #expect(try parser.consume(0x0A) == ServerSentEvent(data: "x"))
    }

    @Test("Comments, unknown fields and blank blocks are no events")
    func ignored() throws {
        #expect(try events(": keep-alive\n\n").isEmpty)
        #expect(try events("foo: bar\n\n").isEmpty)
        #expect(try events("\n\n\n").isEmpty)
        #expect(try events(": c\ndata: x\n: c\n\n") == [ServerSentEvent(data: "x")])
    }

    @Test("A priming event has an id and empty data; a reconnection hint only a retry")
    func eventsWithoutData() throws {
        #expect(try events("id: 0\ndata:\n\n") == [ServerSentEvent(id: "0", data: "")])
        #expect(try events("id: 3\n\n") == [ServerSentEvent(id: "3", data: "")])
        #expect(try events("retry: 250\n\n") == [ServerSentEvent(data: "", retry: 250)])
    }

    @Test("An id with NUL and a retry that is not digits are ignored")
    func invalidValues() throws {
        #expect(try events("id: a\u{0}b\ndata: x\n\n") == [ServerSentEvent(data: "x")])
        for retry in ["-1", "1.5", "+5", "", "10ms", "١٢"] {
            #expect(try events("retry: \(retry)\ndata: x\n\n") == [ServerSentEvent(data: "x")])
        }
    }

    @Test("A byte order mark is skipped at the start of the stream only")
    func byteOrderMark() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        #expect(try events(bom + Array("data: x\n\n".utf8)) == [ServerSentEvent(data: "x")])
        #expect(
            try events(Array("data: x\n\n".utf8) + bom + Array("data: y\n\n".utf8))
                == [ServerSentEvent(data: "x")])
    }

    @Test("An event the stream ends before its blank line is returned")
    func unterminated() throws {
        #expect(try events("data: a\n\ndata: b") == [ServerSentEvent(data: "a"), ServerSentEvent(data: "b")])
        #expect(try events("data: a\n") == [ServerSentEvent(data: "a")])
    }

    @Test("Invalid UTF-8 is replaced, not fatal")
    func invalidUTF8() throws {
        #expect(try events(Array("data: ".utf8) + [0xFF] + Array("\n\n".utf8)) == [ServerSentEvent(data: "\u{FFFD}")])
    }

    @Test("A line longer than the limit fails the stream")
    func lineLimit() throws {
        var parser = ServerSentEventParser()
        let limit = ServerSentEventParser.maxLineLength
        for _ in 0..<limit { _ = try parser.consume(UInt8(ascii: "a")) }
        #expect(throws: ServerSentEventParser.LineTooLong.self) { try parser.consume(UInt8(ascii: "a")) }
    }

    @Test("serverSentEvents reads an async byte sequence")
    func asyncSequence() async throws {
        let bytes = Array("id: 1\ndata: one\n\n: comment\ndata: two\n\n".utf8)
        let stream = AsyncStream<UInt8> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        var events: [ServerSentEvent] = []
        for try await event in stream.serverSentEvents { events.append(event) }
        #expect(events == [ServerSentEvent(id: "1", data: "one"), ServerSentEvent(data: "two")])
    }
}
