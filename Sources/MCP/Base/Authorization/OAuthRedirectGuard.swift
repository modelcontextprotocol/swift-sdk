import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Checks the HTTP redirects of OAuth requests (SSRF protection).
///
/// Discovery requests may follow a redirect to an `https` URL (or a loopback
/// `http` URL, when the previous hop was loopback `http`) whose host is not
/// a private IP literal, and to a loopback host only from a loopback host.
/// Token and registration requests carry credentials and follow no redirects.
final class OAuthRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Policy: Sendable {
        /// Follow redirects that pass the URL checks.
        case validated
        /// Follow no redirect: the 3xx response is returned to the caller.
        case none
    }

    private let policy: Policy
    private let validator: OAuthURLValidator

    init(policy: Policy, validator: OAuthURLValidator) {
        self.policy = policy
        self.validator = validator
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The previous hop, not the first URL of the chain.
        let source = response.url ?? task.currentRequest?.url
        completionHandler(allows(from: source, to: request.url) ? request : nil)
    }

    /// Whether a redirect from `source` to `target` may be followed.
    func allows(from source: URL?, to target: URL?) -> Bool {
        guard policy == .validated, let target,
            let components = URLComponents(url: target, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty
        else { return false }
        if validator.isPrivateIPHost(host) { return false }
        let sourceComponents = source.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        // A remote server must not send the client to services on this machine.
        if isLoopback(host), !(sourceComponents?.host.map { isLoopback($0.lowercased()) } ?? false) {
            return false
        }
        if scheme == OAuthURLScheme.https { return true }
        return scheme == OAuthURLScheme.http && sourceComponents?.scheme?.lowercased() == OAuthURLScheme.http
            && OAuthLoopbackHost.isLoopback(host)
    }

    /// Whether `host` names this machine: `localhost`, a name under
    /// `.localhost` (RFC 6761 §6.3), `127.0.0.0/8` or `::1`.
    private func isLoopback(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        if name == OAuthLoopbackHost.localhost || name.hasSuffix(".\(OAuthLoopbackHost.localhost)") {
            return true
        }
        return validator.isPrivateIPHost(host, includingLoopback: true) && !validator.isPrivateIPHost(host)
    }
}

extension URLSession {
    /// `data(for:)` with the redirect checks of ``OAuthRedirectGuard``.
    ///
    /// swift-corelibs-foundation has no per-task delegates: there the request
    /// runs in a session with this session's configuration and the guard as
    /// its delegate.
    func oauthData(
        for request: URLRequest, redirects policy: OAuthRedirectGuard.Policy,
        validator: OAuthURLValidator
    ) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
            let guarded = URLSession(
                configuration: configuration,
                delegate: OAuthRedirectGuard(policy: policy, validator: validator),
                delegateQueue: nil)
            defer { guarded.finishTasksAndInvalidate() }
            return try await guarded.data(for: request.addingAdditionalHeaders(of: configuration))
        #else
            let guardDelegate = OAuthRedirectGuard(policy: policy, validator: validator)
            return try await data(for: request, delegate: guardDelegate)
        #endif
    }
}
