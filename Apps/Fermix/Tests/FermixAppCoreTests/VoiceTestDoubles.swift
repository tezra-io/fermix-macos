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

/// Audio as the daemon relays it, base64 PCM16: a chunk of voice (a square
/// wave well above `PCM16.voicedRMS`, distinct per `tag`), or Live's padding,
/// the digital silence it sends between replies for the whole call.
enum RelayedAudio {
    static func voice(_ tag: Int = 1) -> String {
        let amplitude = Int16(1_000 + tag * 10)
        var samples = Data()
        for index in 0..<480 {
            var value = (index % 2 == 0 ? amplitude : -amplitude).littleEndian
            withUnsafeBytes(of: &value) { samples.append(contentsOf: $0) }
        }
        return samples.base64EncodedString()
    }

    static let padding = Data(count: 4_800).base64EncodedString()
}
