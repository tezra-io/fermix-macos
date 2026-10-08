import Foundation
import Testing

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
    /// Every request waiting on the prompt. macOS shows one prompt however
    /// often it is asked while it is up, and answers every asker at once.
    private var permissionWaiters: [CheckedContinuation<Void, Never>] = []
    private let waitersLock = NSLock()

    /// How many requests are waiting on the prompt now.
    var pendingPermissionRequests: Int { waitersLock.withLock { permissionWaiters.count } }

    func requestCapturePermission() async throws {
        calls.append(.requestPermission)
        if let permissionError { throw permissionError }
        guard suspendsPermission else { return }

        await withCheckedContinuation { continuation in
            waitersLock.withLock { permissionWaiters.append(continuation) }
        }
    }

    /// The user answered the prompt.
    func grantCapturePermission() {
        let waiters = waitersLock.withLock {
            defer { permissionWaiters.removeAll() }
            return permissionWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
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

extension VoiceCallModel {
    /// A call the daemon has been asked for: started, and `call_start` sent.
    func beginTestCall() {
        callStarting()
        callStarted()
    }
}

/// The whole call stack on fakes: the real session, coordinator and call model
/// over a recording socket, a scripted audio engine, and deadlines driven by
/// hand, so the call's lifecycle is proven end to end with no daemon and no
/// microphone.
@MainActor
final class VoiceCallHarness {
    let socket = FakeRealtimeSocket()
    let engine = FakeVoiceAudioEngine()
    /// The handshake's deadline.
    let sessionDeadlines = ManualDeadlineScheduler()
    /// The stopping call's wait for the daemon's last frame.
    let callDeadlines = ManualDeadlineScheduler()
    let call = VoiceCallModel()
    let coordinator: VoiceCoordinator

    init() {
        let session = VoiceSession(
            transport: RealtimeSocketClient(lines: socket),
            socketPath: "/tmp/fermix-call-tests.sock",
            deadlines: sessionDeadlines
        )
        coordinator = VoiceCoordinator(
            model: call,
            session: session,
            audio: AudioOwner(engine: engine, deadlines: ManualDeadlineScheduler()),
            deadlines: callDeadlines
        )
    }

    /// The daemon answering its half of the handshake.
    func negotiate() {
        socket.deliver(.serverHello(minVersion: 1, maxVersion: 2))
    }

    /// Yields until `condition` holds. The permission request hops off the
    /// main actor and back, so a fixed number of yields would be a guess.
    func settle(
        until condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "the call never settled", sourceLocation: sourceLocation)
    }

    /// Begins a call and lets it run up to `call_start`.
    func beginCall() async {
        coordinator.toggleCall()
        negotiate()
        await settle { call.voice.phase == .active }
    }

    /// How many control frames of one wire type went out.
    func sent(_ type: String) throws -> Int {
        try socket.sentObjects().filter { $0["type"] as? String == type }.count
    }
}
