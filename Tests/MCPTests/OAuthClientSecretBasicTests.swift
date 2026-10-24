import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("OAuth client_secret_basic encoding")
struct OAuthClientSecretBasicTests {
    /// Applies `.clientSecretBasic` and returns the decoded `user:pass` from the Basic header.
    func decodedBasicCredentials(clientID: String, clientSecret: String) async throws -> String {
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!
        var request = URLRequest(url: tokenEndpoint)
        var body: [String: String] = [:]
        try await OAuthConfiguration.TokenEndpointAuthentication
            .clientSecretBasic(clientID: clientID, clientSecret: clientSecret)
            .apply(to: &request, bodyParameters: &body, tokenEndpoint: tokenEndpoint)

        #expect(body.isEmpty, "client_secret_basic must not put credentials in the body")
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(header.hasPrefix("Basic "))
        let data = try #require(Data(base64Encoded: String(header.dropFirst("Basic ".count))))
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("Unreserved characters are left as-is")
    func testUnreservedCharactersUnchanged() async throws {
        let decoded = try await decodedBasicCredentials(
            clientID: "client-A.b_c~9", clientSecret: "Secret-1.2_3~")
        #expect(decoded == "client-A.b_c~9:Secret-1.2_3~")
    }

    @Test("Reserved characters are percent-encoded per RFC 6749 section 2.3.1")
    func testReservedCharactersPercentEncoded() async throws {
        let decoded = try await decodedBasicCredentials(
            clientID: "client:id@example", clientSecret: "p@ss:w%rd+/=")
        #expect(decoded == "client%3Aid%40example:p%40ss%3Aw%25rd%2B%2F%3D")
    }

    @Test("A colon in the client ID cannot shift the user/password boundary")
    func testColonInClientIDDoesNotSplitCredentials() async throws {
        let decoded = try await decodedBasicCredentials(clientID: "a:b", clientSecret: "c")
        let parts = decoded.split(separator: ":", omittingEmptySubsequences: false)
        #expect(parts.count == 2)
        #expect(parts.first == "a%3Ab")
    }

    @Test("Non-ASCII characters are UTF-8 percent-encoded")
    func testNonASCIIPercentEncoded() async throws {
        let decoded = try await decodedBasicCredentials(clientID: "client", clientSecret: "é€")
        #expect(decoded == "client:%C3%A9%E2%82%AC")
    }
}
