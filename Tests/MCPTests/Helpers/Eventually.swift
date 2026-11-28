/// Whether `condition` holds within `limit`, checking every 5 ms.
///
/// Tests wait with this instead of a fixed sleep, so a slow machine only
/// makes them slower: `#expect(await eventually { await flag.isSet })`.
func eventually(
    within limit: Duration = .seconds(30), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A flag that test code sets once, and other tasks wait for.
actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// A count that test code increments, and other tasks wait for.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
