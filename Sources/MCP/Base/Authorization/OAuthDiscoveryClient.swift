import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal protocol for fetching OAuth discovery metadata.
protocol OAuthDiscoveryFetching: Sendable {
    var metadataDiscovery: any OAuthMetadataDiscovering { get }
    func fetchProtectedResourceMetadata(candidates: [URL], fallbackIssuer: URL?, session: URLSession) async throws -> OAuthProtectedResourceMetadata
    func fetchAuthorizationServerMetadata(candidates: [URL], trustedIssuer: URL?, reportRefused: Bool, session: URLSession) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata)
}

extension OAuthDiscoveryFetching {
    func fetchAuthorizationServerMetadata(
        candidates: [URL], session: URLSession
    ) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        try await fetchAuthorizationServerMetadata(candidates: candidates, trustedIssuer: nil, session: session)
    }

    func fetchAuthorizationServerMetadata(
        candidates: [URL], trustedIssuer: URL?, session: URLSession
    ) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        try await fetchAuthorizationServerMetadata(
            candidates: candidates, trustedIssuer: trustedIssuer, reportRefused: true, session: session)
    }
}

/// Metadata could not be fetched: a candidate failed with a network error,
/// a status other than 404 or 410, or a body that is not metadata. Unlike
/// ``OAuthAuthorizationError/metadataDiscoveryFailed`` it says nothing about
/// whether the server publishes metadata, so the SDK does not fall back to
/// default endpoints.
struct OAuthMetadataUnavailable: LocalizedError, Sendable {
    let url: URL
    let reason: String

    var errorDescription: String? { "Authorization metadata at \(url.absoluteString) is unavailable: \(reason)" }
}

/// One discovery GET: the metadata, a definitive absence (404 or 410), or
/// an error that says nothing about the server.
enum OAuthMetadataFetch<Metadata> {
    case found(Metadata)
    case absent
    case unavailable(OAuthMetadataUnavailable)
}

extension OAuthMetadataFetch {
    /// Redirects are followed only to `https` hosts that are not private
    /// addresses.
    static func fetch(
        _ url: URL, session: URLSession, validator: OAuthURLValidator, decode: (Data) throws -> Metadata?
    ) async throws -> OAuthMetadataFetch {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.oauthData(for: request, redirects: .validated, validator: validator)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OAuthAuthorizationError {
            throw error
        } catch {
            return .unavailable(OAuthMetadataUnavailable(url: url, reason: error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .unavailable(OAuthMetadataUnavailable(url: url, reason: "not an HTTP response"))
        }
        if [404, 410].contains(http.statusCode) { return .absent }
        guard (200..<300).contains(http.statusCode) else {
            return .unavailable(OAuthMetadataUnavailable(url: url, reason: "HTTP \(http.statusCode)"))
        }
        guard let metadata = try? decode(data) else {
            return .unavailable(OAuthMetadataUnavailable(url: url, reason: "the body is not valid metadata"))
        }
        return .found(metadata)
    }
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
    /// When every candidate answers 404 or 410 and `fallbackIssuer` is
    /// provided, returns synthetic metadata using that issuer as the
    /// authorization server, for servers that do not expose a PRM document at
    /// any well-known path.
    ///
    /// - Throws: `CancellationError` when cancelled; ``OAuthMetadataUnavailable``
    ///   when a candidate failed otherwise and none succeeded;
    ///   ``OAuthAuthorizationError/metadataDiscoveryFailed`` when every
    ///   candidate is absent and there is no fallback.
    func fetchProtectedResourceMetadata(
        candidates: [URL],
        fallbackIssuer: URL?,
        session: URLSession
    ) async throws -> OAuthProtectedResourceMetadata {
        let decoder = JSONDecoder()
        var unavailable: OAuthMetadataUnavailable?
        for url in candidates {
            let fetch = try await OAuthMetadataFetch<OAuthProtectedResourceMetadata>.fetch(
                url, session: session, validator: urlValidator
            ) {
                let metadata = try decoder.decode(OAuthProtectedResourceMetadata.self, from: $0)
                return metadata.authorizationServers.isEmpty ? nil : metadata
            }
            switch fetch {
            case .found(let metadata): return metadata
            case .absent: continue
            case .unavailable(let error): unavailable = unavailable ?? error
            }
        }
        if let unavailable { throw unavailable }
        if let fallbackIssuer {
            return OAuthProtectedResourceMetadata(
                resource: nil,
                authorizationServers: [fallbackIssuer],
                scopesSupported: nil,
                isFallback: true
            )
        }
        throw OAuthAuthorizationError.metadataDiscoveryFailed
    }

    /// Fetches Authorization Server Metadata from the first candidate that serves it.
    ///
    /// The metadata `issuer` must match the issuer the well-known URL was
    /// built from (RFC 8414 §3.3, SEP-2468); metadata that names another
    /// issuer, or none, is not used. For `trustedIssuer`, an issuer the
    /// application configured, metadata is accepted with any `issuer`.
    ///
    /// - Throws: `CancellationError` when cancelled;
    ///   ``OAuthAuthorizationError/authorizationServerIssuerMismatch(expected:actual:)``
    ///   when the only metadata found names another issuer;
    ///   ``OAuthMetadataUnavailable`` when a candidate failed with an error
    ///   and none succeeded;
    ///   ``OAuthAuthorizationError/authorizationServerMetadataDiscoveryFailed``
    ///   when every candidate answered 404 or 410; the error that refused
    ///   the first candidate, such as
    ///   ``OAuthAuthorizationError/insecureAuthorizationServerEndpoint(context:url:)``
    ///   or ``OAuthAuthorizationError/privateIPAddressBlocked(context:url:)``,
    ///   when every candidate was refused before a request and
    ///   `reportRefused` is set. Without it, such candidates end in
    ///   `authorizationServerMetadataDiscoveryFailed`, for a caller that
    ///   falls back to 2025-03-26 default endpoints.
    func fetchAuthorizationServerMetadata(
        candidates: [URL],
        trustedIssuer: URL?,
        reportRefused: Bool,
        session: URLSession
    ) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        let decoder = JSONDecoder()
        var mismatch: (expected: String, actual: String)?
        var unavailable: OAuthMetadataUnavailable?
        var refused: (any Error)?
        var fetched = false

        for candidateServer in candidates {
            do {
                try urlValidator.validateAuthorizationServerAndHost(
                    candidateServer, context: "Authorization server issuer")
            } catch {
                refused = refused ?? error
                continue
            }
            fetched = true
            let trusted = trustedIssuer == candidateServer

            for metadataURL in metadataDiscovery.authorizationServerMetadataURLs(
                for: candidateServer)
            {
                let fetch = try await OAuthMetadataFetch<OAuthAuthorizationServerMetadata>.fetch(
                    metadataURL, session: session, validator: urlValidator
                ) { try decoder.decode(OAuthAuthorizationServerMetadata.self, from: $0) }
                switch fetch {
                case .absent:
                    continue
                case .unavailable(let error):
                    unavailable = unavailable ?? error
                    continue
                case .found(let asMetadata):
                    let issuer = asMetadata.issuer?.absoluteString ?? ""
                    guard trusted || OAuthIssuer.matches(issuer, candidateServer.absoluteString) else {
                        mismatch = mismatch ?? (candidateServer.absoluteString, issuer)
                        continue
                    }
                    return (server: candidateServer, metadata: asMetadata)
                }
            }
        }

        if let mismatch {
            throw OAuthAuthorizationError.authorizationServerIssuerMismatch(
                expected: mismatch.expected, actual: mismatch.actual)
        }
        if let unavailable { throw unavailable }
        // No candidate was even fetched: say why, unless the caller falls back
        // to 2025-03-26 default endpoints for a synthesized origin.
        if reportRefused, !fetched, let refused { throw refused }
        throw OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
    }
}

extension OAuthDiscoveryClient: OAuthDiscoveryFetching {}
