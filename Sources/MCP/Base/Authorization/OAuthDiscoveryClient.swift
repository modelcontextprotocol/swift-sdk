import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal protocol for fetching OAuth discovery metadata.
protocol OAuthDiscoveryFetching: Sendable {
    var metadataDiscovery: any OAuthMetadataDiscovering { get }
    func fetchProtectedResourceMetadata(candidates: [URL], session: URLSession) async throws -> OAuthProtectedResourceMetadata
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
    func fetchProtectedResourceMetadata(
        candidates: [URL],
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
        throw OAuthAuthorizationError.metadataDiscoveryFailed
    }

    /// Fetches Authorization Server Metadata from the first candidate that returns a valid response.
    func fetchAuthorizationServerMetadata(
        candidates: [URL],
        session: URLSession
    ) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        let decoder = JSONDecoder()
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

                    // RFC 8414 §3: issuer field must match the candidate server URL.
                    // Absent issuer is tolerated (some servers omit it).
                    if let metadataIssuer = asMetadata.issuer {
                        guard metadataIssuer.absoluteString.lowercased()
                            == candidateServer.absoluteString.lowercased()
                        else {
                            continue
                        }
                    }

                    return (server: candidateServer, metadata: asMetadata)
                } catch {
                    continue
                }
            }
        }
        throw OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
    }
}

extension OAuthDiscoveryClient: OAuthDiscoveryFetching {}
