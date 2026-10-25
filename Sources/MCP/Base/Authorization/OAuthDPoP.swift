import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

import Crypto

/// A P-256 key that signs DPoP proofs (ES256).
///
/// `P256.Signing.PrivateKey` conforms, and on Apple platforms so does
/// `SecureEnclave.P256.Signing.PrivateKey`. Conform another type to sign with
/// a key held elsewhere, such as a hardware security module.
public protocol DPoPSigningKey: Sendable {
    /// The public key, published in each proof's `jwk` header.
    var publicKey: P256.Signing.PublicKey { get }

    /// An ECDSA signature of `data` with SHA-256.
    func signature(for data: Data) throws -> P256.Signing.ECDSASignature
}

extension P256.Signing.PrivateKey: DPoPSigningKey {}

#if canImport(CryptoKit)
    import CryptoKit

    extension SecureEnclave.P256.Signing.PrivateKey: DPoPSigningKey {}
#endif

extension OAuthConfiguration {
    /// Sender-constrained access tokens with DPoP (RFC 9449, SEP-1932).
    ///
    /// With DPoP set, ``OAuthAuthorizer`` signs a proof with the key for
    /// every token request and every MCP request. The authorization server
    /// binds the tokens it issues to the key, and the client presents them
    /// with `Authorization: DPoP`. An authorization server that does not
    /// support DPoP answers with a Bearer token, which is then used as one.
    ///
    /// Only ES256 is supported. Tokens are bound to the key: a token in
    /// ``TokenStorage`` bound to another key is discarded, so persist the key
    /// together with the tokens.
    public struct DPoP: Sendable {
        let key: any DPoPSigningKey

        /// Creates a DPoP configuration that signs with `key`.
        ///
        /// - Parameter key: The signing key, for example a
        ///   `SecureEnclave.P256.Signing.PrivateKey`.
        public init(key: some DPoPSigningKey) {
            self.key = key
        }

        /// Creates a DPoP configuration that signs with a software key.
        ///
        /// - Parameter privateKey: The signing key. Defaults to a new key,
        ///   which lives as long as the configuration.
        public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
            self.key = privateKey
        }

        /// The RFC 7638 JWK thumbprint of the public key (the `jkt` that
        /// DPoP-bound tokens carry).
        public var keyThumbprint: String {
            DPoPProofSigner.thumbprint(of: key.publicKey)
        }
    }
}

/// Signs DPoP proofs (RFC 9449 §4) and remembers server nonces (§8, §9).
///
/// Nonces are kept per origin, separately for authorization servers and
/// resource servers.
final class DPoPProofSigner: @unchecked Sendable {
    enum ServerKind: String {
        case authorizationServer = "as"
        case resourceServer = "rs"
    }

    static let algorithm = "ES256"
    static let proofType = "dpop+jwt"

    private let key: any DPoPSigningKey
    private let jwk: [String: String]
    let thumbprint: String

    private let lock = NSLock()
    private var nonces: [String: String] = [:]

    init(configuration: OAuthConfiguration.DPoP) {
        key = configuration.key
        jwk = Self.jwk(of: configuration.key.publicKey)
        thumbprint = Self.thumbprint(of: configuration.key.publicKey)
    }

    /// A compact JWS proof for one HTTP request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method (`htm`).
    ///   - url: The request URL; `htu` drops its query and fragment.
    ///   - accessToken: The token the request presents (`ath`), if any.
    ///   - server: Which nonce to include.
    func proof(
        method: String,
        url: URL,
        accessToken: String?,
        server: ServerKind,
        now: Date = Date()
    ) throws -> String {
        let header: [String: Any] = [
            JWTClaimName.type: Self.proofType,
            JWTClaimName.algorithm: Self.algorithm,
            "jwk": jwk,
        ]
        var claims: [String: Any] = [
            JWTClaimName.jwtID: Self.randomIdentifier(),
            "htm": method.uppercased(),
            "htu": try Self.targetURI(url),
            JWTClaimName.issuedAt: Int(now.timeIntervalSince1970),
        ]
        if let accessToken {
            claims["ath"] = Data(SHA256.hash(data: Data(accessToken.utf8))).base64URLEncodedString()
        }
        if let nonce = nonce(for: url, server: server) {
            claims["nonce"] = nonce
        }
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let signingInput =
            "\(headerData.base64URLEncodedString()).\(claimsData.base64URLEncodedString())"
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(signature.base64URLEncodedString())"
    }

    func nonce(for url: URL, server: ServerKind) -> String? {
        guard let key = Self.nonceKey(url, server) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return nonces[key]
    }

    func setNonce(_ nonce: String, for url: URL, server: ServerKind) {
        guard let key = Self.nonceKey(url, server) else { return }
        lock.lock()
        defer { lock.unlock() }
        nonces[key] = nonce
    }

    /// Records the `DPoP-Nonce` response header, if present. Returns the nonce.
    @discardableResult
    func recordNonce(from headers: [String: String], for url: URL, server: ServerKind) -> String? {
        guard
            let nonce = headers.first(where: {
                $0.key.caseInsensitiveCompare(HTTPHeaderName.dpopNonce) == .orderedSame
            })?.value.trimmingCharacters(in: .whitespaces),
            !nonce.isEmpty
        else { return nil }
        setNonce(nonce, for: url, server: server)
        return nonce
    }

    // MARK: - Helpers

    /// `htu`: the URL without user information, query and fragment
    /// (RFC 9449 §4.2).
    static func targetURI(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthAuthorizationError.invalidResourceURI("no DPoP target URI")
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        guard let target = components.url?.absoluteString else {
            throw OAuthAuthorizationError.invalidResourceURI("no DPoP target URI")
        }
        return target
    }

    static func jwk(of key: P256.Signing.PublicKey) -> [String: String] {
        let raw = key.rawRepresentation
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": raw.prefix(32).base64URLEncodedString(),
            "y": raw.suffix(32).base64URLEncodedString(),
        ]
    }

    /// RFC 7638: SHA-256 over the required members in lexicographic order.
    static func thumbprint(of key: P256.Signing.PublicKey) -> String {
        let jwk = jwk(of: key)
        let canonical =
            #"{"crv":"P-256","kty":"EC","x":"\#(jwk["x"]!)","y":"\#(jwk["y"]!)"}"#
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64URLEncodedString()
    }

    private static func nonceKey(_ url: URL, _ server: ServerKind) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(server.rawValue)|\(scheme)://\(host)\(port)"
    }

    private static func randomIdentifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncodedString()
    }
}
