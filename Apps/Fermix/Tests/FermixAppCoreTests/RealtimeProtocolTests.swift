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

        #expect(try event("server_hello") == .serverHello(minVersion: 1, maxVersion: 2))
        #expect(try event("state") == .state(.listening))
        #expect(try event("audio_delta") == .audioDelta(base64: "AAAA"))
        #expect(try event("transcript_delta") == .transcriptDelta(text: "hello"))
        #expect(try event("assistant_text_delta") == .assistantTextDelta(text: "hi"))
        #expect(try event("tool_event") == .toolEvent(status: .completed, reason: nil))
        #expect(try event("usage") == .usage(RealtimeUsage()))
        #expect(try event("playback_stop") == .playbackStop)
        #expect(
            try event("call_ready") == .callReady(
                RealtimeCallReady(
                    engine: "openai_live",
                    callId: "voice_live:17",
                    providerSessionId: "sess_live_01H9",
                    expiresAt: 1_788_000_000,
                    captions: true
                )
            )
        )
        #expect(
            try event("caption") == .caption(
                RealtimeCaption(speaker: .user, delta: "what is ", startMs: 1_200, endMs: 1_640)
            )
        )
        #expect(
            try event("task") == .task(
                RealtimeTask(
                    delegationId: "dg_01H9",
                    revision: 1,
                    status: .running,
                    summary: "checking the calendar"
                )
            )
        )

        let live = try event("usage") { $0.object["status"] as? String == "live" }
        #expect(
            live == .usage(
                RealtimeUsage(
                    status: "live",
                    voiceSeconds: 64.2,
                    voiceCostCents: 5.35,
                    backendTurns: 2,
                    backendCost: "unknown",
                    accounting: "running"
                )
            )
        )

        let refusal = try event("error") { ($0.object["direction"] as? String) != nil }
        #expect(
            refusal == .error(
                RealtimeServerError(
                    reason: "unsupported_protocol_version",
                    direction: .clientTooNew,
                    minVersion: 1,
                    maxVersion: 2
                )
            )
        )

        let update = try event("error") { ($0.object["kind"] as? String) == "update_required" }
        #expect(
            update == .error(
                RealtimeServerError(
                    reason: "unsupported_protocol_version",
                    kind: .updateRequired,
                    requiredFor: "openai_live",
                    direction: .clientTooOld,
                    minVersion: 2,
                    maxVersion: 2
                )
            )
        )
    }

    @Test("every golden client event is produced by a typed value")
    func encodesEveryClientFixture() throws {
        let fixtures = try RealtimeFixtures.load(.clientEvents)
        let produced: [RealtimeClientEvent] = [
            .clientHello(protocolVersion: 1),
            .clientHello(protocolVersion: 2),
            .callStart,
            .audioChunk(base64: "MTIzNA=="),
            .interrupt(audioEndMs: nil),
            .interrupt(audioEndMs: 1_500),
            .mute(enabled: true),
            .taskCancel(delegationId: "dg_01H9"),
            .callStop
        ]

        #expect(produced.count == fixtures.count)

        for (event, fixture) in zip(produced, fixtures) {
            let line = try event.line()

            // The line socket adds the terminator, so the event must never
            // carry one of its own.
            #expect(!line.contains(0x0A), "\(fixture.type) must be exactly one line")
            #expect(
                try RealtimeFixtures.sameObject(line, fixture.line),
                "\(fixture.type): \(String(decoding: line, as: UTF8.self))"
            )
        }
    }

    /// The two frames a Live call cannot run without, read back as the daemon
    /// sent them. `provider_session_id` and `expires_at` are absent where the
    /// provider never said, which is not the same as a session that never
    /// expires, so both stay optional rather than being defaulted.
    @Test("a call_ready without a provider session or an expiry still decodes")
    func callReadyWithoutOptionalFields() throws {
        let frame = #"{"type":"call_ready","engine":"openai_realtime","call_id":"voice:3","captions":false}"#
        let event = try RealtimeServerEvent.decode(Data(frame.utf8))

        #expect(
            event == .callReady(
                RealtimeCallReady(engine: "openai_realtime", callId: "voice:3", captions: false)
            )
        )
    }

    /// A caption is verbatim: the leading and trailing bytes are the daemon's,
    /// and nothing here trims them or inserts a space the wire did not carry.
    @Test("a caption fragment keeps its own bytes")
    func captionIsVerbatim() throws {
        let frame = #"{"type":"caption","speaker":"assistant","delta":" and then ","start_ms":0,"end_ms":40}"#
        let event = try RealtimeServerEvent.decode(Data(frame.utf8))

        #expect(event == .caption(RealtimeCaption(speaker: .assistant, delta: " and then ", startMs: 0, endMs: 40)))
    }

    @Test("a caption from a speaker this build has never seen keeps its word")
    func unknownCaptionSpeakerIsPreserved() throws {
        let frame = #"{"type":"caption","speaker":"operator","delta":"hi","start_ms":0,"end_ms":1}"#
        let event = try RealtimeServerEvent.decode(Data(frame.utf8))

        #expect(event == .caption(RealtimeCaption(speaker: .unrecognized("operator"), delta: "hi", startMs: 0, endMs: 1)))
    }

    /// A task frame without a summary is a task nobody has described yet, not a
    /// task with an empty description.
    @Test("a task without a summary decodes, and its terminal statuses are terminal")
    func taskStatuses() throws {
        let frame = #"{"type":"task","delegation_id":"dg_2","revision":4,"status":"cancelled"}"#
        let event = try RealtimeServerEvent.decode(Data(frame.utf8))

        #expect(event == .task(RealtimeTask(delegationId: "dg_2", revision: 4, status: .cancelled)))

        for status in [RealtimeTaskStatus.completed, .failed, .cancelled] {
            #expect(status.isTerminal, "\(status)")
        }
        for status in [RealtimeTaskStatus.pending, .running, .unrecognized("paused")] {
            #expect(!status.isTerminal, "\(status)")
        }
    }

    /// The N/N-1 window is only real if a v1 frame still decodes: a daemon that
    /// has moved to the Live engine still sends the Realtime engine's `usage`
    /// for a Realtime call, and it carries none of the Live fields.
    @Test("a usage frame in the version 1 shape decodes with no Live fields")
    func versionOneUsageStillDecodes() throws {
        let event = try RealtimeServerEvent.decode(Data(#"{"type":"usage","input_tokens":1,"output_tokens":2}"#.utf8))

        #expect(event == .usage(RealtimeUsage()))
        guard case .usage(let usage) = event else {
            Issue.record("a usage frame decoded as \(event.wireType)")
            return
        }

        #expect(usage.voiceCostCents == nil)
        #expect(usage.accounting == nil)
        #expect(usage.backendCost == nil)
    }

    /// Unknown is not zero: a backend billing against a subscription allowance
    /// reports its cost as a word, and the word is carried rather than folded
    /// into a number.
    @Test("a Live usage frame carries the vendor's unknown as a word")
    func liveUsageCarriesUnknown() throws {
        let frame = #"{"type":"usage","status":"limit_reached","backend_cost":"unknown","accounting":"complete"}"#
        let event = try RealtimeServerEvent.decode(Data(frame.utf8))

        #expect(event == .usage(RealtimeUsage(status: "limit_reached", backendCost: "unknown", accounting: "complete")))
    }

    /// A terminal status word is not a diagnosis, so the vendor's own sentence
    /// has to survive the decode rather than being dropped for the reason code.
    @Test("an error carries its typed kind and the vendor's own sentence")
    func errorCarriesKindAndDetail() throws {
        let frame = #"{"type":"error","reason":"provider_error","kind":"provider_refused","detail":"Insufficient quota."}"#
        let event = try RealtimeServerEvent.decode(Data(frame.utf8))

        #expect(
            event == .error(
                RealtimeServerError(reason: "provider_error", kind: .providerRefused, detail: "Insufficient quota.")
            )
        )
    }

    @Test("an error kind this build has never seen keeps its own word")
    func unknownErrorKindIsPreserved() throws {
        let event = try RealtimeServerEvent.decode(Data(#"{"type":"error","reason":"x","kind":"moon_phase"}"#.utf8))

        #expect(event == .error(RealtimeServerError(reason: "x", kind: .unrecognized("moon_phase"))))
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
        #expect(
            RealtimeProtocol.inboundLimits
                == LineInboundLimits(maximumLineBytes: 1_048_576, maximumBufferedBytes: 2_097_152)
        )
        #expect(RealtimeProtocol.handshakeTimeout == 3)
    }
}

/// The inbound framing bounds, driven directly rather than through a socket:
/// the line socket's reader, with the realtime wire's bounds and decoder, must
/// refuse an over-length line and an over-length unterminated buffer before
/// either is turned into an event.
@Suite("Realtime inbound framing")
struct RealtimeInboundFramingTests {
    private func realtimeBuffer() -> LineInboundBuffer<RealtimeServerEvent, RealtimeDecodeFailure> {
        LineInboundBuffer(limits: RealtimeProtocol.inboundLimits) { line throws(RealtimeDecodeFailure) in
            try RealtimeServerEvent.decode(line)
        }
    }

    @Test("complete lines are delivered in order")
    func deliversCompleteLines() throws {
        var buffer = realtimeBuffer()
        var events: [RealtimeServerEvent] = []

        let stream = #"{"type":"state","state":"idle"}"# + "\n" + #"{"type":"playback_stop"}"# + "\n"
        try buffer.append(Data(stream.utf8)) { events.append($0) }

        #expect(events == [.state(.idle), .playbackStop])
        #expect(buffer.pendingByteCount == 0)
    }

    @Test("a partial line is held until its newline arrives")
    func holdsPartialLines() throws {
        var buffer = realtimeBuffer()
        var events: [RealtimeServerEvent] = []

        try buffer.append(Data(#"{"type":"play"#.utf8)) { events.append($0) }
        #expect(events.isEmpty)
        #expect(buffer.pendingByteCount > 0)

        try buffer.append(Data((#"back_stop"}"# + "\n").utf8)) { events.append($0) }
        #expect(events == [.playbackStop])
    }

    /// A frame that is not an event is a contract violation: the frames before
    /// it were already delivered, and the refusal carries the decoder's reason.
    @Test("a line that is not an event is refused with the decoder's reason")
    func refusesAnUndecodableLine() {
        var buffer = realtimeBuffer()
        var events: [RealtimeServerEvent] = []
        let stream = #"{"type":"playback_stop"}"# + "\n" + "{not json" + "\n" + #"{"type":"playback_stop"}"# + "\n"

        #expect(throws: RealtimeTransportFailure.undecodable(.malformedJSON)) {
            try buffer.append(Data(stream.utf8)) { events.append($0) }
        }
        #expect(events == [.playbackStop])
    }

    @Test("a line longer than the frame limit is refused")
    func refusesAnOversizedFrame() {
        var buffer = realtimeBuffer()
        let limit = RealtimeProtocol.inboundLimits.maximumLineBytes
        let oversized = Data(repeating: 0x41, count: limit + 1) + Data("\n".utf8)

        #expect(throws: RealtimeTransportFailure.framingViolation(.lineTooLong(bytes: limit + 1))) {
            try buffer.append(oversized) { _ in }
        }
    }

    /// A peer that never sends a newline must not be able to grow the buffer
    /// without bound. The run is already longer than one frame may be, so it is
    /// refused as an oversized frame before a newline ever arrives.
    @Test("an unterminated run is refused once it passes the frame limit")
    func refusesAnUnterminatedRun() {
        var buffer = realtimeBuffer()
        let chunk = Data(repeating: 0x41, count: 512 * 1_024)

        #expect(throws: RealtimeTransportFailure.framingViolation(.lineTooLong(bytes: 3 * 512 * 1_024))) {
            for _ in 0..<3 {
                try buffer.append(chunk) { _ in }
            }
        }
    }

    /// The second bound is on the whole buffer, not on one frame: a burst of
    /// well-formed small frames is refused before it is scanned.
    @Test("a burst larger than the inbound buffer limit is refused before scanning")
    func refusesAnOversizedBurst() {
        var buffer = realtimeBuffer()
        let frame = Data((#"{"type":"playback_stop"}"# + "\n").utf8)
        let repeats = RealtimeProtocol.inboundLimits.maximumBufferedBytes / frame.count + 1
        var burst = Data()
        for _ in 0..<repeats { burst.append(frame) }

        #expect(throws: RealtimeTransportFailure.framingViolation(.bufferExceeded(bytes: burst.count))) {
            try buffer.append(burst) { _ in }
        }
    }
}
