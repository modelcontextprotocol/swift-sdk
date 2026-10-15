import Foundation
import Testing

@testable import MCP

@Suite("PKCE")
struct PKCETests {
    @Test("Generates verifier of correct length")
    func testMakeVerifierLength() {
        let verifier = PKCE.makeVerifier(length: 43)
        #expect(verifier.count == 43)

        let verifierDefault = PKCE.makeVerifier()
        #expect(verifierDefault.count == 64)
    }

    @Test("Verifier contains only unreserved characters")
    func testMakeVerifierCharacters() {
        let verifier = PKCE.makeVerifier(length: 128)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(verifier.rangeOfCharacter(from: allowed.inverted) == nil)
    }

    @Test("Verifier is sufficiently random (doesn't repeat trivially)")
    func testMakeVerifierRandomness() {
        let v1 = PKCE.makeVerifier()
        let v2 = PKCE.makeVerifier()
        #expect(v1 != v2)
    }
}
