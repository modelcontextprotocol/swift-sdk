import Crypto
import Foundation

/// Serves a ``ServerCard`` at `<endpoint>/server-card`, the location the
/// Server Card extension recommends (SEP-2127).
///
/// - A `GET` gets the card as ``ServerCard/mediaType``, with an `ETag`,
///   `Cache-Control: public, max-age=<maxAge>` and
///   `Access-Control-Allow-Origin: *`. With an `If-None-Match` that matches
///   the `ETag`, it gets 304 and no body. A `HEAD` gets the headers of a `GET`,
///   with the card's length in `Content-Length`, and no body.
/// - An `OPTIONS` (a CORS preflight) gets 204 with the CORS headers.
/// - Another method gets 405. The `Accept` header is not checked: every
///   `GET` gets the card.
///
/// A card is public: it must not contain credentials or private endpoints.
/// Answer card requests before the MCP endpoint, with ``response(to:)``,
/// or put the validator first in the pipeline of a transport that sees the
/// card's path, as ``ProtectedResourceMetadataValidator``.
///
/// ```swift
/// let card = try ServerCardValidator(
///     card: ServerCard(info: info, endpoint: endpoint, protocolVersions: Version.supported),
///     endpointPath: "/mcp")
/// if let response = card.response(to: request) { return response }
/// ```
public struct ServerCardValidator: HTTPRequestValidator {
    /// The path the card is served at: `<endpointPath>/server-card`.
    public let path: String

    private let body: Data
    private let etag: String
    private let cacheControl: String

    /// Creates a validator that serves `card`.
    ///
    /// - Parameters:
    ///   - card: The card. It must follow the format.
    ///   - endpointPath: The path of the MCP endpoint, such as `/mcp`.
    ///   - maxAge: How long clients and caches may keep the card, in seconds.
    /// - Throws: ``ServerCardError`` when the card does not follow the format,
    ///   or does not encode as JSON (a non-finite number in `_meta`).
    public init(card: ServerCard, endpointPath: String = "/mcp", maxAge: Int = 3600) throws(ServerCardError) {
        try card.validate()
        var base = endpointPath
        while base.hasSuffix("/") { base.removeLast() }
        path = base + "/server-card"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            body = try encoder.encode(card)
        } catch {
            throw ServerCardError(.invalidCard, "The card does not encode as JSON: \(error)")
        }
        let digest = SHA256.hash(data: body).prefix(16).map { String(format: "%02x", $0) }.joined()
        etag = "\"\(digest)\""
        cacheControl = "public, max-age=\(max(maxAge, 0))"
    }

    /// The response to a request for the card's path, or `nil` for another path.
    public func response(to request: HTTPRequest) -> HTTPResponse? {
        guard request.path == path else { return nil }
        let cors = [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET",
            "Access-Control-Allow-Headers": "Content-Type, If-None-Match",
            "Access-Control-Expose-Headers": HTTPHeaderName.etag,
        ]
        switch request.method.uppercased() {
        case "GET", "HEAD":
            var headers = cors
            headers[HTTPHeaderName.etag] = etag
            headers[HTTPHeaderName.cacheControl] = cacheControl
            if let tags = request.header(HTTPHeaderName.ifNoneMatch), Self.matches(tags, etag) {
                return .data(Data(), statusCode: 304, headers: headers)
            }
            headers[HTTPHeaderName.contentType] = ServerCard.mediaType
            guard request.method.uppercased() == "HEAD" else { return .data(body, headers: headers) }
            // The body is empty: an adapter must not derive the length from it.
            headers["Content-Length"] = String(body.count)
            return .data(Data(), headers: headers)
        case "OPTIONS":
            return .data(Data(), statusCode: 204, headers: cors)
        default:
            return .error(
                statusCode: 405, .invalidRequest("Method Not Allowed"),
                extraHeaders: [HTTPHeaderName.allow: "GET, HEAD, OPTIONS"])
        }
    }

    /// Returns ``response(to:)``.
    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        response(to: request)
    }

    /// Whether an `If-None-Match` value matches `etag`, with the weak
    /// comparison of RFC 9110 §13.1.2.
    static func matches(_ header: String, _ etag: String) -> Bool {
        let strip = { (tag: Substring) -> Substring in
            let trimmed = tag.trimmingCharacters(in: .whitespaces)[...]
            return trimmed.hasPrefix("W/") ? trimmed.dropFirst(2) : trimmed
        }
        return header.split(separator: ",").contains { tag in
            let tag = strip(tag)
            return tag == "*" || tag == strip(Substring(etag))
        }
    }
}
