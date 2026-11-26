import Foundation

// MARK: - Validation Protocol

/// Validates an incoming HTTP request before the transport processes it.
///
/// Validators are composed into a pipeline and executed in order. The first validator
/// that returns a non-nil response short-circuits the pipeline and that error response
/// is returned to the client.
///
/// Conform to this protocol to add custom validation (e.g., authentication):
/// ```swift
/// struct BearerTokenValidator: HTTPRequestValidator {
///     func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
///         guard let auth = request.header("Authorization"),
///               auth.hasPrefix("Bearer ") else {
///             return .error(statusCode: 401, .invalidRequest("Missing bearer token"))
///         }
///         return nil
///     }
/// }
/// ```
public protocol HTTPRequestValidator: Sendable {
    /// Validates the request. Returns an error response if invalid, or `nil` if valid.
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse?
}

// MARK: - Validation Context

/// Context provided to validators for making validation decisions.
public struct HTTPValidationContext: Sendable {
    /// The HTTP method of the request (GET, POST, DELETE).
    public let httpMethod: String

    /// The current session ID, if any (nil in stateless mode or before initialization).
    public let sessionID: String?

    /// Whether the request body contains an `initialize` JSON-RPC request.
    public let isInitializationRequest: Bool

    /// The set of protocol versions this server supports.
    public let supportedProtocolVersions: Set<String>

    /// Creates a context. `supportedProtocolVersions` defaults to the
    /// handshake revisions, which session-based transports serve; a
    /// stateless transport passes `Version.stateless` too.
    public init(
        httpMethod: String,
        sessionID: String? = nil,
        isInitializationRequest: Bool = false,
        supportedProtocolVersions: Set<String> = Set(Version.handshake)
    ) {
        self.httpMethod = httpMethod
        self.sessionID = sessionID
        self.isInitializationRequest = isInitializationRequest
        self.supportedProtocolVersions = supportedProtocolVersions
    }
}

// MARK: - Accept Header Validator

/// Validates the `Accept` header based on the HTTP method and transport response mode.
///
/// - Stateful (SSE) mode: POST requests must accept both `application/json` and `text/event-stream`
/// - Stateless (JSON) mode: POST requests only need to accept `application/json`
/// - GET requests always require `text/event-stream`
public struct AcceptHeaderValidator: HTTPRequestValidator {
    /// The response mode determines which content types are required.
    ///
    /// Frozen: no case is added in 1.x (the two response modes of the HTTP transports).
    public enum Mode: Sendable {
        /// POST requires both `application/json` and `text/event-stream`.
        case sseRequired
        /// POST only requires `application/json`.
        case jsonOnly
    }

    /// The content types POST requests must accept.
    public let mode: Mode

    /// Creates a validator for the given response mode.
    public init(mode: Mode) {
        self.mode = mode
    }

    /// Returns 406 when the `Accept` header lacks a required content type.
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        let accept = request.header(HTTPHeaderName.accept) ?? ""
        let acceptTypes = accept.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        let hasJSON = acceptTypes.contains { $0.hasPrefix(ContentType.json) }
        let hasSSE = acceptTypes.contains { $0.hasPrefix(ContentType.sse) }

        switch context.httpMethod {
        case "POST":
            switch mode {
            case .sseRequired:
                guard hasJSON, hasSSE else {
                    return .error(
                        statusCode: 406,
                        .invalidRequest(
                            "Not Acceptable: Client must accept both application/json and text/event-stream"
                        ),
                        sessionID: context.sessionID
                    )
                }
            case .jsonOnly:
                guard hasJSON else {
                    return .error(
                        statusCode: 406,
                        .invalidRequest(
                            "Not Acceptable: Client must accept application/json"
                        ),
                        sessionID: context.sessionID
                    )
                }
            }
        case "GET":
            guard hasSSE else {
                return .error(
                    statusCode: 406,
                    .invalidRequest(
                        "Not Acceptable: Client must accept text/event-stream"
                    ),
                    sessionID: context.sessionID
                )
            }
        default:
            break
        }

        return nil
    }
}

// MARK: - Content-Type Validator

/// Validates that POST requests have `Content-Type: application/json`.
public struct ContentTypeValidator: HTTPRequestValidator {
    /// Creates a content type validator.
    public init() {}

    /// Returns 415 when a POST request's media type is not `application/json`.
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod == "POST" else { return nil }

        let contentType = request.header(HTTPHeaderName.contentType) ?? ""
        let mainType = contentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? ""

        guard mainType == ContentType.json else {
            return .error(
                statusCode: 415,
                .invalidRequest(
                    "Unsupported Media Type: Content-Type must be application/json"
                ),
                sessionID: context.sessionID
            )
        }

        return nil
    }
}

// MARK: - Protocol Version Validator

/// Validates the `MCP-Protocol-Version` header against supported versions.
///
/// Per spec:
/// - If the header is absent, the server assumes the default negotiated version
/// - If the header is present but unsupported, the server returns 400 Bad Request
/// - Initialization requests are exempt (protocol version comes from the request body)
public struct ProtocolVersionValidator: HTTPRequestValidator {
    /// Creates a protocol version validator.
    public init() {}

    /// Returns 400 with ``MCPError/unsupportedProtocolVersion(supported:requested:)``
    /// when the header names a version outside
    /// ``HTTPValidationContext/supportedProtocolVersions``, and 400 with
    /// ``MCPError/headerMismatch(_:)`` when it was sent more than once and
    /// names a revision that defines that error (2026-07-28 and later).
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Skip for initialization requests (version is in the body, not the header)
        guard !context.isInitializationRequest else { return nil }

        // Skip for non-POST methods (GET/DELETE don't carry protocol version)
        // Actually, per spec, all subsequent requests should include it
        guard let version = request.header(HTTPHeaderName.protocolVersion) else {
            // Per spec: if not received, assume default version
            return nil
        }

        // The header is single-valued. A repeated one arrives on several
        // field lines or joined with commas (RFC 9110 §5.3); at revisions
        // that define HeaderMismatch it is a header failure, not an
        // unsupported version.
        if request.isRepeated(HTTPHeaderName.protocolVersion) {
            let versions = request.headerValues(HTTPHeaderName.protocolVersion)
                .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if versions.contains(where: { Version.profile(for: $0).usesStandardHeaders }) {
                return .error(
                    statusCode: 400,
                    .headerMismatch("\(HTTPHeaderName.protocolVersion) appears more than once"),
                    sessionID: context.sessionID
                )
            }
        }

        guard context.supportedProtocolVersions.contains(version) else {
            return .error(
                statusCode: 400,
                .unsupportedProtocolVersion(
                    supported: context.supportedProtocolVersions.sorted(by: >),
                    requested: version),
                sessionID: context.sessionID
            )
        }

        return nil
    }
}

// MARK: - Session Validator

/// Validates the `Mcp-Session-Id` header for stateful transports.
///
/// - Initialization requests are exempt (no session exists yet)
/// - Non-initialization requests must include the session ID header
/// - The session ID must match the active session
public struct SessionValidator: HTTPRequestValidator {
    /// Creates a session validator.
    public init() {}

    /// Returns 400 when no session exists or the header is missing, and 404
    /// when the session ID does not match.
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Skip validation for initialization requests
        guard !context.isInitializationRequest else { return nil }

        // Non-initialization requests require an established session.
        guard let expectedSessionID = context.sessionID else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Session not initialized"),
                sessionID: nil
            )
        }

        let requestSessionID = request.header(HTTPHeaderName.sessionID)

        guard let requestSessionID else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"),
                sessionID: expectedSessionID
            )
        }

        guard requestSessionID == expectedSessionID else {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Invalid or expired session ID"),
                sessionID: expectedSessionID
            )
        }

        return nil
    }
}

// MARK: - Origin Validator

/// DNS rebinding protection: validates `Origin` and `Host` headers.
///
/// Per spec, servers MUST validate the Origin header to prevent DNS rebinding attacks.
/// This is particularly important for servers running on localhost.
///
/// Use `.localhost()` for local development servers.
/// Use `.disabled` to skip validation (e.g., cloud deployments).
/// Use `init(allowedHosts:allowedOrigins:)` for custom configurations.
public struct OriginValidator: HTTPRequestValidator {
    /// The allowed `Host` values; a trailing `:*` matches any numeric port.
    public let allowedHosts: [String]
    /// The allowed `Origin` values; a trailing `:*` matches any numeric port.
    public let allowedOrigins: [String]
    private let enabled: Bool

    /// Creates a validator that allows the given hosts and origins.
    public init(allowedHosts: [String], allowedOrigins: [String]) {
        self.allowedHosts = allowedHosts
        self.allowedOrigins = allowedOrigins
        self.enabled = true
    }

    private init(disabled: Void) {
        self.allowedHosts = []
        self.allowedOrigins = []
        self.enabled = false
    }

    /// Protection for localhost-bound servers.
    /// Allows requests from `localhost`, `127.0.0.1`, and `[::1]` on the given port.
    /// Pass `nil` to allow any port, including none. Port 80 also accepts a request with no port.
    public static func localhost(port: Int? = nil) -> OriginValidator {
        let portPattern = port.map { String($0) } ?? "*"
        // A request without a port uses the scheme's default (RFC 9110, section 7.2): 80 for `http`.
        let withoutPort = port == 80 ? ["127.0.0.1", "localhost", "[::1]"] : []
        return OriginValidator(
            allowedHosts: [
                "127.0.0.1:\(portPattern)",
                "localhost:\(portPattern)",
                "[::1]:\(portPattern)",
            ] + withoutPort,
            allowedOrigins: [
                "http://127.0.0.1:\(portPattern)",
                "http://localhost:\(portPattern)",
                "http://[::1]:\(portPattern)",
            ] + withoutPort.map { "http://\($0)" }
        )
    }

    /// Disables DNS rebinding protection.
    /// Use for cloud deployments where DNS rebinding is not a threat.
    public static var disabled: OriginValidator {
        OriginValidator(disabled: ())
    }

    /// Returns 421 for a disallowed `Host` and 403 for a disallowed `Origin`.
    ///
    /// A request without either header passes that check.
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard enabled else { return nil }

        // Validate Host header
        if let host = request.header(HTTPHeaderName.host) {
            let hostAllowed = allowedHosts.contains { pattern in
                matchesPattern(host, pattern: pattern)
            }
            if !hostAllowed {
                return .error(
                    statusCode: 421,
                    .invalidRequest("Misdirected Request: Host header not allowed"),
                    sessionID: context.sessionID
                )
            }
        }

        // Validate Origin header (only if present — non-browser clients won't send it)
        if let origin = request.header(HTTPHeaderName.origin) {
            let originAllowed = allowedOrigins.contains { pattern in
                matchesPattern(origin, pattern: pattern)
            }
            if !originAllowed {
                return .error(
                    statusCode: 403,
                    .invalidRequest("Forbidden: Origin not allowed"),
                    sessionID: context.sessionID
                )
            }
        }

        return nil
    }

    /// Matches a value against a pattern that may contain a port wildcard `:*`.
    ///
    /// Examples:
    /// - `"localhost:*"` matches `"localhost:8080"`, `"localhost:3000"`, and `"localhost"`
    /// - `"http://localhost:*"` matches `"http://localhost:8080"` and `"http://localhost"`
    /// - `"localhost:8080"` matches only `"localhost:8080"` exactly
    private func matchesPattern(_ value: String, pattern: String) -> Bool {
        guard pattern.hasSuffix(":*") else {
            return value == pattern
        }

        let prefix = String(pattern.dropLast(2))
        // A value without a port uses the scheme's default port (RFC 9110, section 7.2),
        // which the wildcard covers.
        if value == prefix { return true }
        guard value.hasPrefix(prefix + ":") else { return false }

        let portPart = value.dropFirst(prefix.count + 1)
        return !portPart.isEmpty && portPart.allSatisfy(\.isNumber)
    }
}

// MARK: - Protected Resource Metadata Validator

/// Serves the RFC 9728 Protected Resource Metadata document for discovery.
///
/// Per the MCP authorization specification, servers **MUST** serve Protected Resource
/// Metadata at `/.well-known/oauth-protected-resource` so that clients can discover
/// authorization server endpoints automatically.
///
/// Place this validator **before** ``BearerTokenValidator`` in the pipeline so that
/// unauthenticated metadata discovery requests succeed.
///
/// ```swift
/// let prmValidator = ProtectedResourceMetadataValidator(
///     metadata: OAuthProtectedResourceServerMetadata(
///         resource: "https://api.example.com",
///         authorizationServers: [URL(string: "https://auth.example.com")!]
///     )
/// )
/// let pipeline = StandardValidationPipeline(validators: [
///     prmValidator,
///     bearerTokenValidator,
///     // ...
/// ])
/// ```
public struct ProtectedResourceMetadataValidator: HTTPRequestValidator {
    private let encodedMetadata: Data

    /// Creates a validator that serves the given metadata.
    public init(metadata: OAuthProtectedResourceServerMetadata) {
        self.encodedMetadata = (try? JSONEncoder().encode(metadata)) ?? Data()
    }

    /// Returns the metadata as JSON for a GET of
    /// `/.well-known/oauth-protected-resource` or a path below it, and `nil`
    /// for any other request.
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod == "GET",
            let path = request.path,
            path == OAuthWellKnownPath.protectedResource
                || path.hasPrefix("\(OAuthWellKnownPath.protectedResource)/")
        else {
            return nil
        }
        return .data(encodedMetadata, headers: [HTTPHeaderName.contentType: ContentType.json])
    }
}

// MARK: - OAuth Bearer Validator

/// Result produced by ``BearerTokenValidator/TokenValidator`` when validating an access
/// token.
///
/// Create one with a static member, such as ``valid(_:)``. New results can appear in a minor
/// release.
public struct BearerTokenValidationResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case valid(BearerTokenInfo)
        case insufficientScope(requiredScopes: Set<String>, errorDescription: String?)
        case invalidToken(errorDescription: String?)
        case malformedRequest(errorDescription: String?)
    }

    let outcome: Outcome

    /// The claims of a ``valid(_:)`` result; `nil` for every other result.
    public var tokenInfo: BearerTokenInfo? {
        if case .valid(let info) = outcome { return info }
        return nil
    }

    /// Access token is valid for this request, with its extracted claims.
    ///
    /// Supply a ``BearerTokenInfo`` with `audience` and `expiresAt` populated so that
    /// ``BearerTokenValidator`` can enforce expiry and audience checks automatically.
    /// Pass `BearerTokenInfo()` (all `nil`) to delegate all enforcement to the caller.
    public static func valid(_ info: BearerTokenInfo) -> Self {
        Self(outcome: .valid(info))
    }

    /// Access token is missing required privileges, and new scopes are required.
    public static func insufficientScope(requiredScopes: Set<String>, errorDescription: String? = nil) -> Self {
        Self(outcome: .insufficientScope(requiredScopes: requiredScopes, errorDescription: errorDescription))
    }

    /// Access token is invalid or expired.
    public static func invalidToken(errorDescription: String? = nil) -> Self {
        Self(outcome: .invalidToken(errorDescription: errorDescription))
    }

    /// Authorization request is malformed.
    public static func malformedRequest(errorDescription: String? = nil) -> Self {
        Self(outcome: .malformedRequest(errorDescription: errorDescription))
    }
}

/// Validates OAuth 2.1 Bearer authorization for protected MCP HTTP endpoints.
///
/// This validator implements resource-server error semantics aligned with the MCP auth spec:
/// - `401` with `WWW-Authenticate: Bearer ...` for missing/invalid tokens, and for credentials
///   of another scheme
/// - `403` with `error="insufficient_scope"` for insufficient permissions
/// - `400` with `error="invalid_request"` for malformed Bearer authorization requests
///
/// Include this validator early in your pipeline, before `SessionValidator`, so unauthenticated
/// initialization requests can return a challenge.
///
/// ## Audience Validation (MUST)
///
/// Per the MCP authorization specification, **the resource server MUST validate the audience
/// (`aud` claim) of the access token** to ensure it matches the resource server's own identifier.
/// Failure to validate the audience allows token substitution attacks where a token intended
/// for a different resource is replayed against your server.
///
/// Your ``TokenValidator`` closure **MUST** verify the audience. Example:
///
/// ```swift
/// let validator = BearerTokenValidator(
///     resourceMetadataURL: metadataURL,
///     resourceIdentifier: URL(string: "https://api.example.com")!,
///     tokenValidator: { token, request, context in
///         guard let claims = verifyAndDecode(token) else {
///             return .invalidToken(errorDescription: "Token verification failed")
///         }
///         // MUST: Verify token audience matches this resource server
///         guard claims.audience.contains("https://api.example.com") else {
///             return .invalidToken(errorDescription: "Token audience mismatch")
///         }
///         return .valid(BearerTokenInfo(audience: claims.audience, expiresAt: claims.expiry))
///     }
/// )
/// ```
public struct BearerTokenValidator: HTTPRequestValidator {
    /// Validates a bearer token and returns token info for audience and expiry enforcement.
    public typealias TokenValidator = @Sendable (
        _ token: String,
        _ request: HTTPRequest,
        _ context: HTTPValidationContext
    ) -> BearerTokenValidationResult

    /// Closure that returns the scopes to advertise in `WWW-Authenticate` challenge headers.
    ///
    /// Return `nil` to omit the `scope` parameter from the challenge.
    public typealias ChallengeScopeProvider = @Sendable (
        _ request: HTTPRequest,
        _ context: HTTPValidationContext
    ) -> Set<String>?

    /// Closure that decides whether a request requires Bearer authentication.
    ///
    /// Return `false` to allow a request through unauthenticated (e.g., public health-check endpoints).
    /// Defaults to requiring authentication on all requests.
    public typealias RequirementPredicate = @Sendable (
        _ request: HTTPRequest,
        _ context: HTTPValidationContext
    ) -> Bool

    /// The RFC 9728 Protected Resource Metadata URL, sent as `resource_metadata`
    /// in `WWW-Authenticate` challenges.
    public let resourceMetadataURL: URL
    /// The canonical URI of this resource server, matched against token audiences.
    public let resourceIdentifier: URL
    private let tokenValidator: TokenValidator
    private let challengeScopeProvider: ChallengeScopeProvider?
    private let requiresAuthentication: RequirementPredicate
    private let metadataDiscovery: any OAuthMetadataDiscovering

    /// Creates a `BearerTokenValidator`.
    ///
    /// - Parameters:
    ///   - resourceMetadataURL: Included in `WWW-Authenticate` challenge headers as the
    ///     `resource_metadata` parameter, pointing to the RFC 9728 Protected Resource Metadata document.
    ///   - resourceIdentifier: The canonical URI of this resource server. Used to validate the
    ///     `aud` claim in tokens that supply audience information via ``BearerTokenInfo``.
    ///   - tokenValidator: Validates the Bearer token and returns ``BearerTokenInfo`` with
    ///     claims for SDK-side expiry and audience enforcement.
    ///   - challengeScopeProvider: Optional closure supplying scopes to include in challenge headers.
    ///   - requiresAuthentication: Predicate controlling which requests require a Bearer token.
    ///     Defaults to requiring authentication on all requests.
    ///   - metadataDiscovery: Used for audience URL matching. Defaults to ``DefaultOAuthMetadataDiscovery``.
    public init(
        resourceMetadataURL: URL,
        resourceIdentifier: URL,
        tokenValidator: @escaping TokenValidator,
        challengeScopeProvider: ChallengeScopeProvider? = nil,
        requiresAuthentication: @escaping RequirementPredicate = { _, _ in true },
        metadataDiscovery: any OAuthMetadataDiscovering = DefaultOAuthMetadataDiscovery()
    ) {
        self.resourceMetadataURL = resourceMetadataURL
        self.resourceIdentifier = resourceIdentifier
        self.tokenValidator = tokenValidator
        self.challengeScopeProvider = challengeScopeProvider
        self.requiresAuthentication = requiresAuthentication
        self.metadataDiscovery = metadataDiscovery
    }

    /// Checks the Bearer token of a request that requires authentication.
    ///
    /// Returns 401 with a `WWW-Authenticate` challenge for a request without
    /// Bearer credentials (no `Authorization` header, or another scheme) and
    /// for an invalid, expired or wrong-audience token, 403 for insufficient
    /// scope, and 400 with an `error="invalid_request"` challenge for a
    /// malformed Bearer `Authorization` header (RFC 6750 §3.1).
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard requiresAuthentication(request, context) else { return nil }

        let parsedToken: String
        switch bearerCredentials(in: request.header(HTTPHeaderName.authorization)) {
        case .token(let token):
            parsedToken = token
        case .none:
            // RFC 6750 §3.1: a request without Bearer credentials gets the
            // challenge without an error code.
            return unauthorizedResponse(
                challengeScope: challengeScopeProvider?(request, context),
                error: nil,
                errorDescription: nil,
                sessionID: context.sessionID
            )
        case .malformed(let message):
            return invalidRequestResponse(
                message: message, challengeScope: challengeScopeProvider?(request, context),
                sessionID: context.sessionID)
        }

        switch tokenValidator(parsedToken, request, context).outcome {
        case .valid(let info):
            // Expiry check
            if let exp = info.expiresAt, exp <= Date() {
                return unauthorizedResponse(
                    challengeScope: challengeScopeProvider?(request, context),
                    error: "invalid_token",
                    errorDescription: "Token has expired",
                    sessionID: context.sessionID
                )
            }
            // Audience check — skipped for opaque tokens (audience == nil)
            if let audience = info.audience {
                let matches = audience.contains { audString in
                    guard let audURL = URL(string: audString) else { return false }
                    return metadataDiscovery.protectedResourceMatches(
                        resource: audURL, endpoint: resourceIdentifier)
                }
                if !matches {
                    return unauthorizedResponse(
                        challengeScope: challengeScopeProvider?(request, context),
                        error: "invalid_token",
                        errorDescription: "Token audience mismatch",
                        sessionID: context.sessionID
                    )
                }
            }
            return nil

        case .invalidToken(let errorDescription):
            return unauthorizedResponse(
                challengeScope: challengeScopeProvider?(request, context),
                error: "invalid_token",
                errorDescription: errorDescription,
                sessionID: context.sessionID
            )

        case .insufficientScope(let requiredScopes, let errorDescription):
            return forbiddenInsufficientScopeResponse(
                requiredScopes: requiredScopes,
                errorDescription: errorDescription,
                sessionID: context.sessionID
            )

        case .malformedRequest(let errorDescription):
            return invalidRequestResponse(
                message: errorDescription ?? "Malformed authorization request",
                challengeScope: challengeScopeProvider?(request, context), sessionID: context.sessionID)
        }
    }

    /// 400 with a Bearer challenge carrying `error="invalid_request"`
    /// (RFC 6750 §3.1), so the client still learns `resource_metadata`.
    private func invalidRequestResponse(
        message: String, challengeScope: Set<String>?, sessionID: String?
    ) -> HTTPResponse {
        let challenge = makeBearerChallenge(
            resourceMetadataURL: resourceMetadataURL,
            scope: challengeScope,
            error: "invalid_request",
            errorDescription: message
        )
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: \(message)"),
            sessionID: sessionID,
            extraHeaders: [HTTPHeaderName.wwwAuthenticate: challenge]
        )
    }

    private func unauthorizedResponse(
        challengeScope: Set<String>?,
        error: String?,
        errorDescription: String?,
        sessionID: String?
    ) -> HTTPResponse {
        let challenge = makeBearerChallenge(
            resourceMetadataURL: resourceMetadataURL,
            scope: challengeScope,
            error: error,
            errorDescription: errorDescription
        )
        return .error(
            statusCode: 401,
            .invalidRequest("Unauthorized"),
            sessionID: sessionID,
            extraHeaders: [HTTPHeaderName.wwwAuthenticate: challenge]
        )
    }

    private func forbiddenInsufficientScopeResponse(
        requiredScopes: Set<String>,
        errorDescription: String?,
        sessionID: String?
    ) -> HTTPResponse {
        let challenge = makeBearerChallenge(
            resourceMetadataURL: resourceMetadataURL,
            scope: requiredScopes,
            error: "insufficient_scope",
            errorDescription: errorDescription
        )
        return .error(
            statusCode: 403,
            .invalidRequest("Forbidden: Insufficient scope"),
            sessionID: sessionID,
            extraHeaders: [HTTPHeaderName.wwwAuthenticate: challenge]
        )
    }

    private func makeBearerChallenge(
        resourceMetadataURL: URL,
        scope: Set<String>?,
        error: String?,
        errorDescription: String?
    ) -> String {
        var parameters: [String] = []
        parameters.append("resource_metadata=\"\(escapeAuthParameter(resourceMetadataURL.absoluteString))\"")

        if let scope, !scope.isEmpty {
            let serializedScope = scope.sorted().joined(separator: " ")
            parameters.append("scope=\"\(escapeAuthParameter(serializedScope))\"")
        }

        if let error {
            parameters.append("error=\"\(escapeAuthParameter(error))\"")
        }

        if let errorDescription, !errorDescription.isEmpty {
            parameters.append("error_description=\"\(escapeAuthParameter(errorDescription))\"")
        }

        return "\(OAuthTokenType.bearer) " + parameters.joined(separator: ", ")
    }

    private func escapeAuthParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// What the `Authorization` header of a request holds.
    private enum BearerCredentials {
        case token(String)
        /// No Bearer credentials: no header, an empty one, or another scheme.
        case none
        /// A Bearer header that is malformed, for example without a token
        /// or with two of them.
        case malformed(String)
    }

    private func bearerCredentials(in authorizationHeader: String?) -> BearerCredentials {
        let trimmed = (authorizationHeader ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let scheme = parts.first,
            String(scheme).caseInsensitiveCompare(OAuthTokenType.bearer) == .orderedSame
        else {
            return .none
        }

        let token = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !token.isEmpty else {
            return .malformed("Bearer token is empty")
        }

        // Also two Authorization lines joined into `Bearer a, Bearer b`.
        if token.contains(where: \.isWhitespace) {
            return .malformed("Bearer token must not contain whitespace")
        }

        return .token(token)
    }
}

// MARK: - Validation Pipeline Protocol

/// Runs a validation pipeline against an HTTP request.
///
/// Implementations execute a sequence of validators and return the first error,
/// or `nil` if all validations pass.
public protocol HTTPRequestValidationPipeline: Sendable {
    /// Validates the request using the configured pipeline.
    /// Returns an error response if validation fails, or `nil` if the request is valid.
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse?
}

// MARK: - Standard Validation Pipeline

/// Standard implementation of `HTTPRequestValidationPipeline` that runs validators in sequence.
///
/// The first validator that returns a non-nil error response short-circuits the pipeline.
public struct StandardValidationPipeline: HTTPRequestValidationPipeline {
    private let validators: [any HTTPRequestValidator]

    /// Creates a pipeline with the given validators.
    /// Validators are executed in the order provided.
    public init(validators: [any HTTPRequestValidator]) {
        self.validators = validators
    }

    /// Returns the first error response of the validators, in order, or `nil`.
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        for validator in validators {
            if let errorResponse = validator.validate(request, context: context) {
                return errorResponse
            }
        }
        return nil
    }
}
