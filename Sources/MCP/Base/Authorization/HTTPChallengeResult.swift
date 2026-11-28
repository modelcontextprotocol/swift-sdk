import Foundation

/// How ``HTTPClientTransport`` answers an authorization challenge: the result
/// of ``HTTPClientAuthorizer/handleChallenge(statusCode:headers:endpoint:operationKey:sentAuthorization:session:)``.
///
/// - SeeAlso: https://www.rfc-editor.org/rfc/rfc9449#section-9
public struct HTTPChallengeResult: Hashable, Sendable {
    /// Whether to send the challenged request again.
    public var retry: Bool

    /// Whether the retry only answers a resource server's DPoP `use_dpop_nonce`
    /// challenge with the nonce it sent, keeping the token (RFC 9449 §9).
    ///
    /// ``HTTPClientTransport`` allows one such retry per request without
    /// counting it against ``HTTPClientAuthorizer/maxAuthorizationAttempts``;
    /// a second one fails the request. The transport ignores this value when
    /// ``retry`` is `false`.
    public var isDPoPNonceRetry: Bool

    /// Creates a challenge result.
    ///
    /// - Parameters:
    ///   - retry: Whether to send the challenged request again.
    ///   - isDPoPNonceRetry: Whether the retry only answers a DPoP nonce challenge.
    public init(retry: Bool, isDPoPNonceRetry: Bool = false) {
        self.retry = retry
        self.isDPoPNonceRetry = isDPoPNonceRetry
    }
}

extension HTTPChallengeResult {
    /// Whether a challenge is a resource server's `use_dpop_nonce`, read with
    /// ``DefaultOAuthWWWAuthenticateParser``, with the `DPoP-Nonce` header it
    /// requires (RFC 9449 §9). Without the header no retry can carry a nonce,
    /// so the challenge is an ordinary one.
    static func isDPoPNonceChallenge(statusCode: Int, headers: [String: String]) -> Bool {
        statusCode == 401
            && DefaultOAuthWWWAuthenticateParser()
                .parseChallenge(scheme: OAuthTokenType.dpop, from: headers)?.error
                == OAuthErrorCode.useDPoPNonce
            && headers.contains {
                $0.key.caseInsensitiveCompare(HTTPHeaderName.dpopNonce) == .orderedSame
                    && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }
}
