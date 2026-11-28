import Foundation
import Testing

@testable import ClientSnippets
@testable import MCP
@testable import ServerSnippets

// Runs the Foundation Models snippets of docs/server.md and docs/client.md
// against a client over an in-memory pair, in both protocol eras. No test
// runs a language model.

// The bridge is unavailable on tvOS.
#if canImport(FoundationModels) && !os(tvOS)
    import FoundationModels

    @Suite("Foundation Models snippets")
    struct FoundationModelsSnippetTests {
        private static let eras: [Client.ProtocolMode] = [.handshake, .automatic]

        private func connect(_ server: Server, mode: Client.ProtocolMode) async throws -> Client {
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            try await server.start(transport: serverTransport)
            let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: mode))
            try await client.connect(transport: clientTransport)
            return client
        }

        @Test("A Generable tool lists its schemas and answers with structured content", arguments: eras)
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func generableTool(mode: Client.ProtocolMode) async throws {
            let server = Server(name: "weather", version: "1.0", capabilities: .init(tools: .init()))
            try await registerGenerableTool(on: server)
            let client = try await connect(server, mode: mode)

            let tool = try #require(try await client.listTools().tools.first)
            #expect(tool.name == "get_daily_forecast")
            #expect(tool.inputSchema.objectValue?["required"] == ["city", "days"])
            #expect(tool.outputSchema?.objectValue?["required"] == ["city", "highs"])

            let result = try await client.callTool(name: tool.name, arguments: ["city": "Paris", "days": 2])
            #expect(result.structuredContent == ["city": "Paris", "highs": [19, 20]])

            let outOfRange = try await client.callTool(name: tool.name, arguments: ["city": "Paris", "days": 0])
            #expect(outOfRange.isError == true)

            let error = await #expect(throws: MCPError.self) {
                try await client.callTool(name: tool.name, arguments: ["city": "Paris"])
            }
            #expect(error?.code == -32602)

            await client.disconnect()
            await server.stop()
        }

        @Test("A Foundation Models tool is served and offered back to a session", arguments: eras)
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func foundationModelsTool(mode: Client.ProtocolMode) async throws {
            let server = Server(name: "weather", version: "1.0", capabilities: .init(tools: .init()))
            try await registerUVIndexTool(on: server)
            let client = try await connect(server, mode: mode)

            let listed = try await client.listTools().tools
            #expect(listed.map(\.name) == ["get_uv_index"])
            #expect(listed.first?.annotations.readOnlyHint == true)

            let tools = try await allLanguageModelTools(client)
            #expect(tools.map(\.name) == ["get_uv_index"])
            #expect(try await client.languageModelTools().map(\.name) == ["get_uv_index"])
            let answer = try await #require(tools.first).call(
                arguments: GeneratedContent(json: #"{"city": "Zürich"}"#))
            #expect(answer == "The UV index in Zürich is 5.")

            await client.disconnect()
            await server.stop()
        }
    }
#endif
