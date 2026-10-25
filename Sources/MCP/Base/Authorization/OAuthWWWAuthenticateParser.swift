import Foundation

// MARK: - WWW-Authenticate Parsing Protocol

/// Parses the `WWW-Authenticate` response header to extract challenge parameters.
///
/// ``OAuthAuthorizer`` uses this protocol to inspect 401 and 403 responses from the server.
/// Override the default ``DefaultOAuthWWWAuthenticateParser`` to handle custom challenge formats.
public protocol OAuthWWWAuthenticateParsing {
    /// Parses the `WWW-Authenticate` header from a response header dictionary.
    ///
    /// - Parameter headers: The full set of HTTP response headers (case-insensitive lookup is expected).
    /// - Returns: An ``OAuthBearerChallenge`` if a `Bearer` scheme is found, or `nil` otherwise.
    func parseBearer(from headers: [String: String]) -> OAuthBearerChallenge?

    /// Parses the challenge of an authentication scheme, such as `DPoP`
    /// (RFC 9449 §7.1), from the `WWW-Authenticate` header.
    ///
    /// - Parameters:
    ///   - scheme: The scheme name, matched case-insensitively.
    ///   - headers: The full set of HTTP response headers.
    /// - Returns: The challenge parameters, or `nil` if the scheme is absent.
    func parseChallenge(scheme: String, from headers: [String: String]) -> OAuthBearerChallenge?
}

extension OAuthWWWAuthenticateParsing {
    /// Parses the challenge with ``DefaultOAuthWWWAuthenticateParser``.
    public func parseChallenge(scheme: String, from headers: [String: String])
        -> OAuthBearerChallenge?
    {
        DefaultOAuthWWWAuthenticateParser().parseChallenge(scheme: scheme, from: headers)
    }
}

// MARK: - Default Implementation

/// Default ``OAuthWWWAuthenticateParsing`` implementation.
///
/// Parses `WWW-Authenticate` headers following RFC 6750 §3, handling:
/// - Multiple challenge schemes in a single header value (e.g., `Bearer …, Basic …`)
/// - Quoted-string parameter values with backslash escaping
/// - Case-insensitive scheme and parameter key matching
public struct DefaultOAuthWWWAuthenticateParser: OAuthWWWAuthenticateParsing {
    /// Creates the default challenge parser.
    public init() {}
    private let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )

    /// Parses the `Bearer` challenge.
    public func parseBearer(from headers: [String: String]) -> OAuthBearerChallenge? {
        parseChallenge(scheme: OAuthTokenType.bearer, from: headers)
    }

    /// Parses the challenge of `scheme` from the `WWW-Authenticate` header,
    /// looked up case-insensitively.
    public func parseChallenge(scheme: String, from headers: [String: String])
        -> OAuthBearerChallenge?
    {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare(HTTPHeaderName.wwwAuthenticate) == .orderedSame
        })?.value else {
            return nil
        }
        return parseHeader(value, scheme: scheme)
    }

    private func parseHeader(_ header: String, scheme: String) -> OAuthBearerChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parametersPart = extractParameters(from: trimmed, scheme: scheme) else {
            return nil
        }

        if parametersPart.isEmpty {
            return OAuthBearerChallenge(parameters: [:])
        }

        let components = splitParameters(parametersPart)
        var parameters: [String: String] = [:]

        for component in components {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
                // RFC 7230 quoted-string: backslash-escape \X → X for any character.
                var unescaped = ""
                var escaping = false
                for ch in value {
                    if escaping {
                        unescaped.append(ch)
                        escaping = false
                    } else if ch == "\\" {
                        escaping = true
                    } else {
                        unescaped.append(ch)
                    }
                }
                value = unescaped
            }
            parameters[key] = value
        }

        return OAuthBearerChallenge(parameters: parameters)
    }

    private func extractParameters(from header: String, scheme: String) -> String? {
        let segments = splitParameters(header)

        for index in segments.indices {
            let segment = segments[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isChallengeStart(segment, scheme: scheme) else { continue }

            var parameters: [String] = []
            let initial = stripScheme(scheme, from: segment)
            if !initial.isEmpty {
                parameters.append(initial)
            }

            var nextIndex = segments.index(after: index)
            while nextIndex < segments.endIndex {
                let next = segments[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.isEmpty {
                    nextIndex = segments.index(after: nextIndex)
                    continue
                }
                if startsNewChallenge(next, scheme: scheme) {
                    break
                }
                parameters.append(next)
                nextIndex = segments.index(after: nextIndex)
            }

            return parameters.joined(separator: ",")
        }

        return nil
    }

    private func isChallengeStart(_ segment: String, scheme name: String) -> Bool {
        guard segment.count >= name.count else { return false }
        let schemeEnd = segment.index(segment.startIndex, offsetBy: name.count)
        let scheme = segment[..<schemeEnd]
        guard String(scheme).caseInsensitiveCompare(name) == .orderedSame else {
            return false
        }

        if schemeEnd == segment.endIndex {
            return true
        }
        return segment[schemeEnd].isWhitespace
    }

    private func stripScheme(_ scheme: String, from segment: String) -> String {
        guard segment.count > scheme.count else { return "" }
        let index = segment.index(segment.startIndex, offsetBy: scheme.count)
        return String(segment[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startsNewChallenge(_ segment: String, scheme: String) -> Bool {
        if isChallengeStart(segment, scheme: scheme) {
            return true
        }

        if let equalsIndex = segment.firstIndex(of: "=") {
            let parameterName = String(segment[..<equalsIndex]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !parameterName.isEmpty
                && !parameterName.contains(where: { $0.isWhitespace })
                && isToken(parameterName)
            {
                return false
            }
        }

        guard let whitespaceIndex = segment.firstIndex(where: \.isWhitespace) else {
            // No whitespace, no '=': bare token. Treat as new auth scheme if it's a valid token.
            return isToken(segment)
        }

        let scheme = segment[..<whitespaceIndex]
        return isToken(String(scheme))
    }

    private func isToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.rangeOfCharacter(from: tokenCharacters.inverted) == nil
    }

    private func splitParameters(_ value: String) -> [String] {
        var components: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false

        for character in value {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaping = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == "," && !inQuotes {
                components.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(character)
        }

        if !current.isEmpty {
            components.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return components.filter { !$0.isEmpty }
    }
}

