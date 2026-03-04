import Foundation
import Testing

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@testable import MCP

@Suite("OAuth Authorization Helpers")
struct OAuthAuthorizationTests {
    // Generated fresh each test run — no hardcoded key material in source.
    private static let testPrivateKeyPEM: String = P256.Signing.PrivateKey().pemRepresentation

    private var metadataDiscovery: DefaultOAuthMetadataDiscovery { DefaultOAuthMetadataDiscovery() }

    private static func decodeBase64URL(_ input: Substring) -> Data? {
        var base64 = String(input)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    @Test("Parse Bearer challenge with resource metadata and scope")
    func testParseBearerChallenge() {
        let headers = [
            "WWW-Authenticate":
                "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", scope=\"files:read files:write\", error=\"insufficient_scope\""
        ]

        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: headers)

        #expect(challenge != nil)
        #expect(
            challenge?.resourceMetadataURL
                == URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        #expect(challenge?.scope == "files:read files:write")
        #expect(challenge?.error == "insufficient_scope")
    }

    @Test("Parse Bearer challenge with optional error description")
    func testParseBearerChallengeErrorDescription() {
        let headers = [
            "WWW-Authenticate":
                "Bearer error=\"insufficient_scope\", scope=\"files:read files:write\", resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", error_description=\"Additional file write permission required\""
        ]

        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: headers)

        #expect(challenge != nil)
        #expect(challenge?.error == "insufficient_scope")
        #expect(challenge?.scope == "files:read files:write")
        #expect(
            challenge?.resourceMetadataURL
                == URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        #expect(challenge?.errorDescription == "Additional file write permission required")
    }

    @Test("Parse Bearer challenge when another auth scheme appears first")
    func testParseBearerChallengeWhenBearerIsNotFirst() {
        let headers = [
            "WWW-Authenticate":
                "Basic realm=\"legacy\", Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", scope=\"files:read\""
        ]

        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: headers)

        #expect(challenge != nil)
        #expect(
            challenge?.resourceMetadataURL
                == URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        #expect(challenge?.scope == "files:read")
    }

    @Test("Parse Bearer challenge stops before the next auth scheme")
    func testParseBearerChallengeStopsBeforeNextScheme() {
        let headers = [
            "WWW-Authenticate":
                "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", scope=\"files:read\", DPoP algs=\"ES256\""
        ]

        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: headers)

        #expect(challenge != nil)
        #expect(
            challenge?.resourceMetadataURL
                == URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        #expect(challenge?.scope == "files:read")
        #expect(challenge?.parameters["algs"] == nil)
    }

    @Test("Protected resource metadata discovery fallback URLs")
    func testProtectedResourceMetadataURLs() {
        let endpoint = URL(string: "https://example.com/public/mcp")!
        let urls = metadataDiscovery.protectedResourceMetadataURLs(for: endpoint)

        #expect(
            urls == [
                URL(string: "https://example.com/.well-known/oauth-protected-resource/public/mcp")!,
                URL(string: "https://example.com/.well-known/oauth-protected-resource")!,
            ])
    }

    @Test("Authorization server metadata discovery URLs for issuer with path")
    func testAuthorizationServerMetadataURLsWithPath() {
        let issuer = URL(string: "https://auth.example.com/tenant1")!
        let urls = metadataDiscovery.authorizationServerMetadataURLs(for: issuer)

        #expect(
            urls == [
                URL(string: "https://auth.example.com/.well-known/oauth-authorization-server/tenant1")!,
                URL(string: "https://auth.example.com/.well-known/openid-configuration/tenant1")!,
                URL(string: "https://auth.example.com/tenant1/.well-known/openid-configuration")!,
            ])
    }

    @Test("Authorization server metadata discovery URLs for issuer without path")
    func testAuthorizationServerMetadataURLsWithoutPath() {
        let issuer = URL(string: "https://auth.example.com")!
        let urls = metadataDiscovery.authorizationServerMetadataURLs(for: issuer)

        #expect(
            urls == [
                URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!,
                URL(string: "https://auth.example.com/.well-known/openid-configuration")!,
            ])
    }

    @Test("Canonical resource URI normalization")
    func testCanonicalResourceURINormalization() throws {
        let endpoint = URL(string: "HTTPS://MCP.EXAMPLE.COM/?q=1")!
        let canonical = try metadataDiscovery.canonicalResourceURI(from: endpoint)
        #expect(canonical.absoluteString == "https://mcp.example.com")
    }

    @Test("Canonical resource URI supports explicit port and root slash normalization")
    func testCanonicalResourceURIWithExplicitPort() throws {
        let endpoint = URL(string: "HTTPS://MCP.EXAMPLE.COM:8443/")!
        let canonical = try metadataDiscovery.canonicalResourceURI(from: endpoint)
        #expect(canonical.absoluteString == "https://mcp.example.com:8443")
    }

    @Test("Canonical resource URI preserves specific server path")
    func testCanonicalResourceURIPreservesPath() throws {
        let endpoint = URL(string: "https://mcp.example.com/server/mcp")!
        let canonical = try metadataDiscovery.canonicalResourceURI(from: endpoint)
        #expect(canonical.absoluteString == "https://mcp.example.com/server/mcp")
    }

    @Test("Canonical resource URI rejects missing scheme")
    func testCanonicalResourceURIRejectsMissingScheme() {
        #expect(throws: OAuthAuthorizationError.self) {
            _ = try metadataDiscovery.canonicalResourceURI(from: URL(string: "mcp.example.com")!)
        }
    }

    @Test("Canonical resource URI rejects insecure non-loopback http scheme")
    func testCanonicalResourceURIRejectsNonLoopbackHTTP() {
        #expect(throws: OAuthAuthorizationError.self) {
            _ = try metadataDiscovery.canonicalResourceURI(
                from: URL(string: "http://mcp.example.com/resource")!
            )
        }
    }

    @Test("Canonical resource URI allows loopback http scheme")
    func testCanonicalResourceURIAllowsLoopbackHTTP() throws {
        let canonical = try metadataDiscovery.canonicalResourceURI(
            from: URL(string: "http://localhost:8080/mcp")!
        )
        #expect(canonical.absoluteString == "http://localhost:8080/mcp")
    }

    @Test("Canonical resource URI rejects fragment")
    func testCanonicalResourceURIRejectsFragment() {
        #expect(throws: OAuthAuthorizationError.self) {
            _ = try metadataDiscovery.canonicalResourceURI(
                from: URL(string: "https://mcp.example.com#fragment")!
            )
        }
    }

    @Test("Protected resource matching allows same-origin parent resource")
    func testProtectedResourceMatchingParentResource() {
        let resource = URL(string: "https://mcp.example.com")!
        let endpoint = URL(string: "https://mcp.example.com/mcp")!
        #expect(metadataDiscovery.protectedResourceMatches(resource: resource, endpoint: endpoint))
    }

    @Test("Protected resource matching enforces path boundaries")
    func testProtectedResourceMatchingPathBoundary() {
        let resource = URL(string: "https://mcp.example.com/mcp")!
        let validEndpoint = URL(string: "https://mcp.example.com/mcp/tools")!
        let invalidEndpoint = URL(string: "https://mcp.example.com/mcp2")!

        #expect(metadataDiscovery.protectedResourceMatches(resource: resource, endpoint: validEndpoint))
        #expect(!metadataDiscovery.protectedResourceMatches(resource: resource, endpoint: invalidEndpoint))
    }

    @Test("Protected resource matching rejects origin mismatches")
    func testProtectedResourceMatchingOriginMismatch() {
        let resource = URL(string: "https://evil.example.com/mcp")!
        let endpoint = URL(string: "https://mcp.example.com/mcp")!
        #expect(!metadataDiscovery.protectedResourceMatches(resource: resource, endpoint: endpoint))
    }

    @Test("Scope selection prefers challenge scope")
    func testScopeSelection() {
        let selected = DefaultOAuthScopeSelector().selectScopes(
            challengeScope: "files:read",
            scopesSupported: ["files:read", "files:write"]
        )
        #expect(selected == Set(["files:read"]))

        let fallback = DefaultOAuthScopeSelector().selectScopes(
            challengeScope: nil,
            scopesSupported: ["files:read", "files:write"]
        )
        #expect(fallback == Set(["files:read", "files:write"]))

        let omitted = DefaultOAuthScopeSelector().selectScopes(challengeScope: nil, scopesSupported: nil)
        #expect(omitted == nil)
    }

    #if canImport(CryptoKit)
        @Test("private_key_jwt helper builds signed JWT with expected claims")
        func testPrivateKeyJWTAssertionHelper() throws {
            let tokenEndpoint = URL(string: "https://auth.example.com/oauth/token")!
            let assertion = try OAuthConfiguration.makePrivateKeyJWTAssertion(
                clientID: "test-client",
                tokenEndpoint: tokenEndpoint,
                privateKeyPEM: Self.testPrivateKeyPEM,
                audience: "https://auth.example.com",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresIn: 300
            )

            let parts = assertion.split(separator: ".")
            #expect(parts.count == 3)

            let headerData = Self.decodeBase64URL(parts[0])
            let payloadData = Self.decodeBase64URL(parts[1])
            #expect(headerData != nil)
            #expect(payloadData != nil)

            let header = try JSONSerialization.jsonObject(with: headerData!) as? [String: Any]
            let payload = try JSONSerialization.jsonObject(with: payloadData!) as? [String: Any]

            #expect(header?["alg"] as? String == "ES256")
            #expect(header?["typ"] as? String == "JWT")
            #expect(payload?["iss"] as? String == "test-client")
            #expect(payload?["sub"] as? String == "test-client")
            #expect(payload?["aud"] as? String == "https://auth.example.com")
            #expect(payload?["iat"] as? Int == 1_700_000_000)
            #expect(payload?["exp"] as? Int == 1_700_000_300)
            #expect((payload?["jti"] as? String)?.isEmpty == false)
        }
    #endif

    @Test("private_key_jwt helper rejects non-positive lifetime")
    func testPrivateKeyJWTAssertionRejectsNonPositiveLifetime() {
        #expect(throws: OAuthConfiguration.PrivateKeyJWTAssertionError.self) {
            _ = try OAuthConfiguration.makePrivateKeyJWTAssertion(
                clientID: "test-client",
                tokenEndpoint: URL(string: "https://auth.example.com/token")!,
                privateKeyPEM: Self.testPrivateKeyPEM,
                expiresIn: 0
            )
        }
    }

    // MARK: - WWW-Authenticate Parser Edge Cases

    @Test("Parse Bearer returns nil when WWW-Authenticate header is absent")
    func testParseBearerReturnsNilWhenHeaderAbsent() {
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: ["Content-Type": "text/plain"])
        #expect(challenge == nil)
    }

    @Test("Parse Bearer returns nil for empty header value")
    func testParseBearerReturnsNilForEmptyValue() {
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: ["WWW-Authenticate": ""])
        #expect(challenge == nil)
    }

    @Test("Parse Bearer returns empty challenge for bare Bearer with no parameters")
    func testParseBearerBareBearerScheme() {
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: ["WWW-Authenticate": "Bearer"])
        #expect(challenge != nil)
        #expect(challenge?.parameters.isEmpty == true)
    }

    @Test("Parse Bearer header name lookup is case-insensitive")
    func testParseBearerCaseInsensitiveHeaderName() {
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(
            from: ["www-authenticate": "Bearer scope=\"read\""]
        )
        #expect(challenge != nil)
        #expect(challenge?.scope == "read")
    }

    @Test("Parse Bearer returns nil when only non-Bearer schemes present")
    func testParseBearerReturnsNilForNonBearerScheme() {
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(
            from: ["WWW-Authenticate": "Basic realm=\"example\""]
        )
        #expect(challenge == nil)
    }

    // MARK: - Metadata Discovery Edge Cases

    @Test("Protected resource metadata returns empty for non-HTTPS endpoint")
    func testProtectedResourceMetadataRejectsHTTP() {
        let urls = metadataDiscovery.protectedResourceMetadataURLs(
            for: URL(string: "http://remote.example.com/mcp")!
        )
        #expect(urls.isEmpty)
    }

    @Test("Protected resource metadata for root endpoint produces path-specific and root URLs")
    func testProtectedResourceMetadataRootEndpoint() {
        let urls = metadataDiscovery.protectedResourceMetadataURLs(
            for: URL(string: "https://example.com")!
        )
        #expect(urls.count == 2)
        #expect(urls.allSatisfy {
            $0 == URL(string: "https://example.com/.well-known/oauth-protected-resource")!
        })
    }

    @Test("Protected resource metadata allows loopback HTTP")
    func testProtectedResourceMetadataAllowsLoopbackHTTP() {
        let urls = metadataDiscovery.protectedResourceMetadataURLs(
            for: URL(string: "http://localhost:8080/mcp")!
        )
        #expect(!urls.isEmpty)
    }

    @Test("Authorization server metadata returns empty for non-HTTPS issuer")
    func testAuthorizationServerMetadataRejectsHTTP() {
        let urls = metadataDiscovery.authorizationServerMetadataURLs(
            for: URL(string: "http://remote.example.com")!
        )
        #expect(urls.isEmpty)
    }

    @Test("Authorization server fallback issuer derives origin from endpoint")
    func testAuthorizationServerFallbackIssuer() throws {
        let issuer = try metadataDiscovery.authorizationServerFallbackIssuer(
            from: URL(string: "https://mcp.example.com:8443/server/mcp")!
        )
        #expect(issuer.absoluteString == "https://mcp.example.com:8443")
    }

    @Test("Authorization server fallback issuer normalizes case and strips query")
    func testAuthorizationServerFallbackIssuerNormalization() throws {
        let issuer = try metadataDiscovery.authorizationServerFallbackIssuer(
            from: URL(string: "HTTPS://AUTH.EXAMPLE.COM/path?q=1")!
        )
        #expect(issuer.absoluteString == "https://auth.example.com")
    }

    @Test("Authorization server fallback issuer rejects non-HTTPS non-loopback")
    func testAuthorizationServerFallbackIssuerRejectsInsecure() {
        #expect(throws: OAuthAuthorizationError.self) {
            _ = try metadataDiscovery.authorizationServerFallbackIssuer(
                from: URL(string: "http://remote.example.com/mcp")!
            )
        }
    }

    @Test("Protected resource matching with port mismatch")
    func testProtectedResourceMatchingPortMismatch() {
        let resource = URL(string: "https://mcp.example.com:8443")!
        let endpoint = URL(string: "https://mcp.example.com:9443/mcp")!
        #expect(!metadataDiscovery.protectedResourceMatches(resource: resource, endpoint: endpoint))
    }

    @Test("Protected resource matching with exact path")
    func testProtectedResourceMatchingExactPath() {
        let resource = URL(string: "https://mcp.example.com/mcp")!
        let endpoint = URL(string: "https://mcp.example.com/mcp")!
        #expect(metadataDiscovery.protectedResourceMatches(resource: resource, endpoint: endpoint))
    }

    // MARK: - Scope Selector Edge Cases

    @Test("parseScopeString splits on whitespace and ignores empty tokens")
    func testParseScopeString() {
        let scopes = DefaultOAuthScopeSelector().parseScopeString("files:read  files:write\tprofile")
        #expect(scopes == Set(["files:read", "files:write", "profile"]))
    }

    @Test("parseScopeString returns empty set for blank string")
    func testParseScopeStringEmpty() {
        let scopes = DefaultOAuthScopeSelector().parseScopeString("   ")
        #expect(scopes.isEmpty)
    }

    @Test("serialize produces sorted space-separated string")
    func testSerializeScopes() {
        let result = DefaultOAuthScopeSelector().serialize(Set(["write", "read", "admin"]))
        #expect(result == "admin read write")
    }

    @Test("serialize returns nil for empty set")
    func testSerializeScopesEmpty() {
        let result = DefaultOAuthScopeSelector().serialize(Set())
        #expect(result == nil)
    }

    @Test("selectScopes returns nil for empty challenge scope string")
    func testSelectScopesEmptyChallengeScope() {
        let result = DefaultOAuthScopeSelector().selectScopes(
            challengeScope: "   ",
            scopesSupported: ["files:read"]
        )
        #expect(result == nil)
    }

    @Test("selectScopes returns nil for empty scopesSupported array")
    func testSelectScopesEmptyScopesSupported() {
        let result = DefaultOAuthScopeSelector().selectScopes(
            challengeScope: nil,
            scopesSupported: []
        )
        #expect(result == nil)
    }

    // MARK: - Token Type Validation

    @Test("makePrivateKeyJWTAssertion — token type empty string is rejected")
    func testEmptyTokenTypeIsRejected() throws {
        // OAuthTokenResponse decodes token_type from JSON; simulate an empty value via
        // direct struct construction using the internal initializer path.
        let json = #"{"access_token":"tok","token_type":"","expires_in":3600}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        // The token_type is empty; the authorizer guard must reject this.
        let tokenType = decoded.tokenType.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = !tokenType.isEmpty
            && tokenType.caseInsensitiveCompare("Bearer") == .orderedSame
        #expect(!isValid, "Empty token_type must not be accepted as Bearer")
    }

    @Test("Token type whitespace-only is rejected")
    func testWhitespaceTokenTypeIsRejected() throws {
        let json = #"{"access_token":"tok","token_type":"   ","expires_in":3600}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        let tokenType = decoded.tokenType.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = !tokenType.isEmpty
            && tokenType.caseInsensitiveCompare("Bearer") == .orderedSame
        #expect(!isValid, "Whitespace-only token_type must not be accepted as Bearer")
    }

    // MARK: - InMemoryTokenStorage

    @Test("InMemoryTokenStorage save and load round-trip")
    func testTokenStorageSaveAndLoad() {
        let storage = InMemoryTokenStorage()
        #expect(storage.load() == nil)

        let token = OAuthAccessToken(
            value: "access-123",
            tokenType: "Bearer",
            expiresAt: nil,
            scopes: ["read"],
            authorizationServer: nil,
            refreshToken: nil
        )
        storage.save(token)

        let loaded = storage.load()
        #expect(loaded?.value == "access-123")
        #expect(loaded?.tokenType == "Bearer")
        #expect(loaded?.scopes == Set(["read"]))
    }

    @Test("InMemoryTokenStorage clear removes stored token")
    func testTokenStorageClear() {
        let storage = InMemoryTokenStorage()
        let token = OAuthAccessToken(
            value: "access-456",
            tokenType: "Bearer",
            expiresAt: nil,
            scopes: [],
            authorizationServer: nil,
            refreshToken: nil
        )
        storage.save(token)
        #expect(storage.load() != nil)

        storage.clear()
        #expect(storage.load() == nil)
    }

    @Test("InMemoryTokenStorage save overwrites previous token")
    func testTokenStorageSaveOverwrites() {
        let storage = InMemoryTokenStorage()
        let first = OAuthAccessToken(
            value: "first",
            tokenType: "Bearer",
            expiresAt: nil,
            scopes: [],
            authorizationServer: nil,
            refreshToken: nil
        )
        let second = OAuthAccessToken(
            value: "second",
            tokenType: "Bearer",
            expiresAt: nil,
            scopes: [],
            authorizationServer: nil,
            refreshToken: nil
        )
        storage.save(first)
        storage.save(second)

        #expect(storage.load()?.value == "second")
    }

    // MARK: - Proactive Token Refresh

    @Test("prepareAuthorization does nothing when proactiveRefreshWindowSeconds is zero")
    func testPrepareAuthorizationSkipsWhenWindowIsZero() async throws {
        let storage = InMemoryTokenStorage()
        // Token expires in 50 s — within a large proactive window but not within the 30 s default skew.
        storage.save(OAuthAccessToken(
            value: "original-token",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(50),
            scopes: [],
            authorizationServer: nil,
            refreshToken: "some-refresh-token"
        ))
        let config = OAuthConfiguration(
            authentication: .none(clientID: "client"),
            proactiveRefreshWindowSeconds: 0
        )
        let authorizer = OAuthAuthorizer(configuration: config, tokenStorage: storage)

        try await authorizer.prepareAuthorization(
            for: URL(string: "https://example.com/mcp")!,
            session: .shared
        )

        // Token must be unchanged — proactive refresh is disabled.
        #expect(storage.load()?.value == "original-token")
    }

    @Test("prepareAuthorization does nothing without cached authorization server metadata")
    func testPrepareAuthorizationSkipsWithoutCachedASMetadata() async throws {
        let storage = InMemoryTokenStorage()
        // Token expires in 50 s — within the 400 s proactive window.
        storage.save(OAuthAccessToken(
            value: "original-token",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(50),
            scopes: [],
            authorizationServer: nil,
            refreshToken: "some-refresh-token"
        ))
        let config = OAuthConfiguration(
            authentication: .none(clientID: "client"),
            proactiveRefreshWindowSeconds: 400
        )
        // No handleChallenge call → authorizationServerMetadata remains nil.
        let authorizer = OAuthAuthorizer(configuration: config, tokenStorage: storage)

        try await authorizer.prepareAuthorization(
            for: URL(string: "https://example.com/mcp")!,
            session: .shared
        )

        // Token must be unchanged — refresh requires cached AS metadata.
        #expect(storage.load()?.value == "original-token")
    }

    // MARK: - WWW-Authenticate Bare Scheme Detection

    @Test("Bare scheme Digest terminates preceding Bearer parameter collection")
    func testBareSchemeTerminatesBearer() {
        // "Digest" has no params and no '=', so it must start a new challenge and stop
        // the Bearer parameter collector before "scope" from the second Bearer leaks in.
        let header = #"Bearer scope="a", Digest, Bearer scope="b""#
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(
            from: ["WWW-Authenticate": header])
        #expect(challenge != nil)
        // The outer loop stops at the first Bearer, so scope must be "a", not "b".
        #expect(challenge?.scope == "a")
    }

    @Test("Non-Bearer leading scheme followed by Bearer is parsed correctly")
    func testNonBearerLeadingSchemeFollowedByBearer() {
        let header = #"SomeScheme, Bearer scope="test""#
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(
            from: ["WWW-Authenticate": header])
        #expect(challenge != nil)
        #expect(challenge?.scope == "test")
    }

    // MARK: - Private IP Blocking

    @Test("privateIPAddressBlocked error has informative description")
    func testPrivateIPAddressBlockedErrorDescription() {
        let url = "https://169.254.169.254/.well-known/oauth-protected-resource"
        let error = OAuthAuthorizationError.privateIPAddressBlocked(
            context: "Protected resource metadata URL", url: url)
        let description = error.errorDescription ?? ""
        #expect(description.contains("private or reserved IP"))
        #expect(description.contains(url))
    }

    @Test("cimdNotSupported is thrown when CIMD URL provided but server does not support it")
    func testCIMDNotSupportedError() {
        // Verify the error case exists and its description is meaningful.
        let error = OAuthAuthorizationError.cimdNotSupported(
            clientID: "https://client.example.com/client-metadata.json")
        let description = error.errorDescription ?? ""
        #expect(description.contains("Client ID Metadata Document"))
        #expect(description.contains("client.example.com"))
    }

    // MARK: - BearerTokenValidator Audience and Expiry Tests

    private let testResourceMetadataURL =
        URL(string: "https://api.example.com/.well-known/oauth-protected-resource")!
    private let testResourceIdentifier = URL(string: "https://api.example.com")!

    private func makeBearerValidator(
        tokenValidator: @escaping BearerTokenValidator.TokenValidator
    ) -> BearerTokenValidator {
        BearerTokenValidator(
            resourceMetadataURL: testResourceMetadataURL,
            resourceIdentifier: testResourceIdentifier,
            tokenValidator: tokenValidator
        )
    }

    private func makeRequest(authorization: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.authorization: authorization],
            path: "/mcp"
        )
    }

    private func makeContext() -> HTTPValidationContext {
        HTTPValidationContext(httpMethod: "POST", isInitializationRequest: false)
    }

    @Test("BearerTokenValidator allows valid token with nil audience (opaque token)")
    func testBearerValidatorNilAudienceAllows() {
        let validator = makeBearerValidator { _, _, _ in
            .valid(BearerTokenInfo(audience: nil))
        }
        let result = validator.validate(makeRequest(authorization: "Bearer tok"), context: makeContext())
        #expect(result == nil)
    }

    @Test("BearerTokenValidator allows token with matching audience")
    func testBearerValidatorMatchingAudienceAllows() {
        let validator = makeBearerValidator { _, _, _ in
            .valid(BearerTokenInfo(audience: ["https://api.example.com"]))
        }
        let result = validator.validate(makeRequest(authorization: "Bearer tok"), context: makeContext())
        #expect(result == nil)
    }

    @Test("BearerTokenValidator allows token when one aud entry matches")
    func testBearerValidatorOneOfMultipleAudienceMatches() {
        let validator = makeBearerValidator { _, _, _ in
            .valid(BearerTokenInfo(audience: ["https://other.example.com", "https://api.example.com"]))
        }
        let result = validator.validate(makeRequest(authorization: "Bearer tok"), context: makeContext())
        #expect(result == nil)
    }

    @Test("BearerTokenValidator returns 401 invalid_token when audience does not match")
    func testBearerValidatorAudienceMismatchReturns401() {
        let validator = makeBearerValidator { _, _, _ in
            .valid(BearerTokenInfo(audience: ["https://other.example.com"]))
        }
        let result = validator.validate(makeRequest(authorization: "Bearer tok"), context: makeContext())
        #expect(result?.statusCode == 401)
        let challenge = result?.headers[HTTPHeaderName.wwwAuthenticate]
        #expect(challenge?.contains("error=\"invalid_token\"") == true)
        #expect(challenge?.contains("Token audience mismatch") == true)
    }

    @Test("BearerTokenValidator returns 401 invalid_token when token is expired")
    func testBearerValidatorExpiredTokenReturns401() {
        let pastDate = Date(timeIntervalSinceNow: -3600)
        let validator = makeBearerValidator { _, _, _ in
            .valid(BearerTokenInfo(expiresAt: pastDate))
        }
        let result = validator.validate(makeRequest(authorization: "Bearer tok"), context: makeContext())
        #expect(result?.statusCode == 401)
        let challenge = result?.headers[HTTPHeaderName.wwwAuthenticate]
        #expect(challenge?.contains("error=\"invalid_token\"") == true)
        #expect(challenge?.contains("Token has expired") == true)
    }

    @Test("BearerTokenValidator allows token that has not yet expired")
    func testBearerValidatorNonExpiredTokenAllows() {
        let futureDate = Date(timeIntervalSinceNow: 3600)
        let validator = makeBearerValidator { _, _, _ in
            .valid(BearerTokenInfo(expiresAt: futureDate))
        }
        let result = validator.validate(makeRequest(authorization: "Bearer tok"), context: makeContext())
        #expect(result == nil)
    }

    @Test("BearerTokenValidator checks expiry before audience")
    func testBearerValidatorExpiryCheckedBeforeAudience() {
        let pastDate = Date(timeIntervalSinceNow: -1)
        let validator = makeBearerValidator { _, _, _ in
            // Expired token but matching audience — expiry should win
            .valid(BearerTokenInfo(audience: ["https://api.example.com"], expiresAt: pastDate))
        }
        let result = validator.validate(makeRequest(authorization: "Bearer tok"), context: makeContext())
        #expect(result?.statusCode == 401)
        let challenge = result?.headers[HTTPHeaderName.wwwAuthenticate]
        #expect(challenge?.contains("Token has expired") == true)
    }
}
