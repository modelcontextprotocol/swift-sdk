import Crypto
import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Thrown by a ``RequestStateCodec`` for a token it did not mint unchanged.
public struct InvalidRequestState: Error, Hashable, Sendable {
    /// A reason for the server log. It is never sent to the client.
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// Authenticated encryption for `requestState` tokens (SEP-2322).
///
/// The server stamps and checks the claims (expiry, request binding,
/// audience, principal) itself. A codec provides integrity and, ideally,
/// confidentiality: `unseal(seal(payload))` returns `payload`, and `unseal`
/// throws ``InvalidRequestState`` for any token the codec did not mint
/// unchanged. Both methods are synchronous, so cache key material instead of
/// calling a key service for each token.
public protocol RequestStateCodec: Sendable {
    /// Returns an opaque, URL-safe token that protects `payload`.
    func seal(_ payload: Data) throws -> String
    /// Reverses ``seal(_:)``.
    func unseal(_ token: String) throws -> Data
}

/// The built-in codec: AES-256-GCM under keys derived with HKDF-SHA256.
///
/// `keys[0]` seals; every key unseals, so keys can rotate without dropping
/// rounds in flight:
/// 1. `[old, new]` on every instance: all of them can verify `new`.
/// 2. `[new, old]`: `new` seals; state sealed under `old` still verifies.
/// 3. `[new]`, one time-to-live after step 2 is complete.
///
/// A token is `v1.` followed by base64url(key id ‖ nonce ‖ ciphertext ‖ tag).
/// The prefix and the 4-byte key id are bound as associated data.
public struct AESGCMRequestStateCodec: RequestStateCodec {
    private static let prefix = "v1."
    private static let derivationInfo = Data("mcp/request-state/v1/aes-256-gcm".utf8)
    private static let keyIDLabel = Data("mcp/request-state/v1/kid:".utf8)
    private static let keyIDLength = 4
    private static let nonceLength = 12
    private static let tagLength = 16

    /// The smallest secret accepted, in bytes.
    public static let minimumKeyLength = 32

    private let ring: [Data: SymmetricKey]
    private let sealingKeyID: Data

    /// Creates a codec from secrets of at least ``minimumKeyLength`` random bytes.
    ///
    /// - Throws: ``MCPError/invalidRequest(_:)`` for an empty list, a short
    ///   key or a duplicate key.
    public init(keys: [Data]) throws {
        guard !keys.isEmpty else {
            throw MCPError.invalidRequest("AESGCMRequestStateCodec needs at least one key")
        }
        var ring: [Data: SymmetricKey] = [:]
        var sealingKeyID = Data()
        for (index, secret) in keys.enumerated() {
            guard secret.count >= Self.minimumKeyLength else {
                throw MCPError.invalidRequest(
                    "Request state keys need at least \(Self.minimumKeyLength) bytes; keys[\(index)] has \(secret.count)")
            }
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret), info: Self.derivationInfo, outputByteCount: 32)
            let keyID = key.withUnsafeBytes { bytes in
                Data(SHA256.hash(data: Self.keyIDLabel + Data(bytes)).prefix(Self.keyIDLength))
            }
            guard ring[keyID] == nil else {
                throw MCPError.invalidRequest("keys[\(index)] duplicates an earlier key")
            }
            ring[keyID] = key
            if index == 0 { sealingKeyID = keyID }
        }
        self.ring = ring
        self.sealingKeyID = sealingKeyID
    }

    /// A codec under a new random key that only this process holds.
    public static func random() -> AESGCMRequestStateCodec {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // A 32-byte key is always accepted.
        return try! AESGCMRequestStateCodec(keys: [secret])
    }

    public func seal(_ payload: Data) throws -> String {
        guard let key = ring[sealingKeyID] else { throw InvalidRequestState("no sealing key") }
        let box = try AES.GCM.seal(
            payload, using: key, authenticating: Data(Self.prefix.utf8) + sealingKeyID)
        return Self.prefix + (sealingKeyID + box.nonce + box.ciphertext + box.tag).base64URLEncodedString()
    }

    public func unseal(_ token: String) throws -> Data {
        guard token.hasPrefix(Self.prefix),
            let raw = Data(base64URLEncoded: String(token.dropFirst(Self.prefix.count))),
            raw.count >= Self.keyIDLength + Self.nonceLength + Self.tagLength
        else { throw InvalidRequestState("malformed") }
        let keyID = raw.prefix(Self.keyIDLength)
        guard let key = ring[Data(keyID)] else { throw InvalidRequestState("unknown key") }
        let body = raw.dropFirst(Self.keyIDLength)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: body.prefix(Self.nonceLength)),
                ciphertext: body.dropFirst(Self.nonceLength).dropLast(Self.tagLength),
                tag: body.suffix(Self.tagLength))
            return try AES.GCM.open(box, using: key, authenticating: Data(Self.prefix.utf8) + keyID)
        } catch {
            throw InvalidRequestState("seal")
        }
    }
}

/// How a server protects the `requestState` it gives to clients (SEP-2322).
///
/// The client holds the state between rounds, so what comes back is
/// client input. The server seals outgoing state and verifies each echo
/// before a handler sees it; handlers read and write plaintext. Each token
/// is bound to:
/// - a time window: each round seals again with a fresh expiry;
/// - the request: method, tool or prompt name or resource URI, and a
///   digest of the arguments;
/// - the audience: by default the server name;
/// - the principal, when ``principal`` returns one.
///
/// A token can be echoed any number of times until it expires: a client
/// may send the same round again, or an earlier round's token. To allow
/// each token once, set ``consume``.
///
/// Any failure is answered with -32602 "Invalid or expired requestState";
/// the reason goes to the server log.
public struct RequestStateProtection: Sendable {
    /// The codec that seals and opens tokens.
    public var codec: any RequestStateCodec
    /// How long a sealed state stays valid.
    public var timeToLive: Duration
    /// The audience claim. `nil` uses the server name.
    public var audience: String?
    /// The identity to bind state to, such as the authenticated user.
    /// State sealed for one principal fails for another. `nil` binds nothing:
    /// on a server with several users, a client that sends the same request
    /// and arguments can echo another user's state until it expires.
    public var principal: (@Sendable (Server.HandlerContext) -> String?)?
    /// Records a verified token's unique id until its expiry and returns
    /// whether it was new. `false` rejects the token as replayed. Back it
    /// with a store shared by every instance that holds the keys. A client
    /// that retries a round after a lost response then has to start the
    /// request again. A throw, such as a store that cannot be reached, fails
    /// the round with -32603 instead of reporting a replay. `nil` accepts
    /// replays until expiry.
    public var consume: (@Sendable (_ tokenID: String, _ expiry: Date) async throws -> Bool)?

    public init(
        codec: any RequestStateCodec,
        timeToLive: Duration = .seconds(600),
        audience: String? = nil,
        principal: (@Sendable (Server.HandlerContext) -> String?)? = nil,
        consume: (@Sendable (_ tokenID: String, _ expiry: Date) async throws -> Bool)? = nil
    ) {
        self.codec = codec
        self.timeToLive = timeToLive
        self.audience = audience
        self.principal = principal
        self.consume = consume
    }

    /// Protection under shared secrets, for servers with several instances
    /// or that must accept state across restarts. See
    /// ``AESGCMRequestStateCodec`` for key rotation.
    public init(
        keys: [Data],
        timeToLive: Duration = .seconds(600),
        audience: String? = nil,
        principal: (@Sendable (Server.HandlerContext) -> String?)? = nil,
        consume: (@Sendable (_ tokenID: String, _ expiry: Date) async throws -> Bool)? = nil
    ) throws {
        self.init(
            codec: try AESGCMRequestStateCodec(keys: keys), timeToLive: timeToLive, audience: audience,
            principal: principal, consume: consume)
    }

    /// Protection under a key generated now and held only by this process:
    /// the default. Suits one process (stdio, one HTTP instance). State from
    /// another instance or from before a restart is rejected, and the client
    /// must start the request again.
    public static func ephemeral(timeToLive: Duration = .seconds(600)) -> RequestStateProtection {
        RequestStateProtection(codec: AESGCMRequestStateCodec.random(), timeToLive: timeToLive)
    }
}

/// Seals outgoing `requestState` and verifies incoming state for one server.
struct RequestStateBoundary: Sendable {
    let protection: RequestStateProtection
    let audience: String

    private static let envelopeVersion = 1
    /// Tolerated clock skew for the issue time, in seconds.
    private static let futureSkew = 60.0
    private static let principalLabel = Data("mcp/request-state/principal:".utf8)

    private struct Claims: Codable {
        var v: Int
        var iat: Double
        var exp: Double
        var m: String
        var t: String
        var a: String
        var aud: String
        var p: String?
        var s: String
        /// A unique id, for ``RequestStateProtection/consume``.
        var jti: String
    }

    /// The target and arguments digest a token is bound to.
    struct Binding: Equatable {
        let target: String
        let digest: String
    }

    /// A verified token.
    struct Verified {
        let state: String
        let tokenID: String
        let expiry: Date
    }

    /// The frozen error for every verification failure.
    static let rejection = MCPError.invalidParams("Invalid or expired requestState")

    /// Seals `state` for a round of `method` with the request `binding`.
    func seal(
        _ state: String, method: String, binding: Binding, context: Server.HandlerContext?, now: Date = Date()
    ) throws -> String {
        let issued = now.timeIntervalSince1970
        let claims = Claims(
            v: Self.envelopeVersion, iat: issued,
            exp: issued + protection.timeToLive.seconds,
            m: method, t: binding.target, a: binding.digest, aud: audience,
            p: principal(context).map(Self.principalClaim), s: state,
            jti: Self.randomID())
        return try protection.codec.seal(Self.encoder.encode(claims))
    }

    /// Verifies a token for a round of `method`, returning the plaintext.
    /// `binding` is computed only once the token is authenticated.
    ///
    /// - Throws: ``InvalidRequestState`` with the reason.
    func unseal(
        _ token: String, method: String, binding: () -> Binding, context: Server.HandlerContext?,
        now: Date = Date()
    ) throws -> Verified {
        let payload: Data
        do {
            payload = try protection.codec.unseal(token)
        } catch let error as InvalidRequestState {
            throw error
        } catch {
            throw InvalidRequestState("codec error: \(error)")
        }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            claims.v == Self.envelopeVersion
        else { throw InvalidRequestState("malformed") }
        let time = now.timeIntervalSince1970
        guard claims.iat <= time + Self.futureSkew else { throw InvalidRequestState("issued in the future") }
        guard time < claims.exp else { throw InvalidRequestState("expired") }
        let expected = binding()
        guard claims.m == method, claims.t == expected.target, claims.a == expected.digest else {
            throw InvalidRequestState("request binding")
        }
        guard claims.aud == audience else { throw InvalidRequestState("audience") }
        switch (claims.p, principal(context)) {
        case (nil, nil):
            break
        case (let claim?, let principal?):
            guard Self.principalMatches(claim, principal) else { throw InvalidRequestState("principal") }
        default:
            throw InvalidRequestState("principal")
        }
        return Verified(state: claims.s, tokenID: claims.jti, expiry: Date(timeIntervalSince1970: claims.exp))
    }

    private func principal(_ context: Server.HandlerContext?) -> String? {
        guard let principal = protection.principal, let context else { return nil }
        return principal(context)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The binding of a request: its target and a digest of its arguments.
    static func binding(target: String, arguments: Value) -> Binding {
        let data = (try? encoder.encode(arguments)) ?? Data()
        return Binding(target: target, digest: Data(SHA256.hash(data: data).prefix(16)).base64URLEncodedString())
    }

    private static func randomID() -> String {
        var bytes = Data(count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return bytes.base64URLEncodedString()
    }

    private static func principalClaim(_ principal: String) -> String {
        var salt = Data(count: 8)
        for index in salt.indices { salt[index] = UInt8.random(in: .min ... .max) }
        return (salt + principalTag(salt: salt, principal)).base64URLEncodedString()
    }

    private static func principalMatches(_ claim: String, _ principal: String) -> Bool {
        guard let raw = Data(base64URLEncoded: claim), raw.count == 24 else { return false }
        let expected = principalTag(salt: raw.prefix(8), principal)
        // Constant-time comparison.
        return zip(raw.suffix(16), expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func principalTag(salt: Data, _ principal: String) -> Data {
        Data(SHA256.hash(data: principalLabel + salt + Data(principal.utf8)).prefix(16))
    }
}

extension Duration {
    /// The duration in seconds.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

extension Data {
    /// Decodes unpadded base64url; `nil` for anything else.
    init?(base64URLEncoded text: String) {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.base64URLEncodedString() == text else { return nil }
        self = data
    }
}
