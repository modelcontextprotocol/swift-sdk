import Foundation
import Testing

@testable import MCP

@Suite("Open types")
struct OpenTypeTests {
    @Test("Grant types carry their grant_type values")
    func grantTypes() {
        #expect(OAuthConfiguration.GrantType.authorizationCode.rawValue == "authorization_code")
        #expect(OAuthConfiguration.GrantType.clientCredentials.rawValue == "client_credentials")
        #expect(
            OAuthConfiguration.GrantType.jwtBearer.rawValue == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        #expect(OAuthConfiguration.GrantType.jwtBearer != .clientCredentials)
    }

    @Test("Token endpoint authentication keeps its client ID and method")
    func tokenEndpointAuthentication() {
        typealias Authentication = OAuthConfiguration.TokenEndpointAuthentication
        let basic = Authentication.clientSecretBasic(clientID: "c", clientSecret: "s")
        #expect(basic.clientID == "c")
        #expect(basic.methodName == "client_secret_basic")
        #expect(basic == .clientSecretBasic(clientID: "c", clientSecret: "s"))
        #expect(basic != .clientSecretBasic(clientID: "c", clientSecret: "t"))
        #expect(basic != .clientSecretPost(clientID: "c", clientSecret: "s"))
        #expect(Authentication.none(clientID: "c").methodName == "none")
        let jwt = Authentication.privateKeyJWT(clientID: "c") { _, _ in "a" }
        #expect(jwt.methodName == "private_key_jwt")
        #expect(jwt == .privateKeyJWT(clientID: "c") { _, _ in "b" })
        #expect(jwt != .privateKeyJWT(clientID: "d") { _, _ in "a" })
    }

    @Test("Registration replaces the client ID and keeps the method")
    func registered() {
        typealias Authentication = OAuthConfiguration.TokenEndpointAuthentication
        let post = Authentication.clientSecretPost(clientID: "", clientSecret: "old")
        #expect(post.registered(clientID: "new", clientSecret: nil) == .clientSecretPost(clientID: "new", clientSecret: "old"))
        #expect(post.registered(clientID: "new", clientSecret: "s") == .clientSecretPost(clientID: "new", clientSecret: "s"))
        #expect(Authentication.none(clientID: "").registered(clientID: "new", clientSecret: "s") == .none(clientID: "new"))
    }

    @Test("The signing algorithm is the JWS alg value")
    func signingAlgorithm() {
        #expect(OAuthConfiguration.PrivateKeyJWTSigningAlgorithm.ES256.rawValue == "ES256")
    }

    @Test("Bearer validation results compare by outcome")
    func bearerResults() {
        #expect(BearerTokenValidationResult.invalidToken() == .invalidToken(errorDescription: nil))
        #expect(BearerTokenValidationResult.invalidToken() != .malformedRequest())
        #expect(
            BearerTokenValidationResult.insufficientScope(requiredScopes: ["a"])
                != .insufficientScope(requiredScopes: ["b"]))
        #expect(BearerTokenValidationResult.valid(BearerTokenInfo()) == .valid(BearerTokenInfo()))
    }

    @Test("A mode the SDK does not know round-trips")
    func unknownModes() throws {
        let toolChoice = try JSONDecoder().decode(
            CreateSamplingMessage.ToolChoice.self, from: Data(#"{"mode":"parallel"}"#.utf8))
        #expect(toolChoice.mode == CreateSamplingMessage.ToolChoice.Mode(rawValue: "parallel"))
        #expect(String(decoding: try JSONEncoder().encode(toolChoice), as: UTF8.self) == #"{"mode":"parallel"}"#)
        let mode = try JSONDecoder().decode(Elicitation.Mode.self, from: Data(#""voice""#.utf8))
        #expect(mode.rawValue == "voice")
        #expect(mode != .form && mode != .url)
        #expect(String(decoding: try JSONEncoder().encode(Elicitation.Mode.url), as: UTF8.self) == #""url""#)
    }
}
