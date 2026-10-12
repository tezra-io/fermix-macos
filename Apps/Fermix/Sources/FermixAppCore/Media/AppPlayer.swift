import AVFoundation
import Combine
import Foundation

/// Where something the one player holds is drawn (M66 §3.4), which decides
/// which of its stops reach it.
public enum AppPlayerPlace: Hashable, Sendable {
    /// A sound in the chat, which stops when the window leaves Chat.
    case chat
    /// A sound or a film in one media tab of the pane, which stops when that
    /// tab closes.
    case pane(UUID)
}

/// What the player holds: a file, and where it is drawn. The same file in
/// the chat and in a tab is two items, each stopped by its own place.
public struct AppPlayerItem: Equatable, Sendable {
    public let url: URL
    public let place: AppPlayerPlace

    public init(url: URL, place: AppPlayerPlace) {
        self.url = url
        self.place = place
    }
}

/// Where the held item is and how long it is, published apart from the
/// player: a tick reaches it four times a second while something plays, and
/// only the one view drawing that item observes it.
@MainActor
public final class AppPlayerProgress: ObservableObject {
    @Published public internal(set) var position: Double = 0
    /// The held item's length, once AVFoundation has read it.
    @Published public internal(set) var length: Double?
}

/// The player behind the seam: AVFoundation's in the product, a fake in
/// tests, which never open an audio device.
@MainActor
public protocol AppPlaybackEngine: AnyObject {
    var events: (any AppPlaybackEvents)? { get set }
    /// The `AVPlayer` itself, for AVKit's view to draw; nil until something
    /// is first held, which is when it is made.
    var player: AVPlayer? { get }
    /// Holds `url`, paused at its start, in place of whatever it held, which
    /// stops; nil holds nothing.
    func hold(_ url: URL?)
    func play()
    func pause()
    func seek(to seconds: Double)
    /// Whether AVFoundation can play the file, asked of the file itself and
    /// loaded asynchronously, never read from its name.
    func isPlayable(_ url: URL) async -> Bool
    /// The file's length in seconds, loaded asynchronously; nil where it has
    /// none to read.
    func length(of url: URL) async -> Double?
}

/// What the player tells its one owner.
@MainActor
public protocol AppPlaybackEvents: AnyObject {
    /// Its `timeControlStatus` moved: playing, or waiting to, against paused.
    func playbackPlayingChanged(_ playing: Bool)
    /// Where the held item is: every tick while it plays, and at each seek.
    func playbackMoved(to seconds: Double)
    /// The held item's length, once read.
    func playbackLengthRead(_ seconds: Double)
    /// The held item played to its end.
    func playbackEnded()
}

/// The app's one player (M66 §3.4): one `AVPlayer` for everything that plays,
/// the chat's sounds and the pane's media tabs alike, so its own state is the
/// one truth of what is playing, and one thing plays at a time.
///
/// Holding another item stops the one before. At its end an item goes back
/// to its start and waits there, paused. A call coming up stops it, and
/// nothing plays until the call is over; the window leaving Chat stops a
/// sound in the chat; a media tab closing stops its own; and the main window
/// closing stops whatever it holds, which the composition says. Nothing
/// plays unless the person plays it: a media tab only cues its file.
@MainActor
public final class AppPlayer: ObservableObject {
    /// How far one press of an arrow key, or VoiceOver's increment, moves
    /// along a sound.
    public nonisolated static let step: Double = 5
    /// How often the held item's place is reported while it plays: often
    /// enough for a thin track to move smoothly under an animation the length
    /// of one tick.
    public nonisolated static let tick: Double = 0.25

    /// What the player holds now; nil before anything is played and after a
    /// stop.
    @Published public private(set) var item: AppPlayerItem?
    /// Whether it is playing, read from the player's own `timeControlStatus`
    /// rather than from what it was asked: AVKit's own controls drive it too.
    @Published public private(set) var isPlaying = false
    /// Whether a call is up, while which nothing plays and play is not
    /// offered.
    @Published public private(set) var callIsUp = false
    public let progress = AppPlayerProgress()

    private let engine: any AppPlaybackEngine
    /// The two facts outside the player that stop it, followed for its life.
    private var followed: Set<AnyCancellable> = []

    public init(engine: any AppPlaybackEngine) {
        self.engine = engine
        engine.events = self
    }

    /// AVFoundation's own player, for AVKit's view in a media tab to draw;
    /// nil until something is first held.
    public var avPlayer: AVPlayer? { engine.player }

    /// Follows whether a call is up, and whether the chat is on screen.
    /// Followed rather than told, because both are published by owners built
    /// after the player, which the pane is handed at its own birth.
    public func follow(calls: AnyPublisher<Bool, Never>, chatShown: AnyPublisher<Bool, Never>) {
        calls.removeDuplicates()
            .sink { [weak self] up in self?.callChanged(up) }
            .store(in: &followed)
        chatShown.removeDuplicates()
            .sink { [weak self] shown in
                guard !shown else { return }

                self?.stop(.chat)
            }
            .store(in: &followed)
    }

    // MARK: - What the person asks

    /// Plays `url` for `place`: from where it is, where the player already
    /// holds it, and otherwise from its start, in place of whatever played.
    public func play(_ url: URL, from place: AppPlayerPlace) {
        guard !callIsUp else { return }

        if !holds(url, place) { hold(url, place) }
        engine.play()
    }

    /// A media tab's file, held paused so its tab shows its first frame and
    /// AVKit's controls, where nothing else is playing and no call is up.
    /// Opening a tab plays nothing, and stops nothing either.
    public func cue(_ url: URL, for place: AppPlayerPlace) {
        guard !callIsUp, item == nil || !isPlaying else { return }

        hold(url, place)
    }

    public func pause() {
        engine.pause()
    }

    /// Moves `url` to `seconds`, holding it first, paused, where the player
    /// holds something else.
    public func seek(_ url: URL, from place: AppPlayerPlace, to seconds: Double) {
        guard !callIsUp else { return }

        if !holds(url, place) { hold(url, place) }
        engine.seek(to: seconds)
        progress.position = seconds
    }

    /// Lets go of whatever it holds.
    public func stop() {
        guard item != nil else { return }

        engine.hold(nil)
        item = nil
        progress.position = 0
        progress.length = nil
    }

    /// Lets go of what it holds for `place`, and of nothing else.
    public func stop(_ place: AppPlayerPlace) {
        guard item?.place == place else { return }

        stop()
    }

    public func holds(_ url: URL, _ place: AppPlayerPlace) -> Bool {
        item == AppPlayerItem(url: url, place: place)
    }

    /// Whether the player can play the file at all. What it cannot is opened
    /// outside the app (M66 §3.3).
    public func isPlayable(_ url: URL) async -> Bool {
        await engine.isPlayable(url)
    }

    /// A file's length before it is played, for the time a still sound shows.
    public func length(of url: URL) async -> Double? {
        await engine.length(of: url)
    }

    // MARK: - Mechanics

    private func hold(_ url: URL, _ place: AppPlayerPlace) {
        engine.hold(url)
        item = AppPlayerItem(url: url, place: place)
        progress.position = 0
        progress.length = nil
    }

    private func callChanged(_ up: Bool) {
        callIsUp = up
        guard up else { return }

        stop()
    }
}

extension AppPlayer: AppPlaybackEvents {
    /// Playing during a call is paused at once: AVKit's own controls reach
    /// the player without asking it.
    public func playbackPlayingChanged(_ playing: Bool) {
        guard !(playing && callIsUp) else {
            engine.pause()
            return
        }
        guard playing != isPlaying else { return }

        isPlaying = playing
    }

    public func playbackMoved(to seconds: Double) {
        progress.position = seconds
    }

    public func playbackLengthRead(_ seconds: Double) {
        progress.length = seconds
    }

    /// Back to its start, paused, where a sound shows its length again and a
    /// film its first frame.
    public func playbackEnded() {
        engine.seek(to: 0)
        progress.position = 0
    }
}
