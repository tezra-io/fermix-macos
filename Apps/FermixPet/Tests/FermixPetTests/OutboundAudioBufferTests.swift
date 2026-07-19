import Foundation
import XCTest

@testable import FermixPet

final class OutboundAudioBufferTests: XCTestCase {
    private func frame(_ byte: UInt8) -> Data {
        Data([byte])
    }

    func testHoldsUpToCapacityWithoutDropping() {
        var buffer = OutboundAudioBuffer(capacity: 3)

        XCTAssertEqual(buffer.append(frame(1)), 0)
        XCTAssertEqual(buffer.append(frame(2)), 0)
        XCTAssertEqual(buffer.append(frame(3)), 0)

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.dropped, 0)
    }

    func testDropsOldestWhenAtCapacity() {
        var buffer = OutboundAudioBuffer(capacity: 3)
        buffer.append(frame(1))
        buffer.append(frame(2))
        buffer.append(frame(3))

        // Overflow: the oldest (1) is discarded, newest (4) retained.
        XCTAssertEqual(buffer.append(frame(4)), 1)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.dropped, 1)

        XCTAssertEqual(buffer.removeFirst(), frame(2))
        XCTAssertEqual(buffer.removeFirst(), frame(3))
        XCTAssertEqual(buffer.removeFirst(), frame(4))
        XCTAssertNil(buffer.removeFirst())
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDropCountAccumulatesAcrossOverflows() {
        var buffer = OutboundAudioBuffer(capacity: 2)
        for byte in UInt8(1)...UInt8(10) {
            buffer.append(frame(byte))
        }

        // 10 appended, capacity 2 ⇒ 8 dropped, last 2 retained.
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.dropped, 8)
        XCTAssertEqual(buffer.removeFirst(), frame(9))
        XCTAssertEqual(buffer.removeFirst(), frame(10))
    }

    func testRemoveAllResetsFramesAndDropCount() {
        var buffer = OutboundAudioBuffer(capacity: 1)
        buffer.append(frame(1))
        buffer.append(frame(2)) // drops 1

        buffer.removeAll()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.dropped, 0)
    }
}
