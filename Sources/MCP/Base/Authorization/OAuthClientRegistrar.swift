import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal protocol for OAuth dynamic client registration.
protocol OAuthClientRegistering: Sendable {
    func register(
        configuration: OAuthConfiguration,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )?
}

/// Stateless OAuth dynamic client registration logic.
///
/// Handles Client ID Metadata Document (CIMD) detection and RFC 7591 dynamic registration.
/// State tracking (`clientRegistrationAttempted`, `clientSecretExpiresAt`) is the caller's responsibility.
struct OAuthClientRegistrar: Sendable {
    let urlValidator: OAuthURLValidator

    init(urlValidator: OAuthURLValidator) {
        self.urlValidator = urlValidator
    }

    /// Attempts to register the client, if applicable.
    ///
    /// Returns `nil` if registration is not needed:
    /// - Credentials are already configured (not `.none`)
    /// - CIMD is in use and the server supports it (pre-registered)
    /// - No registration endpoint is available and no CIMD mismatch error
    ///
    /// Throws if registration was attempted but failed (4xx, 5xx, or unexpected response).
    func register(
        configuration: OAuthConfiguration,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )? {
        guard case .none(let clientID) = configuration.authentication else {
            return nil
        }

        let hasClientIDMetadataDocument = isHTTPSURLWithPath(clientID)
        let supportsClientIDMetadataDocument = asMetadata.clientIDMetadataDocumentSupported == true

        if supportsClientIDMetadataDocument,
            clientIDLooksLikeURL(clientID),
            !hasClientIDMetadataDocument
        {
            throw OAuthAuthorizationError.invalidClientIDMetadataURL(clientID)
        }

        if hasClientIDMetadataDocument, supportsClientIDMetadataDocument {
            return nil
        }

        guard let registrationEndpoint = asMetadata.registrationEndpoint else {
            if hasClientIDMetadataDocument && !supportsClientIDMetadataDocument {
                throw OAuthAuthorizationError.cimdNotSupported(clientID: clientID)
            }
            return nil
        }
        try urlValidator.validateAuthorizationServer(
            registrationEndpoint, context: "Client registration endpoint")

        var request = URLRequest(url: registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.contentType)
        request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)

        let grantTypes: [String]
        let responseTypes: [String]
        switch configuration.grantType {
        case .authorizationCode:
            grantTypes = [OAuthGrantTypeValue.authorizationCode]
            responseTypes = [OAuthParameterName.code]
        case .clientCredentials:
            grantTypes = [OAuthGrantTypeValue.clientCredentials]
            responseTypes = []
        }

        var registrationPayload: [String: Any] = [
            "client_name": configuration.clientName,
            "grant_types": grantTypes,
            "token_endpoint_auth_method": configuration.authentication.methodName,
        ]
        if !responseTypes.isEmpty {
            registrationPayload["response_types"] = responseTypes
        }
        if configuration.grantType == .authorizationCode {
            registrationPayload["redirect_uris"] = [
                configuration.authorizationRedirectURI.absoluteString
            ]
        }

        let httpBody = try JSONSerialization.data(withJSONObject: registrationPayload)

        request.httpBody = httpBody

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
            (400..<500).contains(httpResponse.statusCode)
        {
            let oauthError =
                (try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data))?.error
            throw OAuthAuthorizationError.tokenRequestFailed(
                statusCode: httpResponse.statusCode,
                oauthError: oauthError
            )
        }
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let oauthError =
                (try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data))?.error
            throw OAuthAuthorizationError.tokenRequestFailed(
                statusCode: statusCode,
                oauthError: oauthError
            )
        }

        let registration = try JSONDecoder().decode(OAuthClientRegistrationResponse.self, from: data)

        let updatedAuth = OAuthClientRegistrar.updatedAuthentication(
            from: registration, current: configuration.authentication)
        return (response: registration, updatedAuthentication: updatedAuth)
    }

    /// Derives the updated token endpoint authentication from a registration response.
    ///
    /// Updates the client ID (and secret, if issued) while preserving the authentication method.
    static func updatedAuthentication(
        from registration: OAuthClientRegistrationResponse,
        current: OAuthConfiguration.TokenEndpointAuthentication
    ) -> OAuthConfiguration.TokenEndpointAuthentication {
        switch current {
        case .none:
            return .none(clientID: registration.clientID)
        case .clientSecretBasic(_, let currentSecret):
            return .clientSecretBasic(
                clientID: registration.clientID,
                clientSecret: registration.clientSecret ?? currentSecret
            )
        case .clientSecretPost(_, let currentSecret):
            return .clientSecretPost(
                clientID: registration.clientID,
                clientSecret: registration.clientSecret ?? currentSecret
            )
        case .privateKeyJWT(_, let factory):
            return .privateKeyJWT(clientID: registration.clientID, assertionFactory: factory)
        }
    }

    // MARK: - CIMD Helpers

    private func isHTTPSURLWithPath(_ value: String) -> Bool {
        guard let url = URL(string: value),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return false
        }
        return components.scheme?.lowercased() == OAuthURLScheme.https
            && !components.path.isEmpty
            && components.path != "/"
    }

    private func clientIDLooksLikeURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
            let scheme = url.scheme,
            !scheme.isEmpty
        else {
            return false
        }
        return true
    }
}

extension OAuthClientRegistrar: OAuthClientRegistering {}
