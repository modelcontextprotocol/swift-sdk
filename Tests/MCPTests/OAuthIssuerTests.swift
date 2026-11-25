@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("OAuth issuer, application type and authorization server changes")
struct OAuthIssuerTests {
    let flow = OAuthAuthorizationCodeFlow()
    let redirectURI = URL(string: "https://app.example.com/callback")!
    let endpoint = URL(string: "https://mcp.example.com/mcp")!
    let headers401 = [
        "WWW-Authenticate":
            "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
    ]

    private func redirect(iss: String?) -> URL {
        var components = URLComponents(string: "https://app.example.com/callback?code=c&state=s")!
        if let iss { components.queryItems?.append(.init(name: "iss", value: iss)) }
        return components.url!
    }

    private func code(iss: String?, expected: String = "https://as.example", required: Bool) throws -> String {
        try flow.extractCode(
            from: redirect(iss: iss), expectedRedirectURI: redirectURI, expectedState: "s",
            expectedIssuer: .init(issuer: expected, isRequired: required))
    }

    // MARK: - RFC 9207 iss

    @Test("A matching iss is accepted, advertised or not")
    func testMatchingIss() throws {
        #expect(try code(iss: "https://as.example", required: true) == "c")
        #expect(try code(iss: "https://as.example", required: false) == "c")
        #expect(try code(iss: nil, required: false) == "c")
    }

    @Test("A different iss is rejected, without URL normalization")
    func testMismatchedIss() {
        for iss in ["https://evil.example", "https://as.example/", "https://AS.example", "https://as.example:443"] {
            #expect(throws: OAuthAuthorizationError.self) { try code(iss: iss, required: false) }
            #expect(throws: OAuthAuthorizationError.self) { try code(iss: iss, required: true) }
        }
    }

    @Test("A missing iss is rejected when the server advertised it")
    func testMissingIss() {
        do {
            _ = try code(iss: nil, required: true)
            Issue.record("Expected a missing-iss error")
        } catch OAuthAuthorizationError.authorizationResponseMissingIssuer {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("An iss given twice or without a value is rejected, advertised or not")
    func testRepeatedOrEmptyIss() {
        let redirects = [
            "https://app.example.com/callback?code=c&state=s&iss=https://as.example&iss=https://evil.example",
            "https://app.example.com/callback?code=c&state=s&iss=https://evil.example&iss=https://as.example",
            "https://app.example.com/callback?code=c&state=s&iss=https://as.example&iss=https://as.example",
            "https://app.example.com/callback?code=c&state=s&iss",
            "https://app.example.com/callback?code=c&state=s&iss=",
        ]
        for redirect in redirects {
            for required in [false, true] {
                do {
                    _ = try flow.extractCode(
                        from: URL(string: redirect)!, expectedRedirectURI: redirectURI, expectedState: "s",
                        expectedIssuer: .init(issuer: "https://as.example", isRequired: required))
                    Issue.record("Expected an issuer mismatch for \(redirect)")
                } catch OAuthAuthorizationError.authorizationResponseIssuerMismatch {
                } catch {
                    Issue.record("Unexpected error \(error) for \(redirect)")
                }
            }
        }
    }

    @Test("A root issuer with an IPv6 host matches with and without its trailing slash")
    func testIPv6IssuerComparison() {
        #expect(OAuthIssuer.matches("https://[::1]:8443", "https://[::1]:8443/"))
        #expect(OAuthIssuer.matches("https://[2001:db8::1]/", "https://[2001:db8::1]"))
        #expect(!OAuthIssuer.matches("https://[::1]/tenant", "https://[::1]/tenant/"))
        #expect(!OAuthIssuer.matches("https://as.example?x", "https://as.example?x/"))
        #expect(!OAuthIssuer.matches("https://user@as.example", "https://user@as.example/"))
    }

    @Test("The authorizer passes the metadata issuer and its iss support to the flow")
    func testAuthorizerPassesIssuer() async throws {
        let discovery = MockDiscoveryClient()
        let server = discovery.authorizationServerMetadataResult.server
        var metadata = discovery.authorizationServerMetadataResult.metadata
        metadata.authorizationResponseIssParameterSupported = true
        discovery.authorizationServerMetadataResult = (server, metadata)
        let flowMock = MockAuthCodeFlow()
        let authorizer = OAuthAuthorizer(
            configuration: .init(
                grantType: .authorizationCode,
                authentication: .none(clientID: "client"),
                authorizationRedirectURI: URL(string: "http://127.0.0.1:3000/callback")!),
            urlValidator: MockURLValidator(), discoveryClient: discovery,
            tokenEndpointClient: MockTokenClient(), clientRegistrar: MockClientRegistrar(),
            authCodeFlow: flowMock)

        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        #expect(flowMock.lastIssuer == .init(issuer: "https://auth.example.com", isRequired: true))
    }

    // MARK: - SEP-837 application_type

    @Test("application_type is native for loopback and custom schemes, web for https hosts")
    func testApplicationType() {
        func type(_ redirect: String, grant: OAuthConfiguration.GrantType = .authorizationCode)
            -> OAuthConfiguration.ApplicationType
        {
            OAuthConfiguration(
                grantType: grant, authentication: .none(clientID: ""),
                authorizationRedirectURI: URL(string: redirect)!
            ).registrationApplicationType
        }
        #expect(type("http://127.0.0.1:8080/callback") == .native)
        #expect(type("http://localhost/callback") == .native)
        #expect(type("https://localhost/callback") == .native)
        #expect(type("com.example.app:/callback") == .native)
        #expect(type("https://app.example.com/callback") == .web)
        #expect(type("https://app.example.com/callback", grant: .clientCredentials) == .native)
        let explicit = OAuthConfiguration(
            grantType: .authorizationCode, authentication: .none(clientID: ""),
            authorizationRedirectURI: URL(string: "http://127.0.0.1/cb")!, applicationType: .web)
        #expect(explicit.registrationApplicationType == .web)
    }

    // MARK: - SEP-2352 authorization server change

    @Test("When the resource moves to another authorization server, the client registers again")
    func testReregistersOnServerChange() async throws {
        let discovery = MockDiscoveryClient()
        let registrar = MockClientRegistrar()
        registrar.registrationResult = (
            response: .init(
                clientID: "as1-client", clientSecret: "s1", tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil),
            updatedAuthentication: .clientSecretPost(clientID: "as1-client", clientSecret: "s1")
        )
        let authorizer = OAuthAuthorizer(
            configuration: .init(authentication: .none(clientID: "")),
            urlValidator: MockURLValidator(), discoveryClient: discovery,
            tokenEndpointClient: MockTokenClient(), clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow())

        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        #expect(registrar.registerCallCount == 1)
        #expect((try authorizer.authorizationHeaders(for: endpoint, method: "POST"))[HTTPHeaderName.authorization] != nil)

        // The same 401 again, but the metadata now names another server.
        let second = URL(string: "https://auth2.example.com")!
        discovery.protectedResourceMetadataResult = .init(
            resource: nil, authorizationServers: [second], scopesSupported: nil)
        discovery.authorizationServerMetadataResult = (
            second,
            .init(
                issuer: second, authorizationEndpoint: nil,
                tokenEndpoint: URL(string: "https://auth2.example.com/token"),
                registrationEndpoint: URL(string: "https://auth2.example.com/register"),
                codeChallengeMethodsSupported: ["S256"], tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil)
        )
        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)

        #expect(discovery.fetchProtectedResourceMetadataCallCount == 2)
        #expect(registrar.registerCallCount == 2)
        // The second registration starts from the configured credentials, not the first server's.
        #expect(registrar.registeredFrom == [.none(clientID: ""), .none(clientID: "")])
    }

    @Test("Without a server change, a rejected token does not register again")
    func testNoReregistrationWithoutChange() async throws {
        let discovery = MockDiscoveryClient()
        let registrar = MockClientRegistrar()
        registrar.registrationResult = (
            response: .init(
                clientID: "c", clientSecret: nil, tokenEndpointAuthMethod: nil, clientSecretExpiresAt: nil),
            updatedAuthentication: .none(clientID: "c")
        )
        let authorizer = OAuthAuthorizer(
            configuration: .init(authentication: .none(clientID: "")),
            urlValidator: MockURLValidator(), discoveryClient: discovery,
            tokenEndpointClient: MockTokenClient(), clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow())
        for _ in 0..<2 {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        }
        #expect(registrar.registerCallCount == 1)
    }
}
