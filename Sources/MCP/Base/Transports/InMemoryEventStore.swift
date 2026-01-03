import Foundation

/// Simple in-memory implementation of the `EventStore` protocol for resumability support.
///
/// This implementation is primarily intended for examples and testing. For production use,
/// consider implementing a persistent storage solution (e.g., using a database or cache).
///
/// ## How It Works
///
/// The `InMemoryEventStore` generates event IDs that encode the stream ID, allowing
/// events to be replayed for a specific stream when a client reconnects with a
/// `Last-Event-ID` header.
///
/// Event ID format: `{streamId}_{timestamp}_{random}`
///
/// ## Memory Management
///
/// The event store automatically limits memory usage by keeping only the last N events
/// per stream (configurable via `maxEventsPerStream`). When a stream exceeds its limit,
/// the oldest events are automatically evicted.
///
/// You can also manually manage memory using:
/// - `cleanup(olderThan:)`: Remove events older than a specified duration
/// - `removeEvents(forStream:)`: Remove all events for a specific stream
/// - `clear()`: Remove all events
///
/// ## Example Usage
///
/// ```swift
/// // Default: 100 events per stream
/// let eventStore = InMemoryEventStore()
///
/// // Custom limit: 500 events per stream
/// let eventStore = InMemoryEventStore(maxEventsPerStream: 500)
///
/// let transport = HTTPServerTransport(
///     options: .init(
///         sessionIdGenerator: { UUID().uuidString },
///         eventStore: eventStore
///     )
/// )
/// ```
///
/// ## Limitations
///
/// - **Not persistent**: Events are lost when the process restarts
/// - **Single process**: Cannot be shared across multiple server instances
///
/// For production deployments, implement `EventStore` with a persistent backend like
/// Redis, PostgreSQL, or another appropriate storage system.
public actor InMemoryEventStore: EventStore {
    /// Maximum number of events to keep per stream.
    /// When a stream exceeds this limit, the oldest events are automatically evicted.
    public nonisolated let maxEventsPerStream: Int

    /// Per-stream event storage, maintaining chronological order within each stream
    private var streams: [String: [StoredEvent]] = [:]

    /// Event ID to event entry lookup for quick access
    private var eventIndex: [String: StoredEvent] = [:]

    private struct StoredEvent {
        let eventId: String
        let streamId: String
        let message: Data
        let timestamp: Date
    }

    /// Creates a new in-memory event store.
    ///
    /// - Parameter maxEventsPerStream: Maximum number of events to keep per stream.
    ///   When a stream exceeds this limit, the oldest events are automatically evicted.
    ///   Default is 100 events per stream.
    public init(maxEventsPerStream: Int = 100) {
        precondition(maxEventsPerStream > 0, "maxEventsPerStream must be positive")
        self.maxEventsPerStream = maxEventsPerStream
    }

    // MARK: - EventStore Protocol

    /// Stores an event and returns its unique ID.
    ///
    /// If the stream has reached its maximum event limit (`maxEventsPerStream`),
    /// the oldest event in that stream is automatically evicted.
    ///
    /// - Parameters:
    ///   - streamId: The stream this event belongs to
    ///   - message: The JSON-RPC message data. Empty `Data()` indicates a priming event.
    /// - Returns: A unique event ID for this event
    public func storeEvent(streamId: String, message: Data) async throws -> String {
        let eventId = generateEventId(streamId: streamId)
        let event = StoredEvent(
            eventId: eventId,
            streamId: streamId,
            message: message,
            timestamp: Date()
        )

        // Get or create the event list for this stream
        var streamEvents = streams[streamId] ?? []

        // If stream is at capacity, evict the oldest event
        if streamEvents.count >= maxEventsPerStream {
            let oldestEvent = streamEvents.removeFirst()
            eventIndex.removeValue(forKey: oldestEvent.eventId)
        }

        // Add the new event
        streamEvents.append(event)
        streams[streamId] = streamEvents
        eventIndex[eventId] = event

        return eventId
    }

    /// Gets the stream ID associated with an event ID.
    ///
    /// - Parameter eventId: The event ID to look up
    /// - Returns: The stream ID, or nil if not found
    public func streamIdForEventId(_ eventId: String) async -> String? {
        // Try to get from stored event first (fast O(1) lookup)
        if let event = eventIndex[eventId] {
            return event.streamId
        }
        // Fall back to parsing from event ID format
        return extractStreamId(from: eventId)
    }

    /// Replays events after the given event ID.
    ///
    /// Events are replayed in chronological order, only including events from the same stream.
    /// Priming events (empty message data) are skipped during replay.
    ///
    /// - Parameters:
    ///   - lastEventId: The last event ID the client received
    ///   - send: Callback to send each replayed event (eventId, message)
    /// - Returns: The stream ID for continued event delivery
    /// - Throws: `EventStoreError.eventNotFound` if the event ID doesn't exist
    public func replayEventsAfter(
        _ lastEventId: String,
        send: @escaping @Sendable (String, Data) async throws -> Void
    ) async throws -> String {
        // Look up the event in our index
        guard let lastEvent = eventIndex[lastEventId] else {
            throw EventStoreError.eventNotFound(lastEventId)
        }

        let streamId = lastEvent.streamId

        // Get events for this stream
        guard let streamEvents = streams[streamId] else {
            // Stream exists in index but not in streams - should not happen
            throw EventStoreError.eventNotFound(lastEventId)
        }

        // Find the position of the last event and replay everything after it
        var foundLastEvent = false
        for event in streamEvents {
            if foundLastEvent {
                // Skip priming events (empty message data)
                if !event.message.isEmpty {
                    try await send(event.eventId, event.message)
                }
            } else if event.eventId == lastEventId {
                foundLastEvent = true
            }
        }

        return streamId
    }

    // MARK: - Cleanup

    /// Removes events older than the specified duration.
    ///
    /// Call this periodically to remove stale events and free memory.
    ///
    /// - Parameter age: Events older than this duration will be removed
    /// - Returns: The number of events removed
    @discardableResult
    public func cleanUp(olderThan age: Duration) -> Int {
        let cutoff = Date().addingTimeInterval(-age.timeInterval)
        var removed = 0

        for (streamId, events) in streams {
            var remaining: [StoredEvent] = []
            for event in events {
                if event.timestamp < cutoff {
                    eventIndex.removeValue(forKey: event.eventId)
                    removed += 1
                } else {
                    remaining.append(event)
                }
            }
            if remaining.isEmpty {
                streams.removeValue(forKey: streamId)
            } else {
                streams[streamId] = remaining
            }
        }

        return removed
    }

    /// Removes all events for a specific stream.
    ///
    /// - Parameter streamId: The stream ID whose events should be removed
    /// - Returns: The number of events removed
    @discardableResult
    public func removeEvents(forStream streamId: String) -> Int {
        guard let events = streams.removeValue(forKey: streamId) else {
            return 0
        }

        for event in events {
            eventIndex.removeValue(forKey: event.eventId)
        }

        return events.count
    }

    /// The total number of stored events across all streams.
    public var eventCount: Int {
        eventIndex.count
    }

    /// The number of active streams.
    public var streamCount: Int {
        streams.count
    }

    /// Removes all events from all streams.
    public func clear() {
        streams.removeAll()
        eventIndex.removeAll()
    }

    // MARK: - Private Helpers

    /// Generates a unique event ID that encodes the stream ID.
    ///
    /// Format: `{streamId}_{timestamp}_{random}`
    private func generateEventId(streamId: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let random = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        return "\(streamId)_\(timestamp)_\(random)"
    }

    /// Extracts the stream ID from an event ID.
    ///
    /// Handles event IDs in format: `{streamId}_{timestamp}_{random}`
    private func extractStreamId(from eventId: String) -> String? {
        // Find the last two underscores (timestamp and random parts)
        let parts = eventId.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }

        // Reconstruct stream ID (everything before the last two parts)
        // This handles stream IDs that contain underscores
        let streamIdParts = parts.dropLast(2)
        guard !streamIdParts.isEmpty else { return nil }

        return streamIdParts.joined(separator: "_")
    }
}

/// Errors that can occur when working with the event store.
public enum EventStoreError: Error, CustomStringConvertible {
    /// The specified event ID was not found.
    case eventNotFound(String)

    public var description: String {
        switch self {
        case .eventNotFound(let eventId):
            return "Event not found: \(eventId)"
        }
    }
}
