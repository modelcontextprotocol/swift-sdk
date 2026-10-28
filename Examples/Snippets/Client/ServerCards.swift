import Foundation
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Snippets for docs/client.md: Server Cards (SEP-2127).

// snippet: server-card
/// Reads the card at the recommended location of `endpoint`.
func readCard(of endpoint: URL, session: URLSession = .shared) async throws -> ServerCard {
    try await ServerCard.fetch(from: ServerCard.cardURL(forEndpoint: endpoint), session: session)
}

/// The URL of the card's Streamable HTTP endpoint, with its variables filled in.
func connectionURL(from card: ServerCard, tenant: String) throws -> URL? {
    try card.remotes?.first { $0.type == .streamableHTTP }?.url(resolving: ["tenant": tenant])
}

/// What the live server contradicts in the card. The live values win.
func checkCard(_ card: ServerCard, with client: Client) async throws -> [ServerCard.Mismatch] {
    let live = try await client.send(ServerDiscover.request(.init())).value
    return card.mismatches(with: live)
}
// endsnippet
