import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let requestHandlerStorage = RequestHandlerStorage()

    static func setHandler(
        _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) async {
        await requestHandlerStorage.setHandler { request in
            try await handler(request)
        }
    }

    func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        return try await Self.requestHandlerStorage.executeHandler(for: request)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

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

actor RequestHandlerStorage {
    private var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    func setHandler(
        _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) async {
        requestHandler = handler
    }

    func clearHandler() async {
        requestHandler = nil
    }

    func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        guard let handler = requestHandler else {
            throw NSError(
                domain: "MockURLProtocolError", code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey: "No request handler set"
                ])
        }
        return try await handler(request)
    }
}

extension URLRequest {
    func readBody() -> Data? {
        if let httpBodyData = self.httpBody {
            return httpBodyData
        }

        guard let bodyStream = self.httpBodyStream else { return nil }
        bodyStream.open()
        defer { bodyStream.close() }

        let bufferSize: Int = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while bodyStream.hasBytesAvailable {
            let bytesRead = bodyStream.read(buffer, maxLength: bufferSize)
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}
