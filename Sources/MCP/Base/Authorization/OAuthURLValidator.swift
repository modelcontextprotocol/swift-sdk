import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal protocol for URL security validation in OAuth flows.
protocol OAuthURLValidating: Sendable {
    func validateHTTPSOrLoopback(_ url: URL, context: String) throws
    func validateAuthorizationServer(_ url: URL, context: String) throws
    func validateRedirectURI(_ url: URL) throws
    func isPrivateIPHost(_ host: String) -> Bool
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
    /// Blocked ranges:
    /// - IPv4: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`
    /// - IPv6: `fc00::/7` (ULA), `fe80::/10` (link-local)
    ///
    /// **Limitation**: only literal IP addresses are checked. DNS rebinding is not prevented here.
    public func isPrivateIPHost(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 && !host.contains(":") {
            let (a, b) = (octets[0], octets[1])
            return a == 10  // 10.0.0.0/8
                || (a == 172 && (16...31).contains(b))  // 172.16.0.0/12
                || (a == 192 && b == 168)  // 192.168.0.0/16
                || (a == 169 && b == 254)  // 169.254.0.0/16 (link-local / cloud metadata)
                || (a == 100 && (64...127).contains(b))  // 100.64.0.0/10 (CGNAT)
        }
        let lower = host.lowercased()
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }  // fc00::/7 (ULA)
        if lower.hasPrefix("fe") && lower.count > 2 {
            let idx = lower.index(lower.startIndex, offsetBy: 2)
            if "89ab".contains(lower[idx]) { return true }  // fe80::/10 (link-local)
        }
        return false
    }
}

extension OAuthURLValidator: OAuthURLValidating {}
