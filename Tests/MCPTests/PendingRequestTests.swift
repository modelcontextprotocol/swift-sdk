import Foundation
import Testing

@testable import MCP

@Suite("Pending Request Tests")
struct PendingRequestTests {
    // A response that cannot be decoded into the expected result type should throw a
    // ResponseDecodingError carrying the raw response and the decoding error, rather than
    // swallowing the cause. See https://github.com/modelcontextprotocol/swift-sdk/issues/220
    @Test("Decode failure surfaces the underlying error and the raw response")
    func decodeFailureSurfacesDiagnostics() async throws {
        // A value that encodes as a JSON string can never decode into CallTool.Result,
        // which expects a keyed object.
        let response = Value.string("not a CallTool.Result")

        do {
            let _: CallTool.Result = try await resume(returning: response)
            Issue.record("Expected decoding to fail")
        } catch let error as ResponseDecodingError {
            #expect(error.value == response)
            #expect(ObjectIdentifier(error.expectedType) == ObjectIdentifier(CallTool.Result.self))
            let underlyingError = try #require(error.underlyingError)
            #expect(underlyingError is DecodingError)
        }
    }

    @Test("A response that is not a Value carries no raw value")
    func nonValueResponseCarriesNoRawValue() async throws {
        // The response path always yields a Value; a non-Value response is a defensive fallback.
        do {
            let _: CallTool.Result = try await resume(returning: 42)
            Issue.record("Expected decoding to fail")
        } catch let error as ResponseDecodingError {
            #expect(error.value == nil)
            #expect(error.underlyingError == nil)
            #expect(ObjectIdentifier(error.expectedType) == ObjectIdentifier(CallTool.Result.self))
        }
    }

    @Test("The error describes the expected type")
    func errorDescriptionNamesExpectedType() async throws {
        do {
            let _: CallTool.Result = try await resume(returning: Value.string("x"))
            Issue.record("Expected decoding to fail")
        } catch let error as ResponseDecodingError {
            #expect(error.description.contains("Result"))
            #expect(error.errorDescription == error.description)
        }
    }

    @Test("A well-formed response still decodes into the expected type")
    func wellFormedResponseDecodes() async throws {
        let expected = CallTool.Result(isError: false)
        let response = try Value(expected)

        let decoded: CallTool.Result = try await resume(returning: response)

        #expect(decoded == expected)
    }

    /// Drives a value through `AnyPendingRequest` and returns the typed result, or throws the
    /// error the request was resumed with.
    private func resume<T: Sendable & Decodable>(returning value: Any) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let request = AnyPendingRequest(PendingRequest(continuation: continuation))
            request.resume(returning: value)
        }
    }
}
