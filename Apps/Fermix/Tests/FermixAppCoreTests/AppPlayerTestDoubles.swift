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
