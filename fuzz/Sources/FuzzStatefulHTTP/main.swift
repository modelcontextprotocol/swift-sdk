// Initializes a session with StatefulHTTPServerTransport, then sends the
// input as the body of a POST in that session. Nothing may crash, and every
// answer has a valid HTTP status.

import Foundation
import MCP

private let initialize = Data(
    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fuzz","version":"1"}}}"#
        .utf8)

private final class Box: @unchecked Sendable { var status = 0 }

/// The objects of the previous input, which must be released by the next one.
private final class Released: @unchecked Sendable {
    weak var server: Server?
    weak var transport: AnyObject?
}
private let previous = Released()

/// Fails when the previous input's server or transport is still alive: a
/// retained server leaks memory on every session.
private func checkReleased() {
    var waited = 0
    while previous.server != nil || previous.transport != nil, waited < 1000 {
        usleep(1000)
        waited += 1
    }
    precondition(previous.server == nil, "server of the previous input not released")
    precondition(previous.transport == nil, "transport of the previous input not released")
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    checkReleased()
    let body = Data(bytes: start, count: count)
    let done = DispatchSemaphore(value: 0)
    let box = Box()
    Task {
        let server = Server(
            name: "fuzz", version: "1.0.0", capabilities: .init(logging: .init(), tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in .init(content: [.text(text: "ok")]) }
        let transport = StatefulHTTPServerTransport()
        try? await server.start(transport: transport)
        var headers = [
            "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        ]
        let opened = await transport.handleRequest(
            HTTPRequest(method: "POST", headers: headers, body: initialize, path: "/mcp"))
        if let session = opened.headers.first(where: { $0.key.lowercased() == "mcp-session-id" })?.value {
            headers["Mcp-Session-Id"] = session
            headers["MCP-Protocol-Version"] = "2025-11-25"
        }
        let response = await transport.handleRequest(
            HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp"))
        box.status = response.statusCode
        await server.stop()
        previous.server = server
        previous.transport = transport
        done.signal()
    }
    done.wait()
    precondition((100..<600).contains(box.status), "status \(box.status)")
    return 0
}
