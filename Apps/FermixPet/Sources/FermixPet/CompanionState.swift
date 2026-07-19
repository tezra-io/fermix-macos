import AppKit
import Foundation
import SwiftUI

@MainActor
final class CompanionState: ObservableObject {
    enum Mode: String {
        case offline
        case idle
        case listening
        case muted
        case thinking
        case speaking
        case toolUse
        case error
    }

    @Published private(set) var mode: Mode = .offline
    @Published private(set) var connected = false
    @Published private(set) var callActive = false
    @Published private(set) var muted = false
    @Published private(set) var statusText = "offline"

    /// Normalized RMS (0...1) of the model's voice output, updated as PCM
    /// chunks are scheduled for playback; drives the speaking pulse. Plain
    /// var (not @Published) — the pet's TimelineView samples it every frame,
    /// so per-chunk updates need not invalidate the SwiftUI tree.
    private(set) var audioLevel: Float = 0

    /// Whether the pet window is on-screen (not occluded, minimized, or on
    /// another Space). Drives pausing the animation timeline when hidden.
    @Published private(set) var windowVisible = true

    /// True while the pet is actually playing voice audio. Set when a delta
    /// arrives, cleared when playback drains. The daemon flips `mode` back to
    /// listening as soon as the model stops *generating*, but the buffered
    /// audio keeps playing for seconds after — this tracks that real tail so
    /// the pet keeps its speaking look until the voice actually stops.
    @Published private(set) var audioActive = false

    private let socket = RealtimeSocketClient()
    private let audio = AudioController()
    private let socketPath: String
    private var captureStarted = false

    /// Wire protocol version this build speaks. Validated against the daemon's
    /// advertised range during the handshake before `connected` flips true.
    /// See `apps/fermix_core/priv/realtime/PROTOCOL.md`.
    private static let protocolVersion = 1
    private var handshaking = false
    private var pendingCallStart = false
    private var handshakeTimeout: DispatchWorkItem?

    init(socketPath: String = CompanionState.defaultSocketPath()) {
        self.socketPath = socketPath
        socket.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
        socket.onClose = { [weak self] in
            Task { @MainActor in self?.handlePeerClose() }
        }
        audio.onOutputLevel = { [weak self] level in
            // AudioController dispatches to main; assume isolation to write
            // without a Task hop. Exponential smoothing turns chunk-quantized
            // RMS into a smooth swell so the speaking pulse doesn't jitter.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioLevel = 0.65 * self.audioLevel + 0.35 * level
            }
        }
        audio.onPlaybackDrained = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.audio.isPlayingBack {
                    self.audioActive = false
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }
    }

    func shutdown() {
        // Best-effort: `socket.send` enqueues asynchronously, and on the quit
        // path (`quitApplication` → `NSApp.terminate`) the process can exit
        // before the socket queue drains this frame. That is intentional — the
        // daemon treats the socket EOF that follows the pet exiting as the real
        // call teardown (it must, to survive pet crashes), so a `call_stop` that
        // never reaches the wire changes nothing. We do not block the quit path
        // to guarantee delivery: a synchronous drain here is exactly the
        // main-thread-on-the-socket-queue wait this transport was rewritten to
        // remove.
        if connected && callActive {
            socket.send(["type": "call_stop"])
        }

        cancelHandshakeTimeout()
        handshaking = false
        pendingCallStart = false
        callActive = false
        muted = false
        captureStarted = false
        shutdownAudio()
        socket.close()
        connected = false
    }

    func quitApplication() {
        shutdown()
        NSApp.terminate(nil)
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
    }

    nonisolated private static func defaultSocketPath() -> String {
        let environment = ProcessInfo.processInfo.environment

        if let socket = environment["FERMIX_REALTIME_SOCKET"], !socket.isEmpty {
            return (socket as NSString).expandingTildeInPath
        }

        if let home = environment["FERMIX_HOME"], !home.isEmpty {
            let expandedHome = (home as NSString).expandingTildeInPath
            return (expandedHome as NSString).appendingPathComponent("realtime.sock")
        }

        return ("~/.fermix/realtime.sock" as NSString).expandingTildeInPath
    }

    var tint: Color {
        switch mode {
        case .offline: return Color.gray
        case .idle: return Color.teal
        case .listening: return Color.green
        case .muted: return Color.red
        case .thinking: return Color.indigo
        case .speaking: return Color.orange
        case .toolUse: return Color.purple
        case .error: return Color.red
        }
    }

    var iconName: String {
        switch mode {
        case .offline: return "wifi.slash"
        case .idle: return "circle"
        case .listening: return "mic.fill"
        case .muted: return "mic.slash.fill"
        case .thinking: return "sparkles"
        case .speaking: return "waveform"
        case .toolUse: return "wrench.and.screwdriver"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Mode for presentation only. While voice audio is still playing out, the
    /// pet reads as speaking even though `mode` (server turn state) has already
    /// returned to listening/idle. `mode` itself — and all mic/turn logic keyed
    /// off it — is deliberately left untouched.
    var visualMode: Mode {
        (callActive && audioActive) ? .speaking : mode
    }

    var petExpression: PetExpression {
        PetExpression.resolve(for: visualMode, callActive: callActive)
    }

    func toggleConnection() {
        connected ? disconnect() : connect()
    }

    func connect() {
        do {
            try socket.connect(path: socketPath)
            // Stay unconnected until the daemon's server_hello arrives and its
            // version range is validated. `connected` flips true only in
            // completeHandshake(event:).
            handshaking = true
            mode = .idle
            statusText = "connecting"
            socket.send(["type": "client_hello", "protocol_version": Self.protocolVersion])
            startHandshakeTimeout()
            debugLog("client_hello v\(Self.protocolVersion) sent; awaiting server_hello: \(socketPath)")
        } catch {
            handleConnectFailure(error)
        }
    }

    private func handleConnectFailure(_ error: Error) {
        cancelHandshakeTimeout()
        handshaking = false
        pendingCallStart = false
        connected = false
        callActive = false
        mode = .error
        statusText = "offline"
        debugLog("realtime socket connect failed: \(String(describing: error)); path=\(socketPath)")
    }

    func disconnect() {
        endCall()
        cancelHandshakeTimeout()
        handshaking = false
        pendingCallStart = false
        socket.close()
        connected = false
        mode = .offline
        statusText = "offline"
    }

    func toggleCall() {
        if callActive {
            endCall()
        } else {
            startCall()
        }
    }

    func startCall() {
        if callActive {
            return
        }

        if connected {
            beginCallFlow()
            return
        }

        // Not connected yet. Record the intent and drive the handshake; the
        // call begins from completeHandshake(event:) once the daemon's
        // server_hello validates. Never send call_start before connected.
        pendingCallStart = true

        if !handshaking {
            connect()
        }

        if !handshaking && !connected {
            // connect() failed synchronously (socket refused).
            pendingCallStart = false
            statusText = "demo (daemon offline)"
        } else {
            statusText = "connecting"
        }
    }

    private func beginCallFlow() {
        callActive = true
        muted = false
        captureStarted = false
        // Don't unmute here — `beginStreaming(onChunk:)` (called by
        // `startCaptureIfNeeded()` when the server confirms listening
        // state) is what unmutes and attaches the chunk handler. Keeping
        // the path muted until then guarantees no audio reaches the
        // socket between callActive=true and the server's go-ahead.
        mode = .idle
        statusText = "checking mic"

        Task { @MainActor in
            await beginCall()
        }
    }

    private func beginCall() async {
        do {
            try await audio.requestCapturePermission()
            guard callActive else { return }

            // Warm the capture engine now — muted and handlerless, so no
            // audio can leave the process — instead of after the server's
            // "listening" arrives. The engine bring-up is the slow part of
            // call start; doing it before the daemon/provider handshake
            // means the mic is already hot when the UI goes green, so the
            // first words are never lost to warm-up.
            try audio.prepareCapture()
            guard callActive else { return }

            socket.send(["type": "call_start"])
            statusText = "starting"
        } catch {
            mode = .error
            callActive = false
            captureStarted = false
            if connected {
                socket.send(["type": "call_stop"])
            }
            statusText = captureErrorMessage(error)
            debugLog(
                "microphone capture failed: \(statusText); error=\(String(describing: error)); diagnostics=\(audio.diagnostics())"
            )
        }
    }

    func endCall() {
        // Tear capture down fully so macOS clears the microphone privacy
        // indicator as soon as the local call ends.
        shutdownAudio()
        captureStarted = false
        if connected {
            socket.send(["type": "call_stop"])
        }
        callActive = false
        muted = false
        if connected {
            mode = .idle
            statusText = "idle"
        } else {
            mode = .offline
            statusText = "offline"
        }
    }

    func playTestTone() {
        audio.playTestTone()
    }

    func playSystemBeep() {
        NSSound.beep()
    }

    func toggleMute() {
        setMuted(!muted)
    }

    private func setMuted(_ enabled: Bool) {
        muted = enabled
        audio.setCaptureMuted(enabled)

        if connected && callActive {
            socket.send(["type": "mute", "enabled": enabled])
        }

        if callActive {
            mode = enabled ? .muted : .listening
            statusText = enabled ? "muted" : "listening"
        }
    }

    func interrupt() {
        sendInterruptForCurrentPlayback()
        mode = connected && callActive ? activeInputMode : (connected ? .idle : .offline)
        statusText = mode.rawValue
    }

    private func handle(event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        if handshaking {
            handleHandshakeEvent(type: type, event: event)
            return
        }

        switch type {
        case "state":
            let next = event["state"] as? String ?? "idle"
            let previous = mode

            if next == "muted" {
                muted = true
                audio.setCaptureMuted(true)
            } else if next == "idle" {
                muted = false
                audio.setCaptureMuted(false)
            }

            mode = muted && next == "listening" ? .muted : (Mode(rawValue: next) ?? .idle)
            statusText = mode.rawValue

            if next == "listening" {
                startCaptureIfNeeded()
            }

            if previous == .speaking && mode != .speaking {
                audio.resetUtteranceAnchor()
            }

            // The visual "speaking" tail is owned by real playback; once the
            // server has moved on and no audio remains, drop it.
            if !audio.isPlayingBack {
                audioActive = false
            }
        case "audio_delta":
            if let encoded = event["audio"] as? String {
                mode = .speaking
                statusText = "speaking"
                audioActive = true
                audio.play(base64PCM16: encoded)
            }
        case "playback_stop":
            audio.stopPlayback()
            audio.resetUtteranceAnchor()
            audioActive = false
            if callActive {
                mode = activeInputMode
                statusText = mode.rawValue
            }
        case "tool_event":
            switch event["status"] as? String {
            case "completed":
                if callActive {
                    mode = .toolUse
                    statusText = "tool"
                } else {
                    mode = .idle
                    statusText = "idle"
                }
            case "error":
                mode = .error
                statusText = event["reason"] as? String ?? "tool error"
            default:
                mode = .toolUse
                statusText = "tool"
            }
        case "error":
            mode = .error
            statusText = event["reason"] as? String ?? "error"
            // Server signalled an error — detach handler so no in-flight
            // mic buffer races back to the possibly-broken socket.
            shutdownAudio()
            callActive = false
            muted = false
            captureStarted = false
        case "server_hello":
            debugLog("ignoring server_hello received after handshake")
        default:
            debugLog("unhandled realtime server event: \(type)")
        }
    }

    // MARK: - Handshake

    private func handleHandshakeEvent(type: String, event: [String: Any]) {
        switch type {
        case "server_hello":
            completeHandshake(event: event)
        case "error":
            failHandshake(event: event)
        default:
            // An old daemon may emit `state` before/instead of server_hello;
            // ignore until server_hello lands or the handshake times out.
            debugLog("ignoring \(type) while awaiting server_hello")
        }
    }

    private func completeHandshake(event: [String: Any]) {
        guard handshaking else { return }
        cancelHandshakeTimeout()

        let minVersion = intField(event, "min_version") ?? 0
        let maxVersion = intField(event, "max_version") ?? 0

        guard Self.protocolVersion >= minVersion, Self.protocolVersion <= maxVersion else {
            handshaking = false
            pendingCallStart = false
            connected = false
            mode = .error
            statusText = Self.protocolVersion > maxVersion ? "update Fermix" : "update FermixPet"
            socket.close()
            debugLog(
                "protocol mismatch: pet v\(Self.protocolVersion), daemon [\(minVersion),\(maxVersion)]"
            )
            return
        }

        handshaking = false
        connected = true
        mode = .idle
        statusText = "idle"
        debugLog("handshake ok: pet v\(Self.protocolVersion), daemon [\(minVersion),\(maxVersion)]")

        if pendingCallStart {
            pendingCallStart = false
            beginCallFlow()
        }
    }

    private func failHandshake(event: [String: Any]) {
        guard handshaking else { return }
        cancelHandshakeTimeout()
        handshaking = false
        pendingCallStart = false
        connected = false
        mode = .error

        let reason = event["reason"] as? String ?? "handshake failed"

        if reason == "unsupported_protocol_version" {
            let direction = event["direction"] as? String
            statusText = direction == "client_too_old" ? "update FermixPet" : "update Fermix"
        } else {
            statusText = reason
        }

        socket.close()
        debugLog("handshake rejected: \(reason)")
    }

    private func startHandshakeTimeout() {
        cancelHandshakeTimeout()

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.handshakeTimedOut()
            }
        }

        handshakeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func cancelHandshakeTimeout() {
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
    }

    private func handshakeTimedOut() {
        guard handshaking else { return }
        handshaking = false
        pendingCallStart = false
        connected = false
        mode = .error
        // Socket connected but no server_hello — the daemon predates the
        // handshake. The actionable fix is updating Fermix.
        statusText = "update Fermix"
        socket.close()
        debugLog("handshake timed out; no server_hello from daemon")
    }

    private func intField(_ event: [String: Any], _ key: String) -> Int? {
        if let value = event[key] as? Int {
            return value
        }

        if let value = event[key] as? NSNumber {
            return value.intValue
        }

        return nil
    }

    private func startCaptureIfNeeded() {
        guard callActive && !captureStarted else { return }

        do {
            // Attaches the chunk handler, starts capture if needed, and
            // unmutes only after the server confirms listening state.
            try audio.beginStreaming { [weak self] chunk in
                self?.socket.sendAudioChunk(chunk)
            }
            captureStarted = true
            statusText = activeInputMode.rawValue
        } catch {
            mode = .error
            callActive = false
            captureStarted = false
            if connected {
                socket.send(["type": "call_stop"])
            }
            statusText = captureErrorMessage(error)
            debugLog(
                "microphone capture failed: \(statusText); error=\(String(describing: error)); diagnostics=\(audio.diagnostics())"
            )
        }
    }

    private func sendInterruptForCurrentPlayback() {
        let playedMs = audio.currentUtterancePlayedMs()
        audio.stopPlayback()
        audioActive = false

        if connected {
            var payload: [String: Any] = ["type": "interrupt"]
            if let ms = playedMs {
                payload["audio_end_ms"] = ms
            }
            socket.send(payload)
        }
    }

    private var activeInputMode: Mode {
        muted ? .muted : .listening
    }

    private func handlePeerClose() {
        // Daemon socket dropped from the other end. Tear the mic all the
        // way down — there's nothing to stream to.
        cancelHandshakeTimeout()
        handshaking = false
        pendingCallStart = false
        shutdownAudio()
        callActive = false
        muted = false
        captureStarted = false
        connected = false

        if mode != .error {
            mode = .offline
            statusText = "offline"
        }
    }

    private func captureErrorMessage(_ error: Error) -> String {
        if let error = error as? AudioController.CaptureError {
            return error.localizedDescription
        }

        return "mic unavailable"
    }

    private func debugLog(_ message: String) {
        NSLog("FermixPet: %@", message)
    }

    private func shutdownAudio() {
        audio.shutdown()
        audioLevel = 0
        audioActive = false
    }
}
