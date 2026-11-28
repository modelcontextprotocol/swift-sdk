import Foundation

/// One event of a `text/event-stream` body.
struct ServerSentEvent: Equatable, Sendable {
    /// The `id` field, when the event has one without a NUL character.
    var id: String?
    /// The `event` field.
    var event: String?
    /// The `data` lines, joined with line feeds.
    var data: String
    /// The `retry` field, when it is ASCII digits only.
    var retry: Int?
}

/// Parses a `text/event-stream` body byte by byte, as the HTML standard's
/// "Server-sent events" section describes.
///
/// - Lines end with CR, LF or CR LF; a UTF-8 byte order mark at the start of
///   the stream is skipped; lines starting with `:` are comments.
/// - A blank line ends an event. A block of comments only, or of unknown
///   fields only, is no event.
/// - Unlike a browser, an event without `data` is still returned (a priming
///   event carries only an `id`, a reconnection hint only a `retry`).
/// - An event the stream ends before its blank line is incomplete and is
///   discarded: its `id` must not become the resumption point.
struct ServerSentEventParser {
    private var line: [UInt8] = []
    private var afterCR = false
    private var firstLine = true

    private var id: String?
    private var event: String?
    /// The `data` lines so far, joined with line feeds.
    private var data: [UInt8]?
    private var retry: Int?
    private var hasField = false

    /// The most bytes one line may hold; a longer line fails the stream
    /// rather than grow without bound.
    static let maxLineLength = 16 << 20

    /// The most bytes the `data` of one event may hold, its line feeds
    /// included; a larger event fails the stream.
    static let maxEventLength = maxLineLength

    struct LineTooLong: Swift.Error {}
    struct EventTooLong: Swift.Error {}

    /// Consumes one byte. Returns the event a blank line completes.
    mutating func consume(_ byte: UInt8) throws -> ServerSentEvent? {
        switch byte {
        case 0x0A:
            if afterCR {
                afterCR = false
                return nil
            }
            return try endLine()
        case 0x0D:
            afterCR = true
            return try endLine()
        default:
            afterCR = false
            guard line.count < Self.maxLineLength else { throw LineTooLong() }
            line.append(byte)
            return nil
        }
    }

    /// Ends the stream. An event it ended before the event's blank line is
    /// discarded, as the HTML standard requires at the end of the stream, so
    /// this returns `nil`.
    mutating func finish() -> ServerSentEvent? {
        line.removeAll()
        _ = dispatch()
        return nil
    }

    /// The capacity the line buffer keeps between lines; a longer line's
    /// buffer is released once the line ends.
    static let retainedLineCapacity = 64 << 10

    private mutating func endLine() throws -> ServerSentEvent? {
        defer {
            if line.capacity > Self.retainedLineCapacity {
                line = []
            } else {
                line.removeAll(keepingCapacity: true)
            }
        }
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        if line.isEmpty { return dispatch() }
        if line.first == UInt8(ascii: ":") { return nil }
        let name: String
        var bytes: ArraySlice<UInt8>
        if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
            name = String(decoding: line[..<colon], as: UTF8.self)
            bytes = line[(colon + 1)...]
            if bytes.first == UInt8(ascii: " ") { bytes = bytes.dropFirst() }
        } else {
            name = String(decoding: line, as: UTF8.self)
            bytes = []
        }
        if name == "data" {
            // Appended in place: each line costs its own length.
            let length = (data.map { $0.count + 1 } ?? 0) + bytes.count
            guard length <= Self.maxEventLength else { throw EventTooLong() }
            if data == nil {
                data = Array(bytes)
            } else {
                data!.append(0x0A)
                data!.append(contentsOf: bytes)
            }
            hasField = true
            return nil
        }
        let value = String(decoding: bytes, as: UTF8.self)
        switch name {
        case "event":
            event = value
        case "id":
            guard !value.contains("\0") else { return nil }
            id = value
        case "retry":
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                let milliseconds = Int(value)
            else { return nil }
            retry = milliseconds
        default:
            return nil
        }
        hasField = true
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            id = nil
            event = nil
            data = nil
            retry = nil
            hasField = false
        }
        guard hasField else { return nil }
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return ServerSentEvent(id: id, event: event, data: text, retry: retry)
    }
}

/// The server-sent events of a byte sequence.
struct ServerSentEvents<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = ServerSentEvent

    let base: Base

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var parser = ServerSentEventParser()
        var finished = false

        mutating func next() async throws -> ServerSentEvent? {
            guard !finished else { return nil }
            while let byte = try await base.next() {
                if let event = try parser.consume(byte) { return event }
            }
            finished = true
            return parser.finish()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

extension AsyncSequence where Element == UInt8 {
    /// The server-sent events of a `text/event-stream` body.
    var serverSentEvents: ServerSentEvents<Self> { ServerSentEvents(base: self) }
}
