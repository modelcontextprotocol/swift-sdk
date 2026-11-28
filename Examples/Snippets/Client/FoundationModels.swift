import Foundation
import MCP

// Snippets for docs/client.md: MCP tools in a Foundation Models session.

// The bridge is unavailable on tvOS.
#if canImport(FoundationModels) && !os(tvOS)
    import FoundationModels

    // snippet: language-model-tools
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    @available(watchOS, unavailable)
    func makeSession(
        with client: Client,
        confirm: @escaping @Sendable (MCP.Tool, [String: Value]) async throws -> Bool
    ) async throws -> LanguageModelSession {
        // The server's model-visible tools whose input schema converts.
        let tools = try await client.languageModelTools { tool, arguments in
            try await confirm(tool, arguments)
        }
        return LanguageModelSession(
            tools: tools,
            instructions: "Answer weather questions with the tools.")
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    @available(watchOS, unavailable)
    func askAboutUV(_ client: Client) async throws -> String {
        let session = try await makeSession(with: client) { _, _ in true }
        let response = try await session.respond(to: "How strong is the sun in Zürich today?")
        return response.content
    }
    // endsnippet

    // snippet: language-model-tool-strict
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    func allLanguageModelTools(_ client: Client) async throws -> [Client.LanguageModelTool] {
        // Fails on the first model-visible tool whose schema does not convert.
        var tools: [Client.LanguageModelTool] = []
        var cursor: String?
        var seen = Set<String>()
        var pages = 0
        repeat {
            let page = try await client.listTools(cursor: cursor)
            pages += 1
            for tool in page.tools where tool.isVisibleToModel {
                tools.append(try Client.LanguageModelTool(tool, client: client))
            }
            cursor = page.nextCursor.flatMap {
                $0.isEmpty || !seen.insert($0).inserted ? nil : $0
            }
        } while cursor != nil && pages < 100
        return tools
    }
    // endsnippet
#endif
