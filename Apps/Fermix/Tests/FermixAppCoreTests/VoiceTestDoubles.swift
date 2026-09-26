import Foundation

@testable import FermixAppCore

/// The realtime daemon's side of the socket, driven by hand: a session built
/// over `RealtimeSocketClient(lines:)` on one of these crosses the real adapter
/// in both directions, and a case reads back the lines it put on the wire.
typealias FakeRealtimeSocket = FakeLineSocketTransport<RealtimeServerEvent, RealtimeDecodeFailure>

/// The object a client event goes on the wire as, for comparing against what a
/// fake line socket recorded.
func wireObject(_ event: RealtimeClientEvent) throws -> NSDictionary {
    try wireObject(event.line())
}

/// A deadline scheduler a test drives by hand.
@MainActor
final class ManualDeadlineScheduler: DeadlineScheduling {
    private final class Token: DeadlineToken {
        var work: (() -> Void)?
        var cancelled = false

        func cancel() {
            cancelled = true
            work = nil
        }
    }

    private var tokens: [(seconds: TimeInterval, token: Token)] = []

    var scheduledDelays: [TimeInterval] { tokens.filter { !$0.token.cancelled }.map(\.seconds) }
    var liveCount: Int { tokens.filter { !$0.token.cancelled }.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> DeadlineToken {
        let token = Token()
        token.work = work
        tokens.append((seconds, token))
        return token
    }

    /// Fires every deadline that has not been cancelled.
    func fireAll() {
        let live = tokens.filter { !$0.token.cancelled }
        tokens.removeAll()
        for entry in live {
            entry.token.work?()
        }
    }
}

/// Records every call the audio owner makes, so the call lifecycle can be
/// proven without AVFoundation, a microphone, or a permission prompt.
///
/// Non-isolated for the same reason the real engine is: capture buffers arrive
/// on an audio thread in production.
final class FakeVoiceAudioEngine: VoiceAudioEngine, @unchecked Sendable {
    enum Call: Equatable {
        case requestPermission
        case prepareCapture
        case beginStreaming
        case setMuted(Bool)
        case play(String)
        case stopPlayback
        case resetUtteranceAnchor
        case shutdown
    }

    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackDrained: (() -> Void)?

    private(set) var calls: [Call] = []
    private(set) var chunkHandler: (@Sendable (Data) -> Void)?

    var permissionError: (any Error)?
    var prepareError: (any Error)?
    var streamingError: (any Error)?
    var isPlayingBack = false
    var utterancePlayedMs: Int?

    /// Holds `requestCapturePermission` open, the way the real TCC prompt does.
    /// The call can end while it is up, which is the whole point.
    var suspendsPermission = false
    private var permissionContinuation: CheckedContinuation<Void, Never>?

    func requestCapturePermission() async throws {
        calls.append(.requestPermission)
        if let permissionError { throw permissionError }
        guard suspendsPermission else { return }

        await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    /// The user answered the prompt.
    func grantCapturePermission() {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume()
    }

    func prepareCapture() throws {
        calls.append(.prepareCapture)
        if let prepareError { throw prepareError }
    }

    func beginStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws {
        calls.append(.beginStreaming)
        if let streamingError { throw streamingError }
        chunkHandler = onChunk
    }

    func setCaptureMuted(_ muted: Bool) {
        calls.append(.setMuted(muted))
    }

    func play(base64PCM16 encoded: String) {
        calls.append(.play(encoded))
    }

    func stopPlayback() {
        calls.append(.stopPlayback)
    }

    func resetUtteranceAnchor() {
        calls.append(.resetUtteranceAnchor)
    }

    func currentUtterancePlayedMs() -> Int? {
        utterancePlayedMs
    }

    func shutdown() {
        calls.append(.shutdown)
        chunkHandler = nil
    }

    func diagnostics() -> String {
        "fake audio engine"
    }
}
