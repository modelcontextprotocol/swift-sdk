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
        if let charset = charset, !charset.isEmpty, mimeType.starts(with: "text/") {
            mimeType += ";charset=\(charset)"
        }

        // Decode data
        let decodedData: Data
        if isBase64 {
            guard let base64Data = Data(base64Encoded: String(encodedData)) else { return nil }
            decodedData = base64Data
        } else {
            guard let percentDecodedData = percentDecoded(encodedData) else { return nil }
            decodedData = percentDecodedData
        }

        return (mimeType: mimeType, data: decodedData)
    }

    /// Decodes `%XX` escapes directly into bytes, so any byte value is accepted.
    ///
    /// - Parameter string: The percent-encoded string.
    /// - Returns: The decoded bytes, or `nil` if an escape is malformed.
    private static func percentDecoded(_ string: Substring) -> Data? {
        let utf8 = Array(string.utf8)
        var bytes = Data(capacity: utf8.count)
        var index = 0
        while index < utf8.count {
            guard utf8[index] == UInt8(ascii: "%") else {
                bytes.append(utf8[index])
                index += 1
                continue
            }
            guard index + 2 < utf8.count,
                let high = hexValue(utf8[index + 1]),
                let low = hexValue(utf8[index + 2])
            else { return nil }
            bytes.append(high << 4 | low)
            index += 3
        }
        return bytes
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
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
