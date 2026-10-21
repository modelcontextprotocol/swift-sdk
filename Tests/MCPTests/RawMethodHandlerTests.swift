import Foundation
import Testing

@testable import MCP

@Suite("Raw-aware method handler tests")
struct RawMethodHandlerTests {
    private struct InspectRaw: MCP.Method {
        struct Parameters: Codable, Hashable, Sendable {
            let label: String
            let payload: Value
        }

        struct Result: Codable, Hashable, Sendable {
            let accepted: Bool
        }

        static let name = "test/inspect-raw"
    }

    private struct LegacyEcho: MCP.Method {
        struct Parameters: Codable, Hashable, Sendable {
            let label: String
            let payload: Value?
        }

        struct Result: Codable, Hashable, Sendable {
            let label: String
        }

        static let name = "test/legacy-echo"
    }

    private struct CanonicalRaw: MCP.Method {
        struct Parameters: Codable, Hashable, Sendable {
            let value: String
        }

        struct Result: Codable, Hashable, Sendable {
            let accepted: Bool
        }

        static let name = "test/é"
    }

    private actor Capture {
        var rawRequests: [RawRequestContext] = []
        var typedPayloadWasData = false
        var legacyLabels: [String] = []
        var legacyPayloadWasData = false
        var rawHandlerCalls = 0

        func recordRaw(_ context: RawRequestContext, typedPayloadWasData: Bool) {
            rawRequests.append(context)
            self.typedPayloadWasData = typedPayloadWasData
            rawHandlerCalls += 1
        }

        func recordLegacy(_ label: String, payloadWasData: Bool) {
            legacyLabels.append(label)
            legacyPayloadWasData = payloadWasData
        }
    }

    @Test("Single requests expose exact params beside the typed request")
    func singleRawAwareHandler() async throws {
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1")
        let capture = Capture()

        await server.withMethodHandler(InspectRaw.self) { request, rawContext in
            await capture.recordRaw(
                rawContext,
                typedPayloadWasData: request.params.payload.dataValue != nil
            )
            return .init(accepted: true)
        }
        try await server.start(transport: transport)

        let request = #"""
             {
               "jsonrpc" : "2.0",
               "id" : 7,
               "method" : "test/inspect-raw",
               "params" : { "label" : "single", "payload" : "data:,one%20two" }
             }
            """#
        await transport.queue(data: Data(request.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        #expect(await capture.rawHandlerCalls == 1)
        #expect(await capture.typedPayloadWasData)
        let context = try #require(await capture.rawRequests.first)
        #expect(context.request.members.map(\.key) == ["jsonrpc", "id", "method", "params"])
        let parameters = try #require(context.uniqueParameters?.objectValue)
        #expect(parameters.uniqueValue(forExactKey: "payload") == .string("data:,one%20two"))

        await server.stop()
    }

    @Test("Raw-aware routing matches canonical Swift method identity")
    func canonicalMethodIdentity() async throws {
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1")

        actor State {
            var called = false
            func markCalled() { called = true }
        }
        let state = State()
        await server.withMethodHandler(CanonicalRaw.self) { request, rawContext in
            #expect(request.params.value == "ok")
            #expect(rawContext.uniqueParameters?.objectValue != nil)
            await state.markCalled()
            return .init(accepted: true)
        }
        try await server.start(transport: transport)

        let request = #"{"jsonrpc":"2.0","id":9,"method":"test/e\u0301","params":{"value":"ok"}}"#
        await transport.queue(data: Data(request.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        #expect(await state.called)
        await server.stop()
    }

    @Test("Mixed raw-aware and legacy handlers preserve batch item identity")
    func mixedBatchHandlers() async throws {
        let transport = MockTransport()
        let limits = RawJSONLimits(
            maximumDocumentBytes: 512,
            maximumStringBytes: 32,
            maximumDepth: 8,
            maximumContainerEntries: 64
        )
        let server = Server(name: "raw-test", version: "1", rawJSONLimits: limits)
        let capture = Capture()
        let legacyLabel = String(repeating: "legacy", count: 20)

        await server.withMethodHandler(InspectRaw.self) { request, rawContext in
            let payloadWasData: Bool
            if case .data = request.params.payload {
                payloadWasData = true
            } else {
                payloadWasData = false
            }
            await capture.recordRaw(rawContext, typedPayloadWasData: payloadWasData)
            return .init(accepted: true)
        }
        await server.withMethodHandler(LegacyEcho.self) { parameters in
            await capture.recordLegacy(
                parameters.label,
                payloadWasData: parameters.payload?.dataValue != nil
            )
            return .init(label: parameters.label)
        }
        try await server.start(transport: transport)

        let batch = #"""
            [
            {
              "jsonrpc":"2.0","id":41,"method":"test/inspect-raw",
              "params":{"label":"first","payload":"d\u0061ta:,A%20brief%20note","é":1,"e\u0301":2}
            },
            {
              "jsonrpc":"2.0","id":42,"method":"test/legacy-echo",
              "params":{"label":"\#(legacyLabel)","payload":"data:text/plain;base64,SGVsbG8="}
            }
            ]
            """#
        await transport.queue(data: Data(batch.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        #expect(await capture.rawHandlerCalls == 1)
        #expect(await capture.typedPayloadWasData)
        #expect(await capture.legacyLabels == [legacyLabel])
        #expect(await capture.legacyPayloadWasData)

        let contexts = await capture.rawRequests
        let context = try #require(contexts.first)
        #expect(context.request.uniqueValue(forExactKey: "id") == .number("41"))
        let rawParameters = try #require(context.parameters.first?.objectValue)
        #expect(
            rawParameters.uniqueValue(forExactKey: "payload")
                == .string("data:,A%20brief%20note")
        )
        #expect(rawParameters.values(forExactKey: "é") == [.number("1")])
        #expect(rawParameters.values(forExactKey: "e\u{301}") == [.number("2")])

        let responseData = try #require(await transport.sentData.first)
        let responses = try JSONDecoder().decode([AnyResponse].self, from: responseData)
        #expect(responses.map(\.id) == [41, 42])

        await server.stop()
    }

    @Test("Oversized raw strings fail closed before the handler")
    func oversizedStringRejected() async throws {
        let limits = RawJSONLimits(
            maximumDocumentBytes: 4096,
            maximumStringBytes: 32,
            maximumDepth: 8,
            maximumContainerEntries: 64
        )
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1", rawJSONLimits: limits)
        let capture = Capture()

        await server.withMethodHandler(InspectRaw.self) { request, rawContext in
            await capture.recordRaw(rawContext, typedPayloadWasData: request.params.payload.dataValue != nil)
            return .init(accepted: true)
        }
        try await server.start(transport: transport)

        let oversized = String(repeating: "A", count: 256)
        let request = """
            {
              "jsonrpc":"2.0","id":99,"method":"test/inspect-raw",
              "params":{"label":"large","payload":"data:text/plain;base64,\(oversized)"}
            }
            """
        await transport.queue(data: Data(request.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        #expect(await capture.rawHandlerCalls == 0)
        let responseData = try #require(await transport.sentData.first)
        let response = try JSONDecoder().decode(AnyResponse.self, from: responseData)
        guard case .failure(let error) = response.result else {
            Issue.record("Expected a parse failure response")
            await server.stop()
            return
        }
        #expect(error.code == -32700)

        await server.stop()
    }

    @Test("Oversized raw batch items retain IDs and do not suppress siblings")
    func oversizedBatchItem() async throws {
        let limits = RawJSONLimits(
            maximumDocumentBytes: 4096,
            maximumStringBytes: 32,
            maximumDepth: 8,
            maximumContainerEntries: 64
        )
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1", rawJSONLimits: limits)
        let capture = Capture()

        await server.withMethodHandler(InspectRaw.self) { request, rawContext in
            await capture.recordRaw(
                rawContext,
                typedPayloadWasData: request.params.payload.dataValue != nil
            )
            return .init(accepted: true)
        }
        await server.withMethodHandler(LegacyEcho.self) { parameters in
            await capture.recordLegacy(
                parameters.label,
                payloadWasData: parameters.payload?.dataValue != nil
            )
            return .init(label: parameters.label)
        }
        try await server.start(transport: transport)

        let oversized = String(repeating: "A", count: 256)
        let batch = """
            [
              {"jsonrpc":"2.0","id":99,"method":"test/inspect-raw",
               "params":{"label":"large","payload":"\(oversized)"}},
              {"jsonrpc":"2.0","id":100,"method":"test/legacy-echo",
               "params":{"label":"valid"}}
            ]
            """
        await transport.queue(data: Data(batch.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        let responseData = try #require(await transport.sentData.first)
        let responses = try JSONDecoder().decode([AnyResponse].self, from: responseData)
        #expect(responses.map(\.id) == [99, 100])
        guard case .failure(let error) = responses[0].result else {
            Issue.record("Expected a bounded raw-item failure")
            await server.stop()
            return
        }
        #expect(error.code == -32700)
        #expect(await capture.rawHandlerCalls == 0)
        #expect(await capture.legacyLabels == ["valid"])

        await server.stop()
    }

    @Test("Malformed batch items are client errors")
    func malformedBatchItem() async throws {
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1")
        let capture = Capture()
        await server.withMethodHandler(LegacyEcho.self) { parameters in
            await capture.recordLegacy(
                parameters.label,
                payloadWasData: parameters.payload?.dataValue != nil
            )
            return .init(label: parameters.label)
        }
        try await server.start(transport: transport)

        let batch = #"""
            [
              {"jsonrpc":"2.0","id":12,"method":42},
              {"jsonrpc":"2.0","id":13,"method":"test/legacy-echo","params":{"label":"valid"}}
            ]
            """#
        await transport.queue(data: Data(batch.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        let responseData = try #require(await transport.sentData.first)
        let responses = try JSONDecoder().decode([AnyResponse].self, from: responseData)
        #expect(responses.map(\.id) == [12, 13])
        guard case .failure(let error) = responses[0].result else {
            Issue.record("Expected an invalid-request response")
            await server.stop()
            return
        }
        #expect(error.code == -32600)
        #expect(await capture.legacyLabels == ["valid"])

        await server.stop()
    }

    @Test("Malformed batch JSON remains a parse error")
    func malformedBatchJSON() async throws {
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1")
        try await server.start(transport: transport)

        await transport.queue(data: Data(#"[{"jsonrpc":"2.0","id":12"#.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        let responseData = try #require(await transport.sentData.first)
        let response = try JSONDecoder().decode(AnyResponse.self, from: responseData)
        guard case .failure(let error) = response.result else {
            Issue.record("Expected a parse-error response")
            await server.stop()
            return
        }
        #expect(error.code == -32700)

        await server.stop()
    }

    @Test("Malformed legacy requests retain their request ID")
    func malformedLegacyRequestID() async throws {
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1")
        try await server.start(transport: transport)

        let request = #"{"jsonrpc":"2.0","id":7,"method":42}"#
        await transport.queue(data: Data(request.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        let responseData = try #require(await transport.sentData.first)
        let response = try JSONDecoder().decode(AnyResponse.self, from: responseData)
        #expect(response.id == 7)
        guard case .failure(let error) = response.result else {
            Issue.record("Expected a parse-error response")
            await server.stop()
            return
        }
        #expect(error.code == -32700)

        await server.stop()
    }

    @Test("Ambiguous raw-aware method members are rejected")
    func duplicateMethodMembers() async throws {
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1")
        let capture = Capture()
        await server.withMethodHandler(InspectRaw.self) { request, rawContext in
            await capture.recordRaw(
                rawContext,
                typedPayloadWasData: request.params.payload.dataValue != nil
            )
            return .init(accepted: true)
        }
        await server.withMethodHandler(LegacyEcho.self) { parameters in
            await capture.recordLegacy(
                parameters.label,
                payloadWasData: parameters.payload?.dataValue != nil
            )
            return .init(label: parameters.label)
        }
        try await server.start(transport: transport)

        let request = #"""
            {
              "jsonrpc":"2.0","id":88,
              "method":"test/legacy-echo","method":"test/inspect-raw",
              "params":{"label":"ambiguous","payload":"plain"}
            }
            """#
        await transport.queue(data: Data(request.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        let responseData = try #require(await transport.sentData.first)
        let response = try JSONDecoder().decode(AnyResponse.self, from: responseData)
        #expect(response.id == 88)
        guard case .failure(let error) = response.result else {
            Issue.record("Expected an invalid-request response")
            await server.stop()
            return
        }
        #expect(error.code == -32600)
        #expect(await capture.rawHandlerCalls == 0)
        #expect(await capture.legacyLabels.isEmpty)

        await server.stop()
    }

    @Test("Raw limits do not change legacy handler traffic")
    func legacyTrafficIgnoresRawLimits() async throws {
        let limits = RawJSONLimits(
            maximumDocumentBytes: 1,
            maximumStringBytes: 1,
            maximumDepth: 0,
            maximumContainerEntries: 0
        )
        let transport = MockTransport()
        let server = Server(name: "raw-test", version: "1", rawJSONLimits: limits)
        let capture = Capture()

        await server.withMethodHandler(InspectRaw.self) { request, rawContext in
            await capture.recordRaw(
                rawContext,
                typedPayloadWasData: request.params.payload.dataValue != nil
            )
            return .init(accepted: true)
        }
        await server.withMethodHandler(LegacyEcho.self) { parameters in
            await capture.recordLegacy(
                parameters.label,
                payloadWasData: parameters.payload?.dataValue != nil
            )
            return .init(label: parameters.label)
        }
        try await server.start(transport: transport)

        let matchingNotification = #"""
            {
              "jsonrpc":"2.0","method":"test/inspect-raw",
              "params":{"payload":"this notification is intentionally larger than raw limits"}
            }
            """#
        await transport.queue(data: Data(matchingNotification.utf8))

        let request = #"""
            {
              "jsonrpc":"2.0","id":77,"method":"test/legacy-echo",
              "params":{"label":"unbounded-legacy","payload":"data:text/plain;base64,SGVsbG8="}
            }
            """#
        await transport.queue(data: Data(request.utf8))
        try await waitUntil { await transport.sentData.count == 1 }

        #expect(await capture.legacyLabels == ["unbounded-legacy"])
        #expect(await capture.legacyPayloadWasData)
        #expect(await capture.rawHandlerCalls == 0)

        await server.stop()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                throw MCPError.internalError("Timed out waiting for handler")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
