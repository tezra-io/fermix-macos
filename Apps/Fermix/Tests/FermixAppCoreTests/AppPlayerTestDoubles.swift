import AVFoundation
import AppKit
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
    /// The files AVFoundation would say it can play.
    var playable: Set<URL> = []
    /// The lengths AVFoundation would read.
    var lengths: [URL: Double] = [:]

    func hold(_ url: URL?) { requests.append("hold " + (url?.lastPathComponent ?? "nothing")) }
    func play() { requests.append("play") }
    func pause() { requests.append("pause") }
    func seek(to seconds: Double) { requests.append("seek \(seconds)") }
    func isPlayable(_ url: URL) async -> Bool { playable.contains(url) }
    func length(of url: URL) async -> Double? { lengths[url] }
}

/// A media tab's view with no AVKit behind it: what it was last asked to
/// show, and its Play pressed by the test.
@MainActor
final class FakeMediaSurface: BrowserMediaSurface {
    lazy var view = NSView()
    var onPlay: (@MainActor () -> Void)?
    private(set) var holding = false
    private(set) var playable = false

    func show(holding: Bool, playable: Bool) {
        self.holding = holding
        self.playable = playable
    }

    func pressPlay() {
        onPlay?()
    }
}

/// A document tab's view with no Quick Look behind it.
@MainActor
final class FakeDocumentPreview: BrowserDocumentPreview {
    lazy var view = NSView()
    private(set) var shown: [URL] = []
    private(set) var closes = 0

    func show(_ file: URL) { shown.append(file) }
    func close() { closes += 1 }
}

/// The pane's own viewers over fake views, keeping every one it made.
@MainActor
final class FakeBrowserViewers: BrowserViewerMaking {
    private(set) var surfaces: [FakeMediaSurface] = []
    private(set) var previews: [FakeDocumentPreview] = []

    func mediaSurface(_ player: AppPlayer) -> any BrowserMediaSurface {
        let surface = FakeMediaSurface()
        surfaces.append(surface)
        return surface
    }

    func documentPreview() -> any BrowserDocumentPreview {
        let preview = FakeDocumentPreview()
        previews.append(preview)
        return preview
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
