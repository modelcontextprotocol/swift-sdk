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
    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(ContentType.formURLEncoded, forHTTPHeaderField: HTTPHeaderName.contentType)
        urlRequest.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)

        try await authentication.apply(
            to: &urlRequest,
            bodyParameters: &parameters,
            tokenEndpoint: endpoint
        )
        urlRequest.httpBody = encodeForm(parameters)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthAuthorizationError.tokenRequestFailed(statusCode: -1, oauthError: nil)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let oauthError =
                (try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data))?.error
            throw OAuthAuthorizationError.tokenRequestFailed(
                statusCode: httpResponse.statusCode,
                oauthError: oauthError
            )
        }

        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard !decoded.accessToken.isEmpty else {
            throw OAuthAuthorizationError.tokenResponseInvalid
        }
        let tokenType = decoded.tokenType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenType.isEmpty,
            tokenType.caseInsensitiveCompare(OAuthTokenType.bearer) == .orderedSame
        else {
            throw OAuthAuthorizationError.tokenResponseInvalid
        }
        return decoded
    }

    private func encodeForm(_ params: [String: String]) -> Data {
        let body = params
            .sorted { $0.key < $1.key }
            .map { key, value in "\(percentEncode(key))=\(percentEncode(value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func percentEncode(_ string: String) -> String {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

extension OAuthTokenEndpointClient: OAuthTokenRequesting {}
