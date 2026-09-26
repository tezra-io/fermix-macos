import Foundation

/// Bounded, drop-oldest FIFO for outbound droppable lines. A droppable line is
/// real-time media: when the socket backs up we discard the *oldest* pending
/// line rather than let the buffer grow without bound. Lines that must arrive
/// never live here — they go through their own never-dropped queue.
struct DroppableLineBuffer {
    let capacity: Int
    private(set) var lines: [Data] = []
    private(set) var dropped: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0, "droppable line capacity must be positive")
        self.capacity = capacity
    }

    var isEmpty: Bool { lines.isEmpty }
    var count: Int { lines.count }

    /// Append a line, discarding the oldest queued line when already at
    /// capacity. Returns the number of lines dropped to make room (0 or 1).
    @discardableResult
    mutating func append(_ line: Data) -> Int {
        var droppedNow = 0
        if lines.count >= capacity {
            lines.removeFirst()
            dropped += 1
            droppedNow = 1
        }
        lines.append(line)
        return droppedNow
    }

    mutating func removeFirst() -> Data? {
        lines.isEmpty ? nil : lines.removeFirst()
    }

    mutating func removeAll() {
        lines.removeAll()
        dropped = 0
    }
}
