import Foundation
import Testing

@testable import FermixAppCore

@Suite("DroppableLineBuffer")
struct DroppableLineBufferTests {
    private func line(_ byte: UInt8) -> Data {
        Data([byte])
    }

    @Test("holds up to capacity without dropping")
    func holdsUpToCapacityWithoutDropping() {
        var buffer = DroppableLineBuffer(capacity: 3)

        #expect(buffer.append(line(1)) == 0)
        #expect(buffer.append(line(2)) == 0)
        #expect(buffer.append(line(3)) == 0)

        #expect(buffer.count == 3)
        #expect(buffer.dropped == 0)
    }

    @Test("drops the oldest line at capacity")
    func dropsOldestWhenAtCapacity() {
        var buffer = DroppableLineBuffer(capacity: 3)
        buffer.append(line(1))
        buffer.append(line(2))
        buffer.append(line(3))

        // Overflow: the oldest (1) is discarded, newest (4) retained.
        #expect(buffer.append(line(4)) == 1)
        #expect(buffer.count == 3)
        #expect(buffer.dropped == 1)

        #expect(buffer.removeFirst() == line(2))
        #expect(buffer.removeFirst() == line(3))
        #expect(buffer.removeFirst() == line(4))
        #expect(buffer.removeFirst() == nil)
        #expect(buffer.isEmpty)
    }

    @Test("drop count accumulates across overflows")
    func dropCountAccumulatesAcrossOverflows() {
        var buffer = DroppableLineBuffer(capacity: 2)
        for byte in UInt8(1)...UInt8(10) {
            buffer.append(line(byte))
        }

        // 10 appended, capacity 2 means 8 dropped and the last 2 retained.
        #expect(buffer.count == 2)
        #expect(buffer.dropped == 8)
        #expect(buffer.removeFirst() == line(9))
        #expect(buffer.removeFirst() == line(10))
    }

    @Test("removeAll resets lines and drop count")
    func removeAllResetsFramesAndDropCount() {
        var buffer = DroppableLineBuffer(capacity: 1)
        buffer.append(line(1))
        buffer.append(line(2)) // drops 1

        buffer.removeAll()

        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
        #expect(buffer.dropped == 0)
    }
}
