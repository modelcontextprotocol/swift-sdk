import Foundation
import Testing

@testable import MCP

/// Tests for InMemoryEventStore - event storage for resumability support.
@Suite("InMemory Event Store Tests")
struct InMemoryEventStoreTests {

    // MARK: - Basic Operations

    @Test("Initialization creates empty store")
    func initialization() async {
        let store = InMemoryEventStore()
        let count = await store.eventCount
        #expect(count == 0)
    }

    @Test("Store event")
    func storeEvent() async throws {
        let store = InMemoryEventStore()
        let message = #"{"jsonrpc":"2.0","result":"test","id":"1"}"#.data(using: .utf8)!

        let eventId = try await store.storeEvent(streamId: "stream-1", message: message)

        #expect(!eventId.isEmpty)
        #expect(eventId.contains("stream-1"))

        let count = await store.eventCount
        #expect(count == 1)
    }

    @Test("Store multiple events")
    func storeMultipleEvents() async throws {
        let store = InMemoryEventStore()

        for i in 0..<5 {
            let message = #"{"jsonrpc":"2.0","result":"\#(i)","id":"\#(i)"}"#.data(using: .utf8)!
            _ = try await store.storeEvent(streamId: "stream-1", message: message)
        }

        let count = await store.eventCount
        #expect(count == 5)
    }

    @Test("Stream ID for event ID")
    func streamIdForEventId() async throws {
        let store = InMemoryEventStore()
        let message = #"{"jsonrpc":"2.0","result":"test","id":"1"}"#.data(using: .utf8)!

        let eventId = try await store.storeEvent(streamId: "my-stream-id", message: message)

        let streamId = await store.streamIdForEventId(eventId)
        #expect(streamId == "my-stream-id")
    }

    @Test("Stream ID for unknown event ID returns nil")
    func streamIdForUnknownEventId() async {
        let store = InMemoryEventStore()

        let streamId = await store.streamIdForEventId("unknown-event-id")
        #expect(streamId == nil)
    }

    @Test("Stream ID for event ID with underscores")
    func streamIdForEventIdWithUnderscores() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        // Stream ID with underscores
        let eventId = try await store.storeEvent(streamId: "stream_with_underscores", message: message)

        let streamId = await store.streamIdForEventId(eventId)
        #expect(streamId == "stream_with_underscores")
    }

    // MARK: - Event Replay

    @Test("Replay events after")
    func replayEventsAfter() async throws {
        let store = InMemoryEventStore()

        // Store some events
        var eventIds: [String] = []
        for i in 0..<5 {
            let message = #"{"jsonrpc":"2.0","result":"\#(i)","id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream-1", message: message)
            eventIds.append(eventId)
        }

        // Replay events after the second one
        actor MessageCollector {
            var messages: [String] = []
            func add(_ msg: String) { messages.append(msg) }
            func get() -> [String] { messages }
        }
        let collector = MessageCollector()

        let streamId = try await store.replayEventsAfter(eventIds[1]) { _, message in
            if let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                let result = json["result"] as? String
            {
                await collector.add(result)
            }
        }

        #expect(streamId == "stream-1")
        let replayedMessages = await collector.get()
        #expect(replayedMessages == ["2", "3", "4"])  // Events 2, 3, 4 (after event 1)
    }

    @Test("Replay events only from same stream")
    func replayEventsOnlyFromSameStream() async throws {
        let store = InMemoryEventStore()

        // Store events for two different streams
        let message1 = #"{"stream":"1","id":"a"}"#.data(using: .utf8)!
        let eventId1 = try await store.storeEvent(streamId: "stream-1", message: message1)

        let message2 = #"{"stream":"2","id":"b"}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-2", message: message2)

        let message3 = #"{"stream":"1","id":"c"}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-1", message: message3)

        // Replay from stream-1's first event
        actor Counter {
            var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }
        let counter = Counter()

        _ = try await store.replayEventsAfter(eventId1) { _, _ in
            await counter.increment()
        }

        // Should only replay event "c" from stream-1 (not "b" from stream-2)
        let replayedCount = await counter.value()
        #expect(replayedCount == 1)
    }

    @Test("Replay events with unknown event ID throws")
    func replayEventsUnknownEventId() async {
        let store = InMemoryEventStore()

        await #expect(throws: EventStoreError.self) {
            _ = try await store.replayEventsAfter("unknown-event") { _, _ in }
        }
    }

    // MARK: - Cleanup

    @Test("Clear removes all events")
    func clear() async throws {
        let store = InMemoryEventStore()

        // Store some events
        for _ in 0..<5 {
            let message = Data()
            _ = try await store.storeEvent(streamId: "stream", message: message)
        }

        var count = await store.eventCount
        #expect(count == 5)

        await store.clear()

        count = await store.eventCount
        #expect(count == 0)
    }

    @Test("Remove events for stream")
    func removeEventsForStream() async throws {
        let store = InMemoryEventStore()

        // Store events for two streams
        for _ in 0..<3 {
            _ = try await store.storeEvent(streamId: "stream-1", message: Data())
        }
        for _ in 0..<2 {
            _ = try await store.storeEvent(streamId: "stream-2", message: Data())
        }

        var count = await store.eventCount
        #expect(count == 5)

        let removed = await store.removeEvents(forStream: "stream-1")
        #expect(removed == 3)

        count = await store.eventCount
        #expect(count == 2)
    }

    @Test("Cleanup old events")
    func cleanUpOldEvents() async throws {
        let store = InMemoryEventStore()

        // Store an event
        _ = try await store.storeEvent(streamId: "stream", message: Data())

        var count = await store.eventCount
        #expect(count == 1)

        // Clean up with zero age - should remove all
        let removed = await store.cleanUp(olderThan: .zero)
        #expect(removed == 1)

        count = await store.eventCount
        #expect(count == 0)
    }

    @Test("Cleanup does not remove recent events")
    func cleanUpDoesNotRemoveRecentEvents() async throws {
        let store = InMemoryEventStore()

        // Store an event
        _ = try await store.storeEvent(streamId: "stream", message: Data())

        // Clean up with 1 hour age - should not remove recent event
        let removed = await store.cleanUp(olderThan: .seconds(3600))
        #expect(removed == 0)

        let count = await store.eventCount
        #expect(count == 1)
    }

    // MARK: - Concurrency

    @Test("Concurrent store and retrieve")
    func concurrentStoreAndRetrieve() async throws {
        let store = InMemoryEventStore()

        // Concurrently store events
        await withTaskGroup(of: String.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let message = Data()
                    return try! await store.storeEvent(streamId: "stream-\(i % 10)", message: message)
                }
            }
        }

        let count = await store.eventCount
        #expect(count == 100)
    }

    @Test("Concurrent replay")
    func concurrentReplay() async throws {
        let store = InMemoryEventStore()

        // Store events for multiple streams
        // Note: Use non-empty data because empty data is treated as priming events and skipped during replay
        var firstEventIds: [String] = []
        for stream in 0..<5 {
            let message = Data("test".utf8)
            let eventId = try await store.storeEvent(streamId: "stream-\(stream)", message: message)
            firstEventIds.append(eventId)

            // Add more events to each stream
            for _ in 0..<10 {
                _ = try await store.storeEvent(streamId: "stream-\(stream)", message: message)
            }
        }

        // Concurrently replay from each stream
        actor Counter {
            var value = 0
            func increment() { value += 1 }
            func reset() -> Int {
                let v = value
                value = 0
                return v
            }
        }

        await withTaskGroup(of: Int.self) { group in
            for (_, eventId) in firstEventIds.enumerated() {
                group.addTask {
                    let counter = Counter()
                    _ = try? await store.replayEventsAfter(eventId) { _, _ in
                        await counter.increment()
                    }
                    return await counter.reset()
                }
            }

            for await count in group {
                #expect(count == 10)  // Each stream should replay 10 events
            }
        }
    }

    // MARK: - Event ID Format

    @Test("Event ID contains stream ID")
    func eventIdContainsStreamId() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        let eventId = try await store.storeEvent(streamId: "unique-stream-123", message: message)

        #expect(eventId.hasPrefix("unique-stream-123_"))
    }

    @Test("Event IDs are unique")
    func eventIdsAreUnique() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        var eventIds = Set<String>()
        for _ in 0..<100 {
            let eventId = try await store.storeEvent(streamId: "stream", message: message)
            eventIds.insert(eventId)
        }

        #expect(eventIds.count == 100)  // All IDs should be unique
    }

    // MARK: - Max Events Per Stream

    @Test("Default maxEventsPerStream is 100")
    func defaultMaxEventsPerStream() async {
        let store = InMemoryEventStore()
        #expect(store.maxEventsPerStream == 100)
    }

    @Test("Custom maxEventsPerStream is respected")
    func customMaxEventsPerStream() async {
        let store = InMemoryEventStore(maxEventsPerStream: 50)
        #expect(store.maxEventsPerStream == 50)
    }

    @Test("Automatic eviction when max events reached")
    func automaticEviction() async throws {
        let store = InMemoryEventStore(maxEventsPerStream: 5)
        let message = Data("test".utf8)

        // Store 5 events (at capacity)
        var eventIds: [String] = []
        for i in 0..<5 {
            let msg = #"{"id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream", message: msg)
            eventIds.append(eventId)
        }

        var count = await store.eventCount
        #expect(count == 5)

        // Store one more - should evict the oldest
        let newEventId = try await store.storeEvent(streamId: "stream", message: message)

        count = await store.eventCount
        #expect(count == 5)  // Still 5 events

        // The oldest event should be evicted
        let oldestStreamId = await store.streamIdForEventId(eventIds[0])
        // The event is no longer in the index, so we fall back to parsing
        #expect(oldestStreamId == "stream")  // Parsing still works

        // But replay should fail for the evicted event
        await #expect(throws: EventStoreError.self) {
            _ = try await store.replayEventsAfter(eventIds[0]) { _, _ in }
        }

        // The new event should be retrievable
        let newStreamId = await store.streamIdForEventId(newEventId)
        #expect(newStreamId == "stream")
    }

    @Test("Eviction is per-stream")
    func evictionIsPerStream() async throws {
        let store = InMemoryEventStore(maxEventsPerStream: 3)
        let message = Data("test".utf8)

        // Fill stream-1 to capacity
        for _ in 0..<3 {
            _ = try await store.storeEvent(streamId: "stream-1", message: message)
        }

        // Fill stream-2 to capacity
        for _ in 0..<3 {
            _ = try await store.storeEvent(streamId: "stream-2", message: message)
        }

        var count = await store.eventCount
        #expect(count == 6)  // 3 per stream

        // Add to stream-1 - should only evict from stream-1
        _ = try await store.storeEvent(streamId: "stream-1", message: message)

        count = await store.eventCount
        #expect(count == 6)  // Still 6 total (3 + 3)

        let streamCount = await store.streamCount
        #expect(streamCount == 2)
    }

    @Test("Replay works correctly after eviction")
    func replayAfterEviction() async throws {
        let store = InMemoryEventStore(maxEventsPerStream: 5)

        // Store 5 events
        var eventIds: [String] = []
        for i in 0..<5 {
            let msg = #"{"id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream", message: msg)
            eventIds.append(eventId)
        }

        // Store 2 more (evicting the first 2)
        for i in 5..<7 {
            let msg = #"{"id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream", message: msg)
            eventIds.append(eventId)
        }

        // eventIds[2] (id: "2") should still be valid and allow replay of 3, 4, 5, 6
        actor MessageCollector {
            var ids: [String] = []
            func add(_ id: String) { ids.append(id) }
            func get() -> [String] { ids }
        }
        let collector = MessageCollector()

        _ = try await store.replayEventsAfter(eventIds[2]) { _, message in
            if let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                let id = json["id"] as? String
            {
                await collector.add(id)
            }
        }

        let replayedIds = await collector.get()
        #expect(replayedIds == ["3", "4", "5", "6"])
    }

    @Test("Stream count tracks active streams")
    func streamCountTracksActiveStreams() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        var streamCount = await store.streamCount
        #expect(streamCount == 0)

        _ = try await store.storeEvent(streamId: "stream-1", message: message)
        streamCount = await store.streamCount
        #expect(streamCount == 1)

        _ = try await store.storeEvent(streamId: "stream-2", message: message)
        streamCount = await store.streamCount
        #expect(streamCount == 2)

        // Adding to existing stream doesn't increase count
        _ = try await store.storeEvent(streamId: "stream-1", message: message)
        streamCount = await store.streamCount
        #expect(streamCount == 2)

        // Removing stream reduces count
        _ = await store.removeEvents(forStream: "stream-1")
        streamCount = await store.streamCount
        #expect(streamCount == 1)
    }
}
