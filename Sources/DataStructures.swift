import Foundation

/// O(1) amortized FIFO ring queue.
struct RingBuffer<Element> {
    private var storage: [Element?] = []
    private var head: Int = 0
    private var tail: Int = 0
    private(set) var count: Int = 0

    init() {}

    var isEmpty: Bool { count == 0 }

    var first: Element? {
        count > 0 ? storage[head] : nil
    }

    var last: Element? {
        guard count > 0, !storage.isEmpty else { return nil }
        let idx = (tail == 0 ? storage.count : tail) - 1
        return storage[idx]
    }

    mutating func append(_ element: Element) {
        if count == storage.count {
            let newCapacity = max(8, storage.count * 2)
            var next = [Element?](repeating: nil, count: newCapacity)
            let cap = storage.count
            for i in 0..<count {
                next[i] = storage[(head + i) % cap]
            }
            storage = next
            head = 0
            tail = count
        }
        storage[tail] = element
        tail = (tail + 1) % storage.count
        count += 1
    }

    @discardableResult
    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        if count == 0 {
            head = 0
            tail = 0
        }
        return element
    }

    mutating func removeFirst(_ k: Int) {
        guard k > 0 else { return }
        if k >= count {
            removeAll(keepingCapacity: true)
            return
        }
        let cap = storage.count
        for i in 0..<k {
            storage[(head + i) % cap] = nil
        }
        head = (head + k) % cap
        count -= k
    }

    func suffix(_ maxLength: Int) -> [Element] {
        guard maxLength > 0, count > 0, !storage.isEmpty else { return [] }
        let n = min(maxLength, count)
        let startOffset = count - n
        let cap = storage.count
        var result: [Element] = []
        result.reserveCapacity(n)
        for i in startOffset..<count {
            if let element = storage[(head + i) % cap] {
                result.append(element)
            }
        }
        return result
    }

    func toArray() -> [Element] {
        suffix(count)
    }

    func forEachEnumerated(_ body: (Int, Element) -> Void) {
        guard count > 0, !storage.isEmpty else { return }
        let cap = storage.count
        for i in 0..<count {
            if let element = storage[(head + i) % cap] {
                body(i, element)
            }
        }
    }

    mutating func removeAll(keepingCapacity: Bool) {
        if keepingCapacity {
            if count > 0, !storage.isEmpty {
                let cap = storage.count
                for i in 0..<count {
                    storage[(head + i) % cap] = nil
                }
            }
        } else {
            storage.removeAll(keepingCapacity: false)
        }
        head = 0
        tail = 0
        count = 0
    }

    mutating func removeAll(where shouldBeRemoved: (Element) -> Bool) {
        guard count > 0, !storage.isEmpty else { return }
        let cap = storage.count
        var writeSlot = head
        var kept = 0
        for i in 0..<count {
            let readSlot = (head + i) % cap
            guard let element = storage[readSlot] else { continue }
            if shouldBeRemoved(element) {
                storage[readSlot] = nil
            } else {
                if writeSlot != readSlot {
                    storage[writeSlot] = element
                    storage[readSlot] = nil
                }
                writeSlot = (writeSlot + 1) % cap
                kept += 1
            }
        }
        count = kept
        if kept == 0 {
            head = 0
            tail = 0
        } else {
            tail = writeSlot
        }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

/// O(1) intrusive array-backed LRU cache with zero heap allocations on hit or eviction at capacity.
struct LRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Node: Sendable {
        var key: Key
        var value: Value
        var prev: Int
        var next: Int
    }

    let maxCapacity: Int
    private var nodes: [Node] = []
    private var indexByKey: [Key: Int] = [:]
    private var head: Int = -1
    private var tail: Int = -1

    init(maxCapacity: Int) {
        self.maxCapacity = max(1, maxCapacity)
    }

    var count: Int { indexByKey.count }

    mutating func get(_ key: Key) -> Value? {
        guard let idx = indexByKey[key] else { return nil }
        moveToHead(idx)
        return nodes[idx].value
    }

    mutating func put(_ key: Key, value: Value) {
        if let idx = indexByKey[key] {
            nodes[idx].value = value
            moveToHead(idx)
            return
        }
        if nodes.count < maxCapacity {
            let idx = nodes.count
            nodes.append(Node(key: key, value: value, prev: -1, next: head))
            if head != -1 {
                nodes[head].prev = idx
            }
            head = idx
            if tail == -1 {
                tail = idx
            }
            indexByKey[key] = idx
        } else {
            let evictIdx = tail
            let oldKey = nodes[evictIdx].key
            indexByKey.removeValue(forKey: oldKey)
            nodes[evictIdx].key = key
            nodes[evictIdx].value = value
            indexByKey[key] = evictIdx
            moveToHead(evictIdx)
        }
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        indexByKey.removeAll(keepingCapacity: keepingCapacity)
        nodes.removeAll(keepingCapacity: keepingCapacity)
        head = -1
        tail = -1
    }

    private mutating func moveToHead(_ idx: Int) {
        guard idx != head else { return }
        let prevIdx = nodes[idx].prev
        let nextIdx = nodes[idx].next
        if prevIdx != -1 {
            nodes[prevIdx].next = nextIdx
        } else {
            head = nextIdx
        }
        if nextIdx != -1 {
            nodes[nextIdx].prev = prevIdx
        } else {
            tail = prevIdx
        }
        nodes[idx].prev = -1
        nodes[idx].next = head
        if head != -1 {
            nodes[head].prev = idx
        }
        head = idx
        if tail == -1 {
            tail = idx
        }
    }
}
