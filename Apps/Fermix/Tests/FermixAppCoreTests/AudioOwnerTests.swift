import Foundation
import Testing

@testable import FermixAppCore

/// The one app-scoped audio owner: call state, mute state, and the capture
/// lifecycle, over an injected engine. No microphone is ever touched here.
@Suite("Audio owner")
@MainActor
struct AudioOwnerTests {
    private func owner(_ engine: FakeVoiceAudioEngine) -> AudioOwner {
        AudioOwner(engine: engine)
    }

    /// Permission first, then a warmed capture that is muted and handlerless:
    /// nothing can leave the process between the call starting and the daemon
    /// confirming it is listening.
    @Test("beginning a call asks permission, then warms capture muted")
    func beginCallWarmsMutedCapture() async throws {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)

        try await owner.beginCall()

        #expect(engine.calls == [.requestPermission, .setMuted(true), .prepareCapture])
        #expect(owner.callActive)
        #expect(owner.muted == false)
        #expect(owner.isStreaming == false)
        #expect(engine.chunkHandler == nil)
    }

    @Test("streaming starts only when the daemon reports listening")
    func streamingStartsOnListening() async throws {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)
        // The capture tap runs on an audio thread in production, so the sink a
        // test hands over has to be safe to call from one.
        let chunks = ValueBox<Data>()

        try await owner.beginCall()
        try owner.startStreaming { chunks.set($0) }

        #expect(engine.calls.suffix(2) == [.beginStreaming, .setMuted(false)])
        #expect(owner.isStreaming)

        engine.chunkHandler?(Data([1, 2, 3]))
        #expect(chunks.value == Data([1, 2, 3]))
    }

    @Test("starting streaming twice attaches one handler")
    func streamingIsIdempotent() async throws {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)

        try await owner.beginCall()
        try owner.startStreaming { _ in }
        try owner.startStreaming { _ in }

        #expect(engine.calls.filter { $0 == .beginStreaming }.count == 1)
    }

    /// Ending a call must tear capture all the way down so macOS drops the
    /// microphone indicator, on every path including a failed start.
    @Test("ending a call shuts the engine down and clears call state")
    func endCallShutsDown() async throws {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)

        try await owner.beginCall()
        try owner.startStreaming { _ in }
        owner.endCall()

        #expect(engine.calls.last == .shutdown)
        #expect(owner.callActive == false)
        #expect(owner.muted == false)
        #expect(owner.isStreaming == false)
    }

    @Test("a permission refusal leaves no call and no warm capture")
    func permissionRefusalIsFatalToTheCall() async {
        let engine = FakeVoiceAudioEngine()
        engine.permissionError = CaptureError.microphoneDenied
        let owner = owner(engine)

        await #expect(throws: CaptureError.microphoneDenied) {
            try await owner.beginCall()
        }

        #expect(owner.callActive == false)
        #expect(engine.calls.contains(.prepareCapture) == false)
        #expect(engine.calls.last == .shutdown)
    }

    /// The permission prompt is modal and outlives the call that raised it. A
    /// transport drop or an explicit hang-up while it is up ends the call, and
    /// warming capture afterwards would light the microphone indicator with no
    /// call behind it and nothing left to tear it down.
    @Test("a call that ended while the prompt was up never warms capture")
    func callEndedDuringThePermissionPrompt() async throws {
        let engine = FakeVoiceAudioEngine()
        engine.suspendsPermission = true
        let owner = owner(engine)

        let starting = Task { try await owner.beginCall() }
        while engine.calls.isEmpty { await Task.yield() }

        // The transport dropped: the coordinator ends the call while the
        // prompt is still on screen.
        owner.endCall()
        engine.grantCapturePermission()
        try await starting.value

        #expect(owner.callActive == false)
        #expect(engine.calls.contains(.prepareCapture) == false)
        #expect(engine.calls.last == .shutdown)
    }

    @Test("a capture failure while warming ends the call and shuts down")
    func warmFailureEndsTheCall() async {
        let engine = FakeVoiceAudioEngine()
        engine.prepareError = CaptureError.noInputDevice
        let owner = owner(engine)

        await #expect(throws: CaptureError.noInputDevice) {
            try await owner.beginCall()
        }

        #expect(owner.callActive == false)
        #expect(engine.calls.last == .shutdown)
    }

    @Test("a streaming failure ends the call and shuts down")
    func streamingFailureEndsTheCall() async throws {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)
        try await owner.beginCall()
        engine.streamingError = CaptureError.microphoneDenied

        #expect(throws: CaptureError.microphoneDenied) {
            try owner.startStreaming { _ in }
        }

        #expect(owner.callActive == false)
        #expect(engine.calls.last == .shutdown)
    }

    @Test("muting is carried to the engine and reflected in owner state")
    func muteTracksTheEngine() async throws {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)
        try await owner.beginCall()

        owner.setMuted(true)
        #expect(owner.muted)
        #expect(engine.calls.last == .setMuted(true))

        owner.setMuted(false)
        #expect(owner.muted == false)
        #expect(engine.calls.last == .setMuted(false))
    }

    @Test("playback drains are reported once the engine reports empty")
    func playbackDrainIsReported() async throws {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)
        var drained = 0
        owner.onPlaybackDrained = { drained += 1 }

        try await owner.beginCall()
        owner.play(base64PCM16: "AAAA")
        #expect(engine.calls.last == .play("AAAA"))

        engine.isPlayingBack = false
        engine.onPlaybackDrained?()

        #expect(drained == 1)
    }

    @Test("the level callback is smoothed rather than passed through raw")
    func levelIsSmoothed() {
        let engine = FakeVoiceAudioEngine()
        let owner = owner(engine)
        var levels: [Float] = []
        owner.onLevel = { levels.append($0) }

        engine.onOutputLevel?(1.0)
        engine.onOutputLevel?(1.0)

        #expect(levels.count == 2)
        #expect(levels[0] < 1.0)
        #expect(levels[1] > levels[0])
    }

    /// Interrupting reports how much of the current utterance actually played,
    /// which is what the daemon needs to truncate its own transcript.
    @Test("an interrupt reports the played milliseconds and stops playback")
    func interruptReportsPlayedMilliseconds() async throws {
        let engine = FakeVoiceAudioEngine()
        engine.utterancePlayedMs = 1_500
        let owner = owner(engine)
        try await owner.beginCall()

        let played = owner.interruptPlayback()

        #expect(played == 1_500)
        #expect(engine.calls.contains(.stopPlayback))
    }
}
