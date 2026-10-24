import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal protocol for fetching OAuth discovery metadata.
protocol OAuthDiscoveryFetching: Sendable {
    var metadataDiscovery: any OAuthMetadataDiscovering { get }
    func fetchProtectedResourceMetadata(candidates: [URL], fallbackIssuer: URL?, session: URLSession) async throws -> OAuthProtectedResourceMetadata
    func fetchAuthorizationServerMetadata(candidates: [URL], session: URLSession) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata)
}

/// Stateless OAuth metadata fetcher.
///
/// Fetches Protected Resource Metadata (RFC 9728) and Authorization Server Metadata
/// (RFC 8414 / OIDC Discovery 1.0) from ordered candidate URL lists.
/// Cache management is the caller's responsibility.
struct OAuthDiscoveryClient: Sendable {
    let metadataDiscovery: any OAuthMetadataDiscovering
    let urlValidator: OAuthURLValidator

    init(
        metadataDiscovery: any OAuthMetadataDiscovering,
        urlValidator: OAuthURLValidator
    ) {
        self.metadataDiscovery = metadataDiscovery
        self.urlValidator = urlValidator
    }

    /// Fetches Protected Resource Metadata from the first candidate that returns a valid response.
    ///
    /// If all candidates fail and `fallbackIssuer` is provided, returns synthetic metadata
    /// using that issuer as the authorization server — for servers that do not expose a
    /// PRM document at any well-known path.
    func fetchProtectedResourceMetadata(
        candidates: [URL],
        fallbackIssuer: URL?,
        session: URLSession
    ) async throws -> OAuthProtectedResourceMetadata {
        let decoder = JSONDecoder()
        for url in candidates {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode)
                else {
                    continue
                }

                let metadata = try decoder.decode(OAuthProtectedResourceMetadata.self, from: data)
                guard !metadata.authorizationServers.isEmpty else { continue }
                return metadata
            } catch let error as OAuthAuthorizationError {
                throw error
            } catch {
                continue
            }
        }
        if let fallbackIssuer {
            return OAuthProtectedResourceMetadata(
                resource: nil,
                authorizationServers: [fallbackIssuer],
                scopesSupported: nil
            )
        }
        throw OAuthAuthorizationError.metadataDiscoveryFailed
    }

    /// Fetches Authorization Server Metadata from candidates, preferring a response whose
    /// `issuer` matches the candidate URL (RFC 8414 §3). If no candidate produces a matching
    /// issuer, the first valid response is accepted and its own `issuer` is used as the
    /// server identity — accommodating servers that serve metadata at one host but advertise
    /// a different issuer.
    func fetchAuthorizationServerMetadata(
        candidates: [URL],
        session: URLSession
    ) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        let decoder = JSONDecoder()
        var firstValid: (server: URL, metadata: OAuthAuthorizationServerMetadata)?

        for candidateServer in candidates {
            guard (try? urlValidator.validateAuthorizationServer(
                candidateServer, context: "Authorization server issuer")) != nil
            else {
                continue
            }
            if let host = URLComponents(url: candidateServer, resolvingAgainstBaseURL: false)?
                .host?.lowercased(), urlValidator.isPrivateIPHost(host)
            {
                continue
            }

            for metadataURL in metadataDiscovery.authorizationServerMetadataURLs(
                for: candidateServer)
            {
                var request = URLRequest(url: metadataURL)
                request.httpMethod = "GET"
                request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)

                do {
                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                        (200..<300).contains(httpResponse.statusCode)
                    else {
                        continue
                    }

                    let asMetadata = try decoder.decode(
                        OAuthAuthorizationServerMetadata.self, from: data)

                    // Prefer metadata whose issuer matches the candidate URL (RFC 8414 §3).
                    let issuerMatches =
                        asMetadata.issuer == nil
                        || asMetadata.issuer?.absoluteString.lowercased()
                            == candidateServer.absoluteString.lowercased()
                    if issuerMatches {
                        return (server: candidateServer, metadata: asMetadata)
                    }
                    // Keep as fallback in case no issuer-matching candidate is found.
                    if firstValid == nil {
                        let server = asMetadata.issuer ?? candidateServer
                        firstValid = (server: server, metadata: asMetadata)
                    }
                } catch {
                    continue
                }
            }
        }

        if let firstValid {
            return firstValid
        }
        throw OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
    }
}

extension OAuthDiscoveryClient: OAuthDiscoveryFetching {}
