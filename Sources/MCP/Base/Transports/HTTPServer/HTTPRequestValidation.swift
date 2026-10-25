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

    /// Whether the request is a modern `server/discover` call.
    public let isDiscoverRequest: Bool

    /// Whether the request declares a modern (2026-07-28+) protocol version.
    public let isModernRequest: Bool

    /// Protocol version from `params._meta.io.modelcontextprotocol/protocolVersion`, if present.
    /// When set, this is authoritative for modern requests and must agree with the HTTP header.
    public let bodyProtocolVersion: String?

    /// The set of protocol versions this server supports.
    public let supportedProtocolVersions: Set<String>

    /// Requests that do not require a legacy MCP session id.
    public var isSessionExempt: Bool {
        isInitializationRequest || isDiscoverRequest || isModernRequest
    }

    public init(
        httpMethod: String,
        sessionID: String? = nil,
        isInitializationRequest: Bool = false,
        isDiscoverRequest: Bool = false,
        isModernRequest: Bool = false,
        bodyProtocolVersion: String? = nil,
        supportedProtocolVersions: Set<String> = Version.supported
    ) {
        self.httpMethod = httpMethod
        self.sessionID = sessionID
        self.isInitializationRequest = isInitializationRequest
        self.isDiscoverRequest = isDiscoverRequest
        self.isModernRequest = isModernRequest
        self.bodyProtocolVersion = bodyProtocolVersion
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
    public enum Mode: Sendable {
        /// POST requires both `application/json` and `text/event-stream`.
        case sseRequired
        /// POST only requires `application/json`.
        case jsonOnly
    }

    public let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

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
    public init() {}

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

/// Validates protocol version from the `MCP-Protocol-Version` header and/or body `_meta`.
///
/// Per MCP 2026-07-28:
/// - Body `_meta` version is authoritative for modern requests
/// - Header and body MUST agree when both are present
/// - Unsupported versions return HTTP 400 with ``MCPError/unsupportedProtocolVersion(requested:supported:)`` (-32022)
/// - Legacy: if neither is present, assume the negotiated version
/// - Initialization requests are exempt (version is negotiated in the initialize body)
public struct ProtocolVersionValidator: HTTPRequestValidator {
    public init() {}

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Skip for initialization requests (version is in the initialize body)
        guard !context.isInitializationRequest else { return nil }

        let headerVersion = request.header(HTTPHeaderName.protocolVersion)
        let bodyVersion = context.bodyProtocolVersion
        let supported = Array(Array(context.supportedProtocolVersions).sorted().reversed())

        if let bodyVersion, let headerVersion, headerVersion != bodyVersion {
            // Both values may be supported — this is disagreement, not "unsupported".
            return .error(
                statusCode: 400,
                .invalidRequest(
                    "MCP-Protocol-Version header (\(headerVersion)) disagrees with params._meta.\(ProtocolMetaKey.protocolVersion) (\(bodyVersion))"
                ),
                sessionID: context.sessionID
            )
        }

        // A modern header without body `_meta.protocolVersion` would otherwise be
        // accepted here and then mishandled as legacy by the server. Only JSON-RPC
        // *requests* need `_meta`; responses/notifications and GET/DELETE do not.
        if context.httpMethod == "POST",
            let headerVersion, Version.isModern(headerVersion), bodyVersion == nil,
            Self.isJSONRPCRequest(request.body)
        {
            return .error(
                statusCode: 400,
                .invalidRequest(
                    "Modern MCP-Protocol-Version requires params._meta.\(ProtocolMetaKey.protocolVersion)"
                ),
                sessionID: context.sessionID
            )
        }

        let version = bodyVersion ?? headerVersion
        guard let version else {
            // Modern-classified POSTs (discover/listen / modern body) require a version.
            if context.httpMethod == "POST",
                context.isModernRequest,
                Self.isJSONRPCRequest(request.body)
            {
                return .error(
                    statusCode: 400,
                    .invalidRequest(
                        "Modern requests require params._meta.\(ProtocolMetaKey.protocolVersion)"
                    ),
                    sessionID: context.sessionID
                )
            }
            // Legacy: if not received, assume default version.
            return nil
        }

        guard context.supportedProtocolVersions.contains(version) else {
            return .error(
                statusCode: 400,
                .unsupportedProtocolVersion(requested: version, supported: supported),
                sessionID: context.sessionID
            )
        }

        return nil
    }

    private static func isJSONRPCRequest(_ body: Data?) -> Bool {
        guard let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            json["method"] is String,
            json["id"] != nil
        else { return false }
        return true
    }
}

// MARK: - Session Validator

/// Validates the `Mcp-Session-Id` header for stateful transports.
///
/// - Initialization requests are exempt (no session exists yet)
/// - Non-initialization requests must include the session ID header
/// - The session ID must match the active session
public struct SessionValidator: HTTPRequestValidator {
    public init() {}

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Skip validation for initialize, discover, and modern per-request profile.
        guard !context.isSessionExempt else { return nil }

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
    public let allowedHosts: [String]
    public let allowedOrigins: [String]
    private let enabled: Bool

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
    /// Allows requests from `localhost`, `127.0.0.1`, and `[::1]` with the specified port.
    public static func localhost(port: Int? = nil) -> OriginValidator {
        let portPattern = port.map { String($0) } ?? "*"
        return OriginValidator(
            allowedHosts: [
                "127.0.0.1:\(portPattern)",
                "localhost:\(portPattern)",
                "[::1]:\(portPattern)",
            ],
            allowedOrigins: [
                "http://127.0.0.1:\(portPattern)",
                "http://localhost:\(portPattern)",
                "http://[::1]:\(portPattern)",
            ]
        )
    }

    /// Disables DNS rebinding protection.
    /// Use for cloud deployments where DNS rebinding is not a threat.
    public static var disabled: OriginValidator {
        OriginValidator(disabled: ())
    }

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
    /// - `"localhost:*"` matches `"localhost:8080"`, `"localhost:3000"`
    /// - `"http://localhost:*"` matches `"http://localhost:8080"`
    /// - `"localhost:8080"` matches only `"localhost:8080"` exactly
    private func matchesPattern(_ value: String, pattern: String) -> Bool {
        guard pattern.hasSuffix(":*") else {
            return value == pattern
        }

        let prefix = String(pattern.dropLast(2))
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

    public init(metadata: OAuthProtectedResourceServerMetadata) {
        self.encodedMetadata = (try? JSONEncoder().encode(metadata)) ?? Data()
    }

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

/// Result produced by ``BearerTokenValidator`` when validating an access token.
public enum BearerTokenValidationResult: Sendable, Equatable {
    /// Access token is valid for this request, with its extracted claims.
    ///
    /// Supply a ``BearerTokenInfo`` with `audience` and `expiresAt` populated so that
    /// ``BearerTokenValidator`` can enforce expiry and audience checks automatically.
    /// Pass `BearerTokenInfo()` (all `nil`) to delegate all enforcement to the caller.
    case valid(BearerTokenInfo)

    /// Access token is missing required privileges, and new scopes are required.
    case insufficientScope(requiredScopes: Set<String>, errorDescription: String? = nil)

    /// Access token is invalid or expired.
    case invalidToken(errorDescription: String? = nil)

    /// Authorization request is malformed.
    case malformedRequest(errorDescription: String? = nil)
}

/// Validates OAuth 2.1 Bearer authorization for protected MCP HTTP endpoints.
///
/// This validator implements resource-server error semantics aligned with the MCP auth spec:
/// - `401` with `WWW-Authenticate: Bearer ...` for missing/invalid tokens
/// - `403` with `error="insufficient_scope"` for insufficient permissions
/// - `400` for malformed authorization requests
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
///     tokenValidator: { token, request, context in
///         guard let claims = verifyAndDecode(token) else {
///             return .invalidToken(errorDescription: "Token verification failed")
///         }
///         // MUST: Verify token audience matches this resource server
///         guard claims.audience.contains("https://api.example.com") else {
///             return .invalidToken(errorDescription: "Token audience mismatch")
///         }
///         return .valid
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

    public let resourceMetadataURL: URL
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

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard requiresAuthentication(request, context) else { return nil }

        guard let authorizationHeader = request.header(HTTPHeaderName.authorization) else {
            return unauthorizedResponse(
                challengeScope: challengeScopeProvider?(request, context),
                error: nil,
                errorDescription: nil,
                sessionID: context.sessionID
            )
        }

        let parsedToken: String
        switch parseBearerToken(from: authorizationHeader) {
        case .success(let token):
            parsedToken = token
        case .failure(let error):
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: \(error.message)"),
                sessionID: context.sessionID
            )
        }

        switch tokenValidator(parsedToken, request, context) {
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
            let message = errorDescription ?? "Malformed authorization request"
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: \(message)"),
                sessionID: context.sessionID
            )
        }
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

    private struct BearerTokenParseError: Swift.Error {
        let message: String
    }

    private func parseBearerToken(
        from authorizationHeader: String
    ) -> Result<String, BearerTokenParseError> {
        let trimmed = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.init(message: "Authorization header is empty"))
        }

        let parts = trimmed.split(
            maxSplits: 1,
            whereSeparator: { $0.isWhitespace }
        )

        guard parts.count == 2 else {
            return .failure(
                .init(message: "Authorization header must be in the form: Bearer <token>")
            )
        }

        guard String(parts[0]).caseInsensitiveCompare(OAuthTokenType.bearer) == .orderedSame else {
            return .failure(.init(message: "Authorization scheme must be Bearer"))
        }

        let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .failure(.init(message: "Bearer token is empty"))
        }

        if token.contains(where: \.isWhitespace) {
            return .failure(.init(message: "Bearer token must not contain whitespace"))
        }

        return .success(token)
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

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        for validator in validators {
            if let errorResponse = validator.validate(request, context: context) {
                return errorResponse
            }
        }
        return nil
    }
}
