@preconcurrency import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Key-isolated mock URLProtocol.
///
/// Each test creates a session with a unique key and registers its handler under that key.
/// Multiple suites run concurrently without interference because each test's requests carry
/// a different key, so they never read the wrong handler.
#if swift(>=6.1)

    actor IsolatedMockStorage {
        static let shared = IsolatedMockStorage()
        private var handlers:
            [String: @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)] = [:]

        func set(
            key: String,
            handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) {
            handlers[key] = handler
        }

        func execute(key: String, request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            guard let handler = handlers[key] else {
                throw NSError(
                    domain: "IsolatedMockError", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No handler for key '\(key)'"])
            }
            return try await handler(request)
        }
    }

    final class IsolatedMockURLProtocol: URLProtocol, @unchecked Sendable {
        static let sessionKeyHeader = "X-Mock-Key"

        static func makeSession(key: String) -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [IsolatedMockURLProtocol.self]
            config.httpAdditionalHeaders = [sessionKeyHeader: key]
            return URLSession(configuration: config)
        }

        static func setHandler(
            key: String,
            _ handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async {
            await IsolatedMockStorage.shared.set(key: key, handler: handler)
        }

        func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            let key = request.value(forHTTPHeaderField: IsolatedMockURLProtocol.sessionKeyHeader)
                ?? "unknown"
            return try await IsolatedMockStorage.shared.execute(key: key, request: request)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Task {
                do {
                    let (response, data) = try await self.executeHandler(for: request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }
        override func stopLoading() {}
    }

    // MARK: - Per-test session factory

    /// Creates an isolated URLSession + unique key for one test.
    ///
    /// Usage:
    /// ```swift
    /// let (session, key) = makeIsolatedSession()
    /// await IsolatedMockURLProtocol.setHandler(key: key) { _ in (response, data) }
    /// ```
    func makeIsolatedSession() -> (session: URLSession, key: String) {
        let key = UUID().uuidString
        return (IsolatedMockURLProtocol.makeSession(key: key), key)
    }

#endif
