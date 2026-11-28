import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Carries a `URLProtocol` into the task or `@Sendable` closure that answers
/// its request.
///
/// `@unchecked Sendable`: `URLProtocol` is not `Sendable`, and
/// swift-corelibs-foundation marks its conformance unavailable, so a subclass
/// cannot conform either. Yet the URL loading system takes a protocol's client
/// callbacks from any thread. The mocks guard their own mutable state with a
/// lock.
struct SendableURLProtocol<P: URLProtocol>: @unchecked Sendable {
    let value: P

    init(_ value: P) { self.value = value }
}
