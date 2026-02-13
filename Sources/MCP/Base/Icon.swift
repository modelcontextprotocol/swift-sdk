import Foundation

/// An optionally-sized icon that can be displayed in a user interface.
///
/// Icons can be used to provide visual representation of tools, resources, prompts,
/// and other MCP entities.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/schema#icon
public struct Icon: Hashable, Codable, Sendable {
    /// The theme this icon is designed for.
    public enum Theme: String, Hashable, Codable, Sendable {
        /// Icon is designed for light backgrounds
        case light
        /// Icon is designed for dark backgrounds
        case dark
    }

    /// A standard URI pointing to an icon resource.
    ///
    /// May be an HTTP/HTTPS URL or a `data:` URI with Base64-encoded image data.
    ///
    /// - Note: Consumers SHOULD take steps to ensure URLs serving icons are from
    ///   the same domain as the client/server or a trusted domain.
    /// - Note: Consumers SHOULD take appropriate precautions when consuming SVGs
    ///   as they can contain executable JavaScript.
    public let src: String

    /// Optional MIME type override if the source MIME type is missing or generic.
    ///
    /// For example: `"image/png"`, `"image/jpeg"`, or `"image/svg+xml"`.
    public let mimeType: String?

    /// Optional array of strings that specify sizes at which the icon can be used.
    ///
    /// Each string should be in WxH format (e.g., `"48x48"`, `"96x96"`) or `"any"`
    /// for scalable formats like SVG.
    ///
    /// If not provided, the client should assume that the icon can be used at any size.
    public let sizes: [String]?

    /// Optional specifier for the theme this icon is designed for.
    ///
    /// - `light`: Icon is designed to be used with a light background
    /// - `dark`: Icon is designed to be used with a dark background
    ///
    /// If not provided, the client should assume the icon can be used with any theme.
    public let theme: Theme?

    /// Creates a new icon.
    ///
    /// - Parameters:
    ///   - src: A standard URI pointing to an icon resource (HTTP/HTTPS URL or data: URI)
    ///   - mimeType: Optional MIME type override
    ///   - sizes: Optional array of size strings (e.g., ["48x48", "96x96"])
    ///   - theme: Optional theme specifier
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
