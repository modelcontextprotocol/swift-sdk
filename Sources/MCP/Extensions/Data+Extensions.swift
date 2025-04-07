import Foundation
#if canImport(RegexBuilder)
import RegexBuilder
#endif

extension Data {
    // macOS 13+ implementation using RegexBuilder.
    @available(macOS 13, *)
    private static var dataURLRegex: Regex<(Substring, Substring, Substring?, Substring)> {
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
                OneOrMore { .any }
            }
        }
    }
    
    /// Checks if a given string is a valid data URL.
    public static func isDataURL(string: String) -> Bool {
        if #available(macOS 13, *) {
            return string.wholeMatch(of: dataURLRegex) != nil
        } else {
            return _isDataURL_legacy(string: string)
        }
    }

    public static func _isDataURL_legacy(string: String) -> Bool {
        let pattern = "^data:([^,;]*)(?:;charset=([^,;]+))?(?:;base64)?,(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
    
    /// Parses a data URL string into its MIME type and data components.
    public static func parseDataURL(_ string: String) -> (mimeType: String, data: Data)? {
        if #available(macOS 13, *) {
            guard let match = string.wholeMatch(of: dataURLRegex) else {
                return nil
            }
            let (_, mediatype, charset, encodedData) = match.output
            let isBase64 = string.contains(";base64,")
            
            var mimeType = mediatype.isEmpty ? "text/plain" : String(mediatype)
            if let charset = charset, !charset.isEmpty, mimeType.starts(with: "text/") {
                mimeType += ";charset=\(charset)"
            }
            
            let decodedData: Data
            if isBase64 {
                guard let base64Data = Data(base64Encoded: String(encodedData)) else { return nil }
                decodedData = base64Data
            } else {
                guard let percentDecodedData = String(encodedData)
                        .removingPercentEncoding?
                        .data(using: .utf8)
                else { return nil }
                decodedData = percentDecodedData
            }
            return (mimeType: mimeType, data: decodedData)
        } else {
            return _parseDataURL_legacy(string)
        }
    }

    public static func _parseDataURL_legacy(_ string: String) -> (mimeType: String, data: Data)? {
        let pattern = "^data:([^,;]*)(?:;charset=([^,;]+))?(?:;base64)?,(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range) else { return nil }
        
        let nsString = string as NSString
        let mediatype = nsString.substring(with: match.range(at: 1))
        let charset: String? = match.range(at: 2).location != NSNotFound
            ? nsString.substring(with: match.range(at: 2))
            : nil
        let encodedData = nsString.substring(with: match.range(at: 3))
        
        let isBase64 = string.contains(";base64,")
        var mimeType = mediatype.isEmpty ? "text/plain" : mediatype
        if let charset = charset, !charset.isEmpty, mimeType.hasPrefix("text/") {
            mimeType += ";charset=\(charset)"
        }
        
        let decodedData: Data
        if isBase64 {
            guard let base64Data = Data(base64Encoded: encodedData) else { return nil }
            decodedData = base64Data
        } else {
            guard let percentDecodedData = encodedData.removingPercentEncoding?
                    .data(using: .utf8)
            else { return nil }
            decodedData = percentDecodedData
        }
        return (mimeType: mimeType, data: decodedData)
    }
    
    /// Encodes the data as a data URL string with an optional MIME type.
    public func dataURLEncoded(mimeType: String? = nil) -> String {
        let base64Data = self.base64EncodedString()
        return "data:\(mimeType ?? "text/plain");base64,\(base64Data)"
    }
}
