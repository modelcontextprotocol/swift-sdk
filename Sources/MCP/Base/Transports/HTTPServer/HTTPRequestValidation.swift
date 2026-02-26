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

    public init(
        httpMethod: String,
        sessionID: String? = nil,
        isInitializationRequest: Bool = false,
        supportedProtocolVersions: Set<String> = Version.supported
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

/// Validates the `MCP-Protocol-Version` header against supported versions.
///
/// Per spec:
/// - If the header is absent, the server assumes the default negotiated version
/// - If the header is present but unsupported, the server returns 400 Bad Request
/// - Initialization requests are exempt (protocol version comes from the request body)
public struct ProtocolVersionValidator: HTTPRequestValidator {
    public init() {}

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Skip for initialization requests (version is in the body, not the header)
        guard !context.isInitializationRequest else { return nil }

        // Skip for non-POST methods (GET/DELETE don't carry protocol version)
        // Actually, per spec, all subsequent requests should include it
        guard let version = request.header(HTTPHeaderName.protocolVersion) else {
            // Per spec: if not received, assume default version
            return nil
        }

        guard context.supportedProtocolVersions.contains(version) else {
            let supported = context.supportedProtocolVersions.sorted().joined(separator: ", ")
            return .error(
                statusCode: 400,
                .invalidRequest(
                    "Bad Request: Unsupported protocol version: \(version). Supported: \(supported)"
                ),
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
    public init() {}

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
