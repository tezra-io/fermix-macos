import AVFoundation
import Foundation

/// The production `VoiceAudioEngine`: 24 kHz mono PCM16 both ways, a warmed
/// muted capture path cleaned by macOS voice processing, and a teardown that
/// releases the input unit so macOS clears the microphone indicator.
///
/// The engine and the player are used on `queue` alone. Warming capture the
/// first time in a process builds macOS's voice processing unit, which held
/// the main thread for 1.7 seconds on 2026-10-08 (0.2 seconds on later calls),
/// so the chat's call box drew only once it was done. On one serial queue the
/// warm-up runs off the main thread and every other use keeps its order: a
/// teardown asked for while capture is still coming up runs after it.
final class AudioController: VoiceAudioEngine {
    private static let realtimeSampleRate = 24_000.0
    private static let captureBufferFrames: AVAudioFrameCount = 4_800

    private let log = AppLog.logger(.voice)
    private let queue = DispatchQueue(label: "ai.fermix.app.voice-audio", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat
    private var captureTapInstalled = false
    private var utteranceAnchorSampleTime: AVAudioFramePosition?
    private let playbackCounterLock = NSLock()
    private var pendingVoiceBuffers = 0
    private let captureMuteLock = NSLock()
    private var captureMuted = true
    private let chunkHandlerLock = NSLock()
    private var onChunkHandler: (@Sendable (Data) -> Void)?

    /// Invoked on the main thread with the RMS amplitude (0...1) of each
    /// played PCM chunk. Drives the mascot's speaking-pulse visual.
    var onOutputLevel: ((Float) -> Void)?

    /// Invoked on the main thread when the last scheduled buffer that carries
    /// voice finishes — i.e. the reply has actually stopped leaving the
    /// speaker, which is seconds after the model finished generating it. Lets
    /// the pet read as speaking for the true audio duration, not just the
    /// delivery window. Only voice counts: Live pads its output with silence
    /// for the whole call, so a queue that holds padding never empties
    /// (`PCM16`).
    var onPlaybackDrained: (() -> Void)?

    /// Whether voice is still queued or playing. Padding does not count.
    var isPlayingBack: Bool {
        playbackCounterLock.lock()
        defer { playbackCounterLock.unlock() }
        return pendingVoiceBuffers > 0
    }

    init() {
        self.playbackFormat = AVAudioFormat(standardFormatWithSampleRate: Self.realtimeSampleRate, channels: 1)!

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.mainMixerNode.outputVolume = 1.0
    }

    func requestCapturePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }

            if !granted {
                throw CaptureError.microphoneDenied
            }
        case .denied:
            throw CaptureError.microphoneDenied
        case .restricted:
            throw CaptureError.microphoneRestricted
        @unknown default:
            throw CaptureError.microphoneDenied
        }
    }

    /// Warm the capture pipeline without exposing any audio: installs the
    /// tap and starts the engine with the path muted and handlerless, so the
    /// tap's two-stage gate drops every buffer on the floor. Called from the
    /// call flow only (after the permission gate), and run on the queue, so
    /// the slow bring-up neither holds the main thread nor runs after the
    /// server already reports listening.
    func prepareCapture() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.microphoneDenied
        }

        silenceCapture()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            warmCapture { continuation.resume(with: $0) }
        }
    }

    /// Runs the warm-up on the queue and reports its outcome from there.
    private func warmCapture(_ finished: @escaping (Result<Void, any Error>) -> Void) {
        queue.async {
            finished(Result { try self.ensureCaptureRunning() })
        }
    }

    /// Attach a chunk handler and unmute so capture starts pushing data
    /// to the socket. The caller must have already awaited
    /// `requestCapturePermission()` — this throws `.microphoneDenied` if
    /// permission isn't in hand.
    func beginStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.microphoneDenied
        }

        try queue.sync { try ensureCaptureRunning() }

        chunkHandlerLock.lock()
        onChunkHandler = onChunk
        chunkHandlerLock.unlock()

        setCaptureMuted(false)
    }

    /// Idempotent: installs the tap, starts the engine, and leaves the
    /// capture path muted+handlerless. Safe to call repeatedly. On the queue.
    private func ensureCaptureRunning() throws {
        if captureTapInstalled {
            try startEngineIfNeeded()
            return
        }

        // Device-availability check via AVAudioEngine's Core Audio-backed
        // input format, NOT AVCaptureDevice.default(for: .audio).
        //
        // On macOS, AVCaptureDevice (AVFoundation capture framework) and
        // AVAudioEngine.inputNode (Core Audio HAL) are different subsystems
        // and DISAGREE about which devices exist. AVCaptureDevice.default
        // can return nil — e.g. when no AVFoundation-classified capture
        // device is the system default — while AVAudioEngine.inputNode
        // still has a valid 44100/2ch (or similar) input from a USB or
        // Bluetooth interface visible to Core Audio. The engine is what
        // actually captures, so its format is the authoritative signal.
        //
        // We engage the engine first (which lazily binds to the current
        // Core Audio input) and only fall through to noInputDevice if the
        // engine itself reports no usable format. The auth gate is upstream
        // in beginStreaming; this guard only fires when there
        // is literally no mic Core Audio can see.
        let input = engine.inputNode

        if Self.captureFormat(from: input) == nil {
            try startEngineIfNeeded()
        }

        guard Self.captureFormat(from: input) != nil else { throw CaptureError.noInputDevice }

        // Voice processing reshapes the input, so the tap's format is read
        // after it is switched on.
        try enableVoiceProcessing(on: input)

        guard let format = Self.captureFormat(from: input) else { throw CaptureError.noInputDevice }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.realtimeSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.outputFormatUnavailable
        }

        guard let converter = Self.captureConverter(from: format, to: outputFormat) else {
            throw CaptureError.outputFormatUnavailable
        }

        input.installTap(onBus: 0, bufferSize: Self.captureBufferFrames, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Two-stage gate: muted OR no handler ⇒ drop the buffer on
            // the floor. Both conditions are independently sufficient.
            // Nothing leaves the process unless an active call has both
            // wired a handler AND unmuted the capture path.
            guard !self.isCaptureMuted() else { return }

            self.chunkHandlerLock.lock()
            let handler = self.onChunkHandler
            self.chunkHandlerLock.unlock()

            guard let handler = handler else { return }

            let data = Self.pcm16Data(from: buffer, converter: converter, outputFormat: outputFormat)
            if !data.isEmpty {
                handler(data)
            }
        }
        captureTapInstalled = true

        do {
            try startEngineIfNeeded()
        } catch {
            stopCapture()
            throw error
        }
    }

    /// Echo cancellation, noise suppression and voice gain, from macOS. Neither
    /// voice API does this for the pet: GPT-Live takes no noise, echo or turn
    /// detection settings at all, and Realtime's noise reduction runs on the
    /// server, after the pet's own voice has already come back through the
    /// microphone. Measured on 2026-09-28 (USB microphone, display speakers),
    /// it lifts speech clear of key clicks by about 9 dB over the raw input.
    /// It did not remove the echo on that route, whose audio arrives about
    /// 90 ms after the 2 ms the display reports; the daemon takes no words
    /// heard during a reply, or for 2 s after it, as the operator's for that
    /// reason.
    ///
    /// Other audio is ducked as little as macOS allows, and only while someone
    /// speaks, so a call does not quiet everything else for its whole length.
    private func enableVoiceProcessing(on input: AVAudioInputNode) throws {
        guard !input.isVoiceProcessingEnabled else { return }

        // It can only be switched on a stopped engine, and the device check
        // before it may have started this one.
        if engine.isRunning {
            engine.stop()
        }

        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw CaptureError.voiceProcessingUnavailable
        }

        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: true,
            duckingLevel: .min
        )
    }

    /// The converter from the tap's format to the 24 kHz mono the call sends,
    /// reading channel 0 only.
    ///
    /// With voice processing on, macOS hands the tap several channels (six
    /// from a two-channel USB microphone, measured 2026-09-28), and a
    /// converter left to map them to mono by itself produces digital silence:
    /// the call would stream nothing but zeros. The processed voice is on
    /// channel 0.
    static func captureConverter(from format: AVAudioFormat, to outputFormat: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else { return nil }

        converter.channelMap = [0]
        return converter
    }

    /// On the queue.
    private func stopCapture() {
        silenceCapture()

        // Braces: remove the tap so no further callbacks even occur.
        if captureTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            captureTapInstalled = false
        }
    }

    /// Belt: clear the handler and mute, so any tap callback racing with
    /// teardown can't fire a write to the socket. Locks only, so it holds on
    /// any thread, before the queue has reached the teardown.
    private func silenceCapture() {
        chunkHandlerLock.lock()
        onChunkHandler = nil
        chunkHandlerLock.unlock()

        setCaptureMuted(true)
    }

    func setCaptureMuted(_ muted: Bool) {
        captureMuteLock.lock()
        captureMuted = muted
        captureMuteLock.unlock()
    }

    /// Nothing leaves the process from the moment it is called; the engine
    /// comes down on the queue, after any warm-up still running there.
    func shutdown() {
        silenceCapture()
        clearPendingVoice()

        queue.async {
            self.stopCapture()
            self.stopPlayer()

            // Voice processing keeps the audio session and the macOS mic
            // indicator alive even after engine.stop() — disable it explicitly
            // before tearing down the engine.
            if self.engine.inputNode.isVoiceProcessingEnabled {
                try? self.engine.inputNode.setVoiceProcessingEnabled(false)
            }

            if self.engine.isRunning {
                self.engine.stop()
            }

            // Release the input AudioUnit so the OS sees the mic session as
            // terminated; without this the privacy indicator persists.
            self.engine.reset()
        }
    }

    func diagnostics() -> String {
        let auth = Self.authorizationDescription(AVCaptureDevice.authorizationStatus(for: .audio))
        // AVFoundation's view (may say none on macOS even when Core Audio
        // sees a device — see ensureCaptureRunning for the API mismatch).
        let avfDevice = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
        // Core Audio HAL's view via AVAudioEngine — this is what actually
        // backs capture. A valid sample rate + channel count means the
        // engine has a usable input regardless of what AVFoundation reports.
        let engineView = queue.sync {
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            let voiceProcessing = input.isVoiceProcessingEnabled ? "enabled" : "disabled"
            let engineHasInput = Self.captureFormat(from: input) != nil

            return "engineHasInput=\(engineHasInput), inputSampleRate=\(inputFormat.sampleRate), inputChannels=\(inputFormat.channelCount), outputSampleRate=\(outputFormat.sampleRate), outputChannels=\(outputFormat.channelCount), voiceProcessing=\(voiceProcessing), engineRunning=\(engine.isRunning)"
        }

        return "auth=\(auth), avfDevice=\(avfDevice), \(engineView)"
    }

    func play(base64PCM16 encoded: String) {
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            log.error("playback skipped: the daemon sent an empty or undecodable audio chunk")
            return
        }

        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount) else {
            log.error("playback skipped: no buffer for \(frameCount, privacy: .public) frames")
            return
        }
        buffer.frameLength = frameCount

        Self.fillFloatBuffer(buffer, fromPCM16: data)
        emitOutputLevel(from: data)
        let voiced = PCM16.isVoiced(data)

        queue.sync { schedule(buffer, voiced: voiced) }
    }

    /// On the queue.
    private func schedule(_ buffer: AVAudioPCMBuffer, voiced: Bool) {
        if !engine.isRunning {
            do {
                try startEngineIfNeeded()
            } catch {
                log.error("playback engine failed to start: \(String(describing: error), privacy: .public)")
                return
            }
        }

        let wasPlaying = player.isPlaying

        if voiced {
            playbackCounterLock.lock()
            pendingVoiceBuffers += 1
            playbackCounterLock.unlock()
        }

        player.scheduleBuffer(buffer, completionHandler: { [weak self] in
            guard let self, voiced else { return }
            self.playbackCounterLock.lock()
            self.pendingVoiceBuffers = max(0, self.pendingVoiceBuffers - 1)
            let drained = self.pendingVoiceBuffers == 0
            self.playbackCounterLock.unlock()

            if drained {
                DispatchQueue.main.async { self.onPlaybackDrained?() }
            }
        })

        if !wasPlaying {
            player.play()
            utteranceAnchorSampleTime = currentPlayerSampleTime() ?? 0
        }
    }

    /// Compute RMS over the raw PCM16 chunk and dispatch to the main thread,
    /// where `AudioOwner` smooths it into the level the pet draws. Cheap:
    /// ~512 multiply-adds per chunk for a 24 kHz Realtime frame.
    private func emitOutputLevel(from data: Data) {
        guard let callback = onOutputLevel, data.count >= MemoryLayout<Int16>.size else { return }
        let rms = PCM16.rms(data) / Float(Int16.max)

        DispatchQueue.main.async {
            callback(rms)
        }
    }

    private static func fillFloatBuffer(_ buffer: AVAudioPCMBuffer, fromPCM16 data: Data) {
        guard let dest = buffer.floatChannelData?[0] else { return }
        let scale: Float = 1.0 / Float(Int16.max)
        let sampleCount = Int(buffer.frameLength)

        data.withUnsafeBytes { raw in
            guard let int16Source = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<sampleCount {
                dest[index] = Float(int16Source[index]) * scale
            }
        }
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func isCaptureMuted() -> Bool {
        captureMuteLock.lock()
        defer { captureMuteLock.unlock() }
        return captureMuted
    }

    private static func captureFormat(from input: AVAudioInputNode) -> AVAudioFormat? {
        captureFormat(hardware: input.inputFormat(forBus: 0), output: input.outputFormat(forBus: 0))
    }

    /// The format the capture tap is installed at, or nil when Core Audio has
    /// no usable input.
    ///
    /// The input node's hardware format is the truth about the device: with no
    /// default input it reports no sample rate and no channels, while the
    /// node's output format keeps its nominal stereo 44.1 kHz. A tap installed
    /// at that nominal format on an invalid hardware input raises an
    /// Objective-C exception inside AVFAudio ("input hw format invalid",
    /// "Failed to create tap due to format mismatch") that no Swift frame can
    /// catch; on 2026-09-06 it unwound through the call's async continuation
    /// and the next button press aborted the process. So the hardware format
    /// decides whether capture can run at all, and the tap is installed at the
    /// bus's output format only once the hardware has one.
    static func captureFormat(hardware: AVAudioFormat, output: AVAudioFormat) -> AVAudioFormat? {
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return nil }
        guard output.sampleRate > 0, output.channelCount > 0 else { return hardware }

        return output
    }

    func stopPlayback() {
        queue.sync { stopPlayer() }
    }

    /// On the queue.
    private func stopPlayer() {
        player.stop()
        utteranceAnchorSampleTime = nil
        clearPendingVoice()
    }

    private func clearPendingVoice() {
        playbackCounterLock.lock()
        pendingVoiceBuffers = 0
        playbackCounterLock.unlock()
    }

    func resetUtteranceAnchor() {
        queue.sync { utteranceAnchorSampleTime = nil }
    }

    func currentUtterancePlayedMs() -> Int? {
        queue.sync {
            guard let anchor = utteranceAnchorSampleTime,
                  let current = currentPlayerSampleTime() else {
                return nil
            }

            let frames = max(0, current - anchor)
            let ms = Double(frames) / Self.realtimeSampleRate * 1_000.0
            return Int(ms.rounded())
        }
    }

    private func currentPlayerSampleTime() -> AVAudioFramePosition? {
        guard let lastRender = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: lastRender) else {
            return nil
        }

        return playerTime.sampleTime
    }

    static func pcm16Data(
        from buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data {
        let sampleRatio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * sampleRatio) + 8))
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return Data()
        }

        var providedInput = false
        var conversionError: NSError?

        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            providedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else { return Data() }
        return pcm16Data(fromFloatBuffer: converted)
    }

    private static func pcm16Data(fromFloatBuffer buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }

        guard let floats = buffer.floatChannelData else { return Data() }
        var output = Data(capacity: frames * MemoryLayout<Int16>.size)

        for index in 0..<frames {
            let sample = max(-1.0, min(1.0, floats[0][index]))
            var pcm = Int16(sample * Float(Int16.max)).littleEndian
            output.append(Data(bytes: &pcm, count: MemoryLayout<Int16>.size))
        }

        return output
    }

    private static func authorizationDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
}
