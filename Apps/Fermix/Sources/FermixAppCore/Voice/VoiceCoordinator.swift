import Foundation

/// What a surface can ask of voice. The pet and the menu bar act through this;
/// neither reaches the socket or the audio engine.
@MainActor
public protocol VoiceControlling: AnyObject {
    /// The one call control. It begins a call; while the daemon has not yet
    /// been asked for it (the handshake or the microphone prompt is pending)
    /// it calls that start off; during a call it ends it; and while a call is
    /// still ending it begins the next one as soon as the last has ended.
    func toggleCall()
    func setMuted(_ muted: Bool)
    func interrupt()
    /// Calls off the backend delegation the daemon last reported. Nothing is
    /// presumed about the outcome: the task ends when a `task` frame says so.
    func cancelTask()
    /// Releases the microphone and the socket. Sends no daemon lifecycle
    /// command: the daemon outlives the window.
    func shutdown()
}

/// Wires the session, the audio owner, and the model together.
///
/// It decides nothing: routing lives in `VoiceCallModel`, the handshake in
/// `VoiceSession`, and the capture lifecycle in `AudioOwner`. This is the one
/// place they meet, and it is deliberately the smallest of the four. What it
/// does own is order: a start's work is fenced by the attempt that began it,
/// and a start never overtakes the end of the call before it.
@MainActor
public final class VoiceCoordinator: VoiceControlling {
    /// How long a stopped call waits for the daemon's `state idle`, its last
    /// frame, before it is over anyway.
    static let stopGrace: TimeInterval = 2

    private let model: VoiceCallModel
    private let session: VoiceSession
    private let audio: AudioOwner
    private let deadlines: any DeadlineScheduling
    private let log = AppLog.logger(.voice)
    /// The stopping call's wait for its last frame.
    private var stopDeadline: DeadlineToken?
    /// A start asked for while the last call was still ending. It goes when
    /// that call has ended, so the old call's last frames are read as its own.
    private var startAfterStop = false

    public init(
        model: VoiceCallModel,
        session: VoiceSession,
        audio: AudioOwner,
        deadlines: any DeadlineScheduling
    ) {
        self.model = model
        self.session = session
        self.audio = audio
        self.deadlines = deadlines

        session.onNegotiated = { [weak self] _ in self?.negotiated() }
        session.onEvent = { [weak self] event in self?.received(event) }
        session.onFailed = { [weak self] failure in self?.failed(failure) }

        audio.onLevel = { [weak self] level in self?.model.voiceLevelChanged(level) }
        audio.onPlaybackDrained = { [weak self] in self?.model.voicePlaybackDrained() }
    }

    // MARK: - Commands

    public func toggleCall() {
        switch model.voice.phase {
        case .idle, .ended:
            startCall()
        case .starting:
            cancelStart()
        case .active:
            endCall()
        case .stopping:
            startAfterStop = true
        }
    }

    /// The call's controls act on a call and only on one: the daemon answers a
    /// control frame that has no call behind it by closing the socket.
    public func setMuted(_ muted: Bool) {
        guard model.voice.phase == .active else { return }

        audio.setMuted(muted)
        model.voiceMuted(muted)
        session.send(.mute(enabled: muted))
    }

    public func interrupt() {
        guard model.voice.phase == .active else { return }

        let played = audio.interruptPlayback()
        session.send(.interrupt(audioEndMs: played))
        model.voiceInterrupted()
    }

    public func cancelTask() {
        guard model.voice.phase == .active, let delegationId = model.voice.task?.delegationId else { return }

        session.send(.taskCancel(delegationId: delegationId))
    }

    public func shutdown() {
        // Best effort: the socket queue may not drain before the process exits,
        // and that is fine — the daemon treats the socket's EOF as the real
        // teardown, which it must, to survive the app crashing.
        if model.voice.phase == .active {
            session.send(.callStop)
        }

        cancelStopDeadline()
        startAfterStop = false
        audio.endCall()
        session.close()
        model.voiceShutDown()
    }

    // MARK: - The call

    private func startCall() {
        let attempt = model.callStarting()

        guard session.phase == .negotiated else {
            // The call begins from `negotiated()`; nothing is sent before the
            // daemon's window has been checked. A handshake already under way
            // serves this start too.
            session.connect()
            return
        }

        beginCall(attempt)
    }

    /// A start called off before `call_start`: the request is forgotten, the
    /// microphone released if its bring-up began, and the socket left as it
    /// is, negotiated or negotiating, for the next start.
    private func cancelStart() {
        audio.endCall()
        model.callCancelled()
    }

    /// Hangs up, then waits for the daemon to say the call is over: its last
    /// frames still belong to it, and a start may not overtake them.
    private func endCall() {
        session.send(.callStop)
        audio.endCall()
        model.callStopping()

        let attempt = model.voice.attempt
        stopDeadline = deadlines.schedule(after: Self.stopGrace) { [weak self] in
            self?.stopGraceExpired(for: attempt)
        }
    }

    private func stopGraceExpired(for attempt: Int) {
        guard model.voice.phase == .stopping, model.voice.attempt == attempt else { return }

        stopDeadline = nil
        log.error("the daemon did not end the call within \(Self.stopGrace, privacy: .public) seconds")
        model.callEnded()
        stopFinished()
    }

    /// The stopping call is over, by its last frame, its deadline or its
    /// socket. A start asked for meanwhile goes now.
    private func stopFinished() {
        cancelStopDeadline()

        guard startAfterStop else { return }

        startAfterStop = false
        startCall()
    }

    private func cancelStopDeadline() {
        stopDeadline?.cancel()
        stopDeadline = nil
    }

    /// Asks for the microphone, then for the call. The prompt is modal and can
    /// outlast the start that raised it, so only the attempt still current
    /// when it is answered may go on: a cancelled one sends nothing.
    private func beginCall(_ attempt: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.audio.beginCall()
            } catch {
                guard self.isStarting(attempt) else { return }

                self.captureFailed(error)
                return
            }

            guard self.isStarting(attempt) else { return }

            self.model.callStarted()
            self.session.send(.callStart)
        }
    }

    private func isStarting(_ attempt: Int) -> Bool {
        model.voice.phase == .starting && model.voice.attempt == attempt
    }

    private func captureFailed(_ error: any Error) {
        let sentence = (error as? CaptureError)?.errorDescription ?? ProductStrings[.voiceErrorMicrophoneUnknown]
        log.error("microphone capture failed: \(self.audio.diagnostics(), privacy: .public)")

        // `call_start` goes out only once the microphone is ready, so a start
        // that failed before it has no call to stop.
        let callStarted = model.voice.phase == .active
        audio.endCall()
        model.voiceCaptureFailed(sentence)
        if callStarted {
            session.send(.callStop)
        }
    }

    // MARK: - Session events

    private func negotiated() {
        model.voiceNegotiated()

        // Only a start still waiting begins. One called off while the
        // handshake ran leaves the socket negotiated and sends nothing.
        guard model.voice.phase == .starting else { return }

        beginCall(model.voice.attempt)
    }

    private func received(_ event: RealtimeServerEvent) {
        perform(model.apply(event, audioIsPlaying: audio.isPlayingBack))
    }

    private func failed(_ failure: VoiceSessionFailure) {
        let wasStopping = model.voice.phase == .stopping
        audio.endCall()
        model.voiceFailed(failure)

        if wasStopping {
            stopFinished()
        }
    }

    // MARK: - Effects

    private func perform(_ effects: [VoiceEffect]) {
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: VoiceEffect) {
        switch effect {
        case .startCapture:
            startCapture()
        case .setCaptureMuted(let muted):
            audio.setMuted(muted)
        case .play(let base64):
            audio.play(base64PCM16: base64)
        case .stopPlayback:
            audio.stopPlayback()
        case .resetUtteranceAnchor:
            audio.resetUtteranceAnchor()
        case .endAudio:
            audio.endCall()
        case .callEnded:
            stopFinished()
        }
    }

    private func startCapture() {
        do {
            try audio.startStreaming(onChunk: session.audioSink())
        } catch {
            captureFailed(error)
        }
    }
}
