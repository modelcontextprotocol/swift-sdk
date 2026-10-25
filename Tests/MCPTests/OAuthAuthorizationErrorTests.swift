import Foundation
import Testing

@testable import MCP

@Suite("OAuthAuthorizationError")
struct OAuthAuthorizationErrorTests {
    private func throwing(_ error: OAuthAuthorizationError) throws {
        throw error
    }

    @Test("A static member catches every error with its code")
    func catchByCode() {
        do {
            try throwing(.tokenRequestFailed(statusCode: 400, oauthError: "invalid_grant"))
            Issue.record("Expected an error")
        } catch OAuthAuthorizationError.dpopRequired {
            Issue.record("Matched another code")
        } catch OAuthAuthorizationError.tokenRequestFailed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("A switch matches by code")
    func switchByCode() {
        let error = OAuthAuthorizationError.privateIPAddressBlocked(context: "Token endpoint", url: "https://10.0.0.1")
        switch error {
        case .privateIPAddressBlocked: break
        default: Issue.record("Expected privateIPAddressBlocked")
        }
        switch error.code {
        case .privateIPAddressBlocked: break
        default: Issue.record("Expected privateIPAddressBlocked")
        }
    }

    @Test("Equality compares every property")
    func equality() {
        let failed = OAuthAuthorizationError.tokenRequestFailed(statusCode: 400, oauthError: nil)
        #expect(failed == .tokenRequestFailed(statusCode: 400, oauthError: nil))
        #expect(failed != .tokenRequestFailed(statusCode: 401, oauthError: nil))
        #expect(failed != .tokenRequestFailed)
        #expect(OAuthAuthorizationError.dpopRequired == .dpopRequired)
    }

    @Test("The factories keep their details")
    func details() {
        let mismatch = OAuthAuthorizationError.issuedTokenTypeMismatch(expected: "a", actual: nil)
        #expect(mismatch.code == .issuedTokenTypeMismatch)
        #expect(mismatch.expected == ["a"])
        #expect(mismatch.actual == [])
        #expect(mismatch.errorDescription == "Token exchange issued no token type, expected a")
        let failed = OAuthAuthorizationError.tokenRequestFailed(statusCode: 400, oauthError: "invalid_grant")
        #expect(failed.statusCode == 400)
        #expect(failed.oauthError == "invalid_grant")
        #expect(failed.errorDescription == "Token request failed with status 400 (oauth_error: invalid_grant)")
        let blocked = OAuthAuthorizationError.insecureOAuthEndpoint(context: "Token endpoint", url: "http://a")
        #expect(blocked.errorDescription == "Token endpoint must use https or loopback http: http://a")
    }

    @Test("A code the SDK does not know has a description")
    func unknownCode() {
        let error = OAuthAuthorizationError(code: .init(rawValue: "deviceCodeExpired"))
        #expect(error.errorDescription == "OAuth authorization failed: deviceCodeExpired")
        switch error.code {
        case .tokenRequestFailed: Issue.record("Matched a known code")
        default: break
        }
    }
}
