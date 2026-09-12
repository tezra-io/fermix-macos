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
