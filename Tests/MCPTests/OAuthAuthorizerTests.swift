@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Mock Implementations

final class MockURLValidator: OAuthURLValidating, @unchecked Sendable {
    var validateHTTPSOrLoopbackCallCount = 0
    var validateAuthorizationServerCallCount = 0
    var validateRedirectURICallCount = 0
    var shouldThrow: Error?

    func validateHTTPSOrLoopback(_ url: URL, context: String) throws {
        validateHTTPSOrLoopbackCallCount += 1
        if let error = shouldThrow { throw error }
    }

    func validateAuthorizationServer(_ url: URL, context: String) throws {
        validateAuthorizationServerCallCount += 1
        if let error = shouldThrow { throw error }
    }

    func validateRedirectURI(_ url: URL) throws {
        validateRedirectURICallCount += 1
        if let error = shouldThrow { throw error }
    }

    func isPrivateIPHost(_ host: String) -> Bool { false }
}

final class MockDiscoveryClient: OAuthDiscoveryFetching, @unchecked Sendable {
    var fetchProtectedResourceMetadataCallCount = 0
    var fetchAuthorizationServerMetadataCallCount = 0
    let metadataDiscovery: any OAuthMetadataDiscovering = DefaultOAuthMetadataDiscovery()

    var protectedResourceMetadataResult: OAuthProtectedResourceMetadata
    var authorizationServerMetadataResult: (server: URL, metadata: OAuthAuthorizationServerMetadata)

    init(
        authorizationServer: URL = URL(string: "https://auth.example.com")!,
        tokenEndpoint: URL = URL(string: "https://auth.example.com/token")!
    ) {
        self.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil,
            authorizationServers: [authorizationServer],
            scopesSupported: nil
        )
        self.authorizationServerMetadataResult = (
            server: authorizationServer,
            metadata: OAuthAuthorizationServerMetadata(
                issuer: authorizationServer,
                authorizationEndpoint: URL(string: "https://auth.example.com/authorize"),
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        )
    }

    /// The `reportRefused` of the last authorization server metadata fetch.
    var lastReportRefused: Bool?
    /// While set, every candidate is refused with it before a request, as
    /// ``OAuthDiscoveryClient`` does: it is thrown with `reportRefused`, and
    /// `authorizationServerMetadataDiscoveryFailed` without.
    var candidateRefusal: Error?

    /// Thrown by the next protected resource metadata fetch, then cleared.
    var protectedResourceMetadataError: Error?
    /// The `trustedIssuer` of the last authorization server metadata fetch.
    var lastTrustedIssuer: URL?
    /// Thrown by authorization server metadata fetches while set.
    var authorizationServerMetadataError: Error?
    /// The `candidates` of the last protected resource metadata fetch.
    var lastProtectedResourceMetadataCandidates: [URL] = []

    func fetchProtectedResourceMetadata(candidates: [URL], fallbackIssuer: URL?, session: URLSession) async throws -> OAuthProtectedResourceMetadata {
        fetchProtectedResourceMetadataCallCount += 1
        lastProtectedResourceMetadataCandidates = candidates
        if let error = protectedResourceMetadataError {
            protectedResourceMetadataError = nil
            throw error
        }
        return protectedResourceMetadataResult
    }

    func fetchAuthorizationServerMetadata(
        candidates: [URL], trustedIssuer: URL?, reportRefused: Bool, session: URLSession
    ) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        fetchAuthorizationServerMetadataCallCount += 1
        lastTrustedIssuer = trustedIssuer
        lastReportRefused = reportRefused
        if let error = authorizationServerMetadataError { throw error }
        if let refusal = candidateRefusal {
            throw reportRefused ? refusal : OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
        }
        return authorizationServerMetadataResult
    }
}

final class MockTokenClient: OAuthTokenRequesting, @unchecked Sendable {
    var requestCallCount = 0
    var capturedParameters: [String: String]?
    var capturedEndpoint: URL?
    var capturedDPoP: DPoPProofSigner?
    var tokenResponse = OAuthTokenResponse(
        accessToken: "mock-access-token",
        tokenType: "Bearer",
        expiresIn: 3600,
        scope: nil,
        refreshToken: nil
    )

    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        dpop: DPoPProofSigner?,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        requestCallCount += 1
        capturedDPoP = dpop
        capturedParameters = parameters
        capturedEndpoint = endpoint
        return tokenResponse
    }
}

final class MockClientRegistrar: OAuthClientRegistering, @unchecked Sendable {
    var registerCallCount = 0
    /// The authentication each registration started from.
    var registeredFrom: [OAuthConfiguration.TokenEndpointAuthentication] = []
    var registrationResult: (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )?

    func register(
        configuration: OAuthConfiguration,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )? {
        registerCallCount += 1
        registeredFrom.append(configuration.authentication)
        return registrationResult
    }
}

final class MockAuthCodeFlow: OAuthAuthorizationCodeFlowing, @unchecked Sendable {
    var buildURLCallCount = 0
    var performCallCount = 0
    var authorizationCode = "mock-auth-code"
    var lastIssuer: OAuthAuthorizationCodeFlow.ExpectedIssuer?

    func buildURL(
        authorizationEndpoint: URL,
        resource: URL,
        redirectURI: URL,
        clientID: String,
        codeChallenge: String,
        scopes: Set<String>?,
        state: String,
        scopeSerializer: any OAuthScopeSelecting
    ) throws -> URL {
        buildURLCallCount += 1
        return URL(string: "https://auth.example.com/authorize?code=stub")!
    }

    func perform(
        authorizationURL: URL,
        redirectURI: URL,
        state: String,
        issuer: OAuthAuthorizationCodeFlow.ExpectedIssuer?,
        delegate: (any OAuthAuthorizationDelegate)?,
        session: URLSession
    ) async throws -> String {
        performCallCount += 1
        lastIssuer = issuer
        return authorizationCode
    }
}

// MARK: - OAuthAuthorizer Invocation Tests

@Suite("OAuthAuthorizer dependency invocations")
struct OAuthAuthorizerTests {

    let endpoint = URL(string: "https://mcp.example.com/mcp")!
    let headers401 = [
        "WWW-Authenticate":
            "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
    ]

    func makeAuthorizer(
        grantType: OAuthConfiguration.GrantType = .clientCredentials,
        urlValidator: MockURLValidator = MockURLValidator(),
        discoveryClient: MockDiscoveryClient = MockDiscoveryClient(),
        tokenClient: MockTokenClient = MockTokenClient(),
        registrar: MockClientRegistrar = MockClientRegistrar(),
        authCodeFlow: MockAuthCodeFlow = MockAuthCodeFlow()
    ) -> OAuthAuthorizer {
        let config = OAuthConfiguration(
            grantType: grantType,
            authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret")
        )
        return OAuthAuthorizer(
            configuration: config,
            urlValidator: urlValidator,
            discoveryClient: discoveryClient,
            tokenEndpointClient: tokenClient,
            clientRegistrar: registrar,
            authCodeFlow: authCodeFlow
        )
    }

    // MARK: - validateEndpointSecurity

    @Test("validateEndpointSecurity calls urlValidator")
    func testValidateEndpointSecurityCallsURLValidator() throws {
        let validator = MockURLValidator()
        let authorizer = makeAuthorizer(urlValidator: validator)

        try authorizer.validateEndpointSecurity(for: endpoint)

        #expect(validator.validateHTTPSOrLoopbackCallCount == 1)
    }

    @Test("validateEndpointSecurity propagates validation error")
    func testValidateEndpointSecurityPropagatesError() {
        let validator = MockURLValidator()
        validator.shouldThrow = OAuthAuthorizationError.insecureOAuthEndpoint(
            context: "test", url: "http://example.com")
        let authorizer = makeAuthorizer(urlValidator: validator)

        #expect(throws: OAuthAuthorizationError.self) {
            try authorizer.validateEndpointSecurity(for: endpoint)
        }
    }

    // MARK: - handleChallenge (401 — client_credentials)

    @Test("handleChallenge 401 calls discovery and token clients")
    func testHandleChallenge401CallsDiscoveryAndTokenClient() async throws {
        let discovery = MockDiscoveryClient()
        let tokenClient = MockTokenClient()

        let authorizer = makeAuthorizer(
            discoveryClient: discovery,
            tokenClient: tokenClient
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(discovery.fetchProtectedResourceMetadataCallCount >= 1)
        #expect(discovery.fetchAuthorizationServerMetadataCallCount >= 1)
        #expect(tokenClient.requestCallCount == 1)
    }

    @Test("handleChallenge 401 uses client_credentials grant type parameter")
    func testHandleChallenge401ClientCredentialsGrantType() async throws {
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(tokenClient: tokenClient)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(tokenClient.capturedParameters?["grant_type"] == "client_credentials")
    }

    @Test("handleChallenge 401 attaches resource parameter")
    func testHandleChallenge401AttachesResourceParameter() async throws {
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(tokenClient: tokenClient)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(tokenClient.capturedParameters?["resource"] != nil)
    }

    // MARK: - handleChallenge (authorization_code)

    @Test("handleChallenge 401 calls authCodeFlow for authorization_code grant")
    func testHandleChallenge401AuthorizationCodeCallsFlow() async throws {
        let authCodeFlow = MockAuthCodeFlow()
        let tokenClient = MockTokenClient()

        let config = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: "my-client"),
            authorizationRedirectURI: URL(string: "https://app.example.com/callback")!
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: authCodeFlow
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(authCodeFlow.buildURLCallCount == 1)
        #expect(authCodeFlow.performCallCount == 1)
        #expect(tokenClient.capturedParameters?["grant_type"] == "authorization_code")
        #expect(tokenClient.capturedParameters?["code"] == "mock-auth-code")
    }

    // MARK: - handleChallenge (403)

    @Test("handleChallenge 403 returns false for non-insufficient_scope error")
    func testHandleChallenge403NonInsufficientScope() async throws {
        let authorizer = makeAuthorizer()

        let handled = try await authorizer.handleChallenge(
            statusCode: 403,
            headers: ["WWW-Authenticate": "Bearer error=\"access_denied\""],
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == false)
    }

    @Test("handleChallenge 403 insufficient_scope acquires token with upgraded scopes")
    func testHandleChallenge403InsufficientScope() async throws {
        let tokenClient = MockTokenClient()
        let discovery = MockDiscoveryClient()

        let authorizer = makeAuthorizer(
            discoveryClient: discovery,
            tokenClient: tokenClient
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 403,
            headers: [
                "WWW-Authenticate":
                    "Bearer error=\"insufficient_scope\", scope=\"admin\""
            ],
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(tokenClient.requestCallCount == 1)
    }

    // MARK: - Client registration

    @Test("handleChallenge calls client registrar when authentication is .none")
    func testHandleChallengeCallsRegistrar() async throws {
        let registrar = MockClientRegistrar()
        let config = OAuthConfiguration(
            authentication: .none(clientID: "plain-client"))
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 1)
    }

    @Test("handleChallenge skips client registrar when credentials are already configured")
    func testHandleChallengeSkipsRegistrarWithCredentials() async throws {
        let registrar = MockClientRegistrar()
        let authorizer = makeAuthorizer(registrar: registrar)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 0)
    }

    @Test("handleChallenge persists the DCR-assigned clientID on the saved token")
    func testHandleChallengePersistsDCRClientIDOnToken() async throws {
        let assignedClientID = "dcr-assigned-client-id"
        let tokenStorage = InMemoryTokenStorage()
        let registrar = MockClientRegistrar()
        registrar.registrationResult = (
            response: OAuthClientRegistrationResponse(
                clientID: assignedClientID,
                clientSecret: nil,
                tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil
            ),
            updatedAuthentication: .none(clientID: assignedClientID)
        )

        let config = OAuthConfiguration(
            authentication: .none(clientID: "")
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            tokenStorage: tokenStorage,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(registrar.registerCallCount == 1)
        #expect(tokenStorage.load()?.clientID == assignedClientID)
    }

    // MARK: - Refused authorization servers

    @Test("A 2025-03-26 server whose origin is refused falls back to its default endpoints")
    func testRefusedFallbackOriginUsesDefaultEndpoints() async throws {
        let origin = URL(string: "https://mcp.example.com")!
        let discovery = MockDiscoveryClient()
        discovery.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil, authorizationServers: [origin], scopesSupported: nil, isFallback: true)
        discovery.candidateRefusal = OAuthAuthorizationError.privateIPAddressBlocked(
            context: "Authorization server issuer", url: origin.absoluteString)
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(discoveryClient: discovery, tokenClient: tokenClient)

        let handled = try await authorizer.handleChallenge(
            statusCode: 401, headers: ["WWW-Authenticate": "Bearer"], endpoint: endpoint, operationKey: nil,
            session: .shared)

        #expect(handled)
        #expect(discovery.lastReportRefused == false)
        #expect(tokenClient.capturedEndpoint == origin.appendingPathComponent("token"))
    }

    @Test("Refused authorization servers named by the resource fail with the refusal")
    func testRefusedListedServerFails() async throws {
        let refusal = OAuthAuthorizationError.privateIPAddressBlocked(
            context: "Authorization server issuer", url: "https://10.0.0.1")
        let discovery = MockDiscoveryClient()
        discovery.candidateRefusal = refusal
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(discoveryClient: discovery, tokenClient: tokenClient)

        await #expect {
            try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, operationKey: nil, session: .shared)
        } throws: { error in
            (error as? OAuthAuthorizationError)?.errorDescription == refusal.errorDescription
        }
        #expect(discovery.lastReportRefused == true)
        #expect(tokenClient.requestCallCount == 0)
    }

    // MARK: - Private addresses

    /// An authorizer with the SDK's URL validator.
    func makeValidatingAuthorizer(
        grantType: OAuthConfiguration.GrantType = .clientCredentials,
        discoveryClient: MockDiscoveryClient,
        tokenClient: MockTokenClient = MockTokenClient(),
        authCodeFlow: MockAuthCodeFlow = MockAuthCodeFlow()
    ) -> OAuthAuthorizer {
        OAuthAuthorizer(
            configuration: OAuthConfiguration(
                grantType: grantType,
                authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
                authorizationRedirectURI: URL(string: "https://app.example.com/callback")!
            ),
            urlValidator: OAuthURLValidator(),
            discoveryClient: discoveryClient,
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: authCodeFlow
        )
    }

    func isPrivateIPBlocked(_ error: any Error, _ context: String, _ url: String) -> Bool {
        (error as? OAuthAuthorizationError)?.errorDescription
            == OAuthAuthorizationError.privateIPAddressBlocked(context: context, url: url).errorDescription
    }

    @Test("A challenge's resource_metadata URL on a private address is refused before discovery")
    func testPrivateResourceMetadataURLIsRefused() async throws {
        let discovery = MockDiscoveryClient()
        let authorizer = makeValidatingAuthorizer(discoveryClient: discovery)
        let metadataURL = "https://10.0.0.1/.well-known/oauth-protected-resource"

        await #expect {
            try await authorizer.handleChallenge(
                statusCode: 401, headers: ["WWW-Authenticate": "Bearer resource_metadata=\"\(metadataURL)\""],
                endpoint: endpoint, operationKey: nil, session: .shared)
        } throws: { isPrivateIPBlocked($0, "Protected resource metadata URL", metadataURL) }
        #expect(discovery.fetchProtectedResourceMetadataCallCount == 0)
    }

    @Test("A token endpoint on a private address is refused before the token request")
    func testPrivateTokenEndpointIsRefused() async throws {
        let tokenEndpoint = "https://[fd00::1]/token"
        let discovery = MockDiscoveryClient(tokenEndpoint: URL(string: tokenEndpoint)!)
        let tokenClient = MockTokenClient()
        let authorizer = makeValidatingAuthorizer(discoveryClient: discovery, tokenClient: tokenClient)

        await #expect {
            try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, operationKey: nil, session: .shared)
        } throws: { isPrivateIPBlocked($0, "Token endpoint", tokenEndpoint) }
        #expect(tokenClient.requestCallCount == 0)
    }

    @Test("An authorization endpoint on a private address is refused before the user is sent there")
    func testPrivateAuthorizationEndpointIsRefused() async throws {
        let authorizationEndpoint = "https://192.168.1.10/authorize"
        let discovery = MockDiscoveryClient()
        let server = discovery.authorizationServerMetadataResult
        discovery.authorizationServerMetadataResult = (
            server: server.server,
            metadata: OAuthAuthorizationServerMetadata(
                issuer: server.server,
                authorizationEndpoint: URL(string: authorizationEndpoint)!,
                tokenEndpoint: server.metadata.tokenEndpoint,
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        )
        let authCodeFlow = MockAuthCodeFlow()
        let authorizer = makeValidatingAuthorizer(
            grantType: .authorizationCode, discoveryClient: discovery, authCodeFlow: authCodeFlow)

        await #expect {
            try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, operationKey: nil, session: .shared)
        } throws: { isPrivateIPBlocked($0, "Authorization endpoint", authorizationEndpoint) }
        #expect(authCodeFlow.buildURLCallCount == 0)
        #expect(authCodeFlow.performCallCount == 0)
    }
}
