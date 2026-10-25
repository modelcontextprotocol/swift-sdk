import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The body of an HTTP response, read as it arrives.
///
/// On Apple platforms it is `URLSession.AsyncBytes`. swift-corelibs-foundation
/// has no `URLSession.bytes(for:)`, so there a ``StreamingSessionDelegate``
/// feeds the chunks of a data task.
struct ResponseBody: AsyncSequence, Sendable {
    typealias Element = UInt8

    #if canImport(FoundationNetworking)
        let chunks: AsyncThrowingStream<Data, Swift.Error>
        let task: URLSessionDataTask

        struct AsyncIterator: AsyncIteratorProtocol {
            var chunks: AsyncThrowingStream<Data, Swift.Error>.AsyncIterator
            var chunk = Data()
            var index = 0

            mutating func next() async throws -> UInt8? {
                while index >= chunk.endIndex {
                    guard let next = try await chunks.next() else { return nil }
                    chunk = next
                    index = chunk.startIndex
                }
                defer { index += 1 }
                return chunk[index]
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(chunks: chunks.makeAsyncIterator())
        }

        /// Stops reading: cancels the data task.
        func cancel() { task.cancel() }
    #else
        let bytes: URLSession.AsyncBytes

        func makeAsyncIterator() -> URLSession.AsyncBytes.AsyncIterator {
            bytes.makeAsyncIterator()
        }

        /// Stops reading: cancels the data task.
        func cancel() { bytes.task.cancel() }
    #endif

    /// The whole body, up to `limit` bytes.
    func collect(limit: Int = .max) async throws -> Data {
        var body = Data()
        for try await byte in self {
            body.append(byte)
            if body.count >= limit { break }
        }
        return body
    }
}

#if canImport(FoundationNetworking)
    /// The delegate of a session whose data tasks stream their bodies: it
    /// hands each task's response to the caller waiting for it, then the
    /// body's chunks to that task's stream.
    final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Pending {
            var response: CheckedContinuation<URLResponse, Swift.Error>?
            let body: AsyncThrowingStream<Data, Swift.Error>.Continuation
        }

        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        /// Starts `task` and waits for its response.
        func start(
            _ task: URLSessionDataTask, body: AsyncThrowingStream<Data, Swift.Error>.Continuation
        ) async throws -> URLResponse {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock {
                        pending[task.taskIdentifier] = Pending(response: continuation, body: body)
                    }
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let waiter = lock.withLock { () -> CheckedContinuation<URLResponse, Swift.Error>? in
                defer { pending[dataTask.taskIdentifier]?.response = nil }
                return pending[dataTask.taskIdentifier]?.response
            }
            completionHandler(.allow)
            waiter?.resume(returning: response)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let body = lock.withLock { pending[dataTask.taskIdentifier]?.body }
            body?.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            guard let finished = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
            finished.response?.resume(throwing: error ?? URLError(.badServerResponse))
            if let error {
                finished.body.finish(throwing: error)
            } else {
                finished.body.finish()
            }
        }
    }

    extension URLRequest {
        /// The request with the headers of `configuration.httpAdditionalHeaders`
        /// it does not set itself.
        ///
        /// swift-corelibs-foundation adds these headers only while it sends
        /// the request, so a `URLProtocol` would not see them.
        func addingAdditionalHeaders(of configuration: URLSessionConfiguration) -> URLRequest {
            guard let additional = configuration.httpAdditionalHeaders, !additional.isEmpty else { return self }
            var request = self
            for (name, value) in additional {
                guard let name = name as? String, let value = value as? String,
                    request.value(forHTTPHeaderField: name) == nil
                else { continue }
                request.setValue(value, forHTTPHeaderField: name)
            }
            return request
        }
    }
#endif

extension URLSession {
    /// The response to `request` and its body, read as it arrives.
    ///
    /// On swift-corelibs-foundation, `streaming` is a session with this
    /// session's configuration and a ``StreamingSessionDelegate``.
    func responseBody(
        for request: URLRequest, streaming: StreamingSession
    ) async throws -> (ResponseBody, URLResponse) {
        #if canImport(FoundationNetworking)
            let task = streaming.session.dataTask(
                with: request.addingAdditionalHeaders(of: streaming.session.configuration))
            let (chunks, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
            // A body nobody reads any more stops its task.
            continuation.onTermination = { _ in task.cancel() }
            let response = try await streaming.delegate.start(task, body: continuation)
            return (ResponseBody(chunks: chunks, task: task), response)
        #else
            let (bytes, response) = try await self.bytes(for: request)
            return (ResponseBody(bytes: bytes), response)
        #endif
    }
}

/// The session that streams response bodies on swift-corelibs-foundation; on
/// Apple platforms the transport's own session does.
struct StreamingSession: Sendable {
    #if canImport(FoundationNetworking)
        let session: URLSession
        let delegate: StreamingSessionDelegate
    #endif

    init(configuration: URLSessionConfiguration) {
        #if canImport(FoundationNetworking)
            let delegate = StreamingSessionDelegate()
            self.delegate = delegate
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        #endif
    }

    /// Cancels the session's tasks and releases its delegate.
    func invalidate() {
        #if canImport(FoundationNetworking)
            session.invalidateAndCancel()
        #endif
    }
}
