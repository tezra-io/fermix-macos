import Foundation
import Testing

@testable import FermixAppCore

/// The typed realtime events, driven by the vendored golden fixtures.
///
/// Every fixture in both files is exercised and each suite asserts its own
/// completeness, so an event added upstream fails here instead of being
/// silently skipped.
@Suite("Realtime protocol")
struct RealtimeProtocolTests {
    @Test("this build declares the version the vendored contract publishes")
    func declaredVersionMatchesTheContract() throws {
        let schema = try VendoredContracts.data(.realtime, "protocol.schema.json")
        let object = try JSONSerialization.jsonObject(with: schema) as? [String: Any]
        let published = object?["x-protocol-version"] as? Int

        #expect(published == RealtimeProtocol.version)
    }

    @Test("every golden server event decodes into a typed value")
    func decodesEveryServerFixture() throws {
        let fixtures = try RealtimeFixtures.load(.serverEvents)
        var seen: Set<String> = []

        for fixture in fixtures {
            let event = try RealtimeServerEvent.decode(fixture.line)
            seen.insert(fixture.type)

            #expect(event.wireType == fixture.type, "\(fixture.type)")
            #expect(!event.isUnrecognized, "\(fixture.type) decoded as an unknown event")
        }

        #expect(seen.count == Set(fixtures.map(\.type)).count)
    }

    @Test("the golden server events carry their fields")
    func serverFixtureFields() throws {
        let fixtures = try RealtimeFixtures.load(.serverEvents)

        func event(_ type: String, where predicate: (RealtimeFixture) -> Bool = { _ in true }) throws
            -> RealtimeServerEvent {
            guard let fixture = fixtures.first(where: { $0.type == type && predicate($0) }) else {
                throw RealtimeFixtureDefect.fileIsEmpty(file: type)
            }
            return try RealtimeServerEvent.decode(fixture.line)
        }

        #expect(try event("server_hello") == .serverHello(minVersion: 1, maxVersion: 1))
        #expect(try event("state") == .state(.listening))
        #expect(try event("audio_delta") == .audioDelta(base64: "AAAA"))
        #expect(try event("transcript_delta") == .transcriptDelta(text: "hello"))
        #expect(try event("assistant_text_delta") == .assistantTextDelta(text: "hi"))
        #expect(try event("tool_event") == .toolEvent(status: .completed, reason: nil))
        #expect(try event("usage") == .usage)
        #expect(try event("playback_stop") == .playbackStop)

        let refusal = try event("error") { ($0.object["direction"] as? String) != nil }
        #expect(
            refusal == .error(
                RealtimeServerError(
                    reason: "unsupported_protocol_version",
                    direction: .clientTooNew,
                    minVersion: 1,
                    maxVersion: 1
                )
            )
        )
    }

    @Test("every golden client event is produced by a typed value")
    func encodesEveryClientFixture() throws {
        let fixtures = try RealtimeFixtures.load(.clientEvents)
        let produced: [RealtimeClientEvent] = [
            .clientHello(protocolVersion: 1),
            .callStart,
            .audioChunk(base64: "MTIzNA=="),
            .interrupt(audioEndMs: nil),
            .interrupt(audioEndMs: 1_500),
            .mute(enabled: true),
            .callStop
        ]

        #expect(produced.count == fixtures.count)

        for (event, fixture) in zip(produced, fixtures) {
            let frame = try event.frame()

            #expect(frame.last == 0x0A, "\(fixture.type) must be newline terminated")
            #expect(
                try RealtimeFixtures.sameObject(frame.dropLast(), fixture.line),
                "\(fixture.type): \(String(decoding: frame, as: UTF8.self))"
            )
        }
    }

    /// The state vocabulary is open and additive: a value this build has never
    /// seen keeps its wire word rather than being folded into a neighbour.
    @Test("an unknown turn state is preserved, not folded into idle")
    func unknownStateIsPreserved() throws {
        let event = try RealtimeServerEvent.decode(Data(#"{"type":"state","state":"dreaming"}"#.utf8))

        #expect(event == .state(.unrecognized("dreaming")))
    }

    @Test("an unknown event type is preserved and never fatal")
    func unknownEventIsPreserved() throws {
        let event = try RealtimeServerEvent.decode(Data(#"{"type":"weather","sunny":true}"#.utf8))

        #expect(event == .unrecognized(type: "weather"))
        #expect(event.isUnrecognized)
    }

    @Test("a frame that is not an object, or has no type, is refused")
    func structurallyInvalidFramesAreRefused() {
        #expect(throws: RealtimeDecodeFailure.notAnObject) {
            _ = try RealtimeServerEvent.decode(Data("[1,2,3]".utf8))
        }
        #expect(throws: RealtimeDecodeFailure.missingType) {
            _ = try RealtimeServerEvent.decode(Data(#"{"state":"idle"}"#.utf8))
        }
        #expect(throws: RealtimeDecodeFailure.malformedJSON) {
            _ = try RealtimeServerEvent.decode(Data("{not json".utf8))
        }
    }

    @Test("the published bounds are one frame of 1 MiB and 2 MiB of inbound buffer")
    func publishedBounds() {
        #expect(RealtimeProtocol.maximumFrameBytes == 1_048_576)
        #expect(RealtimeProtocol.maximumInboundBufferBytes == 2_097_152)
        #expect(RealtimeProtocol.handshakeTimeout == 3)
    }
}

/// The inbound framing bounds, driven directly rather than through a socket:
/// the reader must refuse an over-length line and an over-length unterminated
/// buffer before either is turned into an event.
@Suite("Realtime inbound framing")
struct RealtimeInboundBufferTests {
    @Test("complete lines are delivered in order")
    func deliversCompleteLines() throws {
        var buffer = RealtimeInboundBuffer()
        var events: [RealtimeServerEvent] = []

        let stream = #"{"type":"state","state":"idle"}"# + "\n" + #"{"type":"playback_stop"}"# + "\n"
        try buffer.append(Data(stream.utf8)) { events.append($0) }

        #expect(events == [.state(.idle), .playbackStop])
        #expect(buffer.pendingByteCount == 0)
    }

    @Test("a partial line is held until its newline arrives")
    func holdsPartialLines() throws {
        var buffer = RealtimeInboundBuffer()
        var events: [RealtimeServerEvent] = []

        try buffer.append(Data(#"{"type":"play"#.utf8)) { events.append($0) }
        #expect(events.isEmpty)
        #expect(buffer.pendingByteCount > 0)

        try buffer.append(Data((#"back_stop"}"# + "\n").utf8)) { events.append($0) }
        #expect(events == [.playbackStop])
    }

    @Test("a line longer than the frame limit is refused")
    func refusesAnOversizedFrame() {
        var buffer = RealtimeInboundBuffer()
        let oversized = Data(repeating: 0x41, count: RealtimeProtocol.maximumFrameBytes + 1) + Data("\n".utf8)

        #expect(throws: RealtimeDecodeFailure.frameTooLarge(bytes: RealtimeProtocol.maximumFrameBytes + 1)) {
            try buffer.append(oversized) { _ in }
        }
    }

    /// A peer that never sends a newline must not be able to grow the buffer
    /// without bound. The run is already longer than one frame may be, so it is
    /// refused as an oversized frame before a newline ever arrives.
    @Test("an unterminated run is refused once it passes the frame limit")
    func refusesAnUnterminatedRun() {
        var buffer = RealtimeInboundBuffer()
        let chunk = Data(repeating: 0x41, count: 512 * 1_024)

        #expect(throws: RealtimeDecodeFailure.frameTooLarge(bytes: 3 * 512 * 1_024)) {
            for _ in 0..<3 {
                try buffer.append(chunk) { _ in }
            }
        }
    }

    /// The second bound is on the whole buffer, not on one frame: a burst of
    /// well-formed small frames is refused before it is scanned.
    @Test("a burst larger than the inbound buffer limit is refused before scanning")
    func refusesAnOversizedBurst() {
        var buffer = RealtimeInboundBuffer()
        let frame = Data((#"{"type":"playback_stop"}"# + "\n").utf8)
        let repeats = RealtimeProtocol.maximumInboundBufferBytes / frame.count + 1
        var burst = Data()
        for _ in 0..<repeats { burst.append(frame) }

        #expect(throws: RealtimeDecodeFailure.inboundBufferExceeded(bytes: burst.count)) {
            try buffer.append(burst) { _ in }
        }
    }
}
