import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Tests for HTTPClientTransport reconnection behavior.
///
/// These tests verify the client transport's ability to handle disconnections
/// and reconnect with proper Last-Event-ID headers.
///
/// TypeScript tests not yet implemented (require streaming mock infrastructure):
///
/// The following tests from `packages/client/test/client/streamableHttp.test.ts` require
/// the ability to mock streaming HTTP responses with controlled failures. The TypeScript SDK
/// uses vi.fn() mocks that can return ReadableStream objects that error mid-stream.
/// Swift's MockURLProtocol doesn't easily support this pattern.
///
/// Possible solutions for future implementation:
/// 1. Create a custom URLProtocol that supports async stream injection
/// 2. Use a real local HTTP server in tests (like TypeScript does with node's http.Server)
/// 3. Test at a lower level by mocking the EventSource directly
///
/// Tests pending implementation:
/// - `should reconnect a GET-initiated notification stream that fails`
/// - `should NOT reconnect a POST-initiated stream that fails`
/// - `should reconnect a POST-initiated stream after receiving a priming event`
/// - `should NOT reconnect a POST stream when response was received`
/// - `should not attempt reconnection after close() is called`
/// - `should use server-provided retry value for reconnection delay`
/// - `should reconnect on graceful stream close`
/// - `should not schedule any reconnection attempts when maxRetries is 0`
@Suite("Client Reconnection Tests")
struct ClientReconnectionTests {

    // MARK: - Reconnection Options Tests

    @Test("Default reconnection options")
    func defaultReconnectionOptions() async throws {
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:8080/mcp")!,
            streaming: false
        )

        let options = transport.reconnectionOptions
        #expect(options.initialReconnectionDelay == 1.0)
        #expect(options.maxReconnectionDelay == 30.0)
        #expect(options.reconnectionDelayGrowFactor == 1.5)
        #expect(options.maxRetries == 2)
    }

    @Test("Custom reconnection options")
    func customReconnectionOptions() async throws {
        let customOptions = HTTPReconnectionOptions(
            initialReconnectionDelay: 0.5,
            maxReconnectionDelay: 10.0,
            reconnectionDelayGrowFactor: 2.0,
            maxRetries: 5
        )

        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:8080/mcp")!,
            streaming: false,
            reconnectionOptions: customOptions
        )

        let options = transport.reconnectionOptions
        #expect(options.initialReconnectionDelay == 0.5)
        #expect(options.maxReconnectionDelay == 10.0)
        #expect(options.reconnectionDelayGrowFactor == 2.0)
        #expect(options.maxRetries == 5)
    }

    // MARK: - Last Event ID Tracking Tests

    @Test("Last received event ID is initially nil")
    func lastEventIdInitiallyNil() async throws {
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:8080/mcp")!,
            streaming: false
        )

        let lastEventId = await transport.lastReceivedEventId
        #expect(lastEventId == nil)
    }

    // MARK: - Resumption Token Callback Tests

    @Test("Resumption token callback can be set")
    func resumptionTokenCallbackCanBeSet() async throws {
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:8080/mcp")!,
            streaming: false
        )

        actor TokenCollector {
            var tokens: [String] = []
            func add(_ token: String) { tokens.append(token) }
            func get() -> [String] { tokens }
        }

        let collector = TokenCollector()

        await transport.setOnResumptionToken { token in
            Task {
                await collector.add(token)
            }
        }

        // The callback is set but won't be triggered without an actual SSE stream
        // This test just verifies the API works
        let tokens = await collector.get()
        #expect(tokens.isEmpty)
    }

    // MARK: - Reconnection Options Struct Tests

    @Test("HTTPReconnectionOptions default values")
    func reconnectionOptionsDefaultValues() {
        let options = HTTPReconnectionOptions()
        #expect(options.initialReconnectionDelay == 1.0)
        #expect(options.maxReconnectionDelay == 30.0)
        #expect(options.reconnectionDelayGrowFactor == 1.5)
        #expect(options.maxRetries == 2)
    }

    @Test("HTTPReconnectionOptions static default")
    func reconnectionOptionsStaticDefault() {
        let options = HTTPReconnectionOptions.default
        #expect(options.initialReconnectionDelay == 1.0)
        #expect(options.maxReconnectionDelay == 30.0)
        #expect(options.reconnectionDelayGrowFactor == 1.5)
        #expect(options.maxRetries == 2)
    }

    @Test("HTTPReconnectionOptions custom initialization")
    func reconnectionOptionsCustomInit() {
        let options = HTTPReconnectionOptions(
            initialReconnectionDelay: 2.0,
            maxReconnectionDelay: 60.0,
            reconnectionDelayGrowFactor: 3.0,
            maxRetries: 10
        )
        #expect(options.initialReconnectionDelay == 2.0)
        #expect(options.maxReconnectionDelay == 60.0)
        #expect(options.reconnectionDelayGrowFactor == 3.0)
        #expect(options.maxRetries == 10)
    }

    // MARK: - Exponential Backoff Logic Tests

    @Test("Exponential backoff calculation")
    func exponentialBackoffCalculation() {
        // Test the math of exponential backoff
        let options = HTTPReconnectionOptions(
            initialReconnectionDelay: 1.0,
            maxReconnectionDelay: 30.0,
            reconnectionDelayGrowFactor: 2.0,
            maxRetries: 10
        )

        // delay = initialDelay * growFactor^attempt
        // Attempt 0: 1.0 * 2^0 = 1.0
        // Attempt 1: 1.0 * 2^1 = 2.0
        // Attempt 2: 1.0 * 2^2 = 4.0
        // Attempt 3: 1.0 * 2^3 = 8.0
        // Attempt 4: 1.0 * 2^4 = 16.0
        // Attempt 5: 1.0 * 2^5 = 32.0 -> capped at 30.0

        let delays = (0...5).map { attempt -> TimeInterval in
            let delay = options.initialReconnectionDelay * pow(options.reconnectionDelayGrowFactor, Double(attempt))
            return min(delay, options.maxReconnectionDelay)
        }

        #expect(delays[0] == 1.0)
        #expect(delays[1] == 2.0)
        #expect(delays[2] == 4.0)
        #expect(delays[3] == 8.0)
        #expect(delays[4] == 16.0)
        #expect(delays[5] == 30.0)  // Capped at max
    }

    // MARK: - Transport State Tests

    @Test("Transport tracks session ID")
    func transportTracksSessionId() async throws {
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:8080/mcp")!,
            streaming: false
        )

        // Initially nil
        let sessionId = await transport.sessionID
        #expect(sessionId == nil)
    }

    @Test("Transport tracks protocol version")
    func transportTracksProtocolVersion() async throws {
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:8080/mcp")!,
            streaming: false
        )

        // Initially nil
        let version = await transport.protocolVersion
        #expect(version == nil)
    }

    // MARK: - Resume Stream API Tests

    #if !os(Linux)
    @Test("Resume stream method exists and is callable")
    func resumeStreamMethodExists() async throws {
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:8080/mcp")!,
            streaming: true
        )

        // The method exists and is callable (though it won't do anything useful
        // without a real connection). This test just verifies the API exists.
        // When not connected, it should return early without throwing.
        try await transport.resumeStream(from: "test-event-id")
        // If we get here, the method exists and is callable
    }
    #endif
}

// MARK: - HTTPClientTransport Extension for Testing

extension HTTPClientTransport {
    /// Sets the onResumptionToken callback
    func setOnResumptionToken(_ callback: @escaping (String) -> Void) async {
        self.onResumptionToken = callback
    }
}
