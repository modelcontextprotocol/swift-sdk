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

    func fetchProtectedResourceMetadata(candidates: [URL], session: URLSession) async throws -> OAuthProtectedResourceMetadata {
        fetchProtectedResourceMetadataCallCount += 1
        return protectedResourceMetadataResult
    }

    func fetchAuthorizationServerMetadata(candidates: [URL], session: URLSession) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        fetchAuthorizationServerMetadataCallCount += 1
        return authorizationServerMetadataResult
    }
}

final class MockTokenClient: OAuthTokenRequesting, @unchecked Sendable {
    var requestCallCount = 0
    var capturedParameters: [String: String]?
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
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        requestCallCount += 1
        capturedParameters = parameters
        return tokenResponse
    }
}

final class MockClientRegistrar: OAuthClientRegistering, @unchecked Sendable {
    var registerCallCount = 0

    func register(
        configuration: OAuthConfiguration,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )? {
        registerCallCount += 1
        return nil
    }
}

final class MockAuthCodeFlow: OAuthAuthorizationCodeFlowing, @unchecked Sendable {
    var buildURLCallCount = 0
    var performCallCount = 0
    var authorizationCode = "mock-auth-code"

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
        delegate: (any OAuthAuthorizationDelegate)?,
        session: URLSession
    ) async throws -> String {
        performCallCount += 1
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

    #if canImport(CryptoKit)
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
    #endif

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
}
