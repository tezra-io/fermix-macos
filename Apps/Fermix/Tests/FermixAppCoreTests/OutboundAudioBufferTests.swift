import Foundation
import Testing

@testable import FermixAppCore

@Suite("OutboundAudioBuffer")
struct OutboundAudioBufferTests {
    private func frame(_ byte: UInt8) -> Data {
        Data([byte])
    }

    @Test("holds up to capacity without dropping")
    func holdsUpToCapacityWithoutDropping() {
        var buffer = OutboundAudioBuffer(capacity: 3)

        #expect(buffer.append(frame(1)) == 0)
        #expect(buffer.append(frame(2)) == 0)
        #expect(buffer.append(frame(3)) == 0)

        #expect(buffer.count == 3)
        #expect(buffer.dropped == 0)
    }

    @Test("drops the oldest frame at capacity")
    func dropsOldestWhenAtCapacity() {
        var buffer = OutboundAudioBuffer(capacity: 3)
        buffer.append(frame(1))
        buffer.append(frame(2))
        buffer.append(frame(3))

        // Overflow: the oldest (1) is discarded, newest (4) retained.
        #expect(buffer.append(frame(4)) == 1)
        #expect(buffer.count == 3)
        #expect(buffer.dropped == 1)

        #expect(buffer.removeFirst() == frame(2))
        #expect(buffer.removeFirst() == frame(3))
        #expect(buffer.removeFirst() == frame(4))
        #expect(buffer.removeFirst() == nil)
        #expect(buffer.isEmpty)
    }

    @Test("drop count accumulates across overflows")
    func dropCountAccumulatesAcrossOverflows() {
        var buffer = OutboundAudioBuffer(capacity: 2)
        for byte in UInt8(1)...UInt8(10) {
            buffer.append(frame(byte))
        }

        // 10 appended, capacity 2 means 8 dropped and the last 2 retained.
        #expect(buffer.count == 2)
        #expect(buffer.dropped == 8)
        #expect(buffer.removeFirst() == frame(9))
        #expect(buffer.removeFirst() == frame(10))
    }

    @Test("removeAll resets frames and drop count")
    func removeAllResetsFramesAndDropCount() {
        var buffer = OutboundAudioBuffer(capacity: 1)
        buffer.append(frame(1))
        buffer.append(frame(2)) // drops 1

        buffer.removeAll()

        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
        #expect(buffer.dropped == 0)
    }
}
