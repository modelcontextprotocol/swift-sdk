import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension HTTPClientAuthorizer {
    /// Whether to retry the request, for the GET stream of
    /// ``HTTPClientTransport``, which counts every challenge as an
    /// authorization attempt.
    func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        sentAuthorization: String?,
        session: URLSession
    ) async throws -> Bool {
        let result: HTTPChallengeResult = try await handleChallenge(
            statusCode: statusCode, headers: headers, endpoint: endpoint, operationKey: operationKey,
            sentAuthorization: sentAuthorization, session: session)
        return result.retry
    }
}
