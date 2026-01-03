import Foundation

/// Result of tool name validation.
public struct ToolNameValidationResult: Sendable {
    /// Whether the tool name is valid.
    public let isValid: Bool
    /// Warnings about the tool name (may be present even if valid).
    public let warnings: [String]

    public init(isValid: Bool, warnings: [String]) {
        self.isValid = isValid
        self.warnings = warnings
    }
}

/// Validates tool names according to MCP specification.
///
/// Tool names must:
/// - Be 1-128 characters long
/// - Contain only alphanumeric characters, underscores, dashes, and dots
///
/// - SeeAlso: https://github.com/modelcontextprotocol/modelcontextprotocol/issues/986
public func validateToolName(_ name: String) -> ToolNameValidationResult {
    var warnings: [String] = []

    // Check length
    if name.isEmpty {
        return ToolNameValidationResult(isValid: false, warnings: ["Tool name cannot be empty"])
    }

    if name.count > 128 {
        return ToolNameValidationResult(
            isValid: false,
            warnings: ["Tool name exceeds maximum length of 128 characters (current: \(name.count))"]
        )
    }

    // Check for specific problematic patterns (warnings, not validation failures)
    if name.contains(" ") {
        warnings.append("Tool name contains spaces, which may cause parsing issues")
    }

    if name.contains(",") {
        warnings.append("Tool name contains commas, which may cause parsing issues")
    }

    // Check for potentially confusing patterns
    if name.hasPrefix("-") || name.hasSuffix("-") {
        warnings.append(
            "Tool name starts or ends with a dash, which may cause parsing issues in some contexts"
        )
    }

    if name.hasPrefix(".") || name.hasSuffix(".") {
        warnings.append(
            "Tool name starts or ends with a dot, which may cause parsing issues in some contexts"
        )
    }

    // Check for invalid characters
    let validCharacterSet = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    let nameCharacterSet = CharacterSet(charactersIn: name)

    if !validCharacterSet.isSuperset(of: nameCharacterSet) {
        // Find invalid characters
        let invalidChars = name.filter { char in
            let charString = String(char)
            let charSet = CharacterSet(charactersIn: charString)
            return !validCharacterSet.isSuperset(of: charSet)
        }
        let uniqueInvalidChars = Set(invalidChars).map { "\"\($0)\"" }.joined(separator: ", ")

        warnings.append("Tool name contains invalid characters: \(uniqueInvalidChars)")
        warnings.append(
            "Allowed characters are: A-Z, a-z, 0-9, underscore (_), dash (-), and dot (.)"
        )

        return ToolNameValidationResult(isValid: false, warnings: warnings)
    }

    return ToolNameValidationResult(isValid: true, warnings: warnings)
}

/// Validates a tool name and logs any warnings.
///
/// - Parameters:
///   - name: The tool name to validate
///   - logger: Optional logger for warnings
/// - Returns: Whether the tool name is valid
@discardableResult
public func validateAndWarnToolName(_ name: String) -> Bool {
    let result = validateToolName(name)

    if !result.warnings.isEmpty {
        print("Tool name validation warning for \"\(name)\":")
        for warning in result.warnings {
            print("  - \(warning)")
        }
        if result.isValid {
            print("Tool registration will proceed, but this may cause compatibility issues.")
            print("Consider updating the tool name to conform to the MCP tool naming standard.")
            print(
                "See SEP: Specify Format for Tool Names (https://github.com/modelcontextprotocol/modelcontextprotocol/issues/986) for more details."
            )
        }
    }

    return result.isValid
}
