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
        let cancellation: Cancellation

        /// Whether `chunks` ended because its reader's task was cancelled:
        /// the stream's iterator then returns `nil`, as at the end of the
        /// body. A body that ended before its reader was cancelled is whole.
        /// `@unchecked Sendable`: `lock` guards `cancelled`.
        final class Cancellation: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false

            var isCancelled: Bool { lock.withLock { cancelled } }

            func record() { lock.withLock { cancelled = true } }
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            var chunks: AsyncThrowingStream<Data, Swift.Error>.AsyncIterator
            let cancellation: Cancellation
            var chunk = Data()
            var index = 0

            mutating func next() async throws -> UInt8? {
                while index >= chunk.endIndex {
                    guard let next = try await chunks.next() else {
                        // A cut body must not pass for a whole one; this
                        // throws where `URLSession.AsyncBytes` would.
                        if cancellation.isCancelled { throw CancellationError() }
                        return nil
                    }
                    chunk = next
                    index = chunk.startIndex
                }
                defer { index += 1 }
                return chunk[index]
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(chunks: chunks.makeAsyncIterator(), cancellation: cancellation)
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
            var responded = false
        }

        private let lock = NSLock()
        private let redirects: OAuthRedirectGuard?
        private var pending: [Int: Pending] = [:]
        /// Tasks that completed before ``start(_:body:)`` registered them, as
        /// one cancelled first does: their error, `nil` for success.
        private var completedEarly: [Int: Swift.Error?] = [:]

        /// A delegate that follows the redirects `redirects` allows, or every
        /// redirect.
        init(redirects: OAuthRedirectGuard? = nil) {
            self.redirects = redirects
            super.init()
        }

        /// Starts `task` and waits for its response. `resumed` runs once the
        /// task is resumed, or has failed.
        func start(
            _ task: URLSessionDataTask, body: AsyncThrowingStream<Data, Swift.Error>.Continuation,
            resumed: () -> Void = {}
        ) async throws -> URLResponse {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let early = lock.withLock { () -> Swift.Error?? in
                        if let error = completedEarly.removeValue(forKey: task.taskIdentifier) { return error }
                        pending[task.taskIdentifier] = Pending(response: continuation, body: body)
                        return nil
                    }
                    defer { resumed() }
                    if let error = early {
                        continuation.resume(throwing: error ?? URLError(.badServerResponse))
                        body.finish(throwing: error ?? URLError(.badServerResponse))
                        return
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
            let entry = lock.withLock { () -> Pending? in
                guard var entry = pending[dataTask.taskIdentifier] else { return nil }
                defer {
                    entry.response = nil
                    entry.responded = true
                    pending[dataTask.taskIdentifier] = entry
                }
                return entry
            }
            let waiter = entry?.response
            // A second response would append its body to the first one's.
            if let entry, entry.responded {
                completionHandler(.cancel)
                entry.body.finish(throwing: URLError(.badServerResponse))
                return
            }
            completionHandler(.allow)
            waiter?.resume(returning: response)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let redirects else { return completionHandler(request) }
            redirects.urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let body = lock.withLock { pending[dataTask.taskIdentifier]?.body }
            body?.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            let finished = lock.withLock { () -> Pending? in
                guard let finished = pending.removeValue(forKey: task.taskIdentifier) else {
                    completedEarly[task.taskIdentifier] = .some(error)
                    return nil
                }
                return finished
            }
            guard let finished else { return }
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
        guard streaming.lifetime.begin() else { throw MCPError.internalError("Transport not connected") }
        #if canImport(FoundationNetworking)
            let task = streaming.session.dataTask(
                with: request.addingAdditionalHeaders(of: streaming.session.configuration))
            let (chunks, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
            let cancellation = ResponseBody.Cancellation()
            // A body nobody reads any more stops its task. The handler runs
            // before a cancelled reader's `next()` returns `nil`.
            continuation.onTermination = { termination in
                if case .cancelled = termination { cancellation.record() }
                task.cancel()
            }
            let response = try await streaming.delegate.start(
                task, body: continuation, resumed: streaming.lifetime.end)
            return (ResponseBody(chunks: chunks, task: task, cancellation: cancellation), response)
        #else
            // `bytes(for:)` creates its task after a suspension, so the
            // session stays valid until it returns.
            defer { streaming.lifetime.end() }
            let (bytes, response) = try await self.bytes(for: request, delegate: streaming.redirects)
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
    #else
        /// The task delegate that checks the redirects, if any.
        let redirects: OAuthRedirectGuard?
    #endif
    let lifetime = Lifetime()

    /// Orders the creation of tasks against invalidation: a session
    /// traps (swift-corelibs-foundation) or raises (Apple platforms) when a
    /// task is created after it was invalidated.
    final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var invalidated = false
        private var starting = 0
        private var deferred: [URLSession] = []

        var isInvalidated: Bool { lock.withLock { invalidated } }

        /// Whether a task may be created; when it may, ``end()`` follows
        /// once it exists and is resumed.
        func begin() -> Bool {
            lock.withLock {
                guard !invalidated else { return false }
                starting += 1
                return true
            }
        }

        func end() {
            let sessions = lock.withLock { () -> [URLSession] in
                starting -= 1
                guard starting == 0, invalidated else { return [] }
                defer { deferred = [] }
                return deferred
            }
            for session in sessions { session.invalidateAndCancel() }
        }

        /// Invalidates `sessions` now, or once the tasks being created exist.
        func invalidate(_ sessions: [URLSession]) {
            let now = lock.withLock { () -> [URLSession] in
                invalidated = true
                guard starting > 0 else { return sessions }
                deferred += sessions
                return []
            }
            for session in now { session.invalidateAndCancel() }
        }
    }

    /// A session with `configuration` that follows the redirects
    /// `redirects` allows, or every redirect.
    init(configuration: URLSessionConfiguration, redirects: OAuthRedirectGuard? = nil) {
        #if canImport(FoundationNetworking)
            let delegate = StreamingSessionDelegate(redirects: redirects)
            self.delegate = delegate
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        #else
            self.redirects = redirects
        #endif
    }

    /// Cancels the session's tasks, and those of `others`, and releases its
    /// delegate. Later ``URLSession/responseBody(for:streaming:)`` calls
    /// throw.
    func invalidate(along others: URLSession...) {
        #if canImport(FoundationNetworking)
            lifetime.invalidate(others + [session])
        #else
            lifetime.invalidate(others)
        #endif
    }
}
