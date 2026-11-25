import Foundation
import MCP

// Snippets for docs/client.md: roots, sampling and elicitation.

// MARK: - Roots

/// The roots the user opened, kept by the application.
actor Workspace {
    private(set) var roots = [Root(uri: "file:///Users/me/project", name: "project")]

    func add(_ root: Root) { roots.append(root) }
}

/// Exposes the workspace roots to the server.
func connectWithRoots(transport: any Transport, workspace: Workspace) async throws -> Client {
    // snippet: roots
    let client = Client(
        name: "my-client", version: "1.0.0",
        capabilities: .init(roots: .init(listChanged: true)))
    await client.withRootsHandler {
        await workspace.roots
    }
    try await client.connect(transport: transport)

    // Later, when the user opens another folder:
    await workspace.add(Root(uri: "file:///Users/me/scratch", name: "scratch"))
    try await client.notifyRootsChanged()  // does nothing at 2026-07-28
    // endsnippet
    return client
}

// MARK: - Sampling

/// A stand-in for the application's model.
func generate(_ prompt: String, system: String?, maxTokens: Int) async throws -> String {
    "Summary of \(prompt.count) characters"
}

/// Answers `sampling/createMessage` with the application's model.
func connectWithSampling(transport: any Transport) async throws -> Client {
    // snippet: sampling
    let client = Client(
        name: "my-client", version: "1.0.0",
        capabilities: .init(sampling: .init()))
    await client.withSamplingHandler { params in
        // Show the request to the user here, and let them edit or reject it.
        let prompt = params.messages.flatMap { message in
            message.content.asArray.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }
        }.joined(separator: "\n")
        let completion = try await generate(
            prompt, system: params.systemPrompt, maxTokens: params.maxTokens)
        return .init(
            model: "my-model", stopReason: .endTurn, role: .assistant,
            content: .text(completion))
    }
    try await client.connect(transport: transport)
    // endsnippet
    return client
}

// MARK: - Elicitation

/// A stand-in for the application's UI: the user accepts with a name.
func showForm(_ message: String, _ schema: Elicitation.RequestSchema) async -> [String: Value]? {
    var answers: [String: Value] = [:]
    for (name, property) in schema.properties {
        answers[name] = property.objectValue?["default"] ?? "Ada"
    }
    return answers
}

/// A stand-in for asking the user before opening a URL.
func userAgreesToOpen(_ url: String, _ message: String) async -> Bool { true }

/// Answers `elicitation/create` in both modes.
func connectWithElicitation(transport: any Transport) async throws -> Client {
    // snippet: elicitation
    let client = Client(
        name: "my-client", version: "1.0.0",
        capabilities: .init(elicitation: .init(form: .init(), url: .init())))
    await client.withElicitationHandler { params in
        switch params {
        case .form(let form):
            // `requestedSchema.properties` holds one flat JSON Schema per field.
            guard let answers = await showForm(form.message, form.requestedSchema) else {
                return .init(action: .decline)
            }
            return .init(action: .accept, content: answers)
        case .url(let request):
            // Accepting means the user agreed to open the URL; the result
            // carries no content. Open it outside the handler.
            guard await userAgreesToOpen(request.url, request.message) else {
                return .init(action: .decline)
            }
            return .init(action: .accept)
        case .unknown:
            // A mode from a later revision.
            return .init(action: .decline)
        }
    }
    try await client.connect(transport: transport)
    // endsnippet
    return client
}

/// Handles -32042: the server needs URL elicitations completed first.
func callAfterURLElicitation(_ client: Client) async throws -> [URLElicitationInfo] {
    // snippet: url-elicitation-required
    var pending: [URLElicitationInfo] = []
    await client.onNotification(ElicitationCompleteNotification.self) { message in
        // The server finished the out-of-band flow; retry the request now.
        print("completed: \(message.params.elicitationId)")
    }
    do {
        let content = try await client.callTool(name: "connect-calendar").content
        print(content)
    } catch MCPError.urlElicitationRequired(let message, let elicitations) {
        print(message)
        for elicitation in elicitations {
            // Ask the user, then open elicitation.url in a browser.
            print(elicitation.elicitationId, elicitation.url)
        }
        pending = elicitations
    }
    // endsnippet
    return pending
}
