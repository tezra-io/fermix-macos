import Foundation

/// What a surface can ask of voice. The pet and the menu bar act through this;
/// neither reaches the socket or the audio engine.
@MainActor
public protocol VoiceControlling: AnyObject {
    func toggleCall()
    func setMuted(_ muted: Bool)
    func interrupt()
    /// Releases the microphone and the socket. Sends no daemon lifecycle
    /// command: the daemon outlives the window.
    func shutdown()
}

/// Wires the session, the audio owner, and the model together.
///
/// It decides nothing: routing lives in `AppModel`, the handshake in
/// `VoiceSession`, and the capture lifecycle in `AudioOwner`. This is the one
/// place they meet, and it is deliberately the smallest of the four.
@MainActor
public final class VoiceCoordinator: VoiceControlling {
    private let model: AppModel
    private let session: VoiceSession
    private let audio: AudioOwner
    private let log = AppLog.logger(.voice)
    private var callRequested = false

    public init(model: AppModel, session: VoiceSession, audio: AudioOwner) {
        self.model = model
        self.session = session
        self.audio = audio

        session.onNegotiated = { [weak self] _ in self?.negotiated() }
        session.onEvent = { [weak self] event in self?.received(event) }
        session.onFailed = { [weak self] failure in self?.failed(failure) }

        audio.onLevel = { [weak self] level in self?.model.voiceLevelChanged(level) }
        audio.onPlaybackDrained = { [weak self] in self?.model.voicePlaybackDrained() }
    }

    // MARK: - Commands

    public func toggleCall() {
        model.voice.callActive ? endCall() : startCall()
    }

    public func setMuted(_ muted: Bool) {
        audio.setMuted(muted)
        model.voiceMuted(muted)
        session.send(.mute(enabled: muted))
    }

    public func interrupt() {
        let played = audio.interruptPlayback()
        session.send(.interrupt(audioEndMs: played))
        model.voiceInterrupted()
    }

    public func shutdown() {
        // Best effort: the socket queue may not drain before the process exits,
        // and that is fine — the daemon treats the socket's EOF as the real
        // teardown, which it must, to survive the app crashing.
        if model.voice.callActive {
            session.send(.callStop)
        }

        callRequested = false
        audio.endCall()
        session.close()
        model.voiceCallEnded()
    }

    // MARK: - The call

    private func startCall() {
        guard session.phase == .negotiated else {
            // Record the intent and drive the handshake. The call begins from
            // `negotiated()`; nothing is sent before the daemon's window has
            // been checked.
            callRequested = true
            model.voiceConnecting()
            session.connect()
            return
        }

        beginCall()
    }

    private func endCall() {
        callRequested = false
        if model.voice.callActive {
            session.send(.callStop)
        }
        audio.endCall()
        model.voiceCallEnded()
    }

    private func beginCall() {
        model.voiceCallBegan()

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.audio.beginCall()
                guard self.model.voice.callActive else { return }
                self.session.send(.callStart)
            } catch {
                self.captureFailed(error)
            }
        }
    }

    private func captureFailed(_ error: any Error) {
        let sentence = (error as? CaptureError)?.errorDescription ?? ProductStrings[.voiceErrorMicrophoneUnknown]
        log.error("microphone capture failed: \(self.audio.diagnostics(), privacy: .public)")

        audio.endCall()
        model.voiceCaptureFailed(sentence)
        session.send(.callStop)
    }

    // MARK: - Session events

    private func negotiated() {
        model.voiceNegotiated()

        guard callRequested else { return }

        callRequested = false
        beginCall()
    }

    private func received(_ event: RealtimeServerEvent) {
        perform(model.apply(event, audioIsPlaying: audio.isPlayingBack))
    }

    private func failed(_ failure: VoiceSessionFailure) {
        callRequested = false
        audio.endCall()
        model.voiceFailed(failure)
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
