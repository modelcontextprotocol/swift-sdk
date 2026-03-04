@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    @Suite("OAuthDiscoveryClient", .serialized)
    struct OAuthDiscoveryClientTests {

        let urlValidator = OAuthURLValidator(allowLoopbackHTTPForAuthorizationServer: true)
        let metadataDiscovery = DefaultOAuthMetadataDiscovery()

        func makeClient() -> OAuthDiscoveryClient {
            OAuthDiscoveryClient(metadataDiscovery: metadataDiscovery, urlValidator: urlValidator)
        }

        func makeProtectedResourceBody(authorizationServers: [String]) throws -> Data {
            let dict: [String: Any] = ["authorization_servers": authorizationServers]
            return try JSONSerialization.data(withJSONObject: dict)
        }

        func makeASMetadataBody(issuer: String) throws -> Data {
            let dict: [String: Any] = [
                "issuer": issuer,
                "token_endpoint": "https://auth.example.com/token",
                "code_challenge_methods_supported": ["S256"],
            ]
            return try JSONSerialization.data(withJSONObject: dict)
        }

        // MARK: - fetchProtectedResourceMetadata

        @Test("Returns metadata from first successful candidate")
        func testFetchProtectedResourceMetadataSuccess() async throws {
            let body = try makeProtectedResourceBody(
                authorizationServers: ["https://auth.example.com"])
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://example.com/.well-known/oauth-protected-resource")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            let metadata = try await makeClient().fetchProtectedResourceMetadata(
                candidates: [URL(string: "https://example.com/.well-known/oauth-protected-resource")!],
                session: session
            )
            let expected = OAuthProtectedResourceMetadata(
                resource: nil,
                authorizationServers: [URL(string: "https://auth.example.com")!],
                scopesSupported: nil)
            #expect(metadata == expected)
        }

        @Test("Skips candidates that return non-2xx status")
        func testFetchProtectedResourceMetadataSkipsNon2xx() async throws {
            let body = try makeProtectedResourceBody(
                authorizationServers: ["https://auth.example.com"])
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let statusCode = request.url?.lastPathComponent == "mcp" ? 404 : 200
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: statusCode,
                    httpVersion: nil, headerFields: nil)!
                return (response, statusCode == 200 ? body : Data())
            }

            let metadata = try await makeClient().fetchProtectedResourceMetadata(
                candidates: [
                    URL(string: "https://example.com/.well-known/oauth-protected-resource/mcp")!,
                    URL(string: "https://example.com/.well-known/oauth-protected-resource")!,
                ],
                session: session
            )
            let expected = OAuthProtectedResourceMetadata(
                resource: nil,
                authorizationServers: [URL(string: "https://auth.example.com")!],
                scopesSupported: nil)
            #expect(metadata == expected)
        }

        @Test("Skips candidates with empty authorizationServers array")
        func testFetchProtectedResourceMetadataSkipsEmptyAuthServers() async throws {
            let emptyBody = try makeProtectedResourceBody(authorizationServers: [])
            let validBody = try makeProtectedResourceBody(
                authorizationServers: ["https://auth.example.com"])
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let body = request.url?.lastPathComponent == "mcp" ? emptyBody : validBody
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            let metadata = try await makeClient().fetchProtectedResourceMetadata(
                candidates: [
                    URL(string: "https://example.com/.well-known/oauth-protected-resource/mcp")!,
                    URL(string: "https://example.com/.well-known/oauth-protected-resource")!,
                ],
                session: session
            )
            let expected = OAuthProtectedResourceMetadata(
                resource: nil,
                authorizationServers: [URL(string: "https://auth.example.com")!],
                scopesSupported: nil)
            #expect(metadata == expected)
        }

        @Test("Throws metadataDiscoveryFailed when all candidates fail")
        func testFetchProtectedResourceMetadataThrowsWhenAllFail() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            await #expect(throws: OAuthAuthorizationError.self) {
                try await makeClient().fetchProtectedResourceMetadata(
                    candidates: [
                        URL(string: "https://example.com/.well-known/oauth-protected-resource")!
                    ],
                    session: session
                )
            }
        }

        // MARK: - fetchAuthorizationServerMetadata

        @Test("Returns server and metadata when issuer matches")
        func testFetchAuthorizationServerMetadataSuccess() async throws {
            let issuer = "https://auth.example.com"
            let body = try makeASMetadataBody(issuer: issuer)
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "\(issuer)/.well-known/oauth-authorization-server")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            let (server, metadata) = try await makeClient().fetchAuthorizationServerMetadata(
                candidates: [URL(string: issuer)!],
                session: session
            )
            let expectedServer = URL(string: issuer)!
            let expectedMetadata = OAuthAuthorizationServerMetadata(
                issuer: URL(string: issuer),
                authorizationEndpoint: nil,
                tokenEndpoint: URL(string: "https://auth.example.com/token"),
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil)
            #expect(server == expectedServer)
            #expect(metadata == expectedMetadata)
        }

        @Test("Skips candidate when issuer field does not match")
        func testFetchAuthorizationServerMetadataSkipsIssuerMismatch() async throws {
            let wrongIssuerBody = try makeASMetadataBody(issuer: "https://other.example.com")
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://auth.example.com")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, wrongIssuerBody)
            }

            await #expect(throws: OAuthAuthorizationError.self) {
                try await makeClient().fetchAuthorizationServerMetadata(
                    candidates: [URL(string: "https://auth.example.com")!],
                    session: session
                )
            }
        }

        @Test("Skips private IP candidates without making HTTP calls")
        func testFetchAuthorizationServerMetadataSkipsPrivateIP() async throws {
            let (session, _) = makeIsolatedSession()
            await #expect(throws: OAuthAuthorizationError.self) {
                try await makeClient().fetchAuthorizationServerMetadata(
                    candidates: [URL(string: "https://10.0.0.1")!],
                    session: session
                )
            }
        }

        @Test("Throws when all candidates return non-2xx")
        func testFetchAuthorizationServerMetadataThrowsWhenAllFail() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            await #expect(throws: OAuthAuthorizationError.self) {
                try await makeClient().fetchAuthorizationServerMetadata(
                    candidates: [URL(string: "https://auth.example.com")!],
                    session: session
                )
            }
        }
    }

#endif
