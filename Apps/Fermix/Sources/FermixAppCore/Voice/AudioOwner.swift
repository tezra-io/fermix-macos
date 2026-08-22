import Foundation

/// Why capture could not start. The sentences are product copy and live in the
/// catalogue; the numbers a defect needs are in `diagnostics()`, not here.
public enum CaptureError: Error, Equatable, Sendable, LocalizedError {
    case microphoneDenied
    case microphoneRestricted
    case noInputDevice
    case outputFormatUnavailable

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: return ProductStrings[.voiceErrorMicrophoneDenied]
        case .microphoneRestricted: return ProductStrings[.voiceErrorMicrophoneRestricted]
        case .noInputDevice: return ProductStrings[.voiceErrorNoInputDevice]
        case .outputFormatUnavailable: return ProductStrings[.voiceErrorOutputFormatUnavailable]
        }
    }
}

/// The audio engine, as the app sees it: permission, capture, playback, and
/// teardown. `AudioController` is the production implementation; the seam is
/// what lets the call lifecycle be proven without a microphone.
///
/// The protocol is deliberately not main-actor isolated: capture buffers arrive
/// on a Core Audio thread, and the two reporting callbacks are delivered on the
/// main queue by the implementation. `onChunk` is `@Sendable` because it is the
/// one closure the audio thread itself invokes.
public protocol VoiceAudioEngine: AnyObject {
    var onOutputLevel: ((Float) -> Void)? { get set }
    var onPlaybackDrained: (() -> Void)? { get set }
    var isPlayingBack: Bool { get }

    func requestCapturePermission() async throws
    /// Warms the capture path muted and handlerless, so nothing can leave the
    /// process before the daemon confirms it is listening.
    func prepareCapture() throws
    func beginStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws
    func setCaptureMuted(_ muted: Bool)
    func play(base64PCM16 encoded: String)
    func stopPlayback()
    func resetUtteranceAnchor()
    func currentUtterancePlayedMs() -> Int?
    func shutdown()
    func diagnostics() -> String
}

/// The one app-scoped owner of the microphone and the speaker.
///
/// It owns call and mute state and the capture lifecycle, and nothing else: it
/// holds no socket, decides no presentation, and never asks for permission
/// except at the start of a call the user began.
@MainActor
public final class AudioOwner {
    /// Smoothing applied to the per-chunk output level. Chunk-quantized RMS
    /// jitters; the pet's pulse should swell.
    private static let levelSmoothing: Float = 0.35

    public private(set) var callActive = false
    public private(set) var muted = false
    public private(set) var isStreaming = false

    public var onLevel: ((Float) -> Void)?
    public var onPlaybackDrained: (() -> Void)?

    public var isPlayingBack: Bool { engine.isPlayingBack }

    private let engine: any VoiceAudioEngine
    private let log = AppLog.logger(.voice)
    private var level: Float = 0

    public init(engine: any VoiceAudioEngine) {
        self.engine = engine

        // Both callbacks are delivered on the main queue by the engine, so the
        // owner's state is reached without a hop. Assuming isolation is what
        // says that out loud rather than leaving it implied.
        engine.onOutputLevel = { [weak self] value in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = (1 - Self.levelSmoothing) * self.level + Self.levelSmoothing * value
                self.onLevel?(self.level)
            }
        }
        engine.onPlaybackDrained = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.engine.isPlayingBack else { return }
                self.onPlaybackDrained?()
            }
        }
    }

    // MARK: - The call

    /// Asks for the microphone, then warms the capture engine muted and
    /// handlerless. Bring-up is the slow part of starting a call, so it happens
    /// while the daemon and the provider are still shaking hands; the two-stage
    /// gate is what makes that safe.
    public func beginCall() async throws {
        guard !callActive else { return }

        callActive = true
        muted = false
        isStreaming = false

        do {
            try await engine.requestCapturePermission()
            // The prompt is modal and outlives the call that raised it: a
            // transport drop or a hang-up while it was up already tore capture
            // down, and warming it now would leave the microphone indicator lit
            // with no call behind it and nothing left to end.
            guard callActive else { return }

            engine.setCaptureMuted(true)
            try engine.prepareCapture()
        } catch {
            endCall()
            throw error
        }
    }

    /// Attaches the chunk handler and unmutes. Called only when the daemon
    /// reports it is listening.
    ///
    /// The handler runs on the Core Audio thread, so it must reach the socket
    /// directly rather than through main-actor state: hopping every 100 ms
    /// chunk to the main queue would queue audio behind a busy main thread with
    /// none of the drop-oldest protection the socket's own buffer provides.
    public func startStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws {
        guard callActive, !isStreaming else { return }

        do {
            try engine.beginStreaming(onChunk: onChunk)
        } catch {
            endCall()
            throw error
        }

        isStreaming = true
        engine.setCaptureMuted(false)
    }

    public func setMuted(_ enabled: Bool) {
        muted = enabled
        engine.setCaptureMuted(enabled)
    }

    /// Tears capture all the way down, on every path, so macOS drops the
    /// microphone indicator as soon as the call ends.
    public func endCall() {
        callActive = false
        muted = false
        isStreaming = false
        level = 0
        engine.shutdown()
    }

    // MARK: - Playback

    public func play(base64PCM16 encoded: String) {
        engine.play(base64PCM16: encoded)
    }

    public func stopPlayback() {
        engine.stopPlayback()
    }

    public func resetUtteranceAnchor() {
        engine.resetUtteranceAnchor()
    }

    /// Stops playback and reports how much of the current utterance actually
    /// reached the speaker, which is what the daemon needs to truncate its own
    /// transcript on an interrupt.
    @discardableResult
    public func interruptPlayback() -> Int? {
        let played = engine.currentUtterancePlayedMs()
        engine.stopPlayback()
        return played
    }

    public func diagnostics() -> String {
        engine.diagnostics()
    }
}
