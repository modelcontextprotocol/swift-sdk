import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - OAuthAuthorizationCodeFlowing Protocol

/// Internal protocol for driving the OAuth 2.1 authorization code flow.
protocol OAuthAuthorizationCodeFlowing: Sendable {
    func buildURL(
        authorizationEndpoint: URL,
        resource: URL,
        redirectURI: URL,
        clientID: String,
        codeChallenge: String,
        scopes: Set<String>?,
        state: String,
        scopeSerializer: any OAuthScopeSelecting
    ) throws -> URL

    func perform(
        authorizationURL: URL,
        redirectURI: URL,
        state: String,
        delegate: (any OAuthAuthorizationDelegate)?,
        session: URLSession
    ) async throws -> String
}

// MARK: - No-Redirect Session Delegate

final class OAuthNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Authorization Code Flow

/// Handles the browser-facing steps of the OAuth 2.1 authorization_code flow.
///
/// Builds the authorization request URL, drives the redirect (via delegate or direct HTTP),
/// and extracts the authorization code from the callback redirect URL.
public struct OAuthAuthorizationCodeFlow: Sendable {

    public init() {}

    /// Builds the authorization request URL.
    ///
    /// - Parameters:
    ///   - authorizationEndpoint: The AS authorization endpoint.
    ///   - resource: The RFC 8707 resource indicator.
    ///   - redirectURI: The redirect URI registered for this client.
    ///   - clientID: The OAuth client identifier.
    ///   - codeChallenge: The PKCE S256 code challenge.
    ///   - scopes: Optional scope set to request.
    ///   - state: The CSRF state nonce.
    ///   - scopeSerializer: Serializes the scope set to a space-separated string.
    /// - Returns: The full authorization request URL with all query parameters.
    public func buildURL(
        authorizationEndpoint: URL,
        resource: URL,
        redirectURI: URL,
        clientID: String,
        codeChallenge: String,
        scopes: Set<String>?,
        state: String,
        scopeSerializer: any OAuthScopeSelecting
    ) throws -> URL {
        guard var components = URLComponents(
            url: authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
        }

        var queryItems: [URLQueryItem] = [
            .init(name: OAuthParameterName.responseType, value: OAuthParameterName.code),
            .init(name: OAuthParameterName.clientID, value: clientID),
            .init(name: OAuthParameterName.redirectURI, value: redirectURI.absoluteString),
            .init(name: OAuthParameterName.state, value: state),
            .init(name: OAuthParameterName.resource, value: resource.absoluteString),
            .init(name: OAuthParameterName.codeChallenge, value: codeChallenge),
            .init(
                name: OAuthParameterName.codeChallengeMethod, value: OAuthCodeChallengeMethod.s256),
        ]

        if let scope = scopes.flatMap(scopeSerializer.serialize) {
            queryItems.append(.init(name: OAuthParameterName.scope, value: scope))
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
        }
        return url
    }

    /// Drives the interactive authorization redirect and returns the authorization code.
    ///
    /// When a delegate is provided, presents the authorization URL and awaits the redirect.
    /// Without a delegate, sends a GET request and captures the redirect `Location` header.
    ///
    /// - Parameters:
    ///   - authorizationURL: The full authorization request URL.
    ///   - redirectURI: The expected redirect URI base for validation.
    ///   - state: The CSRF state nonce to verify in the redirect.
    ///   - delegate: Optional user-facing delegate for browser-based flows.
    ///   - session: The `URLSession` used for the no-redirect path.
    /// - Returns: The extracted authorization code.
    public func perform(
        authorizationURL: URL,
        redirectURI: URL,
        state: String,
        delegate: (any OAuthAuthorizationDelegate)?,
        session: URLSession
    ) async throws -> String {
        if let delegate {
            let redirectURL = try await delegate.presentAuthorizationURL(authorizationURL)
            return try extractCode(
                from: redirectURL,
                expectedRedirectURI: redirectURI,
                expectedState: state
            )
        }

        var request = URLRequest(url: authorizationURL)
        request.httpMethod = "GET"
        request.setValue(
            "text/html, \(ContentType.json)", forHTTPHeaderField: HTTPHeaderName.accept)

        let noRedirectDelegate = OAuthNoRedirectSessionDelegate()
        let noRedirectSession = URLSession(
            configuration: session.configuration,
            delegate: noRedirectDelegate,
            delegateQueue: nil
        )
        defer { noRedirectSession.invalidateAndCancel() }

        let (_, response) = try await noRedirectSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<400).contains(httpResponse.statusCode)
        else {
            throw OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
        }

        guard (300..<400).contains(httpResponse.statusCode) else {
            throw OAuthAuthorizationError.authorizationResponseMissingRedirectLocation
        }

        guard let location = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.location),
            !location.isEmpty,
            let redirectURL = URL(string: location)
        else {
            throw OAuthAuthorizationError.authorizationResponseMissingRedirectLocation
        }

        return try extractCode(
            from: redirectURL,
            expectedRedirectURI: redirectURI,
            expectedState: state
        )
    }

    /// Extracts and validates the authorization code from the redirect URL.
    ///
    /// - Parameters:
    ///   - redirectURL: The redirect URL received from the authorization server.
    ///   - expectedRedirectURI: The redirect URI used in the authorization request.
    ///   - expectedState: The CSRF state nonce sent in the authorization request.
    /// - Returns: The authorization code.
    public func extractCode(
        from redirectURL: URL,
        expectedRedirectURI: URL,
        expectedState: String
    ) throws -> String {
        guard
            let redirectComponents = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
            let expectedComponents = URLComponents(
                url: expectedRedirectURI, resolvingAgainstBaseURL: false)
        else {
            throw OAuthAuthorizationError.authorizationResponseRedirectMismatch(
                expected: expectedRedirectURI.absoluteString,
                actual: redirectURL.absoluteString
            )
        }

        if normalizedRedirectBase(redirectComponents) != normalizedRedirectBase(expectedComponents) {
            throw OAuthAuthorizationError.authorizationResponseRedirectMismatch(
                expected: expectedRedirectURI.absoluteString,
                actual: redirectURL.absoluteString
            )
        }

        guard
            let state = redirectComponents.queryItems?.first(where: {
                $0.name == OAuthParameterName.state
            })?.value,
            !state.isEmpty
        else {
            throw OAuthAuthorizationError.authorizationResponseMissingState
        }

        guard state == expectedState else {
            throw OAuthAuthorizationError.authorizationResponseStateMismatch(
                expected: expectedState,
                actual: state
            )
        }

        guard
            let code = redirectComponents.queryItems?.first(where: {
                $0.name == OAuthParameterName.code
            })?.value,
            !code.isEmpty
        else {
            throw OAuthAuthorizationError.authorizationResponseMissingCode
        }

        return code
    }

    // MARK: - Private Helpers

    private func normalizedRedirectBase(_ components: URLComponents) -> String {
        let scheme = components.scheme?.lowercased() ?? ""
        let host = components.host?.lowercased() ?? ""
        let port: Int
        if let explicitPort = components.port {
            port = explicitPort
        } else if scheme == OAuthURLScheme.https {
            port = OAuthDefaultPort.https
        } else if scheme == OAuthURLScheme.http {
            port = OAuthDefaultPort.http
        } else {
            port = -1
        }
        let path = components.path.isEmpty ? "/" : components.path
        return "\(scheme)://\(host):\(port)\(path)"
    }
}

extension OAuthAuthorizationCodeFlow: OAuthAuthorizationCodeFlowing {}
