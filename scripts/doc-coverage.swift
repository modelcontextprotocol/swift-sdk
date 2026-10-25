// Checks that every public declaration of the MCP module has a doc comment.
//
//   swift scripts/doc-coverage.swift          list undocumented declarations; fail if any
//
// A declaration is `public` or `open` in Sources/MCP. Exempt are the members
// that conformances define and DocC documents from the protocol: Codable,
// Equatable, Hashable and RawRepresentable members, literal initializers,
// descriptions, `AsyncSequence` plumbing, and the `name` and `Parameters` /
// `Result` of `Method` and `Notification` types.

import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("Sources/MCP")

let declaration = try NSRegularExpression(
    pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\s+(?:(?:static|final|override|nonisolated|mutating|indirect|convenience|required|private\(set\)|internal\(set\))\s+)*(func|var|let|init|subscript|enum|struct|class|actor|protocol|typealias|case)\b"#)
let exempt = try NSRegularExpression(
    pattern: #"init\(from decoder|func encode\(to encoder|static func (==|~=|<)|func hash\(into|var (description|debugDescription|errorDescription|failureReason|recoverySuggestion)\b|let rawValue|init\((rawValue|stringLiteral|integerLiteral|floatLiteral|booleanLiteral|nilLiteral|arrayLiteral|dictionaryLiteral|stringInterpolation|unicodeScalarLiteral|extendedGraphemeClusterLiteral)\b|func makeAsyncIterator|func next\(\)|typealias (Element|AsyncIterator|RawValue|Parameters|Result|ArrayLiteralElement|Key|Value|StringLiteralType|IntegerLiteralType)\b|static let name(: String)? ="#)

func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
    regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

var undocumented: [String] = []
let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
    .compactMap { $0 as? URL }
    .filter { $0.pathExtension == "swift" }
    .sorted { $0.path < $1.path }
for file in files {
    let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    for (index, line) in lines.enumerated() where matches(declaration, line) && !matches(exempt, line) {
        // Skip attributes between the doc comment and the declaration,
        // including attributes whose arguments span several lines.
        var previous = index - 1
        while previous >= 0 {
            let text = lines[previous].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("@") {
                previous -= 1
            } else if !text.hasPrefix("///"), text.hasSuffix(")") || text.hasSuffix(","),
                let start = (max(0, previous - 8)..<previous).reversed().first(where: {
                    lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("@")
                })
            {
                previous = start - 1
            } else {
                break
            }
        }
        let above = previous >= 0 ? lines[previous].trimmingCharacters(in: .whitespaces) : ""
        if above.hasPrefix("///") || above.hasSuffix("*/") { continue }
        let path = file.path.replacingOccurrences(of: root.path + "/", with: "")
        undocumented.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
    }
}

if undocumented.isEmpty {
    print("every public declaration is documented")
} else {
    undocumented.forEach { print($0) }
    print("\(undocumented.count) public declarations without a doc comment")
    exit(1)
}
