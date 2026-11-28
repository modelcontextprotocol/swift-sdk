import Foundation
import MCP

// Snippets for docs/server.md: prompts.

// snippet: prompts-register
let reviewPrompt = Prompt(
    name: "code_review",
    title: "Code review",
    description: "Asks the model to review a change",
    arguments: [
        .init(name: "language", description: "Programming language", required: true),
        .init(name: "focus", description: "What to look at first"),
    ])

func registerPrompts(on server: Server) async {
    await server.withMethodHandler(ListPrompts.self) { _ in
        ListPrompts.Result(prompts: [reviewPrompt])
    }
    await server.withMethodHandler(GetPrompt.self) { params in
        guard params.name == reviewPrompt.name else {
            throw MCPError.invalidParams("Unknown prompt: \(params.name)")
        }
        // The SDK does not check `required`: validate arguments here.
        guard let language = params.arguments?["language"] else {
            throw MCPError.invalidParams("Missing required argument: language")
        }
        let focus = params.arguments?["focus"] ?? "correctness"
        return GetPrompt.Result(
            description: "Review of a \(language) change",
            messages: [
                .user("Review this \(language) change. Focus on \(focus)."),
                .assistant("Paste the diff and I will review it."),
            ])
    }
}
// endsnippet

// snippet: prompts-content
func reviewMessages(diff: String, screenshot: Data) -> [Prompt.Message] {
    [
        .user(.text(text: "Review the change below.")),
        .user(.resource(resource: .text(diff, uri: "repo://changes/42.diff", mimeType: "text/x-diff"))),
        .user(.image(data: screenshot.base64EncodedString(), mimeType: "image/png")),
        .user(.resourceLink(uri: "repo://files/README.md", name: "README.md", mimeType: "text/markdown")),
    ]
}
// endsnippet
