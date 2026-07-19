import Foundation
import XCTest

@testable import FermixPet

/// Thread-safe holder for a value captured from a socket-queue callback.
private final class EventBox {
    private let lock = NSLock()
    private var stored: [String: Any]?

    func set(_ value: [String: Any]) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class RealtimeSocketClientTests: XCTestCase {
    func testControlFrameReachesPeerWithNewlineFraming() throws {
        let server = try UnixSocketTestServer(drainReads: true)
        defer { server.shutdown() }

        let client = RealtimeSocketClient()
        try client.connect(path: server.path)
        XCTAssertTrue(server.waitForAccept(timeout: 2.0))

        client.send(["type": "call_start"])

        let deadline = Date().addingTimeInterval(2.0)
        var framedLine: Data?
        while Date() < deadline {
            let data = server.receivedData()
            if let newline = data.firstIndex(of: 0x0A) {
                framedLine = Data(data[..<newline])
                break
            }
            usleep(5_000)
        }

        let line = try XCTUnwrap(framedLine, "peer never received a framed control frame")
        let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "call_start")
        // Wire framing preserved: newline-terminated JSON.
        XCTAssertEqual(server.receivedData().last, 0x0A)

        client.close()
    }

    func testIncomingLineFiresOnEvent() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = RealtimeSocketClient()
        let box = EventBox()
        let received = expectation(description: "onEvent fires for an incoming line")
        client.onEvent = { event in
            box.set(event)
            received.fulfill()
        }

        try client.connect(path: server.path)
        XCTAssertTrue(server.waitForAccept(timeout: 2.0))

        server.writeToClient(Data(#"{"type":"state","state":"listening"}"#.utf8) + Data([0x0A]))
        wait(for: [received], timeout: 3.0)

        XCTAssertEqual(box.value?["type"] as? String, "state")
        XCTAssertEqual(box.value?["state"] as? String, "listening")

        client.close()
    }

    func testPeerCloseFiresOnClose() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = RealtimeSocketClient()
        let closed = expectation(description: "onClose fires on peer EOF")
        client.onClose = { closed.fulfill() }

        try client.connect(path: server.path)
        XCTAssertTrue(server.waitForAccept(timeout: 2.0))

        server.closeAcceptedConnection()
        wait(for: [closed], timeout: 3.0)
    }

    /// The core regression: a peer that has stopped reading must never wedge the
    /// client. Audio floods the bounded buffer (drop-oldest, no unbounded growth
    /// and no blocked queue), and a subsequent control frame that cannot be
    /// flushed within the deadline declares the connection dead.
    func testStalledWriterDropsOldestAudioAndDeclaresConnectionDead() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = RealtimeSocketClient(maxPendingAudioChunks: 4, controlFlushDeadline: 0.4)
        let closed = expectation(description: "onClose fires when a control frame cannot flush")
        client.onClose = { closed.fulfill() }

        try client.connect(path: server.path)
        XCTAssertTrue(server.waitForAccept(timeout: 2.0))

        // Push far more audio than the kernel send buffer plus the 4-chunk cap
        // can hold. If any of these blocked, the test would hang instead of
        // returning here.
        let chunk = Data(repeating: 0xAB, count: 4_096)
        for _ in 0..<2_000 {
            client.sendAudioChunk(chunk)
        }

        // Bounded buffer shed the oldest chunks rather than grow without bound.
        XCTAssertGreaterThan(
            client.testOnlyAudioDropCount(),
            0,
            "stalled writer should have dropped oldest audio chunks"
        )

        // Control frame can't reach the never-reading peer; the flush deadline
        // must tear the connection down.
        client.send(["type": "call_stop"])
        wait(for: [closed], timeout: 5.0)

        client.close()
    }

    /// Steady-call regression: a call that sends only audio (no control frames)
    /// must still declare a wedged peer dead. A steady call generates no control
    /// traffic, so before the audio-stall deadline existed a peer that stopped
    /// reading mid-call was never noticed — audio was dropped forever, the mic
    /// stayed hot, and nothing tore the connection down.
    func testSteadyAudioStallDeclaresConnectionDeadWithoutAnyControlFrame() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        // A large control deadline proves the teardown can only come from the
        // *audio*-stall path: no control frame is ever sent below.
        let client = RealtimeSocketClient(
            maxPendingAudioChunks: 4,
            controlFlushDeadline: 60.0,
            audioStallDeadline: 0.4
        )
        let closed = expectation(description: "onClose fires from the audio-stall deadline")
        client.onClose = { closed.fulfill() }

        try client.connect(path: server.path)
        XCTAssertTrue(server.waitForAccept(timeout: 2.0))

        // Saturate the bounded buffer against a never-reading peer so audio
        // starts dropping, which arms the stall deadline.
        let chunk = Data(repeating: 0xAB, count: 4_096)
        for _ in 0..<2_000 {
            client.sendAudioChunk(chunk)
        }
        XCTAssertGreaterThan(
            client.testOnlyAudioDropCount(),
            0,
            "stalled writer should have dropped oldest audio chunks"
        )

        // No control frame is sent — the audio-stall deadline alone must tear
        // the connection down.
        wait(for: [closed], timeout: 5.0)

        client.close()
    }
}
