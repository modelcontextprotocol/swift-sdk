@preconcurrency import Foundation
import Testing

@testable import MCP

#if swift(>=6.1) && !os(Linux)

    @Suite("OAuth refresh token omission", .serialized)
    struct OAuthRefreshTokenOmissionTests {
        let endpoint = URL(string: "https://mcp.example.com/mcp")!
        let resourceMetadata = URL(
            string: "https://mcp.example.com/.well-known/oauth-protected-resource")!
        let issuer = URL(string: "https://auth.example.com")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        func makeAuthorizer(
            storage: InMemoryTokenStorage,
            grantType: OAuthConfiguration.GrantType = .authorizationCode
        ) -> OAuthAuthorizer {
            OAuthAuthorizer(
                configuration: OAuthConfiguration(
                    grantType: grantType,
                    authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret")
                ),
                tokenStorage: storage
            )
        }

        actor TokenRequests {
            var bodies: [String] = []
            func append(_ body: String) { bodies.append(body) }
        }

        func installHandler(
            key: String,
            refreshToken: String?,
            expiresIn: Int = 3600,
            rejectRefresh: Bool = false
        ) async -> TokenRequests {
            let requests = TokenRequests()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                if request.url == resourceMetadata {
                    return try await MockResponses.resourceMetadata(
                        authorizationServers: [issuer.absoluteString],
                        resource: endpoint.absoluteString
                    )(request)
                }
                if request.url?.host == issuer.host && request.url != tokenEndpoint {
                    return try await MockResponses.asMetadata(
                        issuer: issuer.absoluteString,
                        tokenEndpoint: tokenEndpoint.absoluteString
                    )(request)
                }
                guard request.url == tokenEndpoint else {
                    throw MockResponses.mockError("Unexpected OAuth request")
                }
                let body = String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                await requests.append(body)
                if rejectRefresh && body.contains("grant_type=refresh_token") {
                    return (
                        HTTPURLResponse(
                            url: tokenEndpoint, statusCode: 400,
                            httpVersion: nil, headerFields: nil)!,
                        Data(#"{"error":"invalid_grant"}"#.utf8)
                    )
                }
                return try await MockResponses.tokenSuccess(
                    accessToken: "new-access", expiresIn: expiresIn, refreshToken: refreshToken
                )(request)
            }
            return requests
        }

        func challenge(_ authorizer: OAuthAuthorizer, session: URLSession) async throws {
            let handled = try await authorizer.handleChallenge(
                statusCode: 401,
                headers: [
                    "WWW-Authenticate":
                        "Bearer resource_metadata=\"\(resourceMetadata.absoluteString)\""
                ],
                endpoint: endpoint,
                session: session
            )
            #expect(handled)
        }

        @Test("Refresh response without refresh_token retains the old token for the next refresh")
        func omittedRefreshTokenRetainsOldToken() async throws {
            let storage = InMemoryTokenStorage()
            storage.save(
                OAuthAccessToken(
                    value: "old-access", tokenType: "Bearer", expiresAt: nil,
                    scopes: [], authorizationServer: issuer, refreshToken: "old-refresh"
                ))
            let authorizer = makeAuthorizer(storage: storage, grantType: .clientCredentials)
            let (session, key) = makeIsolatedSession()
            defer { session.invalidateAndCancel() }
            let requests = await installHandler(key: key, refreshToken: nil)

            try await challenge(authorizer, session: session)
            #expect(storage.load()?.value == "new-access")
            #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer new-access")
            #expect(storage.load()?.refreshToken == "old-refresh")

            try await challenge(authorizer, session: session)
            #expect(storage.load()?.refreshToken == "old-refresh")
            let bodies = await requests.bodies
            #expect(bodies.count == 2)
            #expect(bodies.allSatisfy { $0.contains("grant_type=refresh_token") })
            #expect(bodies.allSatisfy { $0.contains("refresh_token=old-refresh") })
        }

        @Test("Refresh response with a replacement refresh_token rotates the stored token")
        func replacementRefreshTokenReplacesOldToken() async throws {
            let storage = InMemoryTokenStorage()
            storage.save(
                OAuthAccessToken(
                    value: "old-access", tokenType: "Bearer", expiresAt: nil,
                    scopes: [], authorizationServer: issuer, refreshToken: "old-refresh"
                ))
            let authorizer = makeAuthorizer(storage: storage)
            let (session, key) = makeIsolatedSession()
            defer { session.invalidateAndCancel() }
            let requests = await installHandler(key: key, refreshToken: "new-refresh")

            try await challenge(authorizer, session: session)
            #expect(storage.load()?.value == "new-access")
            #expect(storage.load()?.refreshToken == "new-refresh")
            #expect(await requests.bodies.first?.contains("refresh_token=old-refresh") == true)
        }

        @Test("Initial token response without refresh_token keeps refresh token absent")
        func initialTokenWithoutRefreshTokenRemainsNil() async throws {
            let storage = InMemoryTokenStorage()
            let authorizer = makeAuthorizer(storage: storage, grantType: .clientCredentials)
            let (session, key) = makeIsolatedSession()
            defer { session.invalidateAndCancel() }
            let requests = await installHandler(key: key, refreshToken: nil)

            try await challenge(authorizer, session: session)
            #expect(storage.load()?.value == "new-access")
            #expect(storage.load()?.refreshToken == nil)
            #expect(await requests.bodies.first?.contains("grant_type=client_credentials") == true)
        }

        @Test("Proactive refresh preserves an omitted replacement refresh token")
        func proactiveRefreshPreservesOldToken() async throws {
            let storage = InMemoryTokenStorage()
            storage.save(
                OAuthAccessToken(
                    value: "old-access", tokenType: "Bearer", expiresAt: nil,
                    scopes: [], authorizationServer: issuer, refreshToken: "old-refresh"
                ))
            let authorizer = makeAuthorizer(storage: storage)
            let (session, key) = makeIsolatedSession()
            defer { session.invalidateAndCancel() }
            let requests = await installHandler(key: key, refreshToken: nil, expiresIn: 0)

            try await challenge(authorizer, session: session)
            try await authorizer.prepareAuthorization(for: endpoint, session: session)

            #expect(storage.load()?.refreshToken == "old-refresh")
            let bodies = await requests.bodies
            #expect(bodies.count == 2)
            #expect(bodies.allSatisfy { $0.contains("grant_type=refresh_token") })
            #expect(bodies.allSatisfy { $0.contains("refresh_token=old-refresh") })
        }

        @Test("A rejected refresh token is not restored after full token acquisition")
        func rejectedRefreshTokenIsNotRestored() async throws {
            let storage = InMemoryTokenStorage()
            storage.save(
                OAuthAccessToken(
                    value: "old-access", tokenType: "Bearer", expiresAt: nil,
                    scopes: [], authorizationServer: issuer, refreshToken: "old-refresh"
                ))
            let authorizer = makeAuthorizer(storage: storage, grantType: .clientCredentials)
            let (session, key) = makeIsolatedSession()
            defer { session.invalidateAndCancel() }
            let requests = await installHandler(key: key, refreshToken: nil, rejectRefresh: true)

            try await challenge(authorizer, session: session)

            #expect(storage.load()?.value == "new-access")
            #expect(storage.load()?.refreshToken == nil)
            let bodies = await requests.bodies
            #expect(bodies.count == 2)
            #expect(bodies.first?.contains("grant_type=refresh_token") == true)
            #expect(bodies.last?.contains("grant_type=client_credentials") == true)
        }
    }

#endif
