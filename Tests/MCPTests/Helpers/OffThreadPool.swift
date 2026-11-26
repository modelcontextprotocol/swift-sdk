import Foundation

/// Runs `work` on a Dispatch thread instead of Swift's cooperative pool.
///
/// Use it for test code that blocks a thread or computes for a long time, such
/// as a blocking `read()` on a pipe or megabytes fed to a parser byte by byte.
/// On the pool such work holds one of its few threads (as few as one on a slow
/// simulator), and every other test running in parallel waits for it. Running
/// the tests with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, which gives the pool
/// a single thread, shows any test that still blocks it: that test never ends.
func offThreadPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}
