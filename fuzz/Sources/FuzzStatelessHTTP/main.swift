// Sends the input as the body of a POST to a server behind
// StatelessHTTPServerTransport. The first byte picks the headers. Nothing may
// crash, and every answer has a valid HTTP status.

import Foundation
import MCP

private func makeServer() async -> Server {
    let server = Server(
        name: "fuzz", version: "1.0.0",
        capabilities: .init(logging: .init(), prompts: .init(), resources: .init(subscribe: true), tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "echo", description: nil, inputSchema: [
                    "type": "object",
                    "properties": ["region": ["type": "string", "x-mcp-header": "Region"]],
                ])
        ])
    }
    await server.withMethodHandler(CallTool.self) { params in
        .init(content: [.text(text: "\(params.arguments ?? [:])")])
    }
    return server
}

private let headerSets: [[String: String]] = [
    ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"],
    [
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "echo",
    ],
    ["Content-Type": "application/json", "Accept": "application/json", "MCP-Protocol-Version": "2025-11-25"],
    ["Content-Type": "text/plain"],
]

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
    guard count > 0 else { return 0 }
    let selector = Int(start.load(as: UInt8.self))
    let body = Data(bytes: start + 1, count: count - 1)
    let headers = headerSets[selector % headerSets.count]
    let done = DispatchSemaphore(value: 0)
    let box = Box()
    Task {
        let server = await makeServer()
        let transport = StatelessHTTPServerTransport()
        try? await server.start(transport: transport)
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
