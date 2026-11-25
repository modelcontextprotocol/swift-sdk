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

    @Test("Accepts IPv6 loopback HTTP")
    func testValidateHTTPSOrLoopbackAcceptsIPv6Loopback() throws {
        try OAuthURLValidator().validateHTTPSOrLoopback(
            URL(string: "http://[::1]:9000/mcp")!, context: "test")
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
        try v.validateAuthorizationServer(
            URL(string: "http://[::1]:8080")!, context: "test")
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
        try OAuthURLValidator().validateRedirectURI(
            URL(string: "http://[::1]:8080/callback")!)
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

    /// The host of `url`, extracted the same way the OAuth flow does before calling
    /// `isPrivateIPHost`. `URLComponents` keeps the brackets around an IPv6 literal.
    private func host(of url: String) throws -> String {
        let components = URLComponents(
            url: try #require(URL(string: url)), resolvingAgainstBaseURL: false)
        return try #require(components?.host).lowercased()
    }

    @Test(
        "Blocks private IPv6 literals taken from a URL",
        arguments: [
            "https://[fc00::1]/", "https://[fd12:3456::1]/", "https://[fe80::1]/",
            "https://[fec0::1]/", "https://[ff02::1]/", "https://[::]/",
            "https://[64:ff9b:1::a00:1]/",
        ])
    func testIsPrivateIPHostBracketedIPv6(url: String) throws {
        #expect(OAuthURLValidator().isPrivateIPHost(try host(of: url)))
    }

    @Test("Ignores the zone index of a link-local IPv6 address")
    func testIsPrivateIPHostZoneIndex() {
        let v = OAuthURLValidator()
        #expect(v.isPrivateIPHost("[fe80::1%en0]"))
        #expect(v.isPrivateIPHost("fe80::1%en0"))
    }

    @Test(
        "Blocks IPv6 addresses that embed a private IPv4 address",
        arguments: [
            "https://[::ffff:169.254.169.254]/", "https://[::ffff:a9fe:a9fe]/",
            "https://[0:0:0:0:0:ffff:10.0.0.1]/", "https://[::ffff:0:169.254.169.254]/",
            "https://[::10.0.0.1]/", "https://[64:ff9b::a9fe:a9fe]/",
            "https://[2002:c0a8:101::1]/", "https://[::ffff:192.0.0.192]/",
            "https://[64:ff9b::c612:1]/", "https://[2002:c612:1::1]/",
        ])
    func testIsPrivateIPHostEmbeddedIPv4(url: String) throws {
        #expect(OAuthURLValidator().isPrivateIPHost(try host(of: url)))
    }

    @Test(
        "Blocks IPv4 addresses that are not a canonical dotted quad",
        arguments: [
            "https://2852039166/", "https://169.254.43518/", "https://0251.0376.0251.0376/",
            "https://0xa9.0xfe.0xa9.0xfe/", "https://012.0.0.1/", "https://10.1/",
            "https://10.0.0.1./", "https://[::ffff:012.0.0.1]/",
        ])
    func testIsPrivateIPHostNonCanonicalIPv4(url: String) throws {
        #expect(OAuthURLValidator().isPrivateIPHost(try host(of: url)))
    }

    @Test(
        "Blocks brackets around anything but an IPv6 address",
        arguments: [
            "[169.254.169.254]", "[10.0.0.1]", "[2852039166]", "[127.0.0.1]", "[::1", "::1]",
        ])
    func testIsPrivateIPHostBracketedNonIPv6(host: String) {
        #expect(OAuthURLValidator().isPrivateIPHost(host))
    }

    @Test("Blocks the unspecified, multicast and reserved IPv4 ranges")
    func testIsPrivateIPHostReservedIPv4() {
        let v = OAuthURLValidator()
        #expect(v.isPrivateIPHost("0.0.0.0"))
        #expect(v.isPrivateIPHost("0.1.2.3"))
        #expect(v.isPrivateIPHost("224.0.0.1"))
        #expect(v.isPrivateIPHost("255.255.255.255"))
    }

    @Test(
        "Blocks the first and last addresses of each range",
        arguments: [
            "0.255.255.255", "10.0.0.0", "10.255.255.255", "100.64.0.0", "100.127.255.255",
            "169.254.0.0", "169.254.255.255", "172.16.0.0", "172.31.255.255", "192.0.0.0",
            "192.0.0.255", "192.168.0.0", "192.168.255.255", "198.18.0.0", "198.19.255.255",
            "224.0.0.0", "[fc00::]", "[fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]",
            "[fe80::]", "[febf:ffff::1]", "[fec0::]", "[feff:ffff::1]", "[ff00::]",
            "[64:ff9b:1::]", "[64:ff9b:1:ffff:ffff:ffff:ffff:ffff]",
        ])
    func testIsPrivateIPHostRangeEdges(host: String) {
        #expect(OAuthURLValidator().isPrivateIPHost(host))
    }

    @Test(
        "Does not block the addresses next to each range",
        arguments: [
            "1.0.0.0", "9.255.255.255", "11.0.0.0", "100.63.255.255", "100.128.0.0",
            "169.253.255.255", "169.255.0.0", "172.15.255.255", "172.32.0.0", "191.255.255.255",
            "192.0.1.0", "192.167.255.255", "192.169.0.0", "198.17.255.255", "198.20.0.0",
            "223.255.255.255", "[fbff:ffff::1]", "[fe00::1]", "[fe7f:ffff::1]", "[64:ff9b:2::1]",
        ])
    func testIsPrivateIPHostRangeNeighbours(host: String) {
        #expect(!OAuthURLValidator().isPrivateIPHost(host))
    }

    @Test("Host names taken from a URL that start like an address are not blocked")
    func testIsPrivateIPHostHexLikeHostnamesFromURL() throws {
        let v = OAuthURLValidator()
        #expect(!v.isPrivateIPHost(try host(of: "https://fd-auth.example.com/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://fcm.googleapis.com/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://fe80.example.com/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://feature.example.com/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://10.0.0.1.example.com/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://1e100.net/")))
    }

    @Test("Does not block public IPv6 addresses or IPv6 forms of public IPv4 addresses")
    func testIsPrivateIPHostPublicIPv6() throws {
        let v = OAuthURLValidator()
        #expect(!v.isPrivateIPHost(try host(of: "https://[2606:4700:4700::1111]/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://[::ffff:8.8.8.8]/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://[::ffff:808:808]/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://[64:ff9b::808:808]/")))
        #expect(!v.isPrivateIPHost(try host(of: "https://[2002:808:808::1]/")))
    }

    @Test("Does not block loopback addresses")
    func testIsPrivateIPHostLoopback() throws {
        let v = OAuthURLValidator()
        #expect(!v.isPrivateIPHost("127.0.0.1"))
        #expect(!v.isPrivateIPHost("::1"))
        #expect(!v.isPrivateIPHost(try host(of: "http://[::1]:8080/")))
        #expect(!v.isPrivateIPHost(try host(of: "http://[::ffff:127.0.0.1]:8080/")))
    }

    @Test("Blocks a host that contains a colon but is not an IPv6 address")
    func testIsPrivateIPHostMalformedIPv6() {
        #expect(OAuthURLValidator().isPrivateIPHost("fc00::1::2"))
    }

    // MARK: - OAuthLoopbackHost

    @Test("Treats only the bracketed IPv6 loopback as a bracketed loopback host")
    func testLoopbackHostBrackets() {
        #expect(OAuthLoopbackHost.isLoopback("[::1]"))
        #expect(OAuthLoopbackHost.isLoopback("::1"))
        #expect(!OAuthLoopbackHost.isLoopback("[127.0.0.1]"))
        #expect(!OAuthLoopbackHost.isLoopback("[localhost]"))
        #expect(!OAuthLoopbackHost.isLoopback("[::2]"))
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
        #expect(guardDelegate.allows(from: loopback, to: URL(string: "http://[::1]:3000/metadata")!))
        #expect(!guardDelegate.allows(
            from: https, to: URL(string: "https://[::ffff:0:10.0.0.1]/metadata")!))
    }

    @Test("Discovery redirects reach a loopback host only from a loopback host")
    func testRedirectGuardLoopback() {
        let guardDelegate = OAuthRedirectGuard(policy: .validated, validator: OAuthURLValidator())
        let https = URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource")!
        for target in [
            "https://127.0.0.1:8443/metadata", "https://127.0.0.2/metadata", "https://localhost/metadata",
            "https://a.localhost/metadata", "https://localhost./metadata", "https://[::1]/metadata",
            "https://[::ffff:127.0.0.1]/metadata", "https://[::127.0.0.1]/metadata",
        ] {
            #expect(!guardDelegate.allows(from: https, to: URL(string: target)!), "\(target)")
        }
        let loopback = URL(string: "https://localhost:8443/.well-known/oauth-protected-resource")!
        #expect(guardDelegate.allows(from: loopback, to: URL(string: "https://127.0.0.1:8443/metadata")!))
        #expect(guardDelegate.allows(from: loopback, to: URL(string: "https://[::1]:8443/metadata")!))
        // The previous hop decides: a public https hop does not reach loopback http.
        #expect(!guardDelegate.allows(from: https, to: URL(string: "http://127.0.0.1:3000/metadata")!))
    }

    @Test("Token and registration requests follow no redirect")
    func testRedirectGuardNone() {
        let guardDelegate = OAuthRedirectGuard(policy: .none, validator: OAuthURLValidator())
        #expect(!guardDelegate.allows(
            from: URL(string: "https://auth.example.com/token")!,
            to: URL(string: "https://auth.example.com/token2")!))
    }
}
