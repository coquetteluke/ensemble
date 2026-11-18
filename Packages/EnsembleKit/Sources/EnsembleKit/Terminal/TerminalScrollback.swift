import Foundation

/// Lines that scrolled off the top of the main screen, oldest first, at most `capacity` of them. When full,
/// each new line drops the oldest one (a ring, so that costs nothing).
public struct TerminalScrollback: Sendable {
    public let capacity: Int
    private var storage: [TerminalLine] = []
    /// Index of the oldest line in `storage` once the ring is full.
    private var head = 0
    /// Lines dropped since the terminal started (over capacity or cleared). Rows counted from the first line
    /// ever kept stay put when this grows, see `TerminalEmulator.firstStableRow`.
    public private(set) var droppedCount = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 0)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    /// Line `index`, 0 being the oldest kept.
    public subscript(index: Int) -> TerminalLine {
        storage[(head + index) % storage.count]
    }

    mutating func append(_ line: TerminalLine) {
        guard capacity > 0 else {
            droppedCount += 1
            return
        }
        if storage.count < capacity {
            storage.append(line)
        } else {
            storage[head] = line
            head = (head + 1) % capacity
            droppedCount += 1
        }
    }

    /// Takes the newest line back (when the window grows taller).
    mutating func removeLast() -> TerminalLine? {
        guard !storage.isEmpty else { return nil }
        if head != 0 {
            storage = Array(storage[head...] + storage[..<head])
            head = 0
        }
        return storage.removeLast()
    }

    mutating func removeAll() {
        droppedCount += storage.count
        storage.removeAll()
        head = 0
    }
}
