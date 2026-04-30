import XCTest
@testable import MCP

final class DataExtensionsTests: XCTestCase {
    
    let validURLs = [
        "data:,Hello%2C%20World!",
        "data:text/plain;base64,SGVsbG8sIFdvcmxkIQ==",
        "data:text/html;charset=UTF-8,<h1>Hello%2C%20World!</h1>",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA", // Minimal valid PNG
        "data:text/plain;charset=UTF-8;base64,SGVsbG8sIFdvcmxkIQ==",
        "data:application/json;base64,eyJrZXkiOiAidmFsdWUifQ==" // {"key": "value"}
    ]
    
    let invalidURLs = [
        "",
        "http://example.com",
        "data:", // Missing comma and data
        "data:text/plain", // Missing comma and data
        "data:text/plain;base64", // Missing comma and data
        "data:text/plain,", // Missing data
        "data:;base64,SGVsbG8sIFdvcmxkIQ==", // Missing mime type (allowed, defaults to text/plain)
    ]

    // MARK: - Data URL Validation Tests
    
    func testIsDataURL() {
        for url in validURLs {
            XCTAssertTrue(Data.isDataURL(string: url), "Should be a valid data URL: \(url)")
        }
        
        for url in invalidURLs {
            // Special case: "data:;base64,SGVsbG8sIFdvcmxkIQ==" *is* valid for parsing,
            // but our current regex requires a non-empty mediatype if ';base64' is present.
            // Let's adjust the expectation for this specific case if needed based on desired behavior.
            // For now, assuming the current regex logic is the desired validation.
            if url == "data:;base64,SGVsbG8sIFdvcmxkIQ==" {
                 // This might be considered valid by some parsers, but fails our regex.
                 // If strict validation against the regex is intended, this is correct.
                XCTAssertTrue(Data.isDataURL(string: url), "Should be a valid data URL (allows empty mediatype): \(url)")
            } else if url == "data:;base64,invalid-base64!" {
                 // This is invalid because the base64 content itself is bad, though the structure might pass regex.
                 // isDataURL only checks structure, not content validity.
                 XCTAssertTrue(Data.isDataURL(string: url), "Should be structurally valid (base64 content ignored by isDataURL): \(url)")
            } else {
                XCTAssertFalse(Data.isDataURL(string: url), "Should be an invalid data URL: \(url)")
            }
        }
    }

    func testIsDataURLLegacy() {
        for url in validURLs {
            XCTAssertTrue(Data._isDataURL_legacy(string: url), "Should be a valid data URL: \(url)")
        }
        
        for url in invalidURLs {
            // Special case: "data:;base64,SGVsbG8sIFdvcmxkIQ==" *is* valid for parsing,
            // but our current regex requires a non-empty mediatype if ';base64' is present.
            // Let's adjust the expectation for this specific case if needed based on desired behavior.
            // For now, assuming the current regex logic is the desired validation.
            if url == "data:;base64,SGVsbG8sIFdvcmxkIQ==" {
                 // This might be considered valid by some parsers, but fails our regex.
                 // If strict validation against the regex is intended, this is correct.
                XCTAssertTrue(Data._isDataURL_legacy(string: url), "Should be a valid data URL (allows empty mediatype): \(url)")
            } else if url == "data:;base64,invalid-base64!" {
                 // This is invalid because the base64 content itself is bad, though the structure might pass regex.
                 // isDataURL only checks structure, not content validity.
                 XCTAssertTrue(Data._isDataURL_legacy(string: url), "Should be structurally valid (base64 content ignored by isDataURL): \(url)")
            } else {
                XCTAssertFalse(Data._isDataURL_legacy(string: url), "Should be an invalid data URL: \(url)")
            }
        }
    }
    
    // MARK: - Data URL Parsing Tests
    
    func testParseTextPlainDataURL() {
        let url = "data:,Hello%2C%20World!"
        let result = Data.parseDataURL(url)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.mimeType, "text/plain")
        XCTAssertEqual(String(data: result?.data ?? Data(), encoding: .utf8), "Hello, World!")
    }
    
    func testParseBase64DataURL() {
        let url = "data:text/plain;base64,SGVsbG8sIFdvcmxkIQ=="
        let result = Data.parseDataURL(url)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.mimeType, "text/plain")
        XCTAssertEqual(String(data: result?.data ?? Data(), encoding: .utf8), "Hello, World!")
    }
    
    func testParseDataURLWithCharset() {
        let url = "data:text/html;charset=UTF-8,<h1>Hello%2C%20World!</h1>"
        let result = Data.parseDataURL(url)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.mimeType, "text/html;charset=UTF-8")
        XCTAssertEqual(String(data: result?.data ?? Data(), encoding: .utf8), "<h1>Hello, World!</h1>")
    }
    
    func testParseDataURLWithOnlyBase64() {
        // Test case where mediatype is empty but base64 is specified
        let url = "data:;base64,SGVsbG8sIFdvcmxkIQ=="
        let result = Data.parseDataURL(url)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.mimeType, "text/plain") // Defaults to text/plain
        XCTAssertEqual(String(data: result?.data ?? Data(), encoding: .utf8), "Hello, World!")
    }

    func testParseInvalidDataURLsForParsing() {
        let urlsToTest = [
            "",
            "http://example.com",
            "data:",
            "data:text/plain",
            "data:text/plain;base64",
            "data:text/plain,",
            "data:text/plain;base64,invalid-base64!" // Invalid base64 should fail parsing
        ]
        
        for url in urlsToTest {
            XCTAssertNil(Data.parseDataURL(url), "Should return nil for invalid data URL during parsing: \(url)")
        }
    }
    
    func testParseInvalidDataURLsForParsingLegacy() {
        let urlsToTest = [
            "",
            "http://example.com",
            "data:",
            "data:text/plain",
            "data:text/plain;base64",
            "data:text/plain,",
            "data:text/plain;base64,invalid-base64!" // Invalid base64 should fail parsing
        ]
        
        for url in urlsToTest {
            XCTAssertNil(Data._parseDataURL_legacy(url), "Should return nil for invalid data URL during parsing: \(url)")
        }
    }
}

final class DataExtensionsTests_Encoding: XCTestCase {

    // MARK: - Data URL Encoding Tests (Common)

    func testDataURLEncoding() {
        let originalText = "Hello, World!"
        let data = originalText.data(using: .utf8)!

        // Test with default MIME type
        let defaultEncodedURL = data.dataURLEncoded()
        XCTAssertTrue(Data.isDataURL(string: defaultEncodedURL)) // Use public API for checking
        let defaultResult = Data.parseDataURL(defaultEncodedURL) // Use public API for parsing
        XCTAssertNotNil(defaultResult)
        XCTAssertEqual(defaultResult?.mimeType, "text/plain")
        XCTAssertEqual(String(data: defaultResult?.data ?? Data(), encoding: .utf8), originalText)

        // Test with custom MIME type
        let customEncodedURL = data.dataURLEncoded(mimeType: "application/octet-stream")
        XCTAssertTrue(Data.isDataURL(string: customEncodedURL))
        let customResult = Data.parseDataURL(customEncodedURL)
        XCTAssertNotNil(customResult)
        XCTAssertEqual(customResult?.mimeType, "application/octet-stream")
        XCTAssertEqual(String(data: customResult?.data ?? Data(), encoding: .utf8), originalText)
    }

    func testRoundTripEncoding() {
        let testCases = [
            ("Hello, World!", "text/plain"),
            ("{ \"key\": \"value\" }", "application/json"),
            ("<html><body>Test</body></html>", "text/html"),
            ("12345", "text/plain")
        ]

        for (text, mimeType) in testCases {
            let originalData = text.data(using: .utf8)!
            let encodedURL = originalData.dataURLEncoded(mimeType: mimeType)
            
            // Verify structure first
            XCTAssertTrue(Data.isDataURL(string: encodedURL), "Encoded URL should be valid: \(encodedURL)")
            
            // Verify parsing and content
            let result = Data.parseDataURL(encodedURL)
            XCTAssertNotNil(result, "Parsing encoded URL should succeed: \(encodedURL)")
            XCTAssertEqual(result?.mimeType, mimeType, "MIME type mismatch for: \(encodedURL)")
            XCTAssertEqual(result?.data, originalData, "Data mismatch for: \(encodedURL)")
            XCTAssertEqual(String(data: result?.data ?? Data(), encoding: .utf8), text, "Decoded string mismatch for: \(encodedURL)")
        }
    }
} 
