// Parses the input as a text/event-stream body, at once and with the parser
// copied at up to 8 offsets that the input's first bytes name. Both must give
// the same events, and a body shorter than the line limit never fails.

import Foundation
@testable import MCP

private func events(_ bytes: some Sequence<UInt8>) throws -> [ServerSentEvent] {
    var parser = ServerSentEventParser()
    var events: [ServerSentEvent] = []
    for byte in bytes {
        if let event = try parser.consume(byte) { events.append(event) }
    }
    if let event = parser.finish() { events.append(event) }
    return events
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let bytes = Array(UnsafeRawBufferPointer(start: start, count: count))
    guard let whole = try? events(bytes) else {
        fatalError("a \(count)-byte body failed to parse")
    }
    // A parser that resumes from a copy must agree with one that ran through.
    // Copying at every byte would copy the line buffer each time: quadratic.
    let splits = Set(bytes.prefix(8).map { Int($0) * count / 256 })
    var parser = ServerSentEventParser()
    var resumed: [ServerSentEvent] = []
    for (offset, byte) in bytes.enumerated() {
        if splits.contains(offset) {
            var copy = parser
            if let event = try! copy.consume(byte) { resumed.append(event) }
            parser = copy
        } else if let event = try! parser.consume(byte) {
            resumed.append(event)
        }
    }
    if let event = parser.finish() { resumed.append(event) }
    precondition(whole == resumed, "copied parser state diverged")
    return 0
}
