import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// Server-event routing and the presentation state it drives. The model owns
/// no socket and no audio engine: it answers with typed effects the voice
/// coordinator performs, which is what makes every route provable here.
@Suite("App model routing")
@MainActor
struct AppModelRoutingTests {
    private func negotiatedModel() -> AppModel {
        let model = AppModel()
        model.voiceNegotiated()
        return model
    }

    @Test("a fresh model is offline and holds no call")
    func startsOffline() {
        let model = AppModel()

        #expect(model.voice.mode == .offline)
        #expect(model.voice.connected == false)
        #expect(model.voice.callActive == false)
        #expect(model.voice.status == .offline)
    }

    /// The attention badge is a claim about the daemon, so a launch that has
    /// not asked it anything must not raise one.
    @Test("a launch that has asked the daemon nothing does not claim attention")
    func launchDoesNotClaimAttention() {
        let model = AppModel()

        #expect(model.menuGlyph == .starting)
        #expect(model.needsAttention == false)
    }

    @Test("listening starts capture and reads as listening")
    func listeningStartsCapture() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        let effects = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(effects.contains(.startCapture))
        #expect(model.voice.mode == .listening)
        #expect(model.voice.status == .listening)
    }

    @Test("a muted turn state mutes capture and reads as muted")
    func mutedStateMutesCapture() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        let effects = model.apply(.state(.muted), audioIsPlaying: false)

        #expect(effects.contains(.setCaptureMuted(true)))
        #expect(model.voice.muted)
        #expect(model.voice.mode == .muted)
    }

    @Test("returning to idle unmutes capture")
    func idleUnmutesCapture() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.state(.muted), audioIsPlaying: false)

        let effects = model.apply(.state(.idle), audioIsPlaying: false)

        #expect(effects.contains(.setCaptureMuted(false)))
        #expect(model.voice.muted == false)
    }

    /// While muted, the daemon's `listening` still means the turn is live, but
    /// the local state must keep reading as muted.
    @Test("listening while muted still reads as muted")
    func listeningWhileMutedStaysMuted() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.state(.muted), audioIsPlaying: false)

        _ = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(model.voice.mode == .muted)
    }

    @Test("an unknown turn state presents as idle without losing the call")
    func unknownStatePresentsAsIdle() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        _ = model.apply(.state(.unrecognized("dreaming")), audioIsPlaying: false)

        #expect(model.voice.mode == .idle)
        #expect(model.voice.callActive)
    }

    @Test("audio deltas play and mark the speaking tail")
    func audioDeltaPlays() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        let effects = model.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: false)

        #expect(effects == [.play(base64: "AAAA")])
        #expect(model.voice.mode == .speaking)
        #expect(model.voice.audioActive)
    }

    /// A reply arrives as tens of chunks a second, and every publish redraws the
    /// window, the status item and the pet. Only the first chunk changes the
    /// voice state, so only the first may publish.
    @Test("audio chunks after the first publish nothing")
    func laterAudioDeltasPublishNothing() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: false)

        var published = 0
        let subscription = model.objectWillChange.sink { _ in published += 1 }
        defer { subscription.cancel() }
        let effects = model.apply(.audioDelta(base64: "BBBB"), audioIsPlaying: true)

        #expect(effects == [.play(base64: "BBBB")])
        #expect(published == 0)
    }

    /// The daemon returns to listening as soon as it stops generating, while
    /// buffered audio keeps playing. The pet must keep its speaking look until
    /// the audio actually stops.
    @Test("the speaking tail survives the daemon moving on while audio plays")
    func speakingTailSurvivesStateChange() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: false)

        _ = model.apply(.state(.listening), audioIsPlaying: true)

        #expect(model.voice.audioActive)
        #expect(model.voice.presentation.visualMode == .speaking)
    }

    @Test("the speaking tail ends when playback has drained")
    func speakingTailEndsWhenDrained() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: false)

        _ = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(model.voice.audioActive == false)
        #expect(model.voice.presentation.visualMode == .listening)
    }

    @Test("leaving speaking resets the utterance anchor")
    func leavingSpeakingResetsTheAnchor() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: false)

        let effects = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(effects.contains(.resetUtteranceAnchor))
    }

    @Test("playback stop clears the tail and returns to the input state")
    func playbackStopReturnsToInput() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: true)

        let effects = model.apply(.playbackStop, audioIsPlaying: true)

        #expect(effects.contains(.stopPlayback))
        #expect(effects.contains(.resetUtteranceAnchor))
        #expect(model.voice.audioActive == false)
        #expect(model.voice.mode == .listening)
    }

    @Test("a tool event reads as tool use during a call")
    func toolEventDuringACall() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        _ = model.apply(.toolEvent(status: .started, reason: nil), audioIsPlaying: false)
        #expect(model.voice.mode == .toolUse)

        _ = model.apply(.toolEvent(status: .completed, reason: nil), audioIsPlaying: false)
        #expect(model.voice.mode == .toolUse)
    }

    @Test("a failed tool carries the daemon's own reason")
    func failedToolCarriesItsReason() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        _ = model.apply(.toolEvent(status: .failed, reason: "write_refused"), audioIsPlaying: false)

        #expect(model.voice.mode == .error)
        #expect(model.voice.status == .refused("write_refused"))
    }

    /// A server error may mean the socket is unusable, so the microphone is
    /// detached before any in-flight buffer can race back to it.
    @Test("a server error tears the call down and shuts audio off")
    func serverErrorTearsDownTheCall() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        let effects = model.apply(.error(RealtimeServerError(reason: "provider_unavailable")), audioIsPlaying: true)

        #expect(effects.contains(.endAudio))
        #expect(model.voice.callActive == false)
        #expect(model.voice.muted == false)
        #expect(model.voice.mode == .error)
        #expect(model.voice.status == .refused("provider_unavailable"))
    }

    /// `call_ready` is a fact about the call rather than a turn state: it says
    /// what answered, and leaves the pet on whatever the daemon last reported.
    @Test("call ready records the engine and the call without moving the mode")
    func callReadyRecordsTheCall() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        let effects = model.apply(
            .callReady(
                RealtimeCallReady(engine: "openai_live", callId: "voice_live:17", captions: true)
            ),
            audioIsPlaying: false
        )

        #expect(effects.isEmpty)
        #expect(model.voice.engine == "openai_live")
        #expect(model.voice.callId == "voice_live:17")
        #expect(model.voice.mode == .listening)
    }

    /// Captions are concatenated as they arrive. Nothing trims a fragment or
    /// inserts a space the daemon did not send, and the two speakers may
    /// overlap, so they share one ordered history rather than two.
    @Test("captions are appended verbatim, in the order they arrived")
    func captionsAreAppendedVerbatim() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        _ = model.apply(
            .caption(RealtimeCaption(speaker: .user, delta: "what is ", startMs: 0, endMs: 440)),
            audioIsPlaying: false
        )
        let effects = model.apply(
            .caption(RealtimeCaption(speaker: .assistant, delta: "the ", startMs: 300, endMs: 520)),
            audioIsPlaying: false
        )

        #expect(effects.isEmpty)
        #expect(model.voice.captions.map(\.delta) == ["what is ", "the "])
        #expect(model.voice.captions.map(\.speaker) == [.user, .assistant])
    }

    /// A Live call emits captions for as long as it runs, so the history is
    /// bounded. The tail is what a surface draws, so the head is what goes.
    @Test("the caption history keeps the last fragments and drops the oldest")
    func captionHistoryIsBounded() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        for index in 0..<(VoiceState.captionLimit + 5) {
            _ = model.apply(
                .caption(
                    RealtimeCaption(speaker: .user, delta: "\(index) ", startMs: index, endMs: index)
                ),
                audioIsPlaying: false
            )
        }

        #expect(model.voice.captions.count == VoiceState.captionLimit)
        #expect(model.voice.captions.first?.delta == "5 ")
        #expect(model.voice.captions.last?.delta == "\(VoiceState.captionLimit + 4) ")
    }

    /// A backend delegation reads like a tool call, because that is what it is
    /// from this side.
    @Test("a running task reads as tool use and a finished one returns to the microphone")
    func taskDrivesTheMode() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        let running = RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .running)
        _ = model.apply(.task(running), audioIsPlaying: false)
        #expect(model.voice.mode == .toolUse)
        #expect(model.voice.task == running)

        let done = RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .completed, summary: "checked")
        _ = model.apply(.task(done), audioIsPlaying: false)
        #expect(model.voice.mode == .listening)
        #expect(model.voice.task == done)
    }

    /// A failed delegation is still a delegation that stopped: the microphone
    /// comes back, and the daemon's own summary is what says it went wrong.
    @Test("a failed task returns to the microphone and keeps its summary")
    func failedTaskReturnsToTheMicrophone() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        let failed = RealtimeTask(
            delegationId: "dg_01H9",
            revision: 2,
            status: .failed,
            summary: "the calendar refused"
        )
        _ = model.apply(.task(failed), audioIsPlaying: false)

        #expect(model.voice.mode == .listening)
        #expect(model.voice.task?.summary == "the calendar refused")
    }

    /// Work whose status word this build cannot read is work nothing may claim
    /// has finished, so the surface keeps reporting it as running.
    @Test("a task status this build cannot read does not end the work")
    func unknownTaskStatusKeepsWorking() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        _ = model.apply(
            .task(RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .unrecognized("paused"))),
            audioIsPlaying: false
        )

        #expect(model.voice.mode == .toolUse)
    }

    /// A bill is a fact, not a state. What a cost ceiling does to a call
    /// arrives as its own error, so a usage frame moves nothing, including the
    /// one that reports the limit was reached.
    @Test("a usage frame is recorded and changes no state")
    func usageIsRecordedOnly() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        let usage = RealtimeUsage(
            status: "limit_reached",
            voiceSeconds: 64.2,
            voiceCostCents: 5.35,
            backendTurns: 2,
            backendCost: "unknown",
            accounting: "complete"
        )
        let effects = model.apply(.usage(usage), audioIsPlaying: false)

        #expect(effects.isEmpty)
        #expect(model.voice.usage == usage)
        #expect(model.voice.mode == .listening)
        #expect(model.voice.callActive)
    }

    /// Everything the daemon reports about a call belongs to that call: the
    /// next one starts with no transcript, no delegation and no bill of its
    /// own, rather than showing the last call's.
    @Test("a new call does not inherit the last call's captions, task, or bill")
    func aNewCallStartsClean() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        _ = model.apply(
            .callReady(RealtimeCallReady(engine: "openai_live", callId: "voice_live:17", captions: true)),
            audioIsPlaying: false
        )
        _ = model.apply(
            .caption(RealtimeCaption(speaker: .user, delta: "what is ", startMs: 0, endMs: 1)),
            audioIsPlaying: false
        )
        _ = model.apply(
            .task(RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .running)),
            audioIsPlaying: false
        )
        _ = model.apply(.usage(RealtimeUsage(voiceCostCents: 5.35)), audioIsPlaying: false)
        model.voiceCallEnded()

        model.voiceCallBegan()

        #expect(model.voice.engine == nil)
        #expect(model.voice.callId == nil)
        #expect(model.voice.captions.isEmpty)
        #expect(model.voice.task == nil)
        #expect(model.voice.usage == nil)
    }

    @Test("a transcript delta changes no state")
    func transcriptDeltasAreInert() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        let before = model.voice

        let effects = model.apply(.transcriptDelta(text: "hello"), audioIsPlaying: false)

        #expect(effects.isEmpty)
        #expect(model.voice == before)
    }

    @Test("an event this build does not know changes no state")
    func unknownEventsAreInert() {
        let model = negotiatedModel()
        model.voiceCallBegan()
        let before = model.voice

        let effects = model.apply(.unrecognized(type: "weather"), audioIsPlaying: false)

        #expect(effects.isEmpty)
        #expect(model.voice == before)
    }

    @Test("losing the session returns to offline and drops the call")
    func sessionLossReturnsToOffline() {
        let model = negotiatedModel()
        model.voiceCallBegan()

        model.voiceFailed(.transport(.peerClosed))

        #expect(model.voice.connected == false)
        #expect(model.voice.callActive == false)
        #expect(model.voice.mode == .offline)
        #expect(model.voice.status == .offline)
    }

    @Test("a version refusal asks for an update rather than naming a wire code")
    func versionRefusalAsksForAnUpdate() {
        let model = negotiatedModel()

        model.voiceFailed(.versionUnsupported(direction: .clientTooOld, minimum: 2, maximum: 2))

        #expect(model.voice.status == .updateRequired)
        #expect(model.voice.mode == .error)
    }
}

/// The presentation derived from voice state: one visual mode, one tint, one
/// symbol, one mascot expression.
@Suite("Voice presentation")
struct VoicePresentationTests {
    @Test("every mode has a tint, a symbol, and an expression")
    func everyModeIsPresentable() {
        for mode in VoiceMode.allCases {
            let presentation = VoicePresentation(mode: mode, callActive: false, audioActive: false)

            #expect(!presentation.iconName.isEmpty, "\(mode)")
            #expect(!presentation.accessibilityLabel.isEmpty, "\(mode)")
            #expect(PetExpression.allCases.contains(presentation.expression), "\(mode)")
        }
    }

    /// The design has one accent and otherwise neutral surfaces, so the tints
    /// come from the palette rather than from system colours.
    @Test("the tints are palette tokens, and only listening takes the accent")
    func tintsComeFromThePalette() {
        #expect(VoicePresentation(mode: .listening, callActive: true, audioActive: false).tint == Palette.accent)
        #expect(VoicePresentation(mode: .offline, callActive: false, audioActive: false).tint == Palette.faint)
        #expect(VoicePresentation(mode: .error, callActive: false, audioActive: false).tint == Palette.error)
        #expect(VoicePresentation(mode: .muted, callActive: true, audioActive: false).tint == Palette.warning)
        #expect(VoicePresentation(mode: .speaking, callActive: true, audioActive: true).tint == Palette.success)
    }

    @Test("playing audio during a call reads as speaking whatever the turn state")
    func playingAudioReadsAsSpeaking() {
        let presentation = VoicePresentation(mode: .listening, callActive: true, audioActive: true)

        #expect(presentation.visualMode == .speaking)
        #expect(presentation.expression == .speaking)
    }

    @Test("audio outside a call does not fake a speaking state")
    func audioOutsideACallIsNotSpeaking() {
        let presentation = VoicePresentation(mode: .idle, callActive: false, audioActive: true)

        #expect(presentation.visualMode == .idle)
    }
}

/// Stopping a reply stops it for good.
///
/// The Live engine answers `interrupt` with `playback_stop` and `listening`
/// but leaves the provider's response running, so the rest of the reply keeps
/// arriving, each run announced by `state: speaking`. Played, it made Stop look
/// broken: the pet went quiet and then carried on talking (owner report of
/// 2026-09-25).
@Suite("Stopping a reply")
@MainActor
struct StoppedReplyTests {
    /// A clock the test moves by hand, so the quiet gap is proved without
    /// waiting on it.
    private final class Clock {
        var now: TimeInterval = 100
    }

    private func speakingModel(_ clock: Clock) -> AppModel {
        let model = AppModel(now: { clock.now })
        model.voiceNegotiated()
        model.voiceCallBegan()
        _ = model.apply(.state(.listening), audioIsPlaying: false)
        _ = model.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: false)
        return model
    }

    @Test("the rest of a stopped reply is not played, and the pet stays listening")
    func stoppedReplyIsDropped() {
        let clock = Clock()
        let model = speakingModel(clock)

        model.voiceInterrupted()
        _ = model.apply(.playbackStop, audioIsPlaying: false)
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        clock.now += 0.1
        #expect(model.apply(.state(.speaking), audioIsPlaying: false).isEmpty)
        clock.now += 0.1
        #expect(model.apply(.audioDelta(base64: "BBBB"), audioIsPlaying: false).isEmpty)
        // Each chunk extends the window: a reply streams in a run of chunks.
        clock.now += AppModel.stoppedReplyGap - 0.1
        #expect(model.apply(.audioDelta(base64: "CCCC"), audioIsPlaying: false).isEmpty)

        #expect(model.voice.mode == .listening)
        #expect(model.voice.audioActive == false)
        #expect(model.voice.presentation.visualMode == .listening)
    }

    @Test("audio after the stopped reply has gone quiet is a new reply, and plays")
    func nextReplyPlays() {
        let clock = Clock()
        let model = speakingModel(clock)

        model.voiceInterrupted()
        clock.now += 0.1
        _ = model.apply(.audioDelta(base64: "BBBB"), audioIsPlaying: false)

        clock.now += AppModel.stoppedReplyGap + 0.1
        let effects = model.apply(.audioDelta(base64: "NEW1"), audioIsPlaying: false)

        #expect(effects == [.play(base64: "NEW1")])
        #expect(model.voice.mode == .speaking)
    }

    @Test("a new call forgets a reply the last one stopped")
    func newCallForgetsTheStoppedReply() {
        let clock = Clock()
        let model = speakingModel(clock)

        model.voiceInterrupted()
        model.voiceCallEnded()
        model.voiceCallBegan()
        clock.now += 0.1

        #expect(model.apply(.audioDelta(base64: "NEW1"), audioIsPlaying: false) == [.play(base64: "NEW1")])
    }
}
