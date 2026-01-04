import Foundation
import RegexBuilder

extension Data {
    /// Regex pattern for data URLs
    @inline(__always) private static var dataURLRegex:
        Regex<(Substring, Substring, Substring?, Substring)>
    {
        Regex {
            "data:"
            Capture {
                ZeroOrMore(.reluctant) {
                    CharacterClass.anyOf(",;").inverted
                }
            }
            Optionally {
                ";charset="
                Capture {
                    OneOrMore(.reluctant) {
                        CharacterClass.anyOf(",;").inverted
                    }
                }
            }
            Optionally { ";base64" }
            ","
            Capture {
                ZeroOrMore { .any }
            }
        }
    }

    /// Checks if a given string is a valid data URL.
    ///
    /// - Parameter string: The string to check.
    /// - Returns: `true` if the string is a valid data URL, otherwise `false`.
    /// - SeeAlso: [RFC 2397](https://www.rfc-editor.org/rfc/rfc2397.html)
    public static func isDataURL(string: String) -> Bool {
        return string.wholeMatch(of: dataURLRegex) != nil
    }

    /// Parses a data URL string into its MIME type and data components.
    ///
    /// - Parameter string: The data URL string to parse.
    /// - Returns: A tuple containing the MIME type and decoded data, or `nil` if parsing fails.
    /// - SeeAlso: [RFC 2397](https://www.rfc-editor.org/rfc/rfc2397.html)
    public static func parseDataURL(_ string: String) -> (mimeType: String, data: Data)? {
        guard let match = string.wholeMatch(of: dataURLRegex) else {
            return nil
        }

        // Extract components using strongly typed captures
        let (_, mediatype, charset, encodedData) = match.output

        let isBase64 = string.contains(";base64,")

        // Process MIME type
        var mimeType = mediatype.isEmpty ? "text/plain" : String(mediatype)
        if let charset, !charset.isEmpty, mimeType.starts(with: "text/") {
            mimeType += ";charset=\(charset)"
        }

        // Decode data
        let decodedData: Data
        if isBase64 {
            guard let base64Data = Data(base64Encoded: String(encodedData)) else { return nil }
            decodedData = base64Data
        } else {
            guard
                let percentDecodedData = String(encodedData).removingPercentEncoding?.data(
                    using: .utf8)
            else { return nil }
            decodedData = percentDecodedData
        }

        return (mimeType: mimeType, data: decodedData)
    }

    /// Encodes the data as a data URL string with an optional MIME type.
    ///
    /// - Parameter mimeType: The MIME type of the data. If `nil`, "text/plain" will be used.
    /// - Returns: A data URL string representation of the data.
    /// - SeeAlso: [RFC 2397](https://www.rfc-editor.org/rfc/rfc2397.html)
    public func dataURLEncoded(mimeType: String? = nil) -> String {
        let base64Data = self.base64EncodedString()
        return "data:\(mimeType ?? "text/plain");base64,\(base64Data)"
    }
}
