import Foundation

// MARK: - WWW-Authenticate Parsing Protocol

/// Parses the `WWW-Authenticate` response header to extract Bearer challenge parameters.
///
/// ``OAuthAuthorizer`` uses this protocol to inspect 401 and 403 responses from the server.
/// Override the default ``DefaultOAuthWWWAuthenticateParser`` to handle custom challenge formats.
public protocol OAuthWWWAuthenticateParsing {
    /// Parses the `WWW-Authenticate` header from a response header dictionary.
    ///
    /// - Parameter headers: The full set of HTTP response headers (case-insensitive lookup is expected).
    /// - Returns: An ``OAuthBearerChallenge`` if a `Bearer` scheme is found, or `nil` otherwise.
    func parseBearer(from headers: [String: String]) -> OAuthBearerChallenge?
}

// MARK: - Default Implementation

/// Default ``OAuthWWWAuthenticateParsing`` implementation.
///
/// Parses `WWW-Authenticate` headers following RFC 6750 §3, handling:
/// - Multiple challenge schemes in a single header value (e.g., `Bearer …, Basic …`)
/// - Quoted-string parameter values with backslash escaping
/// - Case-insensitive scheme and parameter key matching
public struct DefaultOAuthWWWAuthenticateParser: OAuthWWWAuthenticateParsing {
    public init() {}
    private let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )

    public func parseBearer(from headers: [String: String]) -> OAuthBearerChallenge? {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare(HTTPHeaderName.wwwAuthenticate) == .orderedSame
        })?.value else {
            return nil
        }
        return parseBearerHeader(value)
    }

    private func parseBearerHeader(_ header: String) -> OAuthBearerChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parametersPart = extractBearerParameters(from: trimmed) else { return nil }

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
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
            }
            parameters[key] = value
        }

        return OAuthBearerChallenge(parameters: parameters)
    }

    private func extractBearerParameters(from header: String) -> String? {
        let segments = splitParameters(header)

        for index in segments.indices {
            let segment = segments[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isBearerChallengeStart(segment) else { continue }

            var parameters: [String] = []
            let initial = stripBearerScheme(from: segment)
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
                if startsNewChallenge(next) {
                    break
                }
                parameters.append(next)
                nextIndex = segments.index(after: nextIndex)
            }

            return parameters.joined(separator: ",")
        }

        return nil
    }

    private func isBearerChallengeStart(_ segment: String) -> Bool {
        guard segment.count >= OAuthTokenType.bearer.count else { return false }
        let schemeEnd = segment.index(segment.startIndex, offsetBy: OAuthTokenType.bearer.count)
        let scheme = segment[..<schemeEnd]
        guard String(scheme).caseInsensitiveCompare(OAuthTokenType.bearer) == .orderedSame else {
            return false
        }

        if schemeEnd == segment.endIndex {
            return true
        }
        return segment[schemeEnd].isWhitespace
    }

    private func stripBearerScheme(from segment: String) -> String {
        guard segment.count > OAuthTokenType.bearer.count else { return "" }
        let index = segment.index(segment.startIndex, offsetBy: OAuthTokenType.bearer.count)
        return String(segment[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startsNewChallenge(_ segment: String) -> Bool {
        if isBearerChallengeStart(segment) {
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

