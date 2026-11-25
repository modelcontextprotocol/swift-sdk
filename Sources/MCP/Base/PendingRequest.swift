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

    /// Resolves the slot, unless it already is.
    /// - Returns: Whether this outcome is the one the sender gets.
    @discardableResult
    func resolve(_ result: Result<T, Swift.Error>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
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
        return true
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
    private let _resume: @Sendable (Result<Any, Swift.Error>) -> Bool

    init<T: Sendable & Decodable>(_ request: PendingRequest<T>) {
        let continuation = request.continuation
        self.init(T.self) {
            continuation.resume(with: $0)
            return true
        }
    }

    init<T: Sendable & Decodable>(_ slot: ResponseSlot<T>) {
        self.init(T.self) { slot.resolve($0) }
    }

    private init<T: Sendable & Decodable>(
        _ type: T.Type, deliver: @escaping @Sendable (Result<T, Swift.Error>) -> Bool
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
                    return deliver(.success(decoded))
                } else if let typedValue = value as? T {
                    return deliver(.success(typedValue))
                } else {
                    return deliver(.failure(TypeMismatchError()))
                }
            case .failure(let error):
                return deliver(.failure(error))
            }
        }
    }

    /// Delivers a result.
    /// - Returns: `false` when the sender already has an outcome, such as a
    ///   cancellation, and this one is dropped.
    @discardableResult
    func resume(returning value: Any) -> Bool {
        _resume(.success(value))
    }

    /// Delivers an error.
    /// - Returns: `false` when the sender already has an outcome.
    @discardableResult
    func resume(throwing error: Swift.Error) -> Bool {
        _resume(.failure(error))
    }
}
