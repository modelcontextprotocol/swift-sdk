// Helper actor to safely accumulate tasks across sendable closures.
actor TaskCollector<Element: Sendable> {
  private var storage: [Element] = []

  func append(_ element: Element) {
    storage.append(element)
  }

  func snapshot() -> [Element] {
    storage
  }
}
