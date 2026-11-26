import Foundation
import Testing

@testable import MCP

@Suite("OriginValidator Tests")
struct OriginValidatorTests {
    private let context = HTTPValidationContext(httpMethod: "POST")

    private func request(host: String, origin: String? = nil) -> HTTPRequest {
        var headers = ["Host": host]
        if let origin { headers["Origin"] = origin }
        return HTTPRequest(method: "POST", headers: headers)
    }

    @Test("Localhost validator accepts loopback hosts with and without a port")
    func testAcceptsLoopbackHosts() {
        let validator = OriginValidator.localhost()
        for host in ["localhost:8080", "127.0.0.1:3000", "[::1]:9000", "localhost", "127.0.0.1", "[::1]"] {
            #expect(validator.validate(request(host: host), context: context) == nil, "\(host)")
        }
        for origin in [
            "http://localhost:8080", "http://127.0.0.1:3000", "http://[::1]:9000",
            "http://localhost", "http://127.0.0.1", "http://[::1]",
        ] {
            #expect(
                validator.validate(request(host: "localhost:8080", origin: origin), context: context) == nil,
                "\(origin)"
            )
        }
    }

    @Test("Localhost validator rejects other hosts and origins")
    func testRejectsOtherHosts() {
        let validator = OriginValidator.localhost()
        for host in ["evil.example", "evil.example:8080", "localhost.evil.example", "localhost:", "localhost:80x"] {
            #expect(validator.validate(request(host: host), context: context)?.statusCode == 421, "\(host)")
        }
        for origin in [
            "http://evil.example", "http://localhost.evil.example",
            "http://localhost:", "http://localhost:80x", "https://localhost", "null",
        ] {
            #expect(
                validator.validate(request(host: "localhost:8080", origin: origin), context: context)?
                    .statusCode == 403,
                "\(origin)"
            )
        }
    }

    @Test("Port-specific localhost validator still requires that port")
    func testPortSpecificValidator() {
        let validator = OriginValidator.localhost(port: 8080)
        #expect(validator.validate(request(host: "localhost:8080"), context: context) == nil)
        #expect(validator.validate(request(host: "localhost"), context: context)?.statusCode == 421)
        #expect(validator.validate(request(host: "localhost:9090"), context: context)?.statusCode == 421)
        #expect(
            validator.validate(request(host: "localhost:8080", origin: "http://localhost:8080"), context: context)
                == nil)
        #expect(
            validator.validate(request(host: "localhost:8080", origin: "http://localhost"), context: context)?
                .statusCode == 403)
        #expect(
            validator.validate(request(host: "localhost:8080", origin: "http://localhost:9090"), context: context)?
                .statusCode == 403)
    }
}
