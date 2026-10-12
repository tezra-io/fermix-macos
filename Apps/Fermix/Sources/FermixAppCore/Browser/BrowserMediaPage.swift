import AppKit
import Combine
import Foundation

/// What a media tab draws, behind a seam so a test never builds AVKit's view.
@MainActor
public protocol BrowserMediaSurface: AnyObject {
    var view: NSView { get }
    /// What the tab's own Play control does, set once by its page.
    var onPlay: (@MainActor () -> Void)? { get set }
    /// AVKit's view on the app's one player while the tab holds it; while it
    /// does not, the tab's own Play control, which can be pressed as
    /// `playable` says.
    func show(holding: Bool, playable: Bool)
}

/// A media tab's page (M66 §3.5): a sound or a film on the app's one player,
/// in AVKit's own view, which plays only when the person plays it.
///
/// The tab holds the player only while nothing else needs it. Its file is
/// cued as it loads where nothing is playing, so its first frame and AVKit's
/// controls are there at once; where something else is playing, or takes the
/// player later, the tab offers its own Play instead, which takes the player
/// back. Its file is let go when the tab closes. It navigates nowhere, and
/// it is granted nothing: AVFoundation is handed the file and no more.
@MainActor
final class BrowserMediaPage: BrowserPage {
    weak var events: (any BrowserPageEvents)?

    private let player: AppPlayer
    private let surface: any BrowserMediaSurface
    /// Which media tab this is, to the player.
    private let place = AppPlayerPlace.pane(UUID())
    /// The tab's file, once it may load: a file outside the Fermix home waits
    /// for the person's answer.
    private var file: URL?
    private var playerChanges: AnyCancellable?

    init(player: AppPlayer, surface: any BrowserMediaSurface) {
        self.player = player
        self.surface = surface
        surface.onPlay = { [weak self] in self?.play() }
        playerChanges = player.$item.combineLatest(player.$callIsUp).sink { [weak self] item, callIsUp in
            self?.draw(item, callIsUp: callIsUp)
        }
    }

    var view: NSView { surface.view }

    func loadFile(_ url: URL, as kind: BrowserFileKind, readAccess: URL) {
        file = url
        player.cue(url, for: place)
        draw(player.item, callIsUp: player.callIsUp)
    }

    func close() {
        player.stop(place)
    }

    /// A media tab loads no address, keeps no history, and finds and zooms
    /// nothing: AVKit's view carries its own controls.
    func load(_ url: URL) {}
    func back() {}
    func forward() {}
    func reload() {}
    func stop() {}
    func find(_ text: String) {}
    func zoom(_ zoom: BrowserZoom) {}

    private func play() {
        guard let file else { return }

        player.play(file, from: place)
    }

    /// Read from what the player publishes, as it publishes it.
    private func draw(_ item: AppPlayerItem?, callIsUp: Bool) {
        guard let file else {
            surface.show(holding: false, playable: false)
            return
        }

        surface.show(holding: item == AppPlayerItem(url: file, place: place), playable: !callIsUp)
    }
}
