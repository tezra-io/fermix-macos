import AVFoundation
import Foundation

/// The production `VoiceAudioEngine`: 24 kHz mono PCM16 both ways, a warmed
/// muted capture path, and a teardown that releases the input unit so macOS
/// clears the microphone indicator.
final class AudioController: VoiceAudioEngine {
    private static let realtimeSampleRate = 24_000.0
    private static let captureBufferFrames: AVAudioFrameCount = 4_800

    private let log = AppLog.logger(.voice)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat
    private var captureTapInstalled = false
    private var utteranceAnchorSampleTime: AVAudioFramePosition?
    private let playbackCounterLock = NSLock()
    private var pendingPlaybackBuffers = 0
    private let captureMuteLock = NSLock()
    private var captureMuted = true
    private let chunkHandlerLock = NSLock()
    private var onChunkHandler: (@Sendable (Data) -> Void)?

    /// Invoked on the main thread with the RMS amplitude (0...1) of each
    /// played PCM chunk. Drives the mascot's speaking-pulse visual.
    var onOutputLevel: ((Float) -> Void)?

    /// Invoked on the main thread when the last scheduled playback buffer
    /// finishes — i.e. audio has actually stopped leaving the speaker, which
    /// is seconds after the model finished generating it. Lets the pet read as
    /// speaking for the true audio duration, not just the delivery window.
    var onPlaybackDrained: (() -> Void)?

    var isPlayingBack: Bool {
        playbackCounterLock.lock()
        defer { playbackCounterLock.unlock() }
        return pendingPlaybackBuffers > 0
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
    /// call flow only (after the permission gate) so the slow engine bring-up
    /// overlaps the daemon/provider handshake instead of running after the
    /// server already reports listening.
    func prepareCapture() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.microphoneDenied
        }

        chunkHandlerLock.lock()
        onChunkHandler = nil
        chunkHandlerLock.unlock()
        setCaptureMuted(true)

        try ensureCaptureRunning()
    }

    /// Attach a chunk handler and unmute so capture starts pushing data
    /// to the socket. The caller must have already awaited
    /// `requestCapturePermission()` — this throws `.microphoneDenied` if
    /// permission isn't in hand.
    func beginStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.microphoneDenied
        }

        try ensureCaptureRunning()

        chunkHandlerLock.lock()
        onChunkHandler = onChunk
        chunkHandlerLock.unlock()

        setCaptureMuted(false)
    }

    /// Idempotent: installs the tap, starts the engine, and leaves the
    /// capture path muted+handlerless. Safe to call repeatedly.
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
        var format = Self.captureFormat(from: input)

        if format == nil {
            try startEngineIfNeeded()
            format = Self.captureFormat(from: input)
        }

        guard let format else { throw CaptureError.noInputDevice }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.realtimeSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.outputFormatUnavailable
        }

        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
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

    private func stopCapture() {
        // Belt: clear the handler so any tap callback racing with teardown
        // can't fire a write to the socket.
        chunkHandlerLock.lock()
        onChunkHandler = nil
        chunkHandlerLock.unlock()

        setCaptureMuted(true)

        // Braces: remove the tap so no further callbacks even occur.
        if captureTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            captureTapInstalled = false
        }
    }

    func setCaptureMuted(_ muted: Bool) {
        captureMuteLock.lock()
        captureMuted = muted
        captureMuteLock.unlock()
    }

    func shutdown() {
        stopCapture()
        stopPlayback()

        // Voice processing keeps the audio session and the macOS mic
        // indicator alive even after engine.stop() — disable it explicitly
        // before tearing down the engine.
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }

        if engine.isRunning {
            engine.stop()
        }

        // Release the input AudioUnit so the OS sees the mic session as
        // terminated; without this the privacy indicator persists.
        engine.reset()
    }

    func diagnostics() -> String {
        let auth = Self.authorizationDescription(AVCaptureDevice.authorizationStatus(for: .audio))
        // AVFoundation's view (may say none on macOS even when Core Audio
        // sees a device — see ensureCaptureRunning for the API mismatch).
        let avfDevice = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
        // Core Audio HAL's view via AVAudioEngine — this is what actually
        // backs capture. A valid sample rate + channel count means the
        // engine has a usable input regardless of what AVFoundation reports.
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let voiceProcessing = input.isVoiceProcessingEnabled ? "enabled" : "disabled"
        let engineHasInput = Self.captureFormat(from: input) != nil

        return "auth=\(auth), avfDevice=\(avfDevice), engineHasInput=\(engineHasInput), inputSampleRate=\(inputFormat.sampleRate), inputChannels=\(inputFormat.channelCount), outputSampleRate=\(outputFormat.sampleRate), outputChannels=\(outputFormat.channelCount), voiceProcessing=\(voiceProcessing), engineRunning=\(engine.isRunning)"
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

        if !engine.isRunning {
            do {
                try startEngineIfNeeded()
            } catch {
                log.error("playback engine failed to start: \(String(describing: error), privacy: .public)")
                return
            }
        }

        let wasPlaying = player.isPlaying

        playbackCounterLock.lock()
        pendingPlaybackBuffers += 1
        playbackCounterLock.unlock()

        player.scheduleBuffer(buffer, completionHandler: { [weak self] in
            guard let self else { return }
            self.playbackCounterLock.lock()
            self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
            let drained = self.pendingPlaybackBuffers == 0
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
        guard let callback = onOutputLevel else { return }
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return }

        let rms = data.withUnsafeBytes { raw -> Float in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return 0
            }
            var sumSquares: Float = 0
            let scale: Float = 1.0 / Float(Int16.max)
            for index in 0..<count {
                let sample = Float(ptr[index]) * scale
                sumSquares += sample * sample
            }
            return (sumSquares / Float(count)).squareRoot()
        }

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
        player.stop()
        utteranceAnchorSampleTime = nil

        playbackCounterLock.lock()
        pendingPlaybackBuffers = 0
        playbackCounterLock.unlock()
    }

    func resetUtteranceAnchor() {
        utteranceAnchorSampleTime = nil
    }

    func currentUtterancePlayedMs() -> Int? {
        guard let anchor = utteranceAnchorSampleTime,
              let current = currentPlayerSampleTime() else {
            return nil
        }

        let frames = max(0, current - anchor)
        let ms = Double(frames) / Self.realtimeSampleRate * 1_000.0
        return Int(ms.rounded())
    }

    private func currentPlayerSampleTime() -> AVAudioFramePosition? {
        guard let lastRender = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: lastRender) else {
            return nil
        }

        return playerTime.sampleTime
    }

    private static func pcm16Data(
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
