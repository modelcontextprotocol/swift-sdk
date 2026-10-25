// HelloClient: starts the HelloServer example as a subprocess, connects to
// it over stdio, lists its tools and calls `greet`.
//
//   swift build --product HelloServer
//   swift build --product HelloClient
//   $(swift build --show-bin-path)/HelloClient [path/to/HelloServer]
//
// Without an argument, the client starts the HelloServer executable in its
// own directory. It exits with status 0 when the call succeeds.

// snippet: hello-client-spawn
import Foundation
import MCP

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

let serverPath =
    CommandLine.arguments.dropFirst().first
    ?? URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().appendingPathComponent("HelloServer").path

let toServer = Pipe()
let fromServer = Pipe()
let process = Process()
process.executableURL = URL(fileURLWithPath: serverPath)
process.standardInput = toServer
process.standardOutput = fromServer
try process.run()
// endsnippet

// snippet: hello-client
let transport = StdioTransport(
    input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
    output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
let client = Client(name: "hello-client", version: "1.0.0")
try await client.connect(transport: transport)

let (tools, _) = try await client.listTools()
print("Tools:", tools.map(\.name).joined(separator: ", "))

let (content, isError) = try await client.callTool(name: "greet", arguments: ["name": "Swift"])
for case .text(let text, _, _) in content {
    print(text)
}
// endsnippet

// snippet: hello-client-exit
await client.disconnect()
try toServer.fileHandleForWriting.close()  // EOF on the server's stdin: it exits.
process.waitUntilExit()
exit(isError == true ? 1 : 0)
// endsnippet
