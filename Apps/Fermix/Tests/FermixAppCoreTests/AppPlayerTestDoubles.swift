import AVFoundation
import Combine
import Foundation

@testable import FermixAppCore

/// The one player's engine with no `AVPlayer` behind it, so no test opens an
/// audio device: it records what it was asked, and the test speaks for the
/// player through `events`.
@MainActor
final class FakePlaybackEngine: AppPlaybackEngine {
    weak var events: (any AppPlaybackEvents)?
    let player: AVPlayer? = nil
    /// Every request, in order: "hold <name>", "hold nothing", "play",
    /// "pause", "seek <seconds>".
    private(set) var requests: [String] = []

    func hold(_ url: URL?) { requests.append("hold " + (url?.lastPathComponent ?? "nothing")) }
    func play() { requests.append("play") }
    func pause() { requests.append("pause") }
    func seek(to seconds: Double) { requests.append("seek \(seconds)") }
}

/// What AVFoundation would say of each file, set by the test, so no test
/// opens a file: the one fake of the one owner (`MediaFacts`), for the pane,
/// the chat's sounds and a video tile alike. Nothing plays unless the test
/// says it does.
final class FakeMediaFacts: MediaFacts, @unchecked Sendable {
    private let lock = NSLock()
    private var playableFiles: Set<URL>
    private var fileLengths: [URL: Double]

    init(playable: Set<URL> = [], lengths: [URL: Double] = [:]) {
        playableFiles = playable
        fileLengths = lengths
    }

    /// The files AVFoundation would say it can play.
    var playable: Set<URL> {
        get { lock.withLock { playableFiles } }
        set { lock.withLock { playableFiles = newValue } }
    }

    /// The lengths AVFoundation would read.
    var lengths: [URL: Double] {
        get { lock.withLock { fileLengths } }
        set { lock.withLock { fileLengths = newValue } }
    }

    func isPlayable(_ file: URL) async -> Bool { playable.contains(file) }
    func length(of file: URL) async -> Double? { lengths[file] }
}

/// The engine's grants of phone-side files, played by hand (M66 decision 1),
/// so no test opens a socket: a ref is answered as the test set it up front,
/// or waits until the test answers it, and a use that stops waiting is
/// answered `.failed` and stays counted until its release, as the session's
/// grants do. Every hold and release is kept, so a case can prove each hold
/// is paired with exactly one release.
@MainActor
final class FakeMediaGrants: MediaGranting {
    /// What the engine answers at once, by ref; a ref with none waits for
    /// `answer`.
    var answers: [String: MediaGrantOutcome] = [:]
    /// Every hold and release, in order: "hold <ref>", "release <ref>".
    private(set) var log: [String] = []
    /// The uses counted now, by ref.
    private(set) var counts: [String: Int] = [:]
    private var waiting: [(id: Int, ref: String, continuation: CheckedContinuation<MediaGrantOutcome, Never>)] = []
    private var issued = 0

    /// Every use counted now, across refs: zero once each hold has its
    /// release.
    var held: Int { counts.values.reduce(0, +) }
    /// How many times anything was held.
    var holds: Int { log.filter { $0.hasPrefix("hold ") }.count }
    /// How many uses are waiting for the engine's answer.
    var waitingCount: Int { waiting.count }

    /// A ref as the engine names one: 64 lowercase hex digits, all `digit`.
    nonisolated static func ref(_ digit: Character) -> String {
        String(repeating: digit, count: 64)
    }

    /// The managed file the engine grants for `ref`, named with `ext`.
    nonisolated static func granted(_ ref: String, _ ext: String, in folder: URL = URL(fileURLWithPath: "/fermix/companion/media", isDirectory: true)) -> MediaGrantOutcome {
        .granted(MediaGrant(ref: ref, url: folder.appendingPathComponent(ref + "." + ext)))
    }

    func hold(_ ref: String) async -> MediaGrantOutcome {
        log.append("hold " + ref)
        counts[ref, default: 0] += 1
        if let known = answers[ref] { return known }

        issued += 1
        let id = issued
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.append((id, ref, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(id) }
        }
    }

    func release(_ ref: String) {
        log.append("release " + ref)
        counts[ref, default: 0] -= 1
        if counts[ref] == 0 { counts[ref] = nil }
    }

    /// The engine answers every use of `ref` waiting.
    func answer(_ ref: String, _ outcome: MediaGrantOutcome) {
        let answered = waiting.filter { $0.ref == ref }
        waiting.removeAll { $0.ref == ref }
        for use in answered {
            use.continuation.resume(returning: outcome)
        }
    }

    private func stopWaiting(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }

        waiting.remove(at: index).continuation.resume(returning: .failed)
    }
}

/// The two facts the player follows, said by the test: whether a call is
/// up, and whether the chat is on screen.
@MainActor
final class AppPlayerSignals {
    private let call = CurrentValueSubject<Bool, Never>(false)
    private let shown = CurrentValueSubject<Bool, Never>(true)

    var calls: AnyPublisher<Bool, Never> { call.eraseToAnyPublisher() }
    var chat: AnyPublisher<Bool, Never> { shown.eraseToAnyPublisher() }

    func callUp(_ up: Bool) { call.send(up) }
    func chatShown(_ isShown: Bool) { shown.send(isShown) }
}
