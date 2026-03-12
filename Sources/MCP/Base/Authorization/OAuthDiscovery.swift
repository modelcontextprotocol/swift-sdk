import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Scope Selection Protocol

/// Determines which OAuth scopes to request during token acquisition.
///
/// ``OAuthAuthorizer`` uses this protocol to translate raw scope strings from
/// `WWW-Authenticate` challenges and Protected Resource Metadata into the
/// scope set passed to the token endpoint.
///
/// Override the default ``DefaultOAuthScopeSelector`` to apply custom scope
/// filtering or transformation logic.
public protocol OAuthScopeSelecting {
    /// Selects the scope set to request for a token.
    ///
    /// Priority order (highest first):
    /// 1. `challengeScope` — the `scope` parameter from the `WWW-Authenticate` header.
    /// 2. `scopesSupported` — the `scopes_supported` array from Protected Resource Metadata.
    /// 3. `nil` — no scope restriction.
    ///
    /// - Parameters:
    ///   - challengeScope: Space-separated scope string from the Bearer challenge, or `nil`.
    ///   - scopesSupported: Array of supported scopes from the resource metadata, or `nil`.
    /// - Returns: The set of scopes to request, or `nil` to omit the `scope` parameter entirely.
    func selectScopes(challengeScope: String?, scopesSupported: [String]?) -> Set<String>?

    /// Parses a space-separated OAuth scope string into individual scope tokens.
    /// - Parameter scope: A scope string such as `"read write"`.
    /// - Returns: A set of individual scope strings with whitespace-only tokens removed.
    func parseScopeString(_ scope: String) -> Set<String>

    /// Serializes a set of scopes into a space-separated string suitable for the `scope` parameter.
    /// - Parameter scopes: The scope set to serialize.
    /// - Returns: A sorted, space-separated string, or `nil` if the set is empty.
    func serialize(_ scopes: Set<String>) -> String?
}

// MARK: - Default Scope Selector

/// Default ``OAuthScopeSelecting`` implementation.
///
/// Selects scopes in priority order: challenge scope > `scopes_supported` > `nil`.
/// Serializes scopes sorted alphabetically to produce deterministic `scope` parameters.
public struct DefaultOAuthScopeSelector: OAuthScopeSelecting {
    public init() {}

    public func selectScopes(challengeScope: String?, scopesSupported: [String]?) -> Set<String>? {
        if let challengeScope {
            let parsed = parseScopeString(challengeScope)
            return parsed.isEmpty ? nil : parsed
        }

        if let scopesSupported {
            let parsed = Set(scopesSupported.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            return parsed.isEmpty ? nil : parsed
        }

        return nil
    }

    public func parseScopeString(_ scope: String) -> Set<String> {
        Set(
            scope
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    public func serialize(_ scopes: Set<String>) -> String? {
        guard !scopes.isEmpty else { return nil }
        return scopes.sorted().joined(separator: " ")
    }
}

// MARK: - Metadata Discovery Protocol

/// Builds discovery URLs and normalizes resource identifiers for OAuth metadata discovery.
///
/// ``OAuthAuthorizer`` uses this protocol to construct the candidate URL list for both
/// Protected Resource Metadata (RFC 9728) and Authorization Server Metadata (RFC 8414 / OIDC)
/// discovery, and to normalize resource URIs for RFC 8707 audience binding.
///
/// Override the default ``DefaultOAuthMetadataDiscovery`` to customise discovery URL
/// construction or resource-matching logic.
public protocol OAuthMetadataDiscovering: Sendable {
    /// Returns candidate URLs for Protected Resource Metadata, ordered by priority.
    ///
    /// ``OAuthAuthorizer`` tries each URL in order and uses the first successful response.
    ///
    /// - Parameter endpoint: The MCP endpoint URL.
    /// - Returns: An ordered list of discovery URLs (typically `/.well-known/oauth-protected-resource`
    ///   variants).
    func protectedResourceMetadataURLs(for endpoint: URL) -> [URL]

    /// Returns candidate URLs for Authorization Server Metadata, ordered by priority.
    ///
    /// Covers RFC 8414 (`/.well-known/oauth-authorization-server`) and
    /// OIDC Discovery 1.0 (`/.well-known/openid-configuration`), including
    /// path-inserted variants for issuers with non-root paths.
    ///
    /// - Parameter issuer: The authorization server issuer URL.
    /// - Returns: An ordered list of metadata discovery URLs.
    func authorizationServerMetadataURLs(for issuer: URL) -> [URL]

    /// Derives the canonical RFC 8707 resource URI from an endpoint URL.
    ///
    /// The canonical form strips the query string, fragment, and trailing slash
    /// while preserving the scheme, host, port, and path.
    ///
    /// - Parameter endpoint: The MCP endpoint URL.
    /// - Returns: The canonical resource URI.
    /// - Throws: ``OAuthAuthorizationError/invalidResourceURI(_:)`` if the URL does not
    ///   satisfy the HTTPS-or-loopback-HTTP requirement.
    func canonicalResourceURI(from endpoint: URL) throws -> URL

    /// Derives a fallback authorization server issuer URL from an endpoint URL.
    ///
    /// Used when no authorization server is listed in Protected Resource Metadata.
    /// Typically returns the scheme+host+port of the endpoint with an empty path.
    ///
    /// - Parameter endpoint: The MCP endpoint URL.
    /// - Returns: A candidate issuer URL.
    /// - Throws: ``OAuthAuthorizationError/invalidResourceURI(_:)`` if the URL is invalid.
    func authorizationServerFallbackIssuer(from endpoint: URL) throws -> URL

    /// Returns `true` if `resource` is a prefix of `endpoint` in the URL hierarchy.
    ///
    /// A resource matches an endpoint when the two share the same scheme, host, and port,
    /// and the endpoint path starts with the resource path.
    ///
    /// - Parameters:
    ///   - resource: The canonical resource URI from Protected Resource Metadata.
    ///   - endpoint: The canonical endpoint URI being requested.
    /// - Returns: `true` if the endpoint falls within the resource's scope.
    func protectedResourceMatches(resource: URL, endpoint: URL) -> Bool
}

// MARK: - Default Metadata Discovery

/// Default ``OAuthMetadataDiscovering`` implementation following RFC 9728 and RFC 8414.
///
/// - Builds `/.well-known/oauth-protected-resource` URLs with and without the endpoint path suffix.
/// - Builds RFC 8414 and OIDC discovery URLs with path-inserted and path-appended variants.
/// - Canonicalises resource URIs by stripping query, fragment, and trailing slash.
/// - Matches resources using scheme/host/port equality and path prefix rules.
public struct DefaultOAuthMetadataDiscovery: OAuthMetadataDiscovering {
    public init() {}

    public func protectedResourceMetadataURLs(for endpoint: URL) -> [URL] {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            Self.isSecureOAuthScheme(scheme: scheme, host: host)
        else {
            return []
        }

        components.query = nil
        components.fragment = nil

        let endpointPath = components.path
        let normalizedPath = endpointPath == "/" ? "" : endpointPath

        var urls: [URL] = []

        var pathSpecific = components
        pathSpecific.path = "\(OAuthWellKnownPath.protectedResource)\(normalizedPath)"
        if let url = pathSpecific.url {
            urls.append(url)
        }

        var root = components
        root.path = OAuthWellKnownPath.protectedResource
        if let url = root.url {
            urls.append(url)
        }

        return urls
    }

    public func authorizationServerMetadataURLs(for issuer: URL) -> [URL] {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            Self.isSecureOAuthScheme(scheme: scheme, host: host)
        else {
            return []
        }

        components.query = nil
        components.fragment = nil

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hasPath = !path.isEmpty

        var urls: [URL] = []

        if hasPath {
            var oauthInserted = components
            oauthInserted.path = "\(OAuthWellKnownPath.authorizationServer)/\(path)"
            if let url = oauthInserted.url {
                urls.append(url)
            }

            var oidcInserted = components
            oidcInserted.path = "\(OAuthWellKnownPath.openIDConfiguration)/\(path)"
            if let url = oidcInserted.url {
                urls.append(url)
            }

            var oidcAppended = components
            oidcAppended.path = "/\(path)\(OAuthWellKnownPath.openIDConfiguration)"
            if let url = oidcAppended.url {
                urls.append(url)
            }
        } else {
            var oauth = components
            oauth.path = OAuthWellKnownPath.authorizationServer
            if let url = oauth.url {
                urls.append(url)
            }

            var oidc = components
            oidc.path = OAuthWellKnownPath.openIDConfiguration
            if let url = oidc.url {
                urls.append(url)
            }
        }

        return urls
    }

    public func canonicalResourceURI(from endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            Self.isSecureOAuthScheme(scheme: scheme, host: host)
        else {
            throw OAuthAuthorizationError.invalidResourceURI(
                "Resource URI must use https or loopback http"
            )
        }

        if components.fragment != nil {
            throw OAuthAuthorizationError.invalidResourceURI("Resource URI must not contain a fragment")
        }

        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil

        if components.path == "/" {
            components.path = ""
        }

        guard let url = components.url else {
            throw OAuthAuthorizationError.invalidResourceURI("Failed to normalize resource URI")
        }

        return url
    }

    public func authorizationServerFallbackIssuer(from endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            Self.isSecureOAuthScheme(scheme: scheme, host: host)
        else {
            throw OAuthAuthorizationError.invalidResourceURI(
                "Resource URI must use https or loopback http"
            )
        }

        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw OAuthAuthorizationError.invalidResourceURI("Failed to derive issuer URI")
        }
        return url
    }

    public func protectedResourceMatches(resource: URL, endpoint: URL) -> Bool {
        guard let resourceComponents = URLComponents(
            url: resource,
            resolvingAgainstBaseURL: false
        ),
            let endpointComponents = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            return false
        }

        let resourceScheme = resourceComponents.scheme?.lowercased()
        let endpointScheme = endpointComponents.scheme?.lowercased()
        let resourceHost = resourceComponents.host?.lowercased()
        let endpointHost = endpointComponents.host?.lowercased()
        let resourcePort = resourceComponents.port ?? Self.defaultPort(for: resourceScheme)
        let endpointPort = endpointComponents.port ?? Self.defaultPort(for: endpointScheme)

        guard resourceScheme == endpointScheme,
            resourceHost == endpointHost,
            resourcePort == endpointPort
        else {
            return false
        }

        let resourcePath = Self.normalizedResourcePath(resourceComponents.path)
        let endpointPath = Self.normalizedResourcePath(endpointComponents.path)
        if resourcePath.isEmpty {
            return true
        }
        if endpointPath == resourcePath {
            return true
        }
        return endpointPath.hasPrefix(resourcePath + "/")
    }

    private static func normalizedResourcePath(_ rawPath: String) -> String {
        if rawPath.isEmpty || rawPath == "/" {
            return ""
        }
        if rawPath.count > 1 && rawPath.hasSuffix("/") {
            return String(rawPath.dropLast())
        }
        return rawPath
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case OAuthURLScheme.http:
            return OAuthDefaultPort.http
        case OAuthURLScheme.https:
            return OAuthDefaultPort.https
        default:
            return nil
        }
    }

    static func isSecureOAuthScheme(scheme: String, host: String) -> Bool {
        if scheme == OAuthURLScheme.https {
            return true
        }
        if scheme == OAuthURLScheme.http {
            return OAuthLoopbackHost.isLoopback(host)
        }
        return false
    }
}

