import Foundation

/// Icon metadata for representing visual icons for tools, resources, prompts, and implementations.
///
/// Icons can be provided as HTTP/HTTPS URLs or data URIs (base64-encoded images).
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/
public struct Icon: Hashable, Codable, Sendable {
    /// URL or data URI for the icon.
    ///
    /// Can be an HTTP/HTTPS URL or a data URI (e.g., `data:image/png;base64,...`).
    public let src: String

    /// Optional MIME type for the icon.
    ///
    /// Useful when the MIME type cannot be inferred from the `src` URL.
    public let mimeType: String?

    /// Optional array of strings that specify sizes at which the icon can be used.
    ///
    /// Each string should be in WxH format (e.g., `"48x48"`, `"96x96"`) or `"any"` for
    /// scalable formats like SVG.
    ///
    /// If not provided, the client should assume that the icon can be used at any size.
    public let sizes: [String]?

    /// Optional specifier for the theme this icon is designed for.
    ///
    /// If not provided, the client should assume the icon can be used with any theme.
    public let theme: Theme?

    /// The theme an icon is designed for.
    public enum Theme: String, Hashable, Codable, Sendable {
        /// Icon designed for use with a light background.
        case light
        /// Icon designed for use with a dark background.
        case dark
    }

    public init(
        src: String,
        mimeType: String? = nil,
        sizes: [String]? = nil,
        theme: Theme? = nil
    ) {
        self.src = src
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }
}
