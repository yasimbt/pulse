/// Fixed-capacity buffer that overwrites its oldest element.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }
    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    public var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }

    /// The newest `count` elements, oldest first.
    public func suffix(_ count: Int) -> [Element] {
        let taken = min(count, storage.count)
        return (0..<taken).map { storage[(head + storage.count - taken + $0) % storage.count] }
    }
}
