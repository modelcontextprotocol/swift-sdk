import Foundation
import MCP

// SEP-2640 fixtures: a host that lists skills and loads them the way the SDK
// lets it, for the `sep-2640-client-*` scenarios.

private func connectedClient(_ args: [String]) async throws -> Client {
    guard let serverURLString = args.last, let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }
    let client = makeConformanceClient()
    try await client.connect(transport: HTTPClientTransport(endpoint: serverURL))
    return client
}

/// Builds the registry from the listing alone: no file is read.
func runSkillsListingScenario(_ args: [String]) async throws {
    let client = try await connectedClient(args)
    let skills = try await client.listAllSkills()
    for skill in skills {
        print("skill \(skill.name ?? "?"): \(skill.description ?? "")")
    }
    await client.disconnect()
}

/// Loads each listed skill, then reads the reference its SKILL.md names.
/// A skill that fails verification is not loaded, and none of its other
/// files is read.
func runSkillsLoadingScenario(_ args: [String]) async throws {
    let client = try await connectedClient(args)
    for skill in try await client.listAllSkills() {
        do {
            let loaded = try await client.loadSkill(skill)
            _ = try await loaded.read("references/FORMS.md")
        } catch let error as SkillVerificationError {
            var stderr = StandardError()
            print("refused \(skill.uri): \(error)", to: &stderr)
        }
    }
    await client.disconnect()
}
