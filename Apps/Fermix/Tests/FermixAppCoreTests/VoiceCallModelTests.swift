import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// Server-event routing and the call facts it drives. The model owns no socket
/// and no audio engine: it answers with typed effects the voice coordinator
/// performs, which is what makes every route provable here.
@Suite("Voice call model routing")
@MainActor
struct VoiceCallModelRoutingTests {
    private func negotiatedModel() -> VoiceCallModel {
        let model = VoiceCallModel()
        model.voiceNegotiated()
        return model
    }

    @Test("a fresh model is offline and holds no call")
    func startsOffline() {
        let model = VoiceCallModel()

        #expect(model.voice.mode == .offline)
        #expect(model.voice.connected == false)
        #expect(model.voice.callActive == false)
        #expect(model.voice.status == .offline)
        #expect(model.voice.phase == .idle)
        #expect(model.voice.attempt == 0)
    }

    @Test("listening starts capture and reads as listening")
    func listeningStartsCapture() {
        let model = negotiatedModel()
        model.beginTestCall()

        let effects = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(effects.contains(.startCapture))
        #expect(model.voice.mode == .listening)
        #expect(model.voice.status == .listening)
    }

    @Test("a muted turn state mutes capture and reads as muted")
    func mutedStateMutesCapture() {
        let model = negotiatedModel()
        model.beginTestCall()

        let effects = model.apply(.state(.muted), audioIsPlaying: false)

        #expect(effects.contains(.setCaptureMuted(true)))
        #expect(model.voice.muted)
        #expect(model.voice.mode == .muted)
    }

    @Test("returning to idle unmutes capture")
    func idleUnmutesCapture() {
        let model = negotiatedModel()
        model.beginTestCall()
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
        model.beginTestCall()
        _ = model.apply(.state(.muted), audioIsPlaying: false)

        _ = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(model.voice.mode == .muted)
    }

    @Test("an unknown turn state presents as idle without losing the call")
    func unknownStatePresentsAsIdle() {
        let model = negotiatedModel()
        model.beginTestCall()

        _ = model.apply(.state(.unrecognized("dreaming")), audioIsPlaying: false)

        #expect(model.voice.mode == .idle)
        #expect(model.voice.callActive)
    }

    @Test("audio deltas play and mark the speaking tail")
    func audioDeltaPlays() {
        let model = negotiatedModel()
        model.beginTestCall()

        let effects = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)

        #expect(effects == [.play(base64: RelayedAudio.voice(1))])
        #expect(model.voice.mode == .speaking)
        #expect(model.voice.audioActive)
    }

    /// A reply arrives as tens of chunks a second, and every publish redraws the
    /// window, the status item and the pet. Only the first chunk changes the
    /// voice state, so only the first may publish.
    @Test("audio chunks after the first publish nothing")
    func laterAudioDeltasPublishNothing() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)

        var published = 0
        let subscription = model.objectWillChange.sink { _ in published += 1 }
        defer { subscription.cancel() }
        let effects = model.apply(.audioDelta(base64: RelayedAudio.voice(2)), audioIsPlaying: true)

        #expect(effects == [.play(base64: RelayedAudio.voice(2))])
        #expect(published == 0)
    }

    /// The daemon returns to listening as soon as it stops generating, while
    /// buffered audio keeps playing. The pet must keep its speaking look until
    /// the audio actually stops.
    @Test("the speaking tail survives the daemon moving on while audio plays")
    func speakingTailSurvivesStateChange() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)

        _ = model.apply(.state(.listening), audioIsPlaying: true)

        #expect(model.voice.audioActive)
        #expect(model.voice.presentation.visualMode == .speaking)
    }

    /// The Realtime engine's order: it says listening while audio still plays,
    /// and the tail ends when the daemon's next state finds nothing playing.
    /// The drain itself is `LiveReplyEndTests`.
    @Test("the speaking tail ends when the daemon moves on with nothing playing")
    func speakingTailEndsWhenDrained() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)

        _ = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(model.voice.audioActive == false)
        #expect(model.voice.presentation.visualMode == .listening)
    }

    @Test("leaving speaking resets the utterance anchor")
    func leavingSpeakingResetsTheAnchor() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)

        let effects = model.apply(.state(.listening), audioIsPlaying: false)

        #expect(effects.contains(.resetUtteranceAnchor))
    }

    @Test("playback stop clears the tail and returns to the input state")
    func playbackStopReturnsToInput() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: true)

        let effects = model.apply(.playbackStop, audioIsPlaying: true)

        #expect(effects.contains(.stopPlayback))
        #expect(effects.contains(.resetUtteranceAnchor))
        #expect(model.voice.audioActive == false)
        #expect(model.voice.mode == .listening)
    }

    @Test("a tool event reads as tool use during a call")
    func toolEventDuringACall() {
        let model = negotiatedModel()
        model.beginTestCall()

        _ = model.apply(.toolEvent(status: .started, reason: nil), audioIsPlaying: false)
        #expect(model.voice.mode == .toolUse)

        _ = model.apply(.toolEvent(status: .completed, reason: nil), audioIsPlaying: false)
        #expect(model.voice.mode == .toolUse)
    }

    @Test("a failed tool carries the daemon's own reason")
    func failedToolCarriesItsReason() {
        let model = negotiatedModel()
        model.beginTestCall()

        _ = model.apply(.toolEvent(status: .failed, reason: "write_refused"), audioIsPlaying: false)

        #expect(model.voice.mode == .error)
        #expect(model.voice.status == .refused("write_refused"))
    }

    /// A server error may mean the socket is unusable, so the microphone is
    /// detached before any in-flight buffer can race back to it.
    @Test("a server error tears the call down and shuts audio off")
    func serverErrorTearsDownTheCall() {
        let model = negotiatedModel()
        model.beginTestCall()

        let effects = model.apply(.error(RealtimeServerError(reason: "provider_unavailable")), audioIsPlaying: true)

        #expect(effects.contains(.endAudio))
        #expect(model.voice.callActive == false)
        #expect(model.voice.muted == false)
        #expect(model.voice.mode == .error)
        #expect(model.voice.statusText == "The daemon reported: provider_unavailable")
        #expect(model.voice.phase == .ended(.failed(kind: nil, sentence: model.voice.statusText)))
    }

    /// `error.kind` is the daemon's typed failure and `error.detail` the
    /// vendor's own sentence (PROTOCOL.md, `error`). Each kind reads as the
    /// product's sentence for it, and the vendor's words follow when it sent
    /// some, because a terminal word is not a diagnosis.
    @Test("each error kind ends the call in its own sentence, with the vendor's detail after it")
    func errorKindsHaveSentences() throws {
        let sentences: [(RealtimeErrorKind, ProductStringKey)] = [
            (.updateRequired, .voiceStatusUpdateRequired),
            (.providerRefused, .voiceErrorProviderRefused),
            (.costLimit, .voiceErrorCostLimit),
            (.sessionExpired, .voiceErrorSessionExpired),
            (.closeTimeout, .voiceErrorCloseTimeout),
            (.bridgeUnavailable, .voiceErrorBridgeUnavailable),
            (.maxSessionDuration, .voiceErrorMaxSessionDuration),
            (.providerDisconnected, .voiceErrorProviderDisconnected)
        ]

        for (kind, key) in sentences {
            let sentence = ProductStrings[key]
            #expect(ProductCopyRules.violations(in: sentence).isEmpty, "\(key.rawValue)")
            #expect(!sentence.lowercased().split(separator: " ").contains("stop"), "\(key.rawValue)")

            let bare = negotiatedModel()
            bare.beginTestCall()
            _ = bare.apply(.error(RealtimeServerError(reason: "terminal", kind: kind)), audioIsPlaying: false)
            #expect(bare.voice.statusText == sentence)
            #expect(bare.voice.phase == .ended(.failed(kind: kind, sentence: sentence)))

            let detailed = negotiatedModel()
            detailed.beginTestCall()
            _ = detailed.apply(
                .error(RealtimeServerError(reason: "terminal", kind: kind, detail: "The organization is not verified")),
                audioIsPlaying: false
            )
            #expect(detailed.voice.statusText == "\(sentence). The organization is not verified")
        }
    }

    /// With no kind, or one this build cannot read, the daemon's own reason is
    /// still the only words that name what happened.
    @Test("an error with no kind, or an unknown one, keeps the daemon's reason")
    func errorWithoutAKindKeepsTheReason() {
        for kind in [nil, RealtimeErrorKind.unrecognized("solar_flare")] {
            let model = negotiatedModel()
            model.beginTestCall()

            _ = model.apply(.error(RealtimeServerError(reason: "provider_unavailable", kind: kind)), audioIsPlaying: false)

            #expect(model.voice.statusText == String(format: ProductStrings[.voiceStatusRefusedFormat], "provider_unavailable"))
        }
    }

    /// `call_ready` is a fact about the call rather than a turn state: it says
    /// what answered, and leaves the pet on whatever the daemon last reported.
    @Test("call ready records the engine and the call without moving the mode")
    func callReadyRecordsTheCall() {
        let model = negotiatedModel()
        model.beginTestCall()
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

    /// Captions are concatenated as they arrive, one running text per
    /// speaker. Nothing trims a fragment or inserts a space the daemon did not
    /// send, and the two speakers may overlap, so each keeps its own text and
    /// the model remembers which grew last (M56 §4.2).
    @Test("captions grow one verbatim text per speaker, and the last to grow is named")
    func captionsGrowPerSpeaker() {
        let model = negotiatedModel()
        model.beginTestCall()

        for (speaker, delta) in [(RealtimeCaptionSpeaker.user, "what is "), (.assistant, "It "), (.user, "the time")] {
            let effects = model.apply(
                .caption(RealtimeCaption(speaker: speaker, delta: delta, startMs: 0, endMs: 1)),
                audioIsPlaying: false
            )
            #expect(effects.isEmpty)
        }

        #expect(model.voice.captions.text(of: .user) == "what is the time")
        #expect(model.voice.captions.text(of: .assistant) == "It ")
        #expect(model.voice.captions.latest == .user)
    }

    /// A Live call emits captions for as long as it runs, so each text keeps
    /// only its tail. The cut falls where a character begins: the bound is in
    /// bytes, and half a character is not text.
    @Test("a long call keeps each caption text within its bound")
    func captionTextsAreBounded() {
        let model = negotiatedModel()
        model.beginTestCall()
        var said = ""
        var answered = ""

        for index in 0..<400 {
            let question = "é\(index) "
            let answer = "ok \(index), "
            said += question
            answered += answer
            _ = model.apply(.caption(RealtimeCaption(speaker: .user, delta: question, startMs: index, endMs: index)), audioIsPlaying: false)
            _ = model.apply(.caption(RealtimeCaption(speaker: .assistant, delta: answer, startMs: index, endMs: index)), audioIsPlaying: false)
        }

        let user = model.voice.captions.text(of: .user)
        let assistant = model.voice.captions.text(of: .assistant)
        #expect(user.utf8.count <= VoiceCaptions.byteLimit)
        #expect(assistant.utf8.count <= VoiceCaptions.byteLimit)
        #expect(user.utf8.count > VoiceCaptions.byteLimit - 4)
        #expect(said.hasSuffix(user))
        #expect(answered.hasSuffix(assistant))
        #expect(user.hasSuffix("é399 "))
        #expect(model.voice.captions.latest == .assistant)
    }

    /// The contract names two speakers. A third would be a word this build
    /// has no line for, so its fragment is dropped rather than credited to
    /// either of them.
    @Test("a caption from a speaker the contract does not name is dropped")
    func unknownSpeakerIsDropped() {
        let model = negotiatedModel()
        model.beginTestCall()

        _ = model.apply(
            .caption(RealtimeCaption(speaker: .unrecognized("narrator"), delta: "meanwhile", startMs: 0, endMs: 1)),
            audioIsPlaying: false
        )

        #expect(model.voice.captions == VoiceCaptions())
    }

    /// A backend delegation reads like a tool call, because that is what it is
    /// from this side.
    @Test("a running task reads as tool use and a finished one returns to the microphone")
    func taskDrivesTheMode() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        let running = RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .running)
        _ = model.apply(.task(running), audioIsPlaying: false)
        #expect(model.voice.mode == .toolUse)
        #expect(model.voice.tasks.newestRunning == running)

        let done = RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .completed, summary: "checked")
        _ = model.apply(.task(done), audioIsPlaying: false)
        #expect(model.voice.mode == .listening)
        #expect(model.voice.tasks.newestRunning == nil)
        #expect(model.voice.tasks.current == done)
    }

    /// A failed delegation is still a delegation that stopped: the microphone
    /// comes back, and the daemon's own summary is what says it went wrong.
    @Test("a failed task returns to the microphone and keeps its summary")
    func failedTaskReturnsToTheMicrophone() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        let failed = RealtimeTask(
            delegationId: "dg_01H9",
            revision: 2,
            status: .failed,
            summary: "the calendar refused"
        )
        _ = model.apply(.task(failed), audioIsPlaying: false)

        #expect(model.voice.mode == .listening)
        #expect(model.voice.tasks.current?.summary == "the calendar refused")
    }

    /// Work whose status word this build cannot read is work nothing may claim
    /// has finished, so the surface keeps reporting it as running.
    @Test("a task status this build cannot read does not end the work")
    func unknownTaskStatusKeepsWorking() {
        let model = negotiatedModel()
        model.beginTestCall()

        _ = model.apply(
            .task(RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .unrecognized("paused"))),
            audioIsPlaying: false
        )

        #expect(model.voice.mode == .toolUse)
    }

    /// `revision` fences a re-asked task (PROTOCOL.md, `task`): a frame from
    /// an earlier revision is a late answer to an earlier ask.
    @Test("many revisions of one task: the newest wins and a stale frame is refused")
    func revisionsFenceATask() {
        let model = negotiatedModel()
        model.beginTestCall()

        for revision in 1...5 {
            _ = model.apply(.task(RealtimeTask(delegationId: "dg_1", revision: revision, status: .running)), audioIsPlaying: false)
        }
        let late = model.apply(.task(RealtimeTask(delegationId: "dg_1", revision: 3, status: .completed)), audioIsPlaying: false)

        #expect(late.isEmpty)
        #expect(model.voice.tasks.current == RealtimeTask(delegationId: "dg_1", revision: 5, status: .running))
        #expect(model.voice.mode == .toolUse)

        let done = RealtimeTask(delegationId: "dg_1", revision: 5, status: .completed, summary: "booked")
        _ = model.apply(.task(done), audioIsPlaying: false)
        #expect(model.voice.tasks.current == done)
    }

    /// Delegations run side by side. Each keeps its own slot, and the pet keeps
    /// thinking while any of them is still working.
    @Test("one task finishing leaves the work that is still running")
    func concurrentTasksKeepTheirOwnSlots() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.state(.listening), audioIsPlaying: false)

        _ = model.apply(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .running)), audioIsPlaying: false)
        _ = model.apply(.task(RealtimeTask(delegationId: "dg_2", revision: 1, status: .running)), audioIsPlaying: false)
        _ = model.apply(.task(RealtimeTask(delegationId: "dg_2", revision: 1, status: .completed)), audioIsPlaying: false)

        #expect(model.voice.tasks.held.count == 2)
        #expect(model.voice.tasks.newestRunning?.delegationId == "dg_1")
        #expect(model.voice.mode == .toolUse)
    }

    /// A finished task is kept for the task line until the next one starts,
    /// so "Task finished" with its summary is still readable after the work.
    @Test("a finished task stays on the line until the next task starts")
    func finishedTaskStaysUntilTheNext() {
        let model = negotiatedModel()
        model.beginTestCall()
        let done = RealtimeTask(delegationId: "dg_1", revision: 1, status: .completed, summary: "sent")

        _ = model.apply(.task(done), audioIsPlaying: false)
        #expect(model.voice.tasks.current == done)

        let next = RealtimeTask(delegationId: "dg_2", revision: 1, status: .running)
        _ = model.apply(.task(next), audioIsPlaying: false)
        #expect(model.voice.tasks.current == next)
    }

    /// At most eight are held, the oldest finished one first out. The
    /// evicted task's highest revision is remembered for the rest of the call,
    /// so its late frame is still refused rather than read as new work.
    @Test("nine tasks: the oldest finished goes, and a late frame of it is still refused")
    func ninthTaskEvictsTheOldestFinished() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.task(RealtimeTask(delegationId: "dg_0", revision: 1, status: .running)), audioIsPlaying: false)
        _ = model.apply(.task(RealtimeTask(delegationId: "dg_1", revision: 2, status: .completed)), audioIsPlaying: false)

        for index in 2...8 {
            _ = model.apply(.task(RealtimeTask(delegationId: "dg_\(index)", revision: 1, status: .running)), audioIsPlaying: false)
        }

        let ids = model.voice.tasks.held.map(\.delegationId)
        #expect(ids.count == VoiceTasks.limit)
        #expect(!ids.contains("dg_1"))
        #expect(ids.contains("dg_0"))
        #expect(model.voice.tasks.newestRunning?.delegationId == "dg_8")

        _ = model.apply(.task(RealtimeTask(delegationId: "dg_1", revision: 2, status: .completed)), audioIsPlaying: false)
        _ = model.apply(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .running)), audioIsPlaying: false)
        #expect(model.voice.tasks.held.map(\.delegationId) == ids)
    }

    /// With nothing finished to give way, the oldest running task does: the
    /// line shows the newest, and the bound holds.
    @Test("with no finished task to evict, the oldest running one goes")
    func ninthRunningTaskEvictsTheOldest() {
        let model = negotiatedModel()
        model.beginTestCall()

        for index in 0...8 {
            _ = model.apply(.task(RealtimeTask(delegationId: "dg_\(index)", revision: 1, status: .running)), audioIsPlaying: false)
        }

        #expect(model.voice.tasks.held.map(\.delegationId) == (1...8).map { "dg_\($0)" })
    }

    /// A bill is a fact, not a state. What a cost ceiling does to a call
    /// arrives as its own error, so a usage frame moves nothing, including the
    /// one that reports the limit was reached.
    @Test("a usage frame is recorded and changes no state")
    func usageIsRecordedOnly() {
        let model = negotiatedModel()
        model.beginTestCall()
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
        model.beginTestCall()
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
        model.callStopping()
        model.callEnded()

        model.callStarting()

        #expect(model.voice.engine == nil)
        #expect(model.voice.callId == nil)
        #expect(model.voice.captions == VoiceCaptions())
        #expect(model.voice.tasks == VoiceTasks())
        #expect(model.voice.usage == nil)
    }

    @Test("a transcript delta changes no state")
    func transcriptDeltasAreInert() {
        let model = negotiatedModel()
        model.beginTestCall()
        let before = model.voice

        let effects = model.apply(.transcriptDelta(text: "hello"), audioIsPlaying: false)

        #expect(effects.isEmpty)
        #expect(model.voice == before)
    }

    @Test("an event this build does not know changes no state")
    func unknownEventsAreInert() {
        let model = negotiatedModel()
        model.beginTestCall()
        let before = model.voice

        let effects = model.apply(.unrecognized(type: "weather"), audioIsPlaying: false)

        #expect(effects.isEmpty)
        #expect(model.voice == before)
    }

    /// A socket lost mid-call ends the call, and says so: the strip keeps the
    /// failure rather than reading as a call that was hung up.
    @Test("losing the session mid-call ends the call as offline")
    func sessionLossReturnsToOffline() {
        let model = negotiatedModel()
        model.beginTestCall()

        model.voiceFailed(.transport(.peerClosed))

        #expect(model.voice.connected == false)
        #expect(model.voice.callActive == false)
        #expect(model.voice.mode == .offline)
        #expect(model.voice.status == .offline)
        #expect(model.voice.phase == .ended(.failed(kind: nil, sentence: VoiceStatus.offline.text)))
    }

    /// The daemon closes the socket after most errors (PROTOCOL.md, `error`).
    /// The close is the refusal's consequence, not a second failure: "Not
    /// connected" must not overwrite the reason the daemon gave.
    @Test("a refusal survives the socket closing after it")
    func refusalSurvivesTheClose() {
        let model = negotiatedModel()
        model.beginTestCall()
        let refusal = RealtimeServerError(reason: "provider_unavailable")
        _ = model.apply(.error(refusal), audioIsPlaying: false)
        let refused = model.voice

        model.voiceFailed(.transport(.peerClosed))

        #expect(model.voice.status == refused.status)
        #expect(model.voice.phase == refused.phase)
        #expect(model.voice.mode == .error)
        #expect(model.voice.connected == false)
    }

    @Test("a version refusal asks for an update rather than naming a wire code")
    func versionRefusalAsksForAnUpdate() {
        let model = negotiatedModel()

        model.voiceFailed(.versionUnsupported(direction: .clientTooOld, minimum: 2, maximum: 2))

        #expect(model.voice.status == .updateRequired)
        #expect(model.voice.mode == .error)
    }
}

/// The call's lifecycle, end to end on the fakes: the attempt every start
/// mints, the handshake and the permission prompt fenced by it, and a stop that
/// waits for the daemon's last frame before the next call may begin (M56 §4.1).
@Suite("The call's lifecycle")
@MainActor
struct VoiceCallLifecycleTests {
    @Test("a start mints an attempt, and a click while it is pending cancels it")
    func clickWhileStartingCancels() throws {
        let harness = VoiceCallHarness()

        harness.coordinator.toggleCall()
        #expect(harness.call.voice.phase == .starting)
        #expect(harness.call.voice.attempt == 1)
        #expect(harness.call.voice.status == .connecting)
        #expect(harness.call.voice.phase.callControlEnds)

        harness.coordinator.toggleCall()
        #expect(harness.call.voice.phase == .idle)
        #expect(!harness.call.voice.phase.callControlEnds)
        #expect(try harness.sent("client_hello") == 1)
        #expect(try harness.sent("call_start") == 0)
    }

    /// The handshake outlives a cancelled start. When the daemon answers it,
    /// the socket is negotiated for the next start and nothing else happens:
    /// no microphone, no `call_start`.
    @Test("a server hello for a cancelled attempt is dropped")
    func lateHelloForACancelledAttempt() async throws {
        let harness = VoiceCallHarness()
        harness.coordinator.toggleCall()
        harness.coordinator.toggleCall()

        harness.negotiate()
        for _ in 0..<50 { await Task.yield() }

        #expect(harness.call.voice.phase == .idle)
        #expect(harness.call.voice.connected)
        #expect(!harness.engine.calls.contains(.requestPermission))
        #expect(try harness.sent("call_start") == 0)
    }

    /// The prompt is modal and answers every asker at once, so the first
    /// attempt's request comes back too. Only the attempt still current may
    /// warm the microphone and send `call_start`: one call, the second one.
    @Test("start, cancel, start while the permission prompt is up warms once and sends one call start, for the second attempt")
    func restartDuringThePermissionPrompt() async throws {
        let harness = VoiceCallHarness()
        harness.engine.suspendsPermission = true
        harness.coordinator.toggleCall()
        harness.negotiate()
        await harness.settle { harness.engine.pendingPermissionRequests == 1 }

        harness.coordinator.toggleCall()
        harness.coordinator.toggleCall()
        await harness.settle { harness.engine.pendingPermissionRequests == 2 }
        harness.engine.grantCapturePermission()
        await harness.settle { harness.call.voice.phase == .active }

        #expect(harness.call.voice.attempt == 2)
        #expect(harness.engine.calls.filter { $0 == .prepareCapture }.count == 1)
        #expect(try harness.sent("call_start") == 1)
    }

    /// The Live engine's order on `call_stop` (`live_session_server.ex`
    /// `settle/2`, then `local_voice_socket.ex`): `state idle` as it begins
    /// to settle, a `task cancelled` for each delegation still running, the
    /// settled `usage`, then `state idle` again as the call's last frame. The
    /// first idle is not the end: everything up to the settled bill is the
    /// ending call's.
    @Test("a Live call's stop ends at the idle after its settled bill")
    func liveStopEndsAfterTheSettledBill() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.socket.deliver(.callReady(RealtimeCallReady(engine: "openai_live", callId: "voice_live:1", captions: true)))
        harness.socket.deliver(.state(.listening))
        harness.socket.deliver(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .running)))
        harness.socket.deliver(.usage(RealtimeUsage(status: "live", voiceCostCents: 4, accounting: "running")))

        harness.coordinator.toggleCall()

        #expect(harness.call.voice.phase == .stopping)
        #expect(harness.call.voice.callActive)
        #expect(!harness.call.voice.phase.callControlEnds)
        #expect(try harness.sent("call_stop") == 1)
        #expect(harness.engine.calls.last == .shutdown)
        #expect(harness.callDeadlines.scheduledDelays == [VoiceCoordinator.stopGrace])

        let settled = RealtimeUsage(status: "live", voiceCostCents: 12.5, accounting: "complete")
        let streams = harness.engine.calls.filter { $0 == .beginStreaming }.count
        harness.socket.deliver(.state(.listening))
        harness.socket.deliver(.state(.idle))
        harness.socket.deliver(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .cancelled)))
        #expect(harness.call.voice.phase == .stopping)
        harness.socket.deliver(.usage(settled))
        #expect(harness.call.voice.phase == .stopping)
        #expect(harness.engine.calls.filter { $0 == .beginStreaming }.count == streams)

        harness.socket.deliver(.state(.idle))

        #expect(harness.call.voice.phase == .ended(.normal(settled: settled)))
        #expect(harness.call.voice.usage == settled)
        #expect(harness.call.voice.tasks["dg_1"]?.status == .cancelled)
        #expect(harness.call.voice.callActive == false)
        #expect(harness.callDeadlines.liveCount == 0)
    }

    /// The Realtime engine settles nothing: no `call_ready`, no accounting on
    /// its usage, and its first idle is the call's end.
    @Test("a Realtime call's stop ends at its first idle")
    func realtimeStopEndsAtTheFirstIdle() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        let usage = RealtimeUsage(voiceSeconds: 9)
        harness.socket.deliver(.usage(usage))

        harness.coordinator.toggleCall()
        harness.socket.deliver(.state(.idle))

        #expect(harness.call.voice.phase == .ended(.normal(settled: usage)))
        #expect(harness.callDeadlines.liveCount == 0)
    }

    /// A call the daemon ends itself at the cost ceiling: `state idle`, the
    /// usage that reached the limit, then `error` with its kind, and the
    /// socket closes. The failure keeps its kind, its words and that bill,
    /// and the close does not overwrite them.
    @Test("a call ended at the cost limit keeps the failure and the bill through the socket closing")
    func costLimitEndsAsAFailure() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.socket.deliver(.callReady(RealtimeCallReady(engine: "openai_live", callId: "voice_live:1", captions: true)))
        harness.socket.deliver(.state(.listening))

        let limit = RealtimeUsage(status: "limit_reached", voiceCostCents: 500, accounting: "running")
        harness.socket.deliver(.state(.idle))
        harness.socket.deliver(.usage(limit))
        harness.socket.deliver(.error(RealtimeServerError(reason: "cost_limit", kind: .costLimit)))
        let failed = harness.call.voice
        harness.socket.fail(.peerClosed)

        guard case .ended(.failed(kind: .costLimit, let sentence)) = harness.call.voice.phase else {
            Issue.record("the call did not end as a cost limit: \(harness.call.voice.phase)")
            return
        }
        #expect(sentence == ProductStrings[.voiceErrorCostLimit])
        #expect(harness.call.voice.statusText == ProductStrings[.voiceErrorCostLimit])
        #expect(harness.call.voice.status == failed.status)
        #expect(harness.call.voice.usage == limit)
        #expect(harness.call.voice.connected == false)
    }

    /// End then begin at once: the begin waits for the ending call's idle, so
    /// that call's last frames are read as its own and the new call starts
    /// with none of them.
    @Test("end then begin at once: the first call's last frames land on it and the new one starts clean")
    func endThenBeginAtOnce() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.socket.deliver(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .running)))
        var seen: [VoiceState] = []
        let subscription = harness.call.$voice.sink { seen.append($0) }
        defer { subscription.cancel() }

        harness.coordinator.toggleCall()
        harness.coordinator.toggleCall()
        #expect(harness.call.voice.phase == .stopping)
        #expect(try harness.sent("call_start") == 1)

        let settled = RealtimeUsage(voiceCostCents: 12.5, accounting: "complete")
        let finished = RealtimeTask(delegationId: "dg_1", revision: 1, status: .completed)
        harness.socket.deliver(.task(finished))
        harness.socket.deliver(.usage(settled))
        harness.socket.deliver(.state(.idle))
        await harness.settle { harness.call.voice.phase == .active }

        let ended = try #require(seen.last { $0.phase == .ended(.normal(settled: settled)) })
        #expect(ended.tasks.current == finished)
        #expect(ended.attempt == 1)
        #expect(harness.call.voice.attempt == 2)
        #expect(harness.call.voice.tasks == VoiceTasks())
        #expect(harness.call.voice.usage == nil)
        #expect(harness.call.voice.captions == VoiceCaptions())
        #expect(try harness.sent("call_start") == 2)
        #expect(try harness.sent("call_stop") == 1)
    }

    /// The daemon guarantees the idle, but a guarantee is not a deadline: a
    /// call that never hears it still ends, two seconds after the click.
    @Test("a stop ends the call after two seconds when the idle never comes")
    func stopGivesUpAfterTwoSeconds() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.coordinator.toggleCall()
        harness.coordinator.toggleCall()

        harness.callDeadlines.fireAll()

        await harness.settle { harness.call.voice.phase == .active }
        #expect(harness.call.voice.attempt == 2)
        #expect(try harness.sent("call_start") == 2)
    }

    @Test("a stop that times out ends the call, and the late frames after it are dropped")
    func lateFramesAfterTheTimeoutAreDropped() async {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.coordinator.toggleCall()

        harness.callDeadlines.fireAll()
        #expect(harness.call.voice.phase == .ended(.normal(settled: nil)))

        harness.socket.deliver(.usage(RealtimeUsage(voiceCostCents: 3)))
        harness.socket.deliver(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .completed)))
        harness.socket.deliver(.state(.idle))

        #expect(harness.call.voice.phase == .ended(.normal(settled: nil)))
        #expect(harness.call.voice.usage == nil)
        #expect(harness.call.voice.tasks == VoiceTasks())
    }

    /// With no call there is nothing for a call frame to describe. A bill
    /// with no call is no call's bill.
    @Test("call frames with no call are dropped")
    func framesOutsideACallAreDropped() {
        let model = VoiceCallModel()
        model.voiceNegotiated()
        let before = model.voice

        #expect(model.apply(.usage(RealtimeUsage(voiceCostCents: 3)), audioIsPlaying: false).isEmpty)
        #expect(model.apply(.state(.listening), audioIsPlaying: false).isEmpty)
        #expect(model.apply(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .running)), audioIsPlaying: false).isEmpty)
        #expect(model.voice == before)
    }

    /// "Cancel task" names the task and the revision the surface showed. The
    /// wire carries the id alone, so the revision is this side's fence: a
    /// click on work that has since been re-asked or finished sends nothing.
    @Test("a cancel names its task and revision, and a stale one sends nothing")
    func cancelIsFencedByRevision() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.socket.deliver(.task(RealtimeTask(delegationId: "dg_1", revision: 1, status: .running)))
        harness.socket.deliver(.task(RealtimeTask(delegationId: "dg_1", revision: 2, status: .running)))

        harness.coordinator.cancelTask(delegationId: "dg_1", revision: 1)
        harness.coordinator.cancelTask(delegationId: "dg_9", revision: 1)
        #expect(try harness.sent("task_cancel") == 0)

        harness.coordinator.cancelTask(delegationId: "dg_1", revision: 2)
        #expect(try harness.socket.sentObjects().last == wireObject(.taskCancel(delegationId: "dg_1")))

        harness.socket.deliver(.task(RealtimeTask(delegationId: "dg_1", revision: 2, status: .cancelled)))
        harness.coordinator.cancelTask(delegationId: "dg_1", revision: 2)
        #expect(try harness.sent("task_cancel") == 1)
    }

    /// The controls act on a call, and only on one: a mute or an interrupt
    /// sent with no call is a frame the daemon answers by closing the socket.
    @Test("mute and interrupt send nothing outside a call")
    func controlsNeedACall() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.coordinator.toggleCall()

        harness.coordinator.setMuted(true)
        harness.coordinator.interrupt()

        #expect(try harness.sent("mute") == 0)
        #expect(try harness.sent("interrupt") == 0)
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

    private func speakingModel(_ clock: Clock) -> VoiceCallModel {
        let model = VoiceCallModel(now: { clock.now })
        model.voiceNegotiated()
        model.beginTestCall()
        _ = model.apply(.state(.listening), audioIsPlaying: false)
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)
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
        #expect(model.apply(.audioDelta(base64: RelayedAudio.voice(2)), audioIsPlaying: false).isEmpty)
        // Each chunk extends the window: a reply streams in a run of chunks.
        clock.now += VoiceCallModel.stoppedReplyGap - 0.1
        #expect(model.apply(.audioDelta(base64: RelayedAudio.voice(3)), audioIsPlaying: false).isEmpty)

        #expect(model.voice.mode == .listening)
        #expect(model.voice.audioActive == false)
        #expect(model.voice.presentation.visualMode == .listening)
    }

    @Test("padding after Stop does not keep the stopped reply alive")
    func paddingDoesNotExtendTheStoppedReply() {
        let clock = Clock()
        let model = speakingModel(clock)

        model.voiceInterrupted()
        for _ in 0..<12 {
            clock.now += 0.1
            #expect(model.apply(.audioDelta(base64: RelayedAudio.padding), audioIsPlaying: false) == [.play(base64: RelayedAudio.padding)])
        }

        #expect(model.apply(.audioDelta(base64: RelayedAudio.voice(9)), audioIsPlaying: false) == [.play(base64: RelayedAudio.voice(9))])
        #expect(model.voice.mode == .speaking)
    }

    @Test("audio after the stopped reply has gone quiet is a new reply, and plays")
    func nextReplyPlays() {
        let clock = Clock()
        let model = speakingModel(clock)

        model.voiceInterrupted()
        clock.now += 0.1
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(2)), audioIsPlaying: false)

        clock.now += VoiceCallModel.stoppedReplyGap + 0.1
        let effects = model.apply(.audioDelta(base64: RelayedAudio.voice(9)), audioIsPlaying: false)

        #expect(effects == [.play(base64: RelayedAudio.voice(9))])
        #expect(model.voice.mode == .speaking)
    }

    @Test("a new call forgets a reply the last one stopped")
    func newCallForgetsTheStoppedReply() {
        let clock = Clock()
        let model = speakingModel(clock)

        model.voiceInterrupted()
        model.callStopping()
        model.callEnded()
        model.beginTestCall()
        clock.now += 0.1

        #expect(model.apply(.audioDelta(base64: RelayedAudio.voice(9)), audioIsPlaying: false) == [.play(base64: RelayedAudio.voice(9))])
    }
}

/// A reply ending the way the Live engine ends one: its audio runs out and the
/// daemon says nothing more, because Live publishes no end of a reply.
///
/// The pet stayed on its speaking face until the user next spoke (RCA of
/// 2026-09-25, "Pet listening and thinking modes"). These replay the whole
/// sequence from the wire, not a state set by hand.
@Suite("A Live reply ending")
@MainActor
struct LiveReplyEndTests {
    private func liveCall() -> VoiceCallModel {
        let model = VoiceCallModel()
        model.voiceNegotiated()
        model.beginTestCall()
        _ = model.apply(.state(.listening), audioIsPlaying: false)
        return model
    }

    private func speak(_ model: VoiceCallModel) {
        _ = model.apply(.state(.speaking), audioIsPlaying: false)
        _ = model.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)
    }

    /// Live never stops its output: between replies it is digital silence,
    /// one chunk every 100 ms (measured on the dev engine, 2026-09-28).
    @Test("padding plays, but is not speech")
    func paddingIsNotSpeech() {
        let model = liveCall()

        let effects = model.apply(.audioDelta(base64: RelayedAudio.padding), audioIsPlaying: false)

        #expect(effects == [.play(base64: RelayedAudio.padding)])
        #expect(model.voice.mode == .listening)
        #expect(model.voice.audioActive == false)
    }

    @Test("padding after a reply does not keep the pet speaking")
    func paddingAfterAReply() {
        let model = liveCall()
        speak(model)
        _ = model.apply(.audioDelta(base64: RelayedAudio.padding), audioIsPlaying: false)

        model.voicePlaybackDrained()

        #expect(model.voice.mode == .listening)
    }

    @Test("a reply that finishes playing with the user silent returns the pet to listening")
    func silentUserReturnsToListening() {
        let model = liveCall()
        speak(model)
        #expect(model.voice.presentation.visualMode == .speaking)

        model.voicePlaybackDrained()

        #expect(model.voice.mode == .listening)
        #expect(model.voice.status == .listening)
        #expect(PetExpression.resolve(for: model.voice.presentation.visualMode) == .listening)
    }

    @Test("a reply spoken over running backend work returns the pet to that work")
    func runningTaskResumesThinking() {
        let model = liveCall()
        _ = model.apply(.task(RealtimeTask(delegationId: "d1", revision: 1, status: .running, summary: nil)), audioIsPlaying: false)
        speak(model)

        model.voicePlaybackDrained()

        #expect(model.voice.mode == .toolUse)
        #expect(PetExpression.resolve(for: model.voice.presentation.visualMode) == .thinking)

        _ = model.apply(.task(RealtimeTask(delegationId: "d1", revision: 1, status: .completed, summary: nil)), audioIsPlaying: false)
        #expect(model.voice.mode == .listening)
    }

    @Test("a muted call returns to muted, not listening")
    func mutedCallReturnsToMuted() {
        let model = liveCall()
        model.voiceMuted(true)
        speak(model)
        #expect(model.voice.mode == .speaking)

        model.voicePlaybackDrained()

        #expect(model.voice.mode == .muted)
    }

    /// The engine says listening once a reply has had time to play out. Backend
    /// work still running is still the pet's thinking pose.
    @Test("listening while backend work runs keeps the pet on the work")
    func listeningDuringWorkKeepsTheWork() {
        let model = liveCall()
        _ = model.apply(.task(RealtimeTask(delegationId: "d1", revision: 1, status: .running)), audioIsPlaying: false)
        speak(model)

        _ = model.apply(.state(.listening), audioIsPlaying: true)
        model.voicePlaybackDrained()

        #expect(model.voice.mode == .toolUse)
        #expect(PetExpression.resolve(for: model.voice.presentation.visualMode) == .thinking)
    }

    @Test("stopping a reply spoken over backend work returns to the work")
    func stopDuringWorkReturnsToTheWork() {
        let model = liveCall()
        _ = model.apply(.task(RealtimeTask(delegationId: "d1", revision: 1, status: .running)), audioIsPlaying: false)
        speak(model)

        model.voiceInterrupted()

        #expect(model.voice.mode == .toolUse)
    }

    @Test("the daemon's own next state still wins after the drain")
    func daemonStateStillWins() {
        let model = liveCall()
        speak(model)
        model.voicePlaybackDrained()

        _ = model.apply(.state(.thinking), audioIsPlaying: false)
        #expect(model.voice.mode == .thinking)

        speak(model)
        #expect(model.voice.presentation.visualMode == .speaking)
    }
}

/// What counts as voice in the audio the daemon relays, against the levels
/// measured on the dev engine: voice 244 to 3,667, padding 0 to 49.
@Suite("Relayed audio")
struct RelayedAudioTests {
    private func chunk(rms: Int16) -> Data {
        var data = Data()
        for index in 0..<2_400 {
            var value = (index % 2 == 0 ? rms : -rms).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test("Live's quietest voice is voice, and its loudest padding is not")
    func measuredLevels() {
        #expect(PCM16.isVoiced(chunk(rms: 244)))
        #expect(PCM16.isVoiced(chunk(rms: 3_667)))
        #expect(!PCM16.isVoiced(chunk(rms: 49)))
        #expect(!PCM16.isVoiced(chunk(rms: 0)))
    }

    @Test("audio that does not decode is not voice")
    func undecodable() {
        #expect(!PCM16.isVoiced(base64: "not base64!"))
        #expect(PCM16.isVoiced(base64: RelayedAudio.voice()))
        #expect(!PCM16.isVoiced(base64: RelayedAudio.padding))
    }
}

/// What a second view of the call needs from the one model (M56 §4.2, §4.3):
/// "Connecting" until the daemon answers, an ended call kept until it is
/// dismissed, the intro once per call, and whether the primary window is on
/// screen.
@Suite("The call seen from the chat")
@MainActor
struct VoiceCallSecondViewTests {
    private func negotiatedModel() -> VoiceCallModel {
        let model = VoiceCallModel()
        model.voiceNegotiated()
        return model
    }

    /// A start's mode rests at idle, whose label is "Ready": the start said
    /// "Ready" on the Pet page from the click until the first turn state.
    @Test("a start says Connecting until the daemon says what the turn is doing")
    func connectingUntilTheDaemonAnswers() {
        let model = negotiatedModel()

        model.callStarting()
        #expect(model.voice.statusText == ProductStrings[.voiceStatusConnecting])

        model.callStarted()
        _ = model.apply(
            .callReady(RealtimeCallReady(engine: "openai_live", callId: "voice_live:test", captions: true)),
            audioIsPlaying: false
        )
        #expect(model.voice.statusText == ProductStrings[.voiceStatusConnecting])

        _ = model.apply(.state(.listening), audioIsPlaying: false)
        #expect(model.voice.statusText == ProductStrings[.voiceStatusListening])
    }

    @Test("closing the box changes nothing about the call, and lasts until the next start")
    func closingTheBoxLeavesTheCall() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.state(.listening), audioIsPlaying: false)
        #expect(!model.callBoxClosed)

        model.closeCallBox()
        #expect(model.callBoxClosed)
        #expect(model.voice.phase == .active)

        _ = model.apply(
            .error(RealtimeServerError(reason: "provider_disconnected", kind: .providerDisconnected)),
            audioIsPlaying: false
        )
        #expect(model.voice.phase == .ended(.failed(kind: .providerDisconnected, sentence: ProductStrings[.voiceErrorProviderDisconnected])))
        #expect(model.voice.status.carriesItsOwnSentence)
        #expect(model.callBoxClosed)

        model.callStarting()
        #expect(!model.callBoxClosed)
    }

    @Test("the settled cost is the ended call's, never the figure while it is up")
    func settledCostOnlyOnceEnded() {
        let model = negotiatedModel()
        model.beginTestCall()
        _ = model.apply(.usage(RealtimeUsage(voiceCostCents: 4, accounting: "running")), audioIsPlaying: false)
        #expect(model.voice.settledCostCents == nil)

        model.callStopping()
        _ = model.apply(.usage(RealtimeUsage(voiceCostCents: 12.5, accounting: "complete")), audioIsPlaying: false)
        #expect(model.voice.settledCostCents == nil)

        _ = model.apply(.state(.idle), audioIsPlaying: false)
        #expect(model.voice.settledCostCents == 12.5)
    }

    /// The chat view is rebuilt on every rail change, so the call model
    /// remembers whether this call's intro has played.
    @Test("the intro plays once per call, and not again when the strip is rebuilt")
    func introOncePerCall() {
        let model = negotiatedModel()

        model.callStarting()
        #expect(!model.introPlayed)

        model.introShown()
        #expect(model.introPlayed)
        // A rail change mid-call builds a new strip, which reads this again.
        model.callStarted()
        #expect(model.introPlayed)

        model.callStopping()
        model.callEnded()
        #expect(model.introPlayed)

        model.callStarting()
        #expect(!model.introPlayed)
    }

    @Test("the main window's visibility reaches the call model, published only when it moves")
    func mainWindowVisibility() {
        let model = VoiceCallModel()
        var changes = 0
        let subscription = model.objectWillChange.sink { _ in changes += 1 }
        defer { subscription.cancel() }

        #expect(model.mainWindowVisible)

        model.mainWindowVisibilityChanged(false)
        #expect(!model.mainWindowVisible)
        #expect(changes == 1)

        model.mainWindowVisibilityChanged(false)
        #expect(changes == 1)

        model.mainWindowVisibilityChanged(true)
        #expect(model.mainWindowVisible)
        #expect(changes == 2)
    }

    @Test("the composition routes the main window's visibility to the call model")
    func compositionRoutesVisibility() throws {
        let text = try #require(try SourceTree.swiftFiles(matching: "App/AppComposition.swift").first?.text)

        #expect(text.contains("case .main:"))
        #expect(text.contains("voiceCall.mainWindowVisibilityChanged(onScreen)"))
    }

    /// The composer's button names the next click, and the floating pet's
    /// tooltip the failure: both read the gate through the façade.
    @Test("the façade says what the gate decided and why a control is dimmed")
    func facadeReadsTheGate() throws {
        let harness = try PetHarness()
        #expect(harness.model.callAction == .begin)
        #expect(harness.model.callUnavailableReason == nil)

        harness.readiness.voiceReadiness = .degraded
        #expect(harness.model.callAction == .unavailable)
        #expect(harness.model.callUnavailableReason == VoiceReadiness.degraded.sentence)
    }
}
