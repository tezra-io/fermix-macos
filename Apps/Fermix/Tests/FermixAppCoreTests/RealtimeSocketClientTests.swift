import Foundation
import Testing

@testable import FermixAppCore

@Suite("RealtimeSocketClient", .serialized)
struct RealtimeSocketClientTests {
    /// Connect is asynchronous now, so every case waits for the socket to be up
    /// before driving it.
    private func connect(_ client: RealtimeSocketClient, to path: String) throws {
        let connected = TestSignal()
        let outcome = ValueBox<Result<Void, RealtimeConnectFailure>>()
        client.connect(path: path) { result in
            outcome.set(result)
            connected.fire()
        }

        #expect(connected.wait(timeout: 3.0), "connect never completed")
        if case .failure(let failure)? = outcome.value {
            Issue.record("connect failed: errno \(failure.errorNumber)")
        }
    }

    @Test("a control frame reaches the peer with newline framing")
    func controlFrameReachesPeerWithNewlineFraming() throws {
        let server = try UnixSocketTestServer(drainReads: true)
        defer { server.shutdown() }

        let client = RealtimeSocketClient()
        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        client.send(.callStart)

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

        let line = try #require(framedLine, "peer never received a framed control frame")
        let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        #expect(object?["type"] as? String == "call_start")
        // Wire framing preserved: newline-terminated JSON.
        #expect(server.receivedData().last == 0x0A)

        client.close()
    }

    @Test("an incoming line fires onEvent as a typed event")
    func incomingLineFiresOnEvent() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = RealtimeSocketClient()
        let box = ValueBox<RealtimeServerEvent>()
        let received = TestSignal()
        client.onEvent = { event in
            box.set(event)
            received.fire()
        }

        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        server.writeToClient(Data(#"{"type":"state","state":"listening"}"#.utf8) + Data([0x0A]))
        #expect(received.wait(timeout: 3.0), "onEvent never fired for an incoming line")

        #expect(box.value == .state(.listening))

        client.close()
    }

    @Test("a peer close is reported as a typed transport failure")
    func peerCloseIsReported() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = RealtimeSocketClient()
        let box = ValueBox<RealtimeTransportFailure>()
        let closed = TestSignal()
        client.onFailure = { failure in
            box.set(failure)
            closed.fire()
        }

        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        server.closeAcceptedConnection()
        #expect(closed.wait(timeout: 3.0), "onFailure never fired on peer EOF")
        #expect(box.value == .peerClosed)
    }

    /// A frame larger than the published ceiling is refused by the reader rather
    /// than decoded, and the connection is declared dead.
    @Test("an oversized inbound frame tears the connection down")
    func oversizedInboundFrameTearsDown() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = RealtimeSocketClient()
        let box = ValueBox<RealtimeTransportFailure>()
        let closed = TestSignal()
        var events = 0
        client.onEvent = { _ in events += 1 }
        client.onFailure = { failure in
            box.set(failure)
            closed.fire()
        }

        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        // A single line longer than one frame may be, delivered in slices.
        let slice = Data(repeating: 0x41, count: 64 * 1_024)
        for _ in 0..<20 {
            server.writeToClient(slice)
        }

        #expect(closed.wait(timeout: 5.0), "an oversized frame never tore the connection down")
        #expect(box.value?.isFramingViolation == true)
        #expect(events == 0)

        client.close()
    }

    /// The core regression: a peer that has stopped reading must never wedge the
    /// client. Audio floods the bounded buffer (drop-oldest, no unbounded growth
    /// and no blocked queue), and a subsequent control frame that cannot be
    /// flushed within the deadline declares the connection dead.
    @Test("a stalled writer drops the oldest audio and declares the connection dead")
    func stalledWriterDropsOldestAudioAndDeclaresConnectionDead() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = RealtimeSocketClient(maxPendingAudioChunks: 4, controlFlushDeadline: 0.4)
        let box = ValueBox<RealtimeTransportFailure>()
        let closed = TestSignal()
        client.onFailure = { failure in
            box.set(failure)
            closed.fire()
        }

        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        // Push far more audio than the kernel send buffer plus the 4-chunk cap
        // can hold. If any of these blocked, the test would hang instead of
        // returning here.
        let chunk = Data(repeating: 0xAB, count: 4_096)
        for _ in 0..<2_000 {
            client.sendAudioChunk(chunk)
        }

        // Bounded buffer shed the oldest chunks rather than grow without bound.
        #expect(
            client.testOnlyAudioDropCount() > 0,
            "stalled writer should have dropped oldest audio chunks"
        )

        // Control frame can't reach the never-reading peer; the flush deadline
        // must tear the connection down.
        client.send(.callStop)
        #expect(closed.wait(timeout: 5.0), "onFailure never fired when a control frame could not flush")
        #expect(box.value == .controlFlushTimedOut(seconds: 0.4))

        client.close()
    }

    /// Steady-call regression: a call that sends only audio (no control frames)
    /// must still declare a wedged peer dead. A steady call generates no control
    /// traffic, so before the audio-stall deadline existed a peer that stopped
    /// reading mid-call was never noticed — audio was dropped forever, the mic
    /// stayed hot, and nothing tore the connection down.
    @Test("a steady audio stall declares the connection dead without any control frame")
    func steadyAudioStallDeclaresConnectionDeadWithoutAnyControlFrame() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        // A large control deadline proves the teardown can only come from the
        // *audio*-stall path: no control frame is ever sent below.
        let client = RealtimeSocketClient(
            maxPendingAudioChunks: 4,
            controlFlushDeadline: 60.0,
            audioStallDeadline: 0.4
        )
        let box = ValueBox<RealtimeTransportFailure>()
        let closed = TestSignal()
        client.onFailure = { failure in
            box.set(failure)
            closed.fire()
        }

        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        // Saturate the bounded buffer against a never-reading peer so audio
        // starts dropping, which arms the stall deadline.
        let chunk = Data(repeating: 0xAB, count: 4_096)
        for _ in 0..<2_000 {
            client.sendAudioChunk(chunk)
        }
        #expect(
            client.testOnlyAudioDropCount() > 0,
            "stalled writer should have dropped oldest audio chunks"
        )

        // No control frame is sent — the audio-stall deadline alone must tear
        // the connection down.
        #expect(closed.wait(timeout: 5.0), "onFailure never fired from the audio-stall deadline")
        #expect(box.value == .audioStalled(seconds: 0.4))

        client.close()
    }

    /// Connecting must not happen on the caller's thread: a socket that cannot
    /// be reached reports its failure through the completion instead of throwing
    /// into the main actor's call stack.
    @Test("a refused connection is reported through the completion")
    func refusedConnectionIsReported() throws {
        let client = RealtimeSocketClient()
        let finished = TestSignal()
        let outcome = ValueBox<Result<Void, RealtimeConnectFailure>>()

        client.connect(path: NSTemporaryDirectory() + "fermix-missing-\(UUID().uuidString.prefix(8)).sock") { result in
            outcome.set(result)
            finished.fire()
        }

        #expect(finished.wait(timeout: 3.0), "connect never reported an outcome")
        guard case .failure(let failure)? = outcome.value else {
            Issue.record("a missing socket must not report success")
            return
        }
        #expect(failure.errorNumber == ENOENT || failure.errorNumber == ECONNREFUSED)
    }
}
