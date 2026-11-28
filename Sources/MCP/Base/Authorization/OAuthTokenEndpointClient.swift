import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal protocol for making OAuth token endpoint requests.
protocol OAuthTokenRequesting: Sendable {
    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        dpop: DPoPProofSigner?,
        session: URLSession
    ) async throws -> OAuthTokenResponse
}

/// Stateless OAuth token endpoint HTTP client.
///
/// Handles the low-level HTTP mechanics of making token requests.
struct OAuthTokenEndpointClient: Sendable {
    let urlValidator: OAuthURLValidator

    init(urlValidator: OAuthURLValidator) {
        self.urlValidator = urlValidator
    }

    /// Makes a token request to the given endpoint.
    ///
    /// With `dpop`, the request carries a DPoP proof; a `use_dpop_nonce`
    /// error is retried once with the server's nonce (RFC 9449 §8), and the
    /// response may issue a `DPoP` token.
    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        dpop: DPoPProofSigner? = nil,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        var retriedWithNonce = false
        while true {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue(ContentType.formURLEncoded, forHTTPHeaderField: HTTPHeaderName.contentType)
            urlRequest.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)

            try await authentication.apply(
                to: &urlRequest,
                bodyParameters: &parameters,
                tokenEndpoint: endpoint
            )
            urlRequest.httpBody = OAuthFormEncoding.encode(parameters)
            if let dpop {
                urlRequest.setValue(
                    try dpop.proof(
                        method: "POST", url: endpoint, accessToken: nil,
                        server: .authorizationServer),
                    forHTTPHeaderField: HTTPHeaderName.dpop)
            }

            let (data, response) = try await session.oauthData(
                for: urlRequest, redirects: .none, validator: urlValidator)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OAuthAuthorizationError.tokenRequestFailed(statusCode: -1, oauthError: nil)
            }
            let nonce = dpop?.recordNonce(
                from: Self.headers(of: httpResponse), for: endpoint, server: .authorizationServer)

            guard (200..<300).contains(httpResponse.statusCode) else {
                let oauthError =
                    (try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data))?.error
                if httpResponse.statusCode == 400, oauthError == OAuthErrorCode.useDPoPNonce,
                    nonce != nil, !retriedWithNonce
                {
                    retriedWithNonce = true
                    continue
                }
                throw OAuthAuthorizationError.tokenRequestFailed(
                    statusCode: httpResponse.statusCode,
                    oauthError: oauthError
                )
            }

            let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
            guard !decoded.accessToken.isEmpty else {
                throw OAuthAuthorizationError.tokenResponseInvalid
            }
            let tokenType = decoded.tokenType
            let isBearer = tokenType.caseInsensitiveCompare(OAuthTokenType.bearer) == .orderedSame
            // A DPoP token answers only a request that carried a proof.
            let isDPoP =
                dpop != nil
                && tokenType.caseInsensitiveCompare(OAuthTokenType.dpop) == .orderedSame
            guard isBearer || isDPoP else {
                throw OAuthAuthorizationError.tokenResponseInvalid
            }
            return decoded
        }
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return headers
    }
}

extension OAuthTokenEndpointClient: OAuthTokenRequesting {}

/// `application/x-www-form-urlencoded` bodies of token requests.
enum OAuthFormEncoding {
    static func encode(_ params: [String: String]) -> Data {
        let body = params
            .sorted { $0.key < $1.key }
            .map { key, value in "\(percentEncode(key))=\(percentEncode(value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func percentEncode(_ string: String) -> String {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
