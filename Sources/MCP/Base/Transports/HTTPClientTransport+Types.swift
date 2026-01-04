import Foundation

// Types extracted from HTTPClientTransport.swift
// - HTTPReconnectionOptions

/// Configuration options for reconnection behavior of the HTTPClientTransport.
///
/// These options control how the transport handles SSE stream disconnections
/// and reconnection attempts.
public struct HTTPReconnectionOptions: Sendable {
    /// Initial delay between reconnection attempts in seconds.
    /// Default is 1.0 second.
    public var initialReconnectionDelay: TimeInterval

    /// Maximum delay between reconnection attempts in seconds.
    /// Default is 30.0 seconds.
    public var maxReconnectionDelay: TimeInterval

    /// Factor by which the reconnection delay increases after each attempt.
    /// Default is 1.5.
    public var reconnectionDelayGrowFactor: Double

    /// Maximum number of reconnection attempts before giving up.
    /// Default is 2.
    public var maxRetries: Int

    /// Creates reconnection options with default values.
    public init(
        initialReconnectionDelay: TimeInterval = 1.0,
        maxReconnectionDelay: TimeInterval = 30.0,
        reconnectionDelayGrowFactor: Double = 1.5,
        maxRetries: Int = 2
    ) {
        self.initialReconnectionDelay = initialReconnectionDelay
        self.maxReconnectionDelay = maxReconnectionDelay
        self.reconnectionDelayGrowFactor = reconnectionDelayGrowFactor
        self.maxRetries = maxRetries
    }

    /// Default reconnection options.
    public static let `default` = HTTPReconnectionOptions()
}
