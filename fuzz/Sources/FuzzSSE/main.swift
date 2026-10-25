// Parses the input as a text/event-stream body, at once and split at every
// byte the input names. Both must give the same events, and a body shorter
// than the line limit never fails.

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
    var parser = ServerSentEventParser()
    var resumed: [ServerSentEvent] = []
    for byte in bytes {
        var copy = parser
        if let event = try! copy.consume(byte) { resumed.append(event) }
        parser = copy
    }
    if let event = parser.finish() { resumed.append(event) }
    precondition(whole == resumed, "copied parser state diverged")
    return 0
}
