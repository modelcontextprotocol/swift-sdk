import Foundation
import Logging
import Testing

@testable import MCP

// SEP-986: the tool name format of the specification. The SDK refuses no
// name; it logs a warning once for each name.

@Suite("Tool names (SEP-986)")
struct ToolNameTests {
    @Test("Names with the recommended format", arguments: [
        "getUser", "DATA_EXPORT_v2", "admin.tools.list", "a", "tool-1", "_", String(repeating: "a", count: 128),
    ])
    func valid(name: String) {
        #expect(Tool.isValidName(name))
        #expect(Tool.nameProblem(name) == nil)
    }

    @Test("Names without the recommended format", arguments: [
        "", String(repeating: "a", count: 129), "get user", "a,b", "a/b", "café", "ツール", "tab\t", "a:b",
    ])
    func invalid(name: String) {
        #expect(!Tool.isValidName(name))
    }

    @Test("The problem names the cause")
    func problems() {
        #expect(Tool.nameProblem("") == "the name is empty")
        #expect(Tool.nameProblem(String(repeating: "a", count: 129)) == "the name has 129 characters, more than 128")
        #expect(
            Tool.nameProblem("get user, now") == #"the name has characters other than A-Z, a-z, 0-9, _, - and .: " ", ",""#)
        // Characters that are not printable ASCII are not logged as they are.
        #expect(Tool.nameProblem("a\nb") == #"the name has characters other than A-Z, a-z, 0-9, _, - and .: "?""#)
        // Names are case-sensitive: these are two names, both valid.
        #expect(Tool.isValidName("getUser") && Tool.isValidName("GetUser"))
    }

    @Test("Each name is reported once; the set of names has a limit")
    func reportedOnce() {
        var warnings = ToolNameWarnings()
        let first = warnings.warnings(for: ["ok", "bad name", "dup", "dup", "bad name"], checkDuplicates: true)
        #expect(first.map(\.name) == ["bad name", "dup", "bad name"])
        #expect(warnings.warnings(for: ["bad name", "dup", "dup"], checkDuplicates: true).isEmpty)
        #expect(warnings.warnings(for: ["x y", "x y"], checkDuplicates: false).map(\.name) == ["x y"])

        var limited = ToolNameWarnings()
        _ = limited.warnings(for: (0..<1000).map { "bad \($0)" }, checkDuplicates: false)
        #expect(limited.warnings(for: ["bad 1000"], checkDuplicates: false).isEmpty)
    }

    /// A name of `count` distinct scalars from U+0100: none is a name
    /// character, and each is three bytes or fewer in UTF-8.
    private static func distinctScalars(_ count: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var value: UInt32 = 0x100
        var appended = 0
        while appended < count {
            if let scalar = Unicode.Scalar(value) {
                scalars.append(scalar)
                appended += 1
            }
            value += 1
        }
        return String(scalars)
    }

    @Test("A long name is reported for its length, without a scan of its characters")
    func longNames() {
        // 30,000 distinct characters: scanning them for the list took
        // seconds (quadratic); the length alone decides.
        let long = Self.distinctScalars(30_000)
        let start = ContinuousClock.now
        let problem = Tool.nameProblem(long)
        var warnings = ToolNameWarnings()
        let logged = warnings.warnings(for: [long, long], checkDuplicates: true)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(problem == "the name has characters other than A-Z, a-z, 0-9, _, - and ., and \(long.utf8.count) bytes in UTF-8")
        #expect(logged.map(\.problem.utf8.count).allSatisfy { $0 < 200 })
        #expect(logged.count == 2)
        // The long name is not kept, and it is reported once.
        #expect(warnings.logged.allSatisfy { $0.utf8.count < 2 * Tool.maximumNameLength })
        #expect(warnings.warnings(for: [long, long], checkDuplicates: true).isEmpty)
        // Another long name with the same beginning is another name.
        #expect(warnings.warnings(for: [long + "x"], checkDuplicates: false).count == 1)

        let ascii = String(repeating: "a b", count: 1000)
        #expect(Tool.nameProblem(ascii) == "the name has 3000 characters, more than 128")
        // A name within the length lists a few of its characters.
        let short = Self.distinctScalars(40)
        #expect(Tool.nameProblem(short)?.components(separatedBy: "\", \"").count == Tool.maximumListedCharacters)
    }
}

@Suite("Tool names on the wire (SEP-986)", .timeLimit(.minutes(1)))
struct ToolNameWarningTests {
    private let listed = ["getUser", "get user", "get user", "dup", "dup", "x/y"]

    private func serverWarnings(_ log: CapturingLogHandler) -> [String] {
        log.messages.filter { $0.hasPrefix("Tool name does not follow the specification (SEP-986)") }
    }

    private func clientWarnings(_ log: CapturingLogHandler) -> [String] {
        log.messages.filter { $0.hasPrefix("The server listed a tool whose name does not follow") }
    }

    @Test("Server and client list every tool, and warn once for each name", arguments: [
        Client.ProtocolMode.handshake, .automatic,
    ])
    func listed(mode: Client.ProtocolMode) async throws {
        let log = CapturingLogHandler()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair(
            logger: Logger(label: "test") { _ in log })
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let names = listed
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: names.map { Tool(name: $0, description: nil, inputSchema: ["type": "object"]) })
        }
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .init(protocolMode: mode))
        try await client.connect(transport: clientEnd)
        defer { Task { await client.disconnect(); await server.stop() } }

        for _ in 0..<2 {
            #expect(try await client.listTools().tools.map(\.name) == listed)
        }
        // The server: "get user" and "x/y" have the wrong format; "get user"
        // and "dup" are listed twice.
        let fromServer = serverWarnings(log)
        #expect(fromServer.count == 4)
        #expect(fromServer.contains { $0.hasSuffix("tool names should be unique within a server") })
        // The client checks the format only.
        #expect(clientWarnings(log).count == 2)
    }
}
