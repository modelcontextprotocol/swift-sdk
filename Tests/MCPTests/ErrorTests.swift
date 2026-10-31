import Testing

import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Error Tests")
struct ErrorTests {
    /// A representative payment-required `data` payload: an `httpStatus` and a `challenges` array,
    /// matching the MPP "Payment" scheme bound to JSON-RPC.
    private func paymentData(httpStatus: Int = 402) -> [String: Value] {
        [
            "httpStatus": .int(httpStatus),
            "challenges": .array([
                .object([
                    "id": .string("chal-1"),
                    "realm": .string("example"),
                    "method": .string("tempo"),
                    "intent": .string("charge"),
                ])
            ]),
        ]
    }

    @Test("paymentRequired round-trips and preserves code, message, and data")
    func testPaymentRequiredRoundTrip() throws {
        let error = MCPError.paymentRequired(
            code: -32042, message: "Payment Required", data: paymentData())

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(MCPError.self, from: data)

        guard case .paymentRequired(let code, let message, let payload) = decoded else {
            #expect(Bool(false), "Expected .paymentRequired, got \(decoded)")
            return
        }
        #expect(code == -32042)
        #expect(message == "Payment Required")
        #expect(payload["httpStatus"] == .int(402))
        if case .array(let challenges) = payload["challenges"] {
            #expect(challenges.count == 1)
        } else {
            #expect(Bool(false), "Expected a challenges array in the decoded data")
        }
    }

    @Test("code -32042 with challenges decodes to paymentRequired, not urlElicitationRequired")
    func testPaymentRequiredDisambiguatedFromElicitation() throws {
        let error = MCPError.paymentRequired(
            code: -32042, message: "Payment Required", data: paymentData())

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(MCPError.self, from: data)

        if case .urlElicitationRequired = decoded {
            #expect(Bool(false), "A -32042 with `challenges` must not decode as URL elicitation")
        }
        #expect(decoded == error)
    }

    @Test("code -32042 with elicitations still decodes to urlElicitationRequired")
    func testElicitationStillDecodes() throws {
        let error = MCPError.urlElicitationRequired(
            message: "Auth required",
            elicitations: [
                URLElicitationInfo(elicitationId: "e1", url: "https://example.com", message: "Sign in")
            ])

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(MCPError.self, from: data)

        guard case .urlElicitationRequired(let message, let elicitations) = decoded else {
            #expect(Bool(false), "Expected .urlElicitationRequired, got \(decoded)")
            return
        }
        #expect(message == "Auth required")
        #expect(elicitations.count == 1)
        #expect(elicitations.first?.url == "https://example.com")
    }

    @Test("code -32043 with challenges decodes to paymentRequired")
    func testVerificationFailedWithChallenges() throws {
        let error = MCPError.paymentRequired(
            code: -32043, message: "Payment verification failed", data: paymentData())

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(MCPError.self, from: data)

        guard case .paymentRequired(let code, _, _) = decoded else {
            #expect(Bool(false), "Expected .paymentRequired, got \(decoded)")
            return
        }
        #expect(code == -32043)
        #expect(decoded.code == -32043)
    }

    @Test("a bare -32043 without challenges stays a serverError")
    func testVerificationCodeWithoutChallengesIsServerError() throws {
        // Encode a JSON-RPC error object with code -32043 and no `data`.
        let json = #"{"code":-32043,"message":"Service degraded"}"#
        let decoded = try JSONDecoder().decode(MCPError.self, from: Data(json.utf8))

        guard case .serverError(let code, let message) = decoded else {
            #expect(Bool(false), "Expected .serverError, got \(decoded)")
            return
        }
        #expect(code == -32043)
        #expect(message == "Service degraded")
    }

    @Test("paymentRequired exposes the carried code")
    func testCarriedCode() {
        #expect(
            MCPError.paymentRequired(code: -32042, message: "x", data: [:]).code == -32042)
        #expect(
            MCPError.paymentRequired(code: -32043, message: "x", data: [:]).code == -32043)
    }
}
