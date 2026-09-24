import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// A response could not be decoded as the result type expected by the request.
public struct TypeMismatchError: Swift.Error {
    public let expectedType: String
    public let rawValue: Value?
    public let underlyingError: (any Swift.Error)?

    init(expectedType: String, rawValue: Value?, underlyingError: (any Swift.Error)?) {
        self.expectedType = expectedType
        self.rawValue = rawValue
        self.underlyingError = underlyingError
    }
}

/// A pending request with a continuation for the result.
struct PendingRequest<T> {
    let continuation: CheckedContinuation<T, Swift.Error>
}

/// A type-erased pending request.
struct AnyPendingRequest: Sendable {
    private let _resume: @Sendable (Result<Any, Swift.Error>) -> Void

    init<T: Sendable & Decodable>(_ request: PendingRequest<T>) {
        _resume = { result in
            switch result {
            case .success(let value):
                if let typedValue = value as? T {
                    request.continuation.resume(returning: typedValue)
                } else if let value = value as? Value {
                    do {
                        let data = try JSONEncoder().encode(value)
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        request.continuation.resume(returning: decoded)
                    } catch {
                        request.continuation.resume(throwing: TypeMismatchError(
                            expectedType: String(reflecting: T.self),
                            rawValue: value,
                            underlyingError: error
                        ))
                    }
                } else {
                    request.continuation.resume(throwing: TypeMismatchError(
                        expectedType: String(reflecting: T.self),
                        rawValue: nil,
                        underlyingError: nil
                    ))
                }
            case .failure(let error):
                request.continuation.resume(throwing: error)
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
