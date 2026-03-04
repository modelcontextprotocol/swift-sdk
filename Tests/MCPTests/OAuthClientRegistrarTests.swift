@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    @Suite("OAuthClientRegistrar", .serialized)
    struct OAuthClientRegistrarTests {

        let registrar = OAuthClientRegistrar(urlValidator: OAuthURLValidator())
        let registrationEndpoint = URL(string: "https://auth.example.com/register")!

        func makeASMetadata(registrationEndpoint: URL? = nil) -> OAuthAuthorizationServerMetadata {
            OAuthAuthorizationServerMetadata(
                issuer: URL(string: "https://auth.example.com"),
                authorizationEndpoint: URL(string: "https://auth.example.com/authorize"),
                tokenEndpoint: URL(string: "https://auth.example.com/token"),
                registrationEndpoint: registrationEndpoint,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        }

        func makeConfig(
            authentication: OAuthConfiguration.TokenEndpointAuthentication = .none(clientID: "")
        ) -> OAuthConfiguration {
            OAuthConfiguration(authentication: authentication)
        }

        func successRegistrationBody(clientID: String = "registered-client") throws -> Data {
            let dict: [String: Any] = ["client_id": clientID]
            return try JSONSerialization.data(withJSONObject: dict)
        }

        // MARK: - Skip Conditions

        @Test("Returns nil when authentication is not .none")
        func testRegisterReturnsNilForNonNoneAuth() async throws {
            let config = makeConfig(
                authentication: .clientSecretBasic(clientID: "id", clientSecret: "secret"))
            let (session, _) = makeIsolatedSession()
            let result = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(),
                session: session
            )
            #expect(result == nil)
        }

        @Test("Returns nil when no registration endpoint and no CIMD")
        func testRegisterReturnsNilWithoutRegistrationEndpoint() async throws {
            let config = makeConfig(authentication: .none(clientID: "plain-client-id"))
            let (session, _) = makeIsolatedSession()
            let result = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(registrationEndpoint: nil),
                session: session
            )
            #expect(result == nil)
        }

        // MARK: - CIMD Errors

        @Test("Throws when clientID is HTTPS URL with path but server does not support CIMD")
        func testRegisterThrowsCIMDNotSupported() async throws {
            let config = makeConfig(
                authentication: .none(clientID: "https://client.example.com/metadata.json"))
            let asMetadata = OAuthAuthorizationServerMetadata(
                issuer: nil, authorizationEndpoint: nil, tokenEndpoint: nil,
                registrationEndpoint: nil, codeChallengeMethodsSupported: nil,
                tokenEndpointAuthMethodsSupported: nil, clientIDMetadataDocumentSupported: false
            )
            let (session, _) = makeIsolatedSession()

            await #expect(throws: OAuthAuthorizationError.self) {
                try await registrar.register(
                    configuration: config,
                    asMetadata: asMetadata,
                    session: session
                )
            }
        }

        // MARK: - Successful Registration

        @Test("Returns registration response and updated authentication on success")
        func testRegisterSucceeds() async throws {
            let body = try successRegistrationBody(clientID: "registered-client")
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.registrationEndpoint, statusCode: 201,
                    httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            let config = makeConfig(authentication: .none(clientID: ""))
            let result = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(registrationEndpoint: registrationEndpoint),
                session: session
            )

            let resultValue = try #require(result)
            let expected = OAuthConfiguration.TokenEndpointAuthentication.none(clientID: "registered-client")
            #expect(resultValue.updatedAuthentication == expected)
        }

        @Test("Throws on 4xx registration response")
        func testRegisterThrowsOn4xx() async throws {
            let errorBody = try JSONSerialization.data(
                withJSONObject: ["error": "invalid_client_metadata"])
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.registrationEndpoint, statusCode: 400,
                    httpVersion: nil, headerFields: nil)!
                return (response, errorBody)
            }

            let config = makeConfig(authentication: .none(clientID: ""))
            await #expect(throws: OAuthAuthorizationError.self) {
                try await registrar.register(
                    configuration: config,
                    asMetadata: makeASMetadata(registrationEndpoint: registrationEndpoint),
                    session: session
                )
            }
        }

        @Test("Returns nil on non-2xx non-4xx response")
        func testRegisterReturnsNilOn5xx() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.registrationEndpoint, statusCode: 503,
                    httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            let config = makeConfig(authentication: .none(clientID: ""))
            let result = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(registrationEndpoint: registrationEndpoint),
                session: session
            )
            #expect(result == nil)
        }

        // MARK: - updatedAuthentication helper

        @Test("updatedAuthentication updates client ID and secret for basic auth")
        func testUpdatedAuthenticationBasic() {
            let registration = OAuthClientRegistrationResponse(
                clientID: "new-id", clientSecret: "new-secret",
                tokenEndpointAuthMethod: nil, clientSecretExpiresAt: nil
            )
            let result = OAuthClientRegistrar.updatedAuthentication(
                from: registration,
                current: .clientSecretBasic(clientID: "old-id", clientSecret: "old-secret")
            )
            let expected = OAuthConfiguration.TokenEndpointAuthentication.clientSecretBasic(clientID: "new-id", clientSecret: "new-secret")
            #expect(result == expected)
        }

        @Test("updatedAuthentication falls back to existing secret when not returned")
        func testUpdatedAuthenticationFallsBackToCurrentSecret() {
            let registration = OAuthClientRegistrationResponse(
                clientID: "new-id", clientSecret: nil,
                tokenEndpointAuthMethod: nil, clientSecretExpiresAt: nil
            )
            let result = OAuthClientRegistrar.updatedAuthentication(
                from: registration,
                current: .clientSecretBasic(clientID: "old-id", clientSecret: "kept-secret")
            )
            let expected = OAuthConfiguration.TokenEndpointAuthentication.clientSecretBasic(clientID: "new-id", clientSecret: "kept-secret")
            #expect(result == expected)
        }
    }

#endif
