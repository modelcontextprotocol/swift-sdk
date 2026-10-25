import Foundation
import MCP

// Snippets for docs/client.md: tools, prompts, resources and completions.

// MARK: - Tools

/// Lists every tool, following pagination cursors.
func listAllTools(_ client: Client) async throws -> [Tool] {
    // snippet: list-tools
    var tools: [Tool] = []
    var cursor: String?
    repeat {
        let page = try await client.listTools(cursor: cursor)
        tools += page.tools
        cursor = page.nextCursor
    } while cursor != nil
    // endsnippet
    return tools
}

/// Calls a tool and collects its text content.
func callEchoTool(_ client: Client) async throws -> String {
    // snippet: call-tool
    let (content, isError) = try await client.callTool(
        name: "echo", arguments: ["text": "hello"])

    var text = ""
    for item in content {
        switch item {
        case .text(let string, _, _):
            text += string
        case .image(_, let mimeType, _, _), .audio(_, let mimeType, _, _):
            print("binary content: \(mimeType)")
        case .resource(let resource, _, _):
            print("embedded resource: \(resource.uri)")
        case .resourceLink(let uri, let name, _, _, _, _):
            print("link to \(name): \(uri)")
        case .unknown(let type, _):
            // A block from a later revision of the protocol.
            print("unknown content: \(type)")
        }
    }
    if isError == true {
        // The tool ran and failed; `content` describes the failure to the model.
        print("tool error: \(text)")
    }
    // endsnippet
    return text
}

/// The structured output of the `weather` tool.
struct Weather: Codable, Equatable {
    var temperature: Double
    var conditions: String
}

/// Reads `structuredContent`, which the `callTool` tuple does not return.
func callStructuredTool(_ client: Client) async throws -> Weather? {
    // snippet: call-structured
    let result = try await client.send(
        CallTool.request(.init(name: "weather", arguments: ["city": "Paris"]))
    ).value

    var weather: Weather?
    if let structured = result.structuredContent {
        let data = try JSONEncoder().encode(structured)
        weather = try JSONDecoder().decode(Weather.self, from: data)
    }
    // endsnippet
    return weather
}

/// Shows which arguments of each tool the client mirrors into HTTP headers.
func describeHeaderParameters(_ client: Client) async throws -> [String: [String]] {
    // snippet: header-parameters
    // At 2026-07-28 the client records these on every tools/list and sends them
    // as Mcp-Param-* headers on tools/call over HTTP.
    var mirrored: [String: [String]] = [:]
    let (tools, _) = try await client.listTools()
    for tool in tools {
        let parameters = try tool.headerParameters()
        mirrored[tool.name] = parameters.map { "\($0.fieldName) <- \($0.path.joined(separator: "."))" }
    }
    // mirrored["search"] == ["Mcp-Param-Region <- region"]
    // endsnippet
    return mirrored
}

// MARK: - Prompts and resources

/// Lists prompts and renders one.
func renderGreeting(_ client: Client) async throws -> [String] {
    // snippet: prompts
    let (prompts, _) = try await client.listPrompts()
    for prompt in prompts {
        let required = prompt.arguments?.filter { $0.required == true }.map(\.name) ?? []
        print("\(prompt.name), required arguments: \(required)")
    }

    let (description, messages) = try await client.getPrompt(
        name: "greeting", arguments: ["name": "Ada"])
    print(description ?? "")
    var lines: [String] = []
    for message in messages {
        if case .text(let text) = message.content {
            lines.append("\(message.role.rawValue): \(text)")
        }
    }
    // endsnippet
    return lines
}

/// Lists resources and templates and reads one resource.
func readNotes(_ client: Client) async throws -> String? {
    // snippet: resources
    let (resources, _) = try await client.listResources()
    let (templates, _) = try await client.listResourceTemplates()
    print(resources.map(\.uri), templates.map(\.uriTemplate))

    let contents = try await client.readResource(uri: "file:///notes.txt")
    for content in contents {
        if let text = content.text {
            print("\(content.uri): \(text)")
        } else if let blob = content.blob, let data = Data(base64Encoded: blob) {
            print("\(content.uri): \(data.count) bytes")
        }
    }
    // endsnippet
    return contents.first?.text
}

/// Asks for completions of a prompt argument.
func completeLanguage(_ client: Client) async throws -> [String] {
    // snippet: completions
    let completion = try await client.complete(
        promptName: "review", argumentName: "language", argumentValue: "sw")
    print(completion.values, completion.hasMore ?? false)
    // endsnippet
    return completion.values
}
