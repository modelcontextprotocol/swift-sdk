// Checks that every public declaration of the MCP module has a doc comment.
//
//   swift scripts/doc-coverage.swift          list undocumented declarations; fail if any
//
// A declaration is `public` or `open` in Sources/MCP, or a `case` of a public
// enum: a case takes no access modifier, it has the access of its enum. Cases
// of `private`, `internal` or `package` enums (`CodingKeys`) are not checked,
// nor the cases of `switch` statements. Exempt are the members that
// conformances define and DocC documents from the protocol: Codable,
// Equatable, Hashable and RawRepresentable members, literal initializers,
// descriptions, `AsyncSequence` plumbing, and the `name` and `Parameters` /
// `Result` of `Method` and `Notification` types.
//
// The scan reads lines, not a syntax tree: it finds enum bodies by counting
// braces outside string literals and comments, and skips the lines of
// multi-line string literals.

import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("Sources/MCP")

let declaration = try NSRegularExpression(
    pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\s+(?:(?:static|final|override|nonisolated|mutating|indirect|convenience|required|private\(set\)|internal\(set\))\s+)*(func|var|let|init|subscript|enum|struct|class|actor|protocol|typealias)\b"#)
let exempt = try NSRegularExpression(
    pattern: #"init\(from decoder|func encode\(to encoder|static func (==|~=|<)|func hash\(into|var (description|debugDescription|errorDescription|failureReason|recoverySuggestion)\b|let rawValue|init\((rawValue|stringLiteral|integerLiteral|floatLiteral|booleanLiteral|nilLiteral|arrayLiteral|dictionaryLiteral|stringInterpolation|unicodeScalarLiteral|extendedGraphemeClusterLiteral)\b|func makeAsyncIterator|func next\(\)|typealias (Element|AsyncIterator|RawValue|Parameters|Result|ArrayLiteralElement|Key|Value|StringLiteralType|IntegerLiteralType)\b|static let name(: String)? ="#)
/// An enum declaration; group 1 is its access modifier, if any.
let enumDeclaration = try NSRegularExpression(
    pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(public|open|package|internal|fileprivate|private)\s+)?(?:indirect\s+)?enum\s+\w"#)
/// String literals, raw (`#"…"#`) or not, so that the braces in them are not counted.
let stringLiteral = try NSRegularExpression(pattern: ##"#"(?:[^"]|"(?!#))*"#|"(?:[^"\\]|\\.)*""##)

func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
    regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

/// The line without its string literals and its `//` comment.
func code(_ line: String) -> String {
    let stripped = stringLiteral.stringByReplacingMatches(
        in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "\"\"")
    guard let comment = stripped.range(of: "//") else { return stripped }
    return String(stripped[..<comment.lowerBound])
}

func count(_ character: Character, in line: String) -> Int {
    code(line).filter { $0 == character }.count
}

/// The first line of the attribute that ends on line `end`, when its
/// arguments span several lines: walking up from `end`, the parentheses
/// balance on a line that starts with `@`, at most 8 lines up.
func attributeStart(endingAt end: Int, in lines: [String]) -> Int? {
    var depth = 0
    for index in stride(from: end, through: max(0, end - 8), by: -1) {
        let text = lines[index].trimmingCharacters(in: .whitespaces)
        depth += count(")", in: text) - count("(", in: text)
        if text.hasPrefix("@") { return depth == 0 && index < end ? index : nil }
        if depth <= 0 { return nil }
    }
    return nil
}

/// Whether the declaration on line `index` has a doc comment above it,
/// past its attributes.
func isDocumented(_ index: Int, in lines: [String]) -> Bool {
    var previous = index - 1
    while previous >= 0 {
        let text = lines[previous].trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("@") {
            previous -= 1
        } else if let start = attributeStart(endingAt: previous, in: lines) {
            previous = start - 1
        } else {
            break
        }
    }
    let above = previous >= 0 ? lines[previous].trimmingCharacters(in: .whitespaces) : ""
    return above.hasPrefix("///") || above.hasSuffix("*/")
}

var undocumented: [String] = []
let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
    .compactMap { $0 as? URL }
    .filter { $0.pathExtension == "swift" }
    .sorted { $0.path < $1.path }
for file in files {
    let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    let path = file.path.replacingOccurrences(of: root.path + "/", with: "")
    // One entry per open brace: whether it opens the body of a public enum.
    var scopes: [Bool] = []
    // Whether the next brace opens the body of a public enum just declared.
    var enumBody: Bool?
    var inMultilineString = false
    for (index, line) in lines.enumerated() {
        if line.components(separatedBy: "\"\"\"").count % 2 == 0 {
            inMultilineString.toggle()
            continue
        }
        if inMultilineString { continue }
        let text = code(line)
        let isPublicCase =
            scopes.last == true && text.trimmingCharacters(in: .whitespaces).hasPrefix("case ")
        if (isPublicCase || matches(declaration, line)) && !matches(exempt, line)
            && !isDocumented(index, in: lines)
        {
            undocumented.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        if let match = enumDeclaration.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let access = Range(match.range(at: 1), in: text).map { String(text[$0]) }
            enumBody = access == "public" || access == "open"
        }
        for character in text {
            if character == "{" {
                scopes.append(enumBody ?? false)
                enumBody = nil
            } else if character == "}" {
                _ = scopes.popLast()
            }
        }
    }
}

if undocumented.isEmpty {
    print("every public declaration is documented")
} else {
    undocumented.forEach { print($0) }
    print("\(undocumented.count) public declarations without a doc comment")
    exit(1)
}
