import MCP

// Snippets for docs/protocol.md, section "Utilities".

/// Starts a slow tool call, cancels it, and reports what each side saw.
func cancelSlowCall(protocolMode: Client.ProtocolMode = .handshake) async throws -> (client: String, server: String) {
    let server = Server(name: "example", version: "1.0.0", capabilities: .init(tools: .init()))
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let (outcomes, outcome) = AsyncStream<String>.makeStream()
    // snippet: cancellation-server
    await server.withMethodHandler(CallTool.self) { params in
        didStart.yield()
        do {
            try await Task.sleep(for: .seconds(30))  // throws when the request is cancelled
        } catch is CancellationError {
            outcome.yield("tool cancelled")
            throw CancellationError()  // the server sends no response
        }
        return .init(content: [])
    }
    // endsnippet
    let client = Client(
        name: "example-client", version: "1.0.0", configuration: .init(protocolMode: protocolMode))
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    try await client.connect(transport: clientTransport)

    // snippet: cancellation-client
    let call = try await client.startToolCall(name: "slow")
    // endsnippet
    for await _ in started { break }
    var clientResult = "completed"
    // snippet: cancellation-cancel
    try await client.cancelRequest(call.requestID, reason: "User cancelled")
    do {
        _ = try await call.value
    } catch is CancellationError {
        clientResult = "cancelled"
    }
    // endsnippet
    var serverResult = ""
    for await value in outcomes {
        serverResult = value
        break
    }
    await client.disconnect()
    await server.stop()
    return (clientResult, serverResult)
}

/// Pings in either era.
func pingServer(_ client: Client) async throws {
    // snippet: ping
    try await client.ping()  // `ping`, or `server/discover` at 2026-07-28
    // endsnippet
}

/// A tool that reports progress, and a client that prints it. Returns the reports.
func reportProgress() async throws -> [String] {
    let server = Server(name: "example", version: "1.0.0", capabilities: .init(tools: .init()))
    // snippet: progress-server
    await server.withMethodHandler(CallTool.self) { params in
        if let token = params._meta?.progressToken {
            for step in 1...3 {
                try await server.notify(
                    ProgressNotification.message(
                        .init(progressToken: token, progress: Double(step), total: 3, message: "step \(step)")))
            }
        }
        return .init(content: [])
    }
    // endsnippet
    let client = Client(name: "example-client", version: "1.0.0")
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    try await client.connect(transport: clientTransport)

    let (reports, report) = AsyncStream<String>.makeStream()
    // snippet: progress-client
    await client.onNotification(ProgressNotification.self) { message in
        let params = message.params
        report.yield("\(params.message ?? "") \(Int(params.progress))/\(Int(params.total ?? 0))")
    }
    _ = try await client.callTool(
        name: "build", meta: Metadata(progressToken: .unique()))
    // endsnippet
    report.finish()
    var lines: [String] = []
    for await line in reports { lines.append(line) }
    await client.disconnect()
    await server.stop()
    return lines
}

/// A resource handler that reports a missing URI.
func registerResourceNotFound(on server: Server) async {
    // snippet: errors-server
    await server.withMethodHandler(ReadResource.self) { params in
        guard params.uri == "file:///README.md" else {
            throw MCPError.resourceNotFound(uri: params.uri)  // -32602, data.uri
        }
        return .init(contents: [.text("Hello", uri: params.uri)])
    }
    // endsnippet
}

/// Reads a missing resource and classifies the error. Returns the error code, or nil on success.
func classifyError(_ client: Client) async -> Int? {
    // snippet: errors-client
    do {
        _ = try await client.readResource(uri: "file:///missing")
    } catch let error as MCPError {
        switch error {
        case .resourceNotFound(let uri, _):
            print("no resource at \(uri)")
        case .unsupportedProtocolVersion(let supported, _):
            print("retry with one of \(supported)")
        case .headerMismatch(let detail):
            print("proxy or client bug: \(detail ?? "")")
        default:
            print(error.code, error.data ?? .null)
        }
        return error.code
    } catch {
        print("not an MCP error: \(error)")
    }
    // endsnippet
    return nil
}
