@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    // MARK: - Scenario Context

    struct OAuthScenarioContext: Sendable {
        let testEndpoint: URL
        let oauthConfiguration: OAuthConfiguration
        let messageData: Data
        let expectedResponseData: Data?
        let expectedCallCounts: [URL: Int]
        let streaming: Bool
        let sseInitializationTimeout: TimeInterval?
        let expectedErrorSubstring: String?
        let unexpectedErrorSubstrings: [String]
        let secondMessageData: Data?
        let secondExpectedResponseData: Data?

        init(
            testEndpoint: URL,
            oauthConfiguration: OAuthConfiguration,
            messageData: Data,
            expectedResponseData: Data? = nil,
            expectedCallCounts: [URL: Int] = [:],
            streaming: Bool = false,
            sseInitializationTimeout: TimeInterval? = nil,
            expectedErrorSubstring: String? = nil,
            unexpectedErrorSubstrings: [String] = [],
            secondMessageData: Data? = nil,
            secondExpectedResponseData: Data? = nil
        ) {
            self.testEndpoint = testEndpoint
            self.oauthConfiguration = oauthConfiguration
            self.messageData = messageData
            self.expectedResponseData = expectedResponseData
            self.expectedCallCounts = expectedCallCounts
            self.streaming = streaming
            self.sseInitializationTimeout = sseInitializationTimeout
            self.expectedErrorSubstring = expectedErrorSubstring
            self.unexpectedErrorSubstrings = unexpectedErrorSubstrings
            self.secondMessageData = secondMessageData
            self.secondExpectedResponseData = secondExpectedResponseData
        }
    }

    // MARK: - Request Body Helper

    func readRequestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            data.append(buffer, count: bytesRead)
        }
        return data
    }

    // MARK: - Trackers

    actor ProviderTracker: Sendable {
        var capturedContext: OAuthConfiguration.AccessTokenProviderContext?
        func capture(_ context: OAuthConfiguration.AccessTokenProviderContext) {
            capturedContext = context
        }
    }

    actor OrderTracker: Sendable {
        var requests: [URL] = []
        func append(_ url: URL) { requests.append(url) }
        func count() -> Int { requests.count }
    }

    /// Dispenses tokens in order; repeats the last token when the list is exhausted.
    actor TokenDispenser: Sendable {
        private var tokens: [String]
        init(_ tokens: String...) { self.tokens = Array(tokens) }
        func next() -> String {
            if tokens.count > 1 { return tokens.removeFirst() }
            return tokens.first ?? "fallback-token"
        }
    }

    // MARK: - Scenario Definitions

    #if !canImport(FoundationNetworking)

        extension RequestHandlerStorage {

            // MARK: 1 - Client Credentials Retry After 401

            func configureOAuthClientCredentialsRetryAfter401() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/test")!
                let resourceMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource/test")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 1)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer access-token-123")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read", "files:write"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        #expect(request.httpMethod == "POST")
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(
                            body.contains("resource=https%3A%2F%2Flocalhost%3A8080%2Ftest"))
                        #expect(body.contains("scope=files%3Aread"))
                        #expect(body.contains("client_id=test-client"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "access-token-123")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":1}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 2 - Scope Fallback to scopes_supported

            func configureOAuthScopeSelectionFallsBackToScopesSupported() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/fallback-scope")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/fallback-scope"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 21)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer access-token-fallback")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:write", "files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(
                            body.contains(
                                "resource=https%3A%2F%2Flocalhost%3A8080%2Ffallback-scope"))
                        #expect(body.contains("scope=files%3Aread%20files%3Awrite"))
                        #expect(body.contains("client_id=test-client"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "access-token-fallback")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":21}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 3 - Scope Omitted When No Hints

            func configureOAuthScopeOmittedWhenNoHints() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/no-scope-hints")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/no-scope-hints"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 22)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer access-token-no-scope")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(
                            body.contains(
                                "resource=https%3A%2F%2Flocalhost%3A8080%2Fno-scope-hints"))
                        #expect(!body.contains("scope="))
                        #expect(body.contains("client_id=test-client"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "access-token-no-scope")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":22}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 4 - Resource Parameter in Authorization Code Flow

            func configureOAuthResourceParameterInAuthorizationAndToken() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp?foo=bar")!
                let canonicalResource = "https://localhost:8080/public/mcp"
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let authorizationEndpointURL = URL(
                    string: "https://localhost:8080/oauth/authorize")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 23)

                requestHandler = {
                    [testEndpoint, canonicalResource, resourceMetadataURL, asMetadataURL, authorizationEndpointURL, tokenEndpointURL, finalResponseData]
                    request in
                    guard let url = request.url else {
                        throw MockResponses.mockError("Missing request URL")
                    }

                    if url.scheme == authorizationEndpointURL.scheme,
                        url.host == authorizationEndpointURL.host,
                        url.port == authorizationEndpointURL.port,
                        url.path == authorizationEndpointURL.path
                    {
                        let queryItems =
                            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                            ?? []
                        #expect(
                            queryItems.contains(where: {
                                $0.name == "resource" && $0.value == canonicalResource
                            }))
                        #expect(
                            queryItems.contains(where: {
                                $0.name == "response_type" && $0.value == "code"
                            }))
                        #expect(
                            queryItems.contains(where: {
                                $0.name == "client_id" && $0.value == "test-client"
                            }))
                        #expect(
                            queryItems.contains(where: {
                                $0.name == "scope" && $0.value == "files:read"
                            }))
                        let state = queryItems.first(where: { $0.name == "state" })?.value
                        let redirectURI =
                            queryItems.first(where: { $0.name == "redirect_uri" })?.value
                        #expect(state != nil)
                        #expect(redirectURI != nil)

                        var redirectComponents = URLComponents(string: redirectURI ?? "")
                        var redirectQueryItems = redirectComponents?.queryItems ?? []
                        redirectQueryItems.append(.init(name: "code", value: "test"))
                        redirectQueryItems.append(.init(name: "state", value: state))
                        redirectComponents?.queryItems = redirectQueryItems
                        let locationValue =
                            redirectComponents?.url?.absoluteString
                            ?? "http://127.0.0.1:3000/callback?code=test&state=\(state ?? "")"
                        let response = HTTPURLResponse(
                            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                            headerFields: ["Location": locationValue])!
                        return (response, Data())
                    }

                    switch url {
                    case testEndpoint:
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer access-token-resource")
                        #expect(request.url?.query == "foo=bar")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)

                    case resourceMetadataURL:
                        return try await MockResponses.resourceMetadata(
                            authorizationServers: ["https://localhost:8080/auth"],
                            scopesSupported: ["files:read"]
                        )(request)

                    case asMetadataURL:
                        return try await MockResponses.asMetadata(
                            issuer: "https://localhost:8080/auth",
                            tokenEndpoint: "https://localhost:8080/oauth/token",
                            authorizationEndpoint: "https://localhost:8080/oauth/authorize",
                            codeChallengeMethodsSupported: ["S256"]
                        )(request)

                    case tokenEndpointURL:
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=authorization_code"))
                        #expect(
                            body.contains(
                                "resource=https%3A%2F%2Flocalhost%3A8080%2Fpublic%2Fmcp"))
                        #expect(!body.contains("%3Ffoo%3Dbar"))
                        #expect(body.contains("scope=files%3Aread"))
                        #expect(body.contains("client_id=test-client"))
                        #expect(body.contains("code_verifier="))
                        #expect(body.contains("code=test"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "access-token-resource")(request)

                    default:
                        throw MockResponses.mockError("Unexpected URL: \(url.absoluteString)")
                    }
                }

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        grantType: .authorizationCode,
                        authentication: .none(clientID: "test-client")
                    ),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":23}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 5 - Rejects Authorization Without PKCE Metadata

            func configureOAuthRejectsAuthorizationWithoutPKCEMetadata() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/pkce-metadata-missing")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/pkce-metadata-missing"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let authorizationEndpointURL = URL(
                    string: "https://localhost:8080/oauth/authorize")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!

                requestHandler = {
                    [testEndpoint, resourceMetadataURL, asMetadataURL, authorizationEndpointURL, tokenEndpointURL]
                    request in
                    guard let url = request.url else {
                        throw MockResponses.mockError("Missing request URL")
                    }

                    if url.scheme == authorizationEndpointURL.scheme,
                        url.host == authorizationEndpointURL.host,
                        url.port == authorizationEndpointURL.port,
                        url.path == authorizationEndpointURL.path
                    {
                        let response = HTTPURLResponse(
                            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                            headerFields: [
                                "Location": "http://127.0.0.1:3000/callback?code=test"
                            ])!
                        return (response, Data())
                    }

                    switch url {
                    case testEndpoint:
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)

                    case resourceMetadataURL:
                        return try await MockResponses.resourceMetadata(
                            authorizationServers: ["https://localhost:8080/auth"],
                            scopesSupported: ["files:read"]
                        )(request)

                    case asMetadataURL:
                        return try await MockResponses.asMetadata(
                            issuer: "https://localhost:8080/auth",
                            tokenEndpoint: "https://localhost:8080/oauth/token",
                            authorizationEndpoint: "https://localhost:8080/oauth/authorize"
                        )(request)

                    case tokenEndpointURL:
                        return try await MockResponses.tokenSuccess(
                            accessToken: "should-not-be-issued")(request)

                    default:
                        throw MockResponses.mockError("Unexpected URL: \(url.absoluteString)")
                    }
                }

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        grantType: .authorizationCode,
                        authentication: .none(clientID: "test-client")
                    ),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":24}"#.data(using: .utf8)!,
                    expectedCallCounts: [tokenEndpointURL: 0],
                    expectedErrorSubstring: "code_challenge_methods_supported"
                )
            }

            // MARK: 6 - Rejects Authorization Without S256 PKCE

            func configureOAuthRejectsAuthorizationWithoutS256PKCE() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/pkce-s256-missing")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/pkce-s256-missing"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let authorizationEndpointURL = URL(
                    string: "https://localhost:8080/oauth/authorize")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!

                requestHandler = {
                    [testEndpoint, resourceMetadataURL, asMetadataURL, authorizationEndpointURL, tokenEndpointURL]
                    request in
                    guard let url = request.url else {
                        throw MockResponses.mockError("Missing request URL")
                    }

                    if url.scheme == authorizationEndpointURL.scheme,
                        url.host == authorizationEndpointURL.host,
                        url.port == authorizationEndpointURL.port,
                        url.path == authorizationEndpointURL.path
                    {
                        let response = HTTPURLResponse(
                            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                            headerFields: [
                                "Location": "http://127.0.0.1:3000/callback?code=test"
                            ])!
                        return (response, Data())
                    }

                    switch url {
                    case testEndpoint:
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)

                    case resourceMetadataURL:
                        return try await MockResponses.resourceMetadata(
                            authorizationServers: ["https://localhost:8080/auth"],
                            scopesSupported: ["files:read"]
                        )(request)

                    case asMetadataURL:
                        return try await MockResponses.asMetadata(
                            issuer: "https://localhost:8080/auth",
                            tokenEndpoint: "https://localhost:8080/oauth/token",
                            authorizationEndpoint: "https://localhost:8080/oauth/authorize",
                            codeChallengeMethodsSupported: ["plain"]
                        )(request)

                    case tokenEndpointURL:
                        return try await MockResponses.tokenSuccess(
                            accessToken: "should-not-be-issued")(request)

                    default:
                        throw MockResponses.mockError("Unexpected URL: \(url.absoluteString)")
                    }
                }

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        grantType: .authorizationCode,
                        authentication: .none(clientID: "test-client")
                    ),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":25}"#.data(using: .utf8)!,
                    expectedCallCounts: [tokenEndpointURL: 0],
                    expectedErrorSubstring: "must support PKCE S256"
                )
            }

            // MARK: 7 - Rejects Authorization Response Redirect Mismatch

            func configureOAuthRejectsAuthorizationResponseRedirectMismatch()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(
                    string: "https://localhost:8080/authorization-redirect-mismatch")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/authorization-redirect-mismatch"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let authorizationEndpointURL = URL(
                    string: "https://localhost:8080/oauth/authorize")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!

                requestHandler = {
                    [testEndpoint, resourceMetadataURL, asMetadataURL, authorizationEndpointURL, tokenEndpointURL]
                    request in
                    guard let url = request.url else {
                        throw MockResponses.mockError("Missing request URL")
                    }

                    if url.scheme == authorizationEndpointURL.scheme,
                        url.host == authorizationEndpointURL.host,
                        url.port == authorizationEndpointURL.port,
                        url.path == authorizationEndpointURL.path
                    {
                        let queryItems =
                            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                            ?? []
                        let state =
                            queryItems.first(where: { $0.name == "state" })?.value ?? ""
                        let locationValue =
                            "https://evil.example.com/callback?code=test&state=\(state)"
                        let response = HTTPURLResponse(
                            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                            headerFields: ["Location": locationValue])!
                        return (response, Data())
                    }

                    switch url {
                    case testEndpoint:
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)

                    case resourceMetadataURL:
                        return try await MockResponses.resourceMetadata(
                            authorizationServers: ["https://localhost:8080/auth"],
                            scopesSupported: ["files:read"]
                        )(request)

                    case asMetadataURL:
                        return try await MockResponses.asMetadata(
                            issuer: "https://localhost:8080/auth",
                            tokenEndpoint: "https://localhost:8080/oauth/token",
                            authorizationEndpoint: "https://localhost:8080/oauth/authorize",
                            codeChallengeMethodsSupported: ["S256"]
                        )(request)

                    case tokenEndpointURL:
                        return try await MockResponses.tokenSuccess(
                            accessToken: "should-not-be-issued")(request)

                    default:
                        throw MockResponses.mockError("Unexpected URL: \(url.absoluteString)")
                    }
                }

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        grantType: .authorizationCode,
                        authentication: .none(clientID: "test-client")
                    ),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":26}"#.data(using: .utf8)!,
                    expectedCallCounts: [tokenEndpointURL: 0],
                    expectedErrorSubstring: "redirect URI mismatch"
                )
            }

            // MARK: 8 - Rejects Authorization Response State Mismatch

            func configureOAuthRejectsAuthorizationResponseStateMismatch()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(
                    string: "https://localhost:8080/authorization-state-mismatch")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/authorization-state-mismatch"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let authorizationEndpointURL = URL(
                    string: "https://localhost:8080/oauth/authorize")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!

                requestHandler = {
                    [testEndpoint, resourceMetadataURL, asMetadataURL, authorizationEndpointURL, tokenEndpointURL]
                    request in
                    guard let url = request.url else {
                        throw MockResponses.mockError("Missing request URL")
                    }

                    if url.scheme == authorizationEndpointURL.scheme,
                        url.host == authorizationEndpointURL.host,
                        url.port == authorizationEndpointURL.port,
                        url.path == authorizationEndpointURL.path
                    {
                        let queryItems =
                            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                            ?? []
                        let redirectURI =
                            queryItems.first(where: { $0.name == "redirect_uri" })?.value
                        var redirectComponents = URLComponents(string: redirectURI ?? "")
                        var redirectQueryItems = redirectComponents?.queryItems ?? []
                        redirectQueryItems.append(.init(name: "code", value: "test"))
                        redirectQueryItems.append(
                            .init(name: "state", value: "unexpected-state"))
                        redirectComponents?.queryItems = redirectQueryItems
                        let locationValue =
                            redirectComponents?.url?.absoluteString
                            ?? "http://127.0.0.1:3000/callback?code=test&state=unexpected-state"
                        let response = HTTPURLResponse(
                            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                            headerFields: ["Location": locationValue])!
                        return (response, Data())
                    }

                    switch url {
                    case testEndpoint:
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)

                    case resourceMetadataURL:
                        return try await MockResponses.resourceMetadata(
                            authorizationServers: ["https://localhost:8080/auth"],
                            scopesSupported: ["files:read"]
                        )(request)

                    case asMetadataURL:
                        return try await MockResponses.asMetadata(
                            issuer: "https://localhost:8080/auth",
                            tokenEndpoint: "https://localhost:8080/oauth/token",
                            authorizationEndpoint: "https://localhost:8080/oauth/authorize",
                            codeChallengeMethodsSupported: ["S256"]
                        )(request)

                    case tokenEndpointURL:
                        return try await MockResponses.tokenSuccess(
                            accessToken: "should-not-be-issued")(request)

                    default:
                        throw MockResponses.mockError("Unexpected URL: \(url.absoluteString)")
                    }
                }

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        grantType: .authorizationCode,
                        authentication: .none(clientID: "test-client")
                    ),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":27}"#.data(using: .utf8)!,
                    expectedCallCounts: [tokenEndpointURL: 0],
                    expectedErrorSubstring: "state mismatch"
                )
            }

            // MARK: 9 - Access Token Only Via Authorization Header

            func configureOAuthAccessTokenOnlyViaAuthorizationHeader() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/test?foo=bar")!
                let resourceMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource/test")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 12)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer access-token-xyz")
                        #expect(request.url?.query == "foo=bar")
                        #expect(
                            !(request.url?.absoluteString.contains("access_token=") ?? false))
                        let requestBody =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(!requestBody.contains("access_token="))
                        #expect(
                            request.value(forHTTPHeaderField: "Content-Type")
                                == "application/json")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: MockResponses.tokenSuccess(
                        accessToken: "access-token-xyz"),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":12}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 10 - Authorization Header For Every Request In Session

            func configureOAuthAuthorizationHeaderForEveryRequestInSession()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(string: "https://localhost:8080/session-auth")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/session-auth")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let firstResponseData = #"{"jsonrpc":"2.0","result":{"ok":true},"id":31}"#.data(
                    using: .utf8)!
                let secondResponseData = #"{"jsonrpc":"2.0","result":{"ok":true},"id":32}"#.data(
                    using: .utf8)!

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: {
                        [firstResponseData, secondResponseData] request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer session-access-token")
                        #expect(
                            !(request.url?.absoluteString.contains("access_token=") ?? false))
                        let requestBody =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(!requestBody.contains("access_token="))

                        let responseBody: Data
                        if requestBody.contains("\"id\":31") {
                            responseBody = firstResponseData
                        } else if requestBody.contains("\"id\":32") {
                            responseBody = secondResponseData
                        } else {
                            throw MockResponses.mockError(
                                "Unexpected JSON-RPC body: \(requestBody)")
                        }

                        let response = HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: [
                                "Content-Type": "application/json",
                                "MCP-Session-Id": "session-123",
                            ])!
                        return (response, responseBody)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(
                            body.contains(
                                "resource=https%3A%2F%2Flocalhost%3A8080%2Fsession-auth"))
                        #expect(body.contains("scope=files%3Aread"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "session-access-token")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":31}"#.data(using: .utf8)!,
                    expectedResponseData: firstResponseData,
                    expectedCallCounts: [
                        testEndpoint: 3, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 1,
                    ],
                    secondMessageData: #"{"jsonrpc":"2.0","method":"ping","id":32}"#.data(
                        using: .utf8)!,
                    secondExpectedResponseData: secondResponseData
                )
            }

            // MARK: 11 - Streaming GET Uses Authorization Header Only

            func configureOAuthStreamingGETUsesAuthorizationHeaderOnly() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/stream-auth?foo=bar")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/stream-auth")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let sseEventData = "id: evt-1\ndata: {\"stream\":\"ok\"}\n\n".data(using: .utf8)!

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { [sseEventData] request in
                        if request.httpMethod == "GET" {
                            #expect(
                                request.value(forHTTPHeaderField: "Authorization")
                                    == "Bearer stream-access-token")
                            #expect(request.url?.query == "foo=bar")
                            #expect(
                                !(request.url?.absoluteString.contains("access_token=") ?? false))
                            #expect(
                                request.value(forHTTPHeaderField: "MCP-Session-Id")
                                    == "stream-session-id")
                            let response = HTTPURLResponse(
                                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "text/event-stream"])!
                            return (response, sseEventData)
                        }

                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }

                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer stream-access-token")
                        #expect(
                            !(request.url?.absoluteString.contains("access_token=") ?? false))
                        let requestBody =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(!requestBody.contains("access_token="))

                        let response = HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: [
                                "Content-Type": "text/plain",
                                "MCP-Session-Id": "stream-session-id",
                            ])!
                        return (response, Data())
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(
                            body.contains(
                                "resource=https%3A%2F%2Flocalhost%3A8080%2Fstream-auth"))
                        #expect(body.contains("scope=files%3Aread"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "stream-access-token")(request)
                    },
                ])

                let expectedEventPayload = #"{"stream":"ok"}"#.data(using: .utf8)!
                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":41}"#.data(
                        using: .utf8)!,
                    expectedResponseData: expectedEventPayload,
                    streaming: true,
                    sseInitializationTimeout: 1
                )
            }

            // MARK: 12 - Rejects Non-Bearer Token Type

            func configureOAuthRejectsNonBearerTokenType() -> OAuthScenarioContext {
                let testEndpoint = URL(
                    string: "https://localhost:8080/non-bearer-token-type")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/non-bearer-token-type"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: MockResponses.tokenResponse(
                        accessToken: "non-bearer-token", tokenType: "DPoP"),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":51}"#.data(
                        using: .utf8)!,
                    expectedErrorSubstring: "Token response is invalid"
                )
            }

            // MARK: 13 - Token Endpoint Failure Redacts Response Body

            func configureOAuthTokenEndpointFailureRedactsResponseBody() -> OAuthScenarioContext {
                let testEndpoint = URL(
                    string: "https://localhost:8080/token-error-redaction")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/token-error-redaction"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: MockResponses.tokenError(
                        error: "invalid_client",
                        errorDescription: "leaked-secret-value",
                        extraFields: ["access_token": "should-not-leak"]
                    ),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":52}"#.data(
                        using: .utf8)!,
                    expectedErrorSubstring: "oauth_error: invalid_client",
                    unexpectedErrorSubstrings: ["leaked-secret-value", "should-not-leak"]
                )
            }

            // MARK: 14 - Rejects Non-HTTPS Token Endpoint

            func configureOAuthRejectsNonHTTPSTokenEndpoint() -> OAuthScenarioContext {
                let testEndpoint = URL(
                    string: "https://localhost:8080/non-https-token-endpoint")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/non-https-token-endpoint"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "http://localhost:8080/oauth/token"
                    ),
                ])

                var oauth = OAuthConfiguration(
                    authentication: .none(clientID: "test-client"))
                oauth.allowLoopbackHTTPAuthorizationServerEndpoints = false

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: oauth,
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":53}"#.data(
                        using: .utf8)!,
                    expectedErrorSubstring: "Token endpoint must use https"
                )
            }

            // MARK: 15 - Allows Loopback HTTP Authorization Server Endpoints

            func configureOAuthAllowsLoopbackHTTPAuthorizationServerEndpoints()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(
                    string: "https://localhost:8080/loopback-http-auth-server-enabled")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/loopback-http-auth-server-enabled"
                )!
                let asMetadataURL = URL(
                    string: "http://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "http://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 54)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") != nil {
                            return try await MockResponses.jsonSuccess(body: finalResponseData)(
                                request)
                        }
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["http://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "http://localhost:8080/auth",
                        tokenEndpoint: "http://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "loopback-http-token")(request)
                    },
                ])

                var oauth = OAuthConfiguration(
                    authentication: .none(clientID: "test-client"))
                oauth.allowLoopbackHTTPAuthorizationServerEndpoints = true

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: oauth,
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":54}"#.data(
                        using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [tokenEndpointURL: 1]
                )
            }

            // MARK: 16 - Access Token Provider Receives Discovery Context

            func configureOAuthAccessTokenProviderReceivesDiscoveryContext()
                -> (OAuthScenarioContext, ProviderTracker)
            {
                let testEndpoint = URL(string: "https://localhost:8080/test")!
                let resourceMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource/test")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 2)
                let providerTracker = ProviderTracker()

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL,
                                scope: "files:read files:write"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer provider-access-token")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read", "files:write"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        authorizationEndpoint: "https://localhost:8080/oauth/authorize",
                        codeChallengeMethodsSupported: ["S256"]
                    ),
                    tokenEndpointURL: { request in
                        let response = HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, Data())
                    },
                ])

                let oauthConfiguration = OAuthConfiguration(
                    authentication: .none(clientID: "test-client"),
                    accessTokenProvider: { [providerTracker] providerContext, _ in
                        await providerTracker.capture(providerContext)
                        return "provider-access-token"
                    }
                )

                let context = OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: oauthConfiguration,
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":2}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 0,
                    ]
                )
                return (context, providerTracker)
            }

            // MARK: 17 - Discovery Uses Header Resource Metadata

            func configureOAuthDiscoveryUsesHeaderResourceMetadata() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let headerMetadataURL = URL(
                    string: "https://localhost:8080/custom-metadata")!
                let fallbackPathMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let fallbackRootMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 3)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: headerMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer access-token-123")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    headerMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    fallbackPathMetadataURL: MockResponses.httpError(statusCode: 500),
                    fallbackRootMetadataURL: MockResponses.httpError(statusCode: 500),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: MockResponses.tokenSuccess(
                        accessToken: "access-token-123"),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":3}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, headerMetadataURL: 1,
                        fallbackPathMetadataURL: 0, fallbackRootMetadataURL: 0,
                    ]
                )
            }

            // MARK: 18 - Discovery Fallback Well-Known Order

            func configureOAuthDiscoveryFallbackWellKnownOrder()
                -> (OAuthScenarioContext, OrderTracker)
            {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let fallbackPathMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let fallbackRootMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 4)
                let tracker = OrderTracker()

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                scope: "files:read")(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer access-token-456")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    fallbackPathMetadataURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.httpError(statusCode: 404)(request)
                    },
                    fallbackRootMetadataURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.resourceMetadata(
                            authorizationServers: ["https://localhost:8080/auth"],
                            scopesSupported: ["files:read"]
                        )(request)
                    },
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: MockResponses.tokenSuccess(
                        accessToken: "access-token-456"),
                ])

                let context = OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":4}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData
                )
                return (context, tracker)
            }

            // MARK: 19 - Discovery Fails When Metadata Unavailable

            func configureOAuthDiscoveryFailsWhenMetadataUnavailable()
                -> (OAuthScenarioContext, OrderTracker)
            {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let fallbackPathMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let fallbackRootMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-protected-resource")!
                let tracker = OrderTracker()

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        return try await MockResponses.bearerChallenge(
                            scope: "files:read")(request)
                    },
                    fallbackPathMetadataURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.httpError(statusCode: 404)(request)
                    },
                    fallbackRootMetadataURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.httpError(statusCode: 404)(request)
                    },
                ])

                let context = OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":7}"#.data(using: .utf8)!,
                    expectedErrorSubstring: "metadata"
                )
                return (context, tracker)
            }

            // MARK: 20 - AS Metadata Discovery Order For Path Issuer

            func configureOAuthASMetadataDiscoveryOrderForPathIssuer()
                -> (OAuthScenarioContext, OrderTracker)
            {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let authorizationServer = URL(string: "https://localhost:8080/tenant1")!
                let asMetadataOAuthInsertedURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-authorization-server/tenant1")!
                let asMetadataOIDCInsertedURL = URL(
                    string: "https://localhost:8080/.well-known/openid-configuration/tenant1")!
                let asMetadataOIDCAppendedURL = URL(
                    string: "https://localhost:8080/tenant1/.well-known/openid-configuration")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 5)
                let tracker = OrderTracker()

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer path-issuer-token")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/tenant1"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataOAuthInsertedURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.httpError(statusCode: 404)(request)
                    },
                    asMetadataOIDCInsertedURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.httpError(statusCode: 404)(request)
                    },
                    asMetadataOIDCAppendedURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.asMetadata(
                            issuer: "https://localhost:8080/tenant1",
                            tokenEndpoint: "https://localhost:8080/oauth/token"
                        )(request)
                    },
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(body.contains("scope=files%3Aread"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "path-issuer-token")(request)
                    },
                    authorizationServer: { _ in
                        throw MockResponses.mockError(
                            "Unexpected direct issuer request")
                    },
                ])

                let context = OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":5}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData
                )
                return (context, tracker)
            }

            // MARK: 21 - AS Metadata Discovery Order For Root Issuer

            func configureOAuthASMetadataDiscoveryOrderForRootIssuer()
                -> (OAuthScenarioContext, OrderTracker)
            {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let authorizationServer = URL(string: "https://localhost:8080")!
                let asMetadataOAuthURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server")!
                let asMetadataOIDCURL = URL(
                    string: "https://localhost:8080/.well-known/openid-configuration")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 6)
                let tracker = OrderTracker()

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer root-issuer-token")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataOAuthURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.httpError(statusCode: 404)(request)
                    },
                    asMetadataOIDCURL: { [tracker] request in
                        await tracker.append(request.url!)
                        return try await MockResponses.asMetadata(
                            issuer: "https://localhost:8080",
                            tokenEndpoint: "https://localhost:8080/oauth/token"
                        )(request)
                    },
                    tokenEndpointURL: MockResponses.tokenSuccess(
                        accessToken: "root-issuer-token"),
                    authorizationServer: { _ in
                        throw MockResponses.mockError(
                            "Unexpected direct issuer request")
                    },
                ])

                let context = OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":6}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData
                )
                return (context, tracker)
            }

            // MARK: 22 - Registration Prefers CIMD When Advertised

            func configureOAuthRegistrationPrefersCIMDWhenAdvertised() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let registrationEndpointURL = URL(
                    string: "https://localhost:8080/register")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let clientMetadataDocumentID = "https://client.example.com/metadata.json"
                let finalResponseData = MockResponses.jsonRPCResult(id: 8)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer cimd-token")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        registrationEndpoint: "https://localhost:8080/register",
                        clientIDMetadataDocumentSupported: true
                    ),
                    registrationEndpointURL: MockResponses.httpError(statusCode: 500),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(
                            body.contains(
                                "client_id=https%3A%2F%2Fclient.example.com%2Fmetadata.json"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "cimd-token")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        authentication: .none(clientID: clientMetadataDocumentID)),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":8}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [registrationEndpointURL: 0]
                )
            }

            // MARK: 23 - Pre-Registration Uses Static Credentials

            func configureOAuthPreRegistrationUsesStaticCredentials() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let registrationEndpointURL = URL(
                    string: "https://localhost:8080/register")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 13)

                let expectedClientID = "pre-registered-client"
                let expectedClientSecret = "pre-registered-secret"
                let expectedBasic = Data(
                    "\(expectedClientID):\(expectedClientSecret)".utf8
                ).base64EncodedString()

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer pre-registered-token")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        registrationEndpoint: "https://localhost:8080/register"
                    ),
                    registrationEndpointURL: MockResponses.httpError(statusCode: 500),
                    tokenEndpointURL: { [expectedBasic] request in
                        #expect(request.httpMethod == "POST")
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Basic \(expectedBasic)")
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(
                            body.contains(
                                "resource=https%3A%2F%2Flocalhost%3A8080%2Fpublic%2Fmcp"))
                        #expect(body.contains("scope=files%3Aread"))
                        #expect(!body.contains("client_id="))
                        #expect(!body.contains("client_secret="))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "pre-registered-token")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        authentication: .clientSecretBasic(
                            clientID: expectedClientID,
                            clientSecret: expectedClientSecret
                        )),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":13}"#.data(
                        using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [registrationEndpointURL: 0]
                )
            }

            // MARK: 24 - Registration Falls Back to Dynamic Registration (CIMD Not Advertised)

            func configureOAuthRegistrationFallsBackToDynamicRegistrationCIMDNotAdvertised()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let registrationEndpointURL = URL(
                    string: "https://localhost:8080/register")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let clientMetadataDocumentID = "https://client.example.com/metadata.json"
                let finalResponseData = MockResponses.jsonRPCResult(id: 9)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer dynamic-registration-token")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        registrationEndpoint: "https://localhost:8080/register",
                        clientIDMetadataDocumentSupported: false
                    ),
                    registrationEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("\"grant_types\":[\"client_credentials\"]"))
                        #expect(body.contains("\"token_endpoint_auth_method\":\"none\""))
                        #expect(!body.contains("\"response_types\""))
                        #expect(!body.contains("redirect_uris"))
                        #expect(!body.contains("authorization_code"))
                        return try await MockResponses.registrationSuccess(
                            clientID: "registered-client")(request)
                    },
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(body.contains("client_id=registered-client"))
                        #expect(
                            !body.contains(
                                "client_id=https%3A%2F%2Fclient.example.com%2Fmetadata.json"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "dynamic-registration-token")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        authentication: .none(clientID: clientMetadataDocumentID)),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":9}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [registrationEndpointURL: 1]
                )
            }

            // MARK: 25 - Registration Falls Back to Dynamic Registration (CIMD Capability Missing)

            func configureOAuthRegistrationFallsBackToDynamicRegistrationCIMDCapabilityMissing()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let registrationEndpointURL = URL(
                    string: "https://localhost:8080/register")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let clientMetadataDocumentID = "https://client.example.com/metadata.json"
                let finalResponseData = MockResponses.jsonRPCResult(id: 14)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                            )(request)
                        }
                        #expect(
                            request.value(forHTTPHeaderField: "Authorization")
                                == "Bearer dynamic-registration-token-missing-capability")
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(
                            request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        registrationEndpoint: "https://localhost:8080/register"
                    ),
                    registrationEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("\"grant_types\":[\"client_credentials\"]"))
                        #expect(!body.contains("redirect_uris"))
                        return try await MockResponses.registrationSuccess(
                            clientID: "registered-client-2")(request)
                    },
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        #expect(body.contains("grant_type=client_credentials"))
                        #expect(body.contains("client_id=registered-client-2"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "dynamic-registration-token-missing-capability")(
                            request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        authentication: .none(clientID: clientMetadataDocumentID)),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":14}"#.data(
                        using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [registrationEndpointURL: 1]
                )
            }

            // MARK: 26 - Registration Missing Mechanism Returns Actionable Error

            func configureOAuthRegistrationMissingMechanismReturnsActionableError()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let clientMetadataDocumentID = "https://client.example.com/metadata.json"

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        clientIDMetadataDocumentSupported: false
                    ),
                    tokenEndpointURL: MockResponses.httpError(statusCode: 500),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        authentication: .none(clientID: clientMetadataDocumentID)),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":10}"#.data(
                        using: .utf8)!,
                    expectedErrorSubstring:
                        "Authorization server does not support Client ID Metadata Documents"
                )
            }

            // MARK: 27 - CIMD Rejects Non-HTTPS Client ID URL

            func configureOAuthCIMDRejectsNonHTTPSClientIDURL() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let invalidClientID = "http://client.example.com/metadata.json"

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        clientIDMetadataDocumentSupported: true
                    ),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        authentication: .none(clientID: invalidClientID)),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":11}"#.data(
                        using: .utf8)!,
                    expectedErrorSubstring:
                        "Client ID metadata document URL must use https and include a path"
                )
            }

            // MARK: 28 - Rejects Insecure MCP Endpoint URL

            func configureOAuthRejectsInsecureMCPEndpointURL() -> OAuthScenarioContext {
                let insecureEndpoint = URL(string: "http://example.com/public/mcp")!

                return OAuthScenarioContext(
                    testEndpoint: insecureEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":12}"#.data(
                        using: .utf8)!,
                    expectedErrorSubstring:
                        "MCP endpoint must use https or loopback http"
                )
            }

            // MARK: 30 - PRM Cache Invalidated When resource_metadata URL Changes

            func configureOAuthPRMCacheInvalidatedOnResourceMetadataURLChange()
                -> OAuthScenarioContext
            {
                let testEndpoint = URL(string: "https://localhost:8080/cache-invalidation")!
                let resourceMetadataURL_A = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/cache-a")!
                let resourceMetadataURL_B = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/cache-b")!
                let asMetadataURL_A = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-authorization-server/auth-a")!
                let asMetadataURL_B = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-authorization-server/auth-b")!
                let tokenEndpointURL_A = URL(
                    string: "https://localhost:8080/oauth/token-a")!
                let tokenEndpointURL_B = URL(
                    string: "https://localhost:8080/oauth/token-b")!
                let firstResponseData = MockResponses.jsonRPCResult(id: 71)
                let secondResponseData = MockResponses.jsonRPCResult(id: 72)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        let authHeader = request.value(forHTTPHeaderField: "Authorization")
                        let bodyStr =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        if authHeader == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL_A, scope: "files:read"
                            )(request)
                        } else if authHeader == "Bearer token-a" {
                            if bodyStr.contains("\"id\":71") {
                                return try await MockResponses.jsonSuccess(
                                    body: firstResponseData)(request)
                            } else {
                                // Second message with old token → return 401 with new URL_B
                                return try await MockResponses.bearerChallenge(
                                    resourceMetadataURL: resourceMetadataURL_B, scope: "files:read"
                                )(request)
                            }
                        } else if authHeader == "Bearer token-b" {
                            return try await MockResponses.jsonSuccess(
                                body: secondResponseData)(request)
                        }
                        throw MockResponses.mockError(
                            "Unexpected Authorization header: \(String(describing: authHeader))")
                    },
                    resourceMetadataURL_A: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth-a"],
                        scopesSupported: ["files:read"]
                    ),
                    resourceMetadataURL_B: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth-b"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL_A: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth-a",
                        tokenEndpoint: "https://localhost:8080/oauth/token-a"
                    ),
                    asMetadataURL_B: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth-b",
                        tokenEndpoint: "https://localhost:8080/oauth/token-b"
                    ),
                    tokenEndpointURL_A: MockResponses.tokenSuccess(accessToken: "token-a"),
                    tokenEndpointURL_B: MockResponses.tokenSuccess(accessToken: "token-b"),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":71}"#.data(using: .utf8)!,
                    expectedResponseData: firstResponseData,
                    expectedCallCounts: [
                        resourceMetadataURL_A: 1,
                        resourceMetadataURL_B: 1,
                        tokenEndpointURL_A: 1,
                        tokenEndpointURL_B: 1,
                    ],
                    secondMessageData: #"{"jsonrpc":"2.0","method":"ping","id":72}"#.data(
                        using: .utf8)!,
                    secondExpectedResponseData: secondResponseData
                )
            }

            // MARK: 29 - Rejects Non-Loopback HTTP Redirect URI

            func configureOAuthRejectsNonLoopbackHTTPRedirectURI() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/public/mcp")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        return try await MockResponses.bearerChallenge(
                            resourceMetadataURL: resourceMetadataURL, scope: "files:read"
                        )(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        scopesSupported: ["files:read"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        authorizationEndpoint: "https://localhost:8080/oauth/authorize",
                        codeChallengeMethodsSupported: ["S256"]
                    ),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(
                        grantType: .authorizationCode,
                        authentication: .none(clientID: "test-client"),
                        authorizationRedirectURI: URL(
                            string: "http://evil.example.com/callback")!
                    ),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":13}"#.data(
                        using: .utf8)!,
                    expectedErrorSubstring:
                        "Redirect URI must use https or loopback http and must not include fragments"
                )
            }

            // MARK: 31 - Resource Uses PRM Resource Field (Gap 1)

            func configureOAuthResourceUsesPRMResourceField() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/mcp/tools")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/mcp/tools")!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 91)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL)(request)
                        }
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(request)
                    },
                    // PRM resource = "https://localhost:8080" (origin only, no path)
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"],
                        resource: "https://localhost:8080"
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        // Must use the PRM resource field, not the specific endpoint path
                        #expect(body.contains("resource=https%3A%2F%2Flocalhost%3A8080"))
                        #expect(!body.contains("resource=https%3A%2F%2Flocalhost%3A8080%2Fmcp"))
                        return try await MockResponses.tokenSuccess(
                            accessToken: "access-token-prm-resource")(request)
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":91}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2, resourceMetadataURL: 1, asMetadataURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 32 - Second Authorization Server Tried When First Fails (Gap 2)

            func configureOAuthSecondAuthorizationServerTriedWhenFirstFails() -> OAuthScenarioContext
            {
                let testEndpoint = URL(string: "https://localhost:8080/test-as-fallback")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/test-as-fallback"
                )!
                // AS1 discovery URLs — all return 404
                let as1MetadataURL1 = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/as1")!
                let as1MetadataURL2 = URL(
                    string: "https://localhost:8080/.well-known/openid-configuration/as1")!
                let as1MetadataURL3 = URL(
                    string: "https://localhost:8080/as1/.well-known/openid-configuration")!
                // AS2 first discovery URL — returns valid metadata
                let as2MetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/as2")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token-as2")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 92)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL)(request)
                        }
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: [
                            "https://localhost:8080/as1",
                            "https://localhost:8080/as2",
                        ]
                    ),
                    // AS1: all well-known URLs return 404
                    as1MetadataURL1: MockResponses.httpError(statusCode: 404),
                    as1MetadataURL2: MockResponses.httpError(statusCode: 404),
                    as1MetadataURL3: MockResponses.httpError(statusCode: 404),
                    // AS2: first well-known URL returns valid metadata
                    as2MetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/as2",
                        tokenEndpoint: "https://localhost:8080/oauth/token-as2"
                    ),
                    tokenEndpointURL: MockResponses.tokenSuccess(
                        accessToken: "access-token-from-as2"),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":92}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2,
                        resourceMetadataURL: 1,
                        as1MetadataURL1: 1,
                        as1MetadataURL2: 1,
                        as1MetadataURL3: 1,
                        as2MetadataURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 33 - Re-Registration After Client Secret Expiry (Gap 3)

            func configureOAuthReRegistersAfterClientSecretExpiry() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/test-secret-expiry")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/test-secret-expiry"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let registrationEndpointURL = URL(string: "https://localhost:8080/register")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let firstResponseData = MockResponses.jsonRPCResult(id: 93)
                let secondResponseData = MockResponses.jsonRPCResult(id: 94)
                let regTracker = OrderTracker()

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        let auth = request.value(forHTTPHeaderField: "Authorization")
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        if auth == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL)(request)
                        }
                        if auth == "Bearer token-v1" && body.contains("\"id\":93") {
                            return try await MockResponses.jsonSuccess(body: firstResponseData)(
                                request)
                        }
                        // Second request with old token → trigger re-auth
                        if auth == "Bearer token-v1" && body.contains("\"id\":94") {
                            return try await MockResponses.bearerChallenge()(request)
                        }
                        if auth == "Bearer token-v2" {
                            return try await MockResponses.jsonSuccess(body: secondResponseData)(
                                request)
                        }
                        throw MockResponses.mockError(
                            "Unexpected auth: \(String(describing: auth))")
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token",
                        registrationEndpoint: "https://localhost:8080/register"
                    ),
                    registrationEndpointURL: { [regTracker] request in
                        await regTracker.append(request.url!)
                        let count = await regTracker.count()
                        // Return different client IDs per registration call
                        let clientID = count == 1 ? "client-v1" : "client-v2"
                        // client_secret_expires_at = 1 (Unix epoch — always in the past)
                        let dict: [String: Any] = [
                            "client_id": clientID,
                            "client_secret_expires_at": 1,
                        ]
                        let data = try JSONSerialization.data(withJSONObject: dict)
                        let response = HTTPURLResponse(
                            url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, data)
                    },
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        if body.contains("client_id=client-v1") {
                            return try await MockResponses.tokenSuccess(accessToken: "token-v1")(
                                request)
                        }
                        if body.contains("client_id=client-v2") {
                            return try await MockResponses.tokenSuccess(accessToken: "token-v2")(
                                request)
                        }
                        throw MockResponses.mockError("Unexpected client_id in token request")
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "anon")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":93}"#.data(using: .utf8)!,
                    expectedResponseData: firstResponseData,
                    expectedCallCounts: [
                        registrationEndpointURL: 2,
                        tokenEndpointURL: 2,
                    ],
                    secondMessageData: #"{"jsonrpc":"2.0","method":"ping","id":94}"#.data(
                        using: .utf8)!,
                    secondExpectedResponseData: secondResponseData
                )
            }

            // MARK: 34 - Issuer Mismatch Causes Next Discovery URL Variant to Be Tried (Gap 4)

            func configureOAuthIssuerMismatchTriesNextURLVariant() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/test-issuer-check")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/test-issuer-check"
                )!
                // Discovery URL 1 returns wrong issuer → skipped
                let wrongIssuerURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                // Discovery URL 2 returns correct issuer → used
                let correctIssuerURL = URL(
                    string: "https://localhost:8080/.well-known/openid-configuration/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let finalResponseData = MockResponses.jsonRPCResult(id: 95)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        if request.value(forHTTPHeaderField: "Authorization") == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL)(request)
                        }
                        return try await MockResponses.jsonSuccess(body: finalResponseData)(request)
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"]
                    ),
                    // URL 1: returns metadata with wrong issuer field → SDK skips it
                    wrongIssuerURL: MockResponses.asMetadata(
                        issuer: "https://evil.example.com",
                        tokenEndpoint: "https://evil.example.com/token"
                    ),
                    // URL 2: returns metadata with correct issuer → SDK accepts it
                    correctIssuerURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: MockResponses.tokenSuccess(
                        accessToken: "access-token-after-issuer-check"),
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    oauthConfiguration: .init(authentication: .none(clientID: "test-client")),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":95}"#.data(using: .utf8)!,
                    expectedResponseData: finalResponseData,
                    expectedCallCounts: [
                        testEndpoint: 2,
                        resourceMetadataURL: 1,
                        wrongIssuerURL: 1,
                        correctIssuerURL: 1,
                        tokenEndpointURL: 1,
                    ]
                )
            }

            // MARK: 35 - Proactive Token Refresh Within Window (Gap 5)

            func configureOAuthProactiveTokenRefreshWithinWindow() -> OAuthScenarioContext {
                let testEndpoint = URL(string: "https://localhost:8080/test-proactive-refresh")!
                let resourceMetadataURL = URL(
                    string:
                        "https://localhost:8080/.well-known/oauth-protected-resource/test-proactive-refresh"
                )!
                let asMetadataURL = URL(
                    string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
                let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
                let firstResponseData = MockResponses.jsonRPCResult(id: 96)
                let secondResponseData = MockResponses.jsonRPCResult(id: 97)

                requestHandler = MockResponses.routingHandler(routes: [
                    testEndpoint: { request in
                        let auth = request.value(forHTTPHeaderField: "Authorization")
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        if auth == nil {
                            return try await MockResponses.bearerChallenge(
                                resourceMetadataURL: resourceMetadataURL)(request)
                        }
                        if body.contains("\"id\":96") {
                            return try await MockResponses.jsonSuccess(body: firstResponseData)(
                                request)
                        }
                        // Second request: must be sent with the proactively refreshed token
                        if auth == "Bearer refreshed-token" {
                            return try await MockResponses.jsonSuccess(body: secondResponseData)(
                                request)
                        }
                        throw MockResponses.mockError(
                            "Expected refreshed token on second request, got: \(String(describing: auth))"
                        )
                    },
                    resourceMetadataURL: MockResponses.resourceMetadata(
                        authorizationServers: ["https://localhost:8080/auth"]
                    ),
                    asMetadataURL: MockResponses.asMetadata(
                        issuer: "https://localhost:8080/auth",
                        tokenEndpoint: "https://localhost:8080/oauth/token"
                    ),
                    tokenEndpointURL: { request in
                        let body =
                            String(data: readRequestBody(request) ?? Data(), encoding: .utf8) ?? ""
                        if body.contains("grant_type=client_credentials") {
                            // Initial token: expires in 300s (within 400s proactive window)
                            return try await MockResponses.tokenSuccess(
                                accessToken: "initial-token",
                                expiresIn: 300,
                                refreshToken: "rt-1"
                            )(request)
                        }
                        if body.contains("grant_type=refresh_token") {
                            #expect(body.contains("refresh_token=rt-1"))
                            return try await MockResponses.tokenSuccess(
                                accessToken: "refreshed-token",
                                expiresIn: 3600
                            )(request)
                        }
                        throw MockResponses.mockError("Unexpected grant type in token request")
                    },
                ])

                return OAuthScenarioContext(
                    testEndpoint: testEndpoint,
                    // proactiveRefreshWindowSeconds = 400 > expires_in = 300
                    oauthConfiguration: .init(
                        authentication: .none(clientID: "test-client"),
                        proactiveRefreshWindowSeconds: 400
                    ),
                    messageData: #"{"jsonrpc":"2.0","method":"ping","id":96}"#.data(using: .utf8)!,
                    expectedResponseData: firstResponseData,
                    expectedCallCounts: [
                        testEndpoint: 3,  // initial 401 + first send retry + second send
                        tokenEndpointURL: 2,  // initial client_credentials + refresh_token
                    ],
                    secondMessageData: #"{"jsonrpc":"2.0","method":"ping","id":97}"#.data(
                        using: .utf8)!,
                    secondExpectedResponseData: secondResponseData
                )
            }

        }

    #endif  // !canImport(FoundationNetworking)

#endif  // swift(>=6.1)
