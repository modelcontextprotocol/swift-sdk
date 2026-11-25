import Foundation

/// Error thrown when a type mismatch occurs during response handling
struct TypeMismatchError: Swift.Error {}

/// A pending request with a continuation for the result
struct PendingRequest<T> {
    let continuation: CheckedContinuation<T, Swift.Error>
}

/// Holds the outcome of a request until its sender awaits it.
///
/// A slot can be registered synchronously, before the request is sent, so a
/// response or a cancellation that arrives first is never lost. The first
/// outcome wins; later ones are ignored.
final class ResponseSlot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var outcome: Result<T, Swift.Error>?
    private var waiter: CheckedContinuation<T, Swift.Error>?

    func resolve(_ result: Result<T, Swift.Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
        } else {
            outcome = result
            lock.unlock()
        }
    }

    /// Waits for the outcome. Call at most once.
    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                self.outcome = nil
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// A type-erased pending request.
struct AnyPendingRequest: Sendable {
    private let _resume: @Sendable (Result<Any, Swift.Error>) -> Void

    init<T: Sendable & Decodable>(_ request: PendingRequest<T>) {
        let continuation = request.continuation
        self.init(T.self) { continuation.resume(with: $0) }
    }

    init<T: Sendable & Decodable>(_ slot: ResponseSlot<T>) {
        self.init(T.self) { slot.resolve($0) }
    }

    private init<T: Sendable & Decodable>(
        _ type: T.Type, deliver: @escaping @Sendable (Result<T, Swift.Error>) -> Void
    ) {
        _resume = { result in
            switch result {
            case .success(let value):
                // A result decoded from the wire keeps `data:` URL strings;
                // the typed decode turns those in `Value` fields into `.data`.
                if let value = value as? Value,
                    let data = try? JSONEncoder().encode(value),
                    let decoded = try? JSONDecoder().decode(T.self, from: data)
                {
                    deliver(.success(decoded))
                } else if let typedValue = value as? T {
                    deliver(.success(typedValue))
                } else {
                    deliver(.failure(TypeMismatchError()))
                }
            case .failure(let error):
                deliver(.failure(error))
            }
        }
    }

    func resume(returning value: Any) {
        _resume(.success(value))
    }

    func resume(throwing error: Swift.Error) {
        _resume(.failure(error))
    }
}
