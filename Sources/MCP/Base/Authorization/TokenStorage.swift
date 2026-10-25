import Foundation

// MARK: - Token Storage Protocol

/// Abstraction for persisting OAuth access tokens.
///
/// Implement this protocol to provide custom token storage (e.g., Keychain-backed).
/// The default ``InMemoryTokenStorage`` stores tokens in memory only.
/// Implementations must be safe to call from several tasks at once.
public protocol TokenStorage: AnyObject, Sendable {
    func save(_ token: OAuthAccessToken)
    func load() -> OAuthAccessToken?
    func clear()
}

// MARK: - In-Memory Implementation

/// Default ``TokenStorage`` that stores the access token in memory only.
///
/// The token is lost when the process exits. For persistent storage
/// (e.g., system Keychain), implement ``TokenStorage`` directly. Its methods
/// may be called from several tasks at once.
public final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var token: OAuthAccessToken?

    public init() {}

    public func save(_ token: OAuthAccessToken) {
        lock.withLock { self.token = token }
    }

    public func load() -> OAuthAccessToken? {
        lock.withLock { token }
    }

    public func clear() {
        lock.withLock { token = nil }
    }
}
