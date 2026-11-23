import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Internal protocol for URL security validation in OAuth flows.
protocol OAuthURLValidating: Sendable {
    func validateHTTPSOrLoopback(_ url: URL, context: String) throws
    func validateAuthorizationServer(_ url: URL, context: String) throws
    func validateRedirectURI(_ url: URL) throws
    func isPrivateIPHost(_ host: String) -> Bool
}

extension OAuthURLValidating {
    /// Throws ``OAuthAuthorizationError/privateIPAddressBlocked(context:url:)``
    /// when `url` has a private or reserved IP literal host.
    func rejectPrivateIP(_ url: URL, context: String) throws {
        if let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased(),
            isPrivateIPHost(host)
        {
            throw OAuthAuthorizationError.privateIPAddressBlocked(
                context: context, url: url.absoluteString)
        }
    }

    /// Validates an authorization server URL and rejects private IP literal hosts.
    func validateAuthorizationServerAndHost(_ url: URL, context: String) throws {
        try validateAuthorizationServer(url, context: context)
        try rejectPrivateIP(url, context: context)
    }
}

/// URL security rules for OAuth endpoints.
///
/// Validates that URLs used in the OAuth flow satisfy HTTPS requirements and SSRF protections.
/// Configured once and shared across the discovery, token, and registration components.
public struct OAuthURLValidator: Sendable {

    /// When `true`, loopback HTTP URLs are accepted for authorization server endpoints.
    ///
    /// This is a package-level compatibility option for local test environments.
    public let allowLoopbackHTTPForAuthorizationServer: Bool

    public init(allowLoopbackHTTPForAuthorizationServer: Bool = false) {
        self.allowLoopbackHTTPForAuthorizationServer = allowLoopbackHTTPForAuthorizationServer
    }

    /// Validates that the URL uses HTTPS or loopback HTTP, and has no fragment.
    ///
    /// Used for MCP endpoints and protected resource metadata URLs.
    public func validateHTTPSOrLoopback(_ url: URL, context: String) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.fragment == nil
        else {
            throw OAuthAuthorizationError.invalidResourceURI(
                "Invalid \(context): \(url.absoluteString)"
            )
        }

        guard scheme == OAuthURLScheme.https
            || (scheme == OAuthURLScheme.http && OAuthLoopbackHost.isLoopback(host))
        else {
            throw OAuthAuthorizationError.insecureOAuthEndpoint(
                context: context,
                url: url.absoluteString
            )
        }
    }

    /// Validates that the URL is an HTTPS authorization server endpoint.
    ///
    /// Loopback HTTP is permitted when `allowLoopbackHTTPForAuthorizationServer` is `true`.
    public func validateAuthorizationServer(_ url: URL, context: String) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.fragment == nil
        else {
            throw OAuthAuthorizationError.invalidResourceURI(
                "Invalid \(context): \(url.absoluteString)"
            )
        }

        if allowLoopbackHTTPForAuthorizationServer,
            scheme == OAuthURLScheme.http,
            OAuthLoopbackHost.isLoopback(host)
        {
            return
        }

        guard scheme == OAuthURLScheme.https else {
            throw OAuthAuthorizationError.insecureAuthorizationServerEndpoint(
                context: context,
                url: url.absoluteString
            )
        }
    }

    /// Validates the redirect URI for authorization_code flows.
    ///
    /// Accepts HTTPS or loopback HTTP; rejects any URI containing a fragment.
    public func validateRedirectURI(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            components.fragment == nil
        else {
            throw OAuthAuthorizationError.invalidRedirectURI(url.absoluteString)
        }

        if scheme == OAuthURLScheme.https { return }

        if scheme == OAuthURLScheme.http,
            let host = components.host?.lowercased(),
            OAuthLoopbackHost.isLoopback(host)
        {
            return
        }

        throw OAuthAuthorizationError.invalidRedirectURI(url.absoluteString)
    }

    /// Returns `true` if `host` is a literal IPv4 or IPv6 address in a private or reserved range.
    ///
    /// The host is parsed with `inet_pton`, so every spelling of an address is
    /// classified the same way. Blocked:
    /// - IPv4: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `169.254.0.0/16`,
    ///   `172.16.0.0/12`, `192.0.0.0/24`, `192.168.0.0/16`, `198.18.0.0/15`,
    ///   `224.0.0.0/4` and `240.0.0.0/4`;
    /// - IPv6: `::` , `fc00::/7` (ULA), `fe80::/10` (link-local), `fec0::/10`,
    ///   `ff00::/8` (multicast), `64:ff9b:1::/48` (local-use NAT64), and IPv4
    ///   addresses embedded as IPv4-mapped (`::ffff:0:0/96`), IPv4-translated
    ///   (`::ffff:0:0:0/96`), IPv4-compatible (`::/96`), NAT64 (`64:ff9b::/96`)
    ///   or 6to4 (`2002::/16`), classified as IPv4;
    /// - numeric hosts that are not a canonical dotted quad but that resolvers
    ///   read as IPv4, such as `167772161`, `10.1`, `0x0a.0.0.1` or `10.0.0.1.`;
    /// - spellings that parsers read differently: brackets around anything but
    ///   an IPv6 address (`[127.0.0.1]`) or unbalanced (`[::1`), a host with `:`
    ///   that is not an IPv6 address (`fc00::1::2`), and an embedded IPv4 address
    ///   that is not a canonical dotted quad (`::ffff:012.0.0.1`).
    ///
    /// Host names are never blocked. Loopback addresses are not blocked.
    ///
    /// **Limitation**: only literal IP addresses are checked. DNS rebinding is not prevented here.
    public func isPrivateIPHost(_ host: String) -> Bool {
        isPrivateIPHost(host, includingLoopback: false)
    }

    /// ``isPrivateIPHost(_:)``; with `includingLoopback`, `127.0.0.0/8` and
    /// `::1`, also embedded in IPv6 as above, count as private too.
    func isPrivateIPHost(_ host: String, includingLoopback loopback: Bool) -> Bool {
        var literal = host.lowercased()
        if literal.hasPrefix("[") || literal.hasSuffix("]") {
            // `URLComponents.host` keeps the brackets of an IPv6 literal; they
            // belong around nothing else.
            guard literal.hasPrefix("["), literal.hasSuffix("]"), literal.contains(":") else {
                return true
            }
            literal = String(literal.dropFirst().dropLast())
        }
        if let zone = literal.firstIndex(of: "%") {
            literal = String(literal[..<zone])  // fe80::1%en0
        }
        if literal.contains(":") {
            // `inet_pton` reads `::ffff:012.0.0.1` as 12.0.0.1, resolvers may not.
            if let tail = literal.split(separator: ":").last, tail.contains("."),
                !Self.isCanonicalIPv4(String(tail))
            {
                return true
            }
            guard let bytes = Self.parse(literal, family: AF_INET6, size: 16) else { return true }
            return Self.isPrivateIPv6(bytes, loopback: loopback)
        }
        if let bytes = Self.parse(literal, family: AF_INET, size: 4) {
            // `012.0.0.1` parses as 12.0.0.1 here and as 10.0.0.1 (octal) in
            // resolvers: a non-canonical spelling is blocked.
            guard literal == bytes.map(String.init).joined(separator: ".") else { return true }
            return Self.isPrivateIPv4(bytes, loopback: loopback)
        }
        return Self.isNumericIPv4(literal)
    }

    /// The bytes of `text` as an address of `family`, or `nil`.
    private static func parse(_ text: String, family: Int32, size: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 16)
        let parsed = buffer.withUnsafeMutableBytes { inet_pton(family, text, $0.baseAddress) }
        return parsed == 1 ? Array(buffer.prefix(size)) : nil
    }

    /// Whether `text` is an IPv4 address written as a canonical dotted quad.
    private static func isCanonicalIPv4(_ text: String) -> Bool {
        guard let bytes = parse(text, family: AF_INET, size: 4) else { return false }
        return text == bytes.map(String.init).joined(separator: ".")
    }

    private static func isPrivateIPv4(_ octets: [UInt8], loopback: Bool) -> Bool {
        let (a, b, c) = (octets[0], octets[1], octets[2])
        return a == 0  // 0.0.0.0/8
            || (loopback && a == 127)  // 127.0.0.0/8, when asked
            || a == 10  // 10.0.0.0/8
            || (a == 100 && (64...127).contains(b))  // 100.64.0.0/10 (CGNAT)
            || (a == 169 && b == 254)  // 169.254.0.0/16 (link-local, cloud metadata)
            || (a == 172 && (16...31).contains(b))  // 172.16.0.0/12
            || (a == 192 && b == 0 && c == 0)  // 192.0.0.0/24 (IETF protocol assignments)
            || (a == 192 && b == 168)  // 192.168.0.0/16
            || (a == 198 && (18...19).contains(b))  // 198.18.0.0/15 (benchmarking)
            || a >= 224  // 224.0.0.0/4 (multicast), 240.0.0.0/4 (reserved)
    }

    private static func isPrivateIPv6(_ bytes: [UInt8], loopback: Bool) -> Bool {
        let prefix96 = bytes.prefix(12)
        let embedded = Array(bytes.suffix(4))
        if bytes.allSatisfy({ $0 == 0 }) { return true }  // ::
        if prefix96.elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]) {
            return isPrivateIPv4(embedded, loopback: loopback)  // ::ffff:0:0/96 (IPv4-mapped)
        }
        if prefix96.allSatisfy({ $0 == 0 }) {
            if embedded == [0, 0, 0, 1] { return loopback }  // ::1 (loopback)
            return isPrivateIPv4(embedded, loopback: loopback)  // ::/96 (IPv4-compatible)
        }
        if prefix96.elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0]) {
            return isPrivateIPv4(embedded, loopback: loopback)  // ::ffff:0:0:0/96 (IPv4-translated)
        }
        if prefix96.elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) {
            return isPrivateIPv4(embedded, loopback: loopback)  // 64:ff9b::/96 (NAT64)
        }
        let (first, second) = (bytes[0], bytes[1])
        if first == 0x20 && second == 0x02 {
            return isPrivateIPv4(Array(bytes[2..<6]), loopback: loopback)  // 2002::/16 (6to4)
        }
        return first & 0xfe == 0xfc  // fc00::/7 (ULA)
            || (first == 0xfe && second & 0xc0 == 0x80)  // fe80::/10 (link-local)
            || (first == 0xfe && second & 0xc0 == 0xc0)  // fec0::/10 (site-local)
            || first == 0xff  // ff00::/8 (multicast)
            || bytes.prefix(6).elementsEqual([0, 0x64, 0xff, 0x9b, 0, 1])  // 64:ff9b:1::/48
    }

    /// Whether resolvers read `host` as an IPv4 address (`inet_aton`).
    private static func isNumericIPv4(_ host: String) -> Bool {
        // Resolvers drop a trailing root label: `10.0.0.1.` is 10.0.0.1.
        let host = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !host.isEmpty, host.first?.isNumber == true,
            host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" })
        else { return false }
        var address = in_addr()
        return inet_aton(host, &address) != 0
    }
}

extension OAuthURLValidator: OAuthURLValidating {}
