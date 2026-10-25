import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("OAuthURLValidator")
struct OAuthURLValidatorTests {

    // MARK: - validateHTTPSOrLoopback

    @Test("Accepts HTTPS URL")
    func testValidateHTTPSOrLoopbackAcceptsHTTPS() throws {
        try OAuthURLValidator().validateHTTPSOrLoopback(
            URL(string: "https://example.com/mcp")!, context: "test")
    }

    @Test("Accepts loopback HTTP")
    func testValidateHTTPSOrLoopbackAcceptsLoopback() throws {
        try OAuthURLValidator().validateHTTPSOrLoopback(
            URL(string: "http://localhost:8080/mcp")!, context: "test")
        try OAuthURLValidator().validateHTTPSOrLoopback(
            URL(string: "http://127.0.0.1:9000/mcp")!, context: "test")
    }

    @Test("Rejects remote HTTP")
    func testValidateHTTPSOrLoopbackRejectsRemoteHTTP() {
        #expect(throws: OAuthAuthorizationError.self) {
            try OAuthURLValidator().validateHTTPSOrLoopback(
                URL(string: "http://example.com/mcp")!, context: "test")
        }
    }

    @Test("Rejects URL with fragment")
    func testValidateHTTPSOrLoopbackRejectsFragment() {
        #expect(throws: OAuthAuthorizationError.self) {
            try OAuthURLValidator().validateHTTPSOrLoopback(
                URL(string: "https://example.com/mcp#frag")!, context: "test")
        }
    }

    // MARK: - validateAuthorizationServer

    @Test("Accepts HTTPS authorization server")
    func testValidateAuthorizationServerAcceptsHTTPS() throws {
        try OAuthURLValidator().validateAuthorizationServer(
            URL(string: "https://auth.example.com")!, context: "test")
    }

    @Test("Rejects HTTP authorization server by default")
    func testValidateAuthorizationServerRejectsHTTP() {
        #expect(throws: OAuthAuthorizationError.self) {
            try OAuthURLValidator().validateAuthorizationServer(
                URL(string: "http://auth.example.com")!, context: "test")
        }
    }

    @Test("Accepts loopback HTTP when flag is set")
    func testValidateAuthorizationServerAcceptsLoopbackWhenAllowed() throws {
        let v = OAuthURLValidator(allowLoopbackHTTPForAuthorizationServer: true)
        try v.validateAuthorizationServer(
            URL(string: "http://localhost:8080")!, context: "test")
    }

    @Test("Rejects loopback HTTP when flag is not set")
    func testValidateAuthorizationServerRejectsLoopbackWhenNotAllowed() {
        #expect(throws: OAuthAuthorizationError.self) {
            try OAuthURLValidator().validateAuthorizationServer(
                URL(string: "http://localhost:8080")!, context: "test")
        }
    }

    // MARK: - validateRedirectURI

    @Test("Accepts HTTPS redirect URI")
    func testValidateRedirectURIAcceptsHTTPS() throws {
        try OAuthURLValidator().validateRedirectURI(
            URL(string: "https://app.example.com/callback")!)
    }

    @Test("Accepts loopback HTTP redirect URI")
    func testValidateRedirectURIAcceptsLoopback() throws {
        try OAuthURLValidator().validateRedirectURI(
            URL(string: "http://localhost:8080/callback")!)
    }

    @Test("Rejects remote HTTP redirect URI")
    func testValidateRedirectURIRejectsRemoteHTTP() {
        #expect(throws: OAuthAuthorizationError.self) {
            try OAuthURLValidator().validateRedirectURI(
                URL(string: "http://app.example.com/callback")!)
        }
    }

    @Test("Rejects redirect URI with fragment")
    func testValidateRedirectURIRejectsFragment() {
        #expect(throws: OAuthAuthorizationError.self) {
            try OAuthURLValidator().validateRedirectURI(
                URL(string: "https://app.example.com/callback#section")!)
        }
    }

    // MARK: - isPrivateIPHost

    @Test("Identifies private IPv4 ranges")
    func testIsPrivateIPHostIPv4() {
        let v = OAuthURLValidator()
        #expect(v.isPrivateIPHost("10.0.0.1"))
        #expect(v.isPrivateIPHost("172.16.0.1"))
        #expect(v.isPrivateIPHost("172.31.255.255"))
        #expect(v.isPrivateIPHost("192.168.1.1"))
        #expect(v.isPrivateIPHost("169.254.169.254"))
        #expect(v.isPrivateIPHost("100.64.0.1"))
    }

    @Test("Does not block public IPv4 addresses")
    func testIsPrivateIPHostPublicIPv4() {
        let v = OAuthURLValidator()
        #expect(!v.isPrivateIPHost("1.2.3.4"))
        #expect(!v.isPrivateIPHost("8.8.8.8"))
        #expect(!v.isPrivateIPHost("203.0.113.1"))
    }

    @Test("Identifies private IPv6 ULA and link-local addresses")
    func testIsPrivateIPHostIPv6() {
        let v = OAuthURLValidator()
        #expect(v.isPrivateIPHost("fc00::1"))
        #expect(v.isPrivateIPHost("fd12:3456::1"))
        #expect(v.isPrivateIPHost("fe80::1"))
    }

    @Test("Does not block public hostnames")
    func testIsPrivateIPHostPublicHostname() {
        let v = OAuthURLValidator()
        #expect(!v.isPrivateIPHost("example.com"))
        #expect(!v.isPrivateIPHost("localhost"))
    }

    @Test("Host names that start like IPv6 prefixes are not blocked")
    func testIsPrivateIPHostHexLikeHostnames() {
        let v = OAuthURLValidator()
        #expect(!v.isPrivateIPHost("fdic.gov"))
        #expect(!v.isPrivateIPHost("fcbarcelona.com"))
        #expect(!v.isPrivateIPHost("fe8.example.com"))
        #expect(!v.isPrivateIPHost("10.0.0.1.example.com"))
    }

    @Test("Bracketed, zoned and IPv4-mapped IPv6 literals are checked")
    func testIsPrivateIPHostIPv6Forms() {
        let v = OAuthURLValidator()
        #expect(v.isPrivateIPHost("[fd00::1]"))
        #expect(v.isPrivateIPHost("fe80::1%en0"))
        #expect(v.isPrivateIPHost("::ffff:10.0.0.1"))
        #expect(v.isPrivateIPHost("::ffff:169.254.169.254"))
        #expect(!v.isPrivateIPHost("::ffff:8.8.8.8"))
        #expect(v.isPrivateIPHost("0.0.0.0"))
        #expect(!v.isPrivateIPHost("2001:db8::1"))
    }

    @Test(
        "Every spelling of a private address is blocked",
        arguments: [
            "[::ffff:a00:1]", "[0:0:0:0:0:ffff:10.0.0.1]", "[::ffff:a9fe:a9fe]", "[64:ff9b::a00:1]",
            "[::10.0.0.1]", "167772161", "10.1", "0x0a.0.0.1", "012.0.0.1", "0251.0376.0251.0376",
            "198.18.0.1", "224.0.0.1", "255.255.255.255", "192.0.0.8", "[::]", "[ff02::1]", "[fec0::1]",
        ])
    func testIsPrivateIPHostSpellings(host: String) {
        #expect(OAuthURLValidator().isPrivateIPHost(host))
    }

    @Test("Public and loopback addresses in any spelling are not blocked")
    func testIsPrivateIPHostPublicSpellings() {
        let v = OAuthURLValidator()
        #expect(!v.isPrivateIPHost("[::ffff:808:808]"))
        #expect(!v.isPrivateIPHost("[64:ff9b::808:808]"))
        #expect(!v.isPrivateIPHost("[::1]"))
        #expect(!v.isPrivateIPHost("127.0.0.1"))
        #expect(!v.isPrivateIPHost("1e100.net"))
        #expect(!v.isPrivateIPHost("deadbeef.example"))
    }

    // MARK: - Redirects

    @Test("Discovery redirects must stay https and public")
    func testRedirectGuardValidated() {
        let guardDelegate = OAuthRedirectGuard(policy: .validated, validator: OAuthURLValidator())
        let https = URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource")!
        #expect(guardDelegate.allows(from: https, to: URL(string: "https://other.example.com/metadata")!))
        #expect(!guardDelegate.allows(from: https, to: URL(string: "http://other.example.com/metadata")!))
        #expect(!guardDelegate.allows(from: https, to: URL(string: "https://169.254.169.254/latest")!))
        #expect(!guardDelegate.allows(from: https, to: URL(string: "https://[fd00::1]/metadata")!))
        #expect(!guardDelegate.allows(from: https, to: URL(string: "http://localhost:3000/metadata")!))
        let loopback = URL(string: "http://localhost:3000/.well-known/oauth-protected-resource")!
        #expect(guardDelegate.allows(from: loopback, to: URL(string: "http://127.0.0.1:3000/metadata")!))
    }

    @Test("Token and registration requests follow no redirect")
    func testRedirectGuardNone() {
        let guardDelegate = OAuthRedirectGuard(policy: .none, validator: OAuthURLValidator())
        #expect(!guardDelegate.allows(
            from: URL(string: "https://auth.example.com/token")!,
            to: URL(string: "https://auth.example.com/token2")!))
    }
}
