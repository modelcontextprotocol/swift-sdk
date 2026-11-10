import Testing

@testable import MCP

@Suite("Pending request tests")
struct PendingRequestTests {
    @Test("Failed tool result decoding exposes the raw value and decoding error")
    func failedDecodingKeepsResponse() async throws {
        let raw = Value.object(["unexpected": .string("response")])

        do {
            let _: CallTool.Result = try await withCheckedThrowingContinuation { continuation in
                let pending = AnyPendingRequest(PendingRequest(continuation: continuation))
                pending.resume(returning: raw)
            }
            Issue.record("Expected decoding to fail")
        } catch let error as TypeMismatchError {
            #expect(error.expectedType.contains("CallTool.Result"))
            #expect(error.rawValue == raw)
            guard case .keyNotFound(let key, _) = error.underlyingError as? DecodingError else {
                Issue.record("Expected the missing content key to be reported")
                return
            }
            #expect(key.stringValue == "content")
        }
    }

    @Test("Valid tool result still decodes")
    func validResultStillDecodes() async throws {
        let raw = Value.object(["content": .array([])])
        let result: CallTool.Result = try await withCheckedThrowingContinuation { continuation in
            let pending = AnyPendingRequest(PendingRequest(continuation: continuation))
            pending.resume(returning: raw)
        }
        #expect(result.content.isEmpty)
    }

    @Test("Non-JSON response reports the expected type")
    func mismatchedResponseType() async throws {
        do {
            let _: CallTool.Result = try await withCheckedThrowingContinuation { continuation in
                let pending = AnyPendingRequest(PendingRequest(continuation: continuation))
                pending.resume(returning: 42)
            }
            Issue.record("Expected a type mismatch")
        } catch let error as TypeMismatchError {
            #expect(error.expectedType.contains("CallTool.Result"))
            #expect(error.rawValue == nil)
            #expect(error.underlyingError == nil)
        }
    }
}
