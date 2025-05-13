import Foundation
import Testing

@testable import MCP

@Suite("Base64 Data Tests")
struct Base64DataTests {

    @Test("Check valid data URLs")
    func testIsDataURL() {
        // Basic valid data URL
        #expect(Data.isDataURL(string: "data:,A%20brief%20note"))

        // Valid image data URL from RFC example
        #expect(
            Data.isDataURL(string: "data:image/gif;base64,R0lGODdhMAAwAPAAAAAAAP///ywAAAAAMAAw"))

        // Valid data URL with charset parameter
        #expect(Data.isDataURL(string: "data:text/plain;charset=iso-8859-7,%be%fg%be"))

        // Valid custom application type from RFC example
        #expect(
            Data.isDataURL(
                string: "data:application/vnd-xxx-query,select_vcount,fcol_from_fieldtable/local"))

        // Valid with implicit mediatype (defaults to text/plain)
        #expect(Data.isDataURL(string: "data:,hello%20world"))

        // Valid with just charset parameter
        #expect(Data.isDataURL(string: "data:;charset=utf-8,hello"))
    }

    @Test("Check invalid data URLs")
    func testInvalidDataURLs() {
        // Not a data URL
        #expect(!Data.isDataURL(string: "https://example.com"))

        // Missing comma separator
        #expect(!Data.isDataURL(string: "data:text/plain"))

        // Malformed scheme
        #expect(!Data.isDataURL(string: "dat:,hello"))

        // Empty string
        #expect(!Data.isDataURL(string: ""))
    }

    @Test("Parse data URL with plain text")
    func testParseDataURLPlainText() {
        // Example from RFC 2397
        let result = Data.parseDataURL("data:,A%20brief%20note")
        #expect(result != nil)
        if let (mimeType, data) = result {
            #expect(mimeType == "text/plain")
            #expect(String(data: data, encoding: .utf8) == "A brief note")
        }
    }

    @Test("Parse data URL with charset")
    func testParseDataURLWithCharset() {
        // Modified example from RFC 2397 (using valid percent encoding)
        let result = Data.parseDataURL(
            "data:text/plain;charset=iso-8859-7,%CF%84%CE%B5%CF%83%CF%84")
        #expect(result != nil)
        if let (mimeType, _) = result {
            #expect(mimeType == "text/plain;charset=iso-8859-7")
        }
    }

    @Test("Parse data URL with base64 encoding")
    func testParseDataURLBase64() {
        // Simple base64 encoded "Hello"
        let result = Data.parseDataURL("data:text/plain;base64,SGVsbG8=")
        #expect(result != nil)
        if let (mimeType, data) = result {
            #expect(mimeType == "text/plain")
            #expect(String(data: data, encoding: .utf8) == "Hello")
        }
    }

    @Test("Parse data URL with implicit text/plain")
    func testParseDataURLImplicitTextPlain() {
        let result = Data.parseDataURL("data:,hello%20world")
        #expect(result != nil)
        if let (mimeType, data) = result {
            #expect(mimeType == "text/plain")
            #expect(String(data: data, encoding: .utf8) == "hello world")
        }
    }

    @Test("Parse invalid data URLs")
    func testParseInvalidDataURLs() {
        // Not a data URL
        #expect(Data.parseDataURL("https://example.com") == nil)

        // Malformed base64
        #expect(Data.parseDataURL("data:text/plain;base64,SGVsbG8=!") == nil)

        // Empty base64 data (valid according to RFC 2397)
        let result = Data.parseDataURL("data:text/plain;base64,")
        #expect(result != nil)
        if let (mimeType, data) = result {
            #expect(mimeType == "text/plain")
            #expect(data.isEmpty)
        }
    }

    @Test("Test data URL encoding")
    func testDataURLEncoding() {
        let testData = "Hello, world!".data(using: .utf8)!

        // Default mime type (text/plain)
        let url1 = testData.dataURLEncoded()
        #expect(url1.hasPrefix("data:text/plain;base64,"))
        #expect(Data.isDataURL(string: url1))

        // Custom mime type
        let url2 = testData.dataURLEncoded(mimeType: "application/octet-stream")
        #expect(url2.hasPrefix("data:application/octet-stream;base64,"))
        #expect(Data.isDataURL(string: url2))

        // Roundtrip test
        if let (mimeType, data) = Data.parseDataURL(url2) {
            #expect(mimeType == "application/octet-stream")
            #expect(data == testData)
        } else {
            #expect(Bool(false), "Failed to parse encoded data URL")
        }
    }

    @Test("Test complex example from RFC 2397")
    func testComplexExample() {
        // Partial example of image from RFC (shortened for test brevity)
        let dataURL = "data:image/gif;base64,R0lGODdhMAAwAPAAAAAAAP///ywAAAAAMAAw"

        let result = Data.parseDataURL(dataURL)
        #expect(result != nil)
        if let (mimeType, _) = result {
            #expect(mimeType == "image/gif")
        }
    }
}
