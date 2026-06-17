import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import protocol Foundation.LocalizedError

/// An error thrown when a server response cannot be decoded into the result type its request expects.
///
/// The client decodes each response payload into the concrete `Result` type declared by the request
/// method. When the payload is valid JSON but does not match that type — an unexpected shape, a
/// missing key, a value of the wrong type — the client throws this error in place of the result.
///
/// The error preserves the raw response and the decoding error that caused it, so a caller can
/// diagnose the mismatch or fall back to reading the response directly:
///
/// ```swift
/// do {
///     let (content, isError) = try await client.callTool(name: "search", arguments: ["query": "mcp"])
///     // Use the decoded result.
/// } catch let error as ResponseDecodingError {
///     // The server's response did not match the expected result type.
///     logger.error("\(error)")
///     // Fall back to reading the raw response directly, when it is present.
///     if case let .object(fields)? = error.value {
///         // ...
///     }
/// }
/// ```
public struct ResponseDecodingError: Swift.Error {
    /// The result type the response was expected to decode into.
    ///
    /// This is a metatype, so compare it with `ObjectIdentifier`:
    /// `ObjectIdentifier(error.expectedType) == ObjectIdentifier(CallTool.Result.self)`.
    public let expectedType: Any.Type

    /// The raw response value returned by the server, before typed decoding.
    ///
    /// When the response decoded to a ``Value`` but could not convert into ``expectedType`` — the
    /// case this error exists for — it holds that value so the caller can read the fields it needs
    /// directly. It is `nil` only on a defensive fallback the live client does not normally reach,
    /// where the response was not a ``Value`` at all.
    public let value: Value?

    /// The error raised while decoding ``value`` into ``expectedType``, when one is available.
    ///
    /// This is typically a `DecodingError` whose context names the failing coding path and the
    /// reason the value did not match.
    public let underlyingError: (any Swift.Error)?

    init(
        expectedType: Any.Type,
        value: Value? = nil,
        underlyingError: (any Swift.Error)? = nil
    ) {
        self.expectedType = expectedType
        self.value = value
        self.underlyingError = underlyingError
    }
}

// `expectedType` is a metatype and `value` is `Sendable`. `underlyingError` is an `any Error`
// captured at the throw site, which the SDK only ever populates with a `DecodingError` value, and
// the initializer is internal so a caller cannot inject a non-`Sendable` error. Every stored
// property is immutable, so the error is safe to share across isolation domains, as `MCPError` is.
extension ResponseDecodingError: @unchecked Sendable {}

extension ResponseDecodingError: CustomStringConvertible {
    public var description: String {
        var description = "Response could not be decoded into \(expectedType)"
        if let underlyingError {
            description += ": \(underlyingError)"
        }
        return description
    }
}

extension ResponseDecodingError: LocalizedError {
    public var errorDescription: String? { description }
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
                        request.continuation.resume(
                            throwing: ResponseDecodingError(
                                expectedType: T.self,
                                value: value,
                                underlyingError: error
                            )
                        )
                    }
                } else {
                    request.continuation.resume(
                        throwing: ResponseDecodingError(expectedType: T.self)
                    )
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
