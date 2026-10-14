import AVFoundation
import Foundation

/// The one `AVPlayer`, behind the player's seam (M66 §3.4).
///
/// It is made the first time something is held, so a person who never plays
/// anything never has one, and it plays to the Mac's current output. What it
/// reports it reads from the player itself: `timeControlStatus` for whether
/// it plays, a periodic observer for where, and the item's end.
@MainActor
final class AVFoundationPlayback: AppPlaybackEngine {
    weak var events: (any AppPlaybackEvents)?
    private(set) var player: AVPlayer?
    private var playingObservation: NSKeyValueObservation?
    /// The periodic observer's token, held for the player's life.
    private var ticks: Any?
    /// The held item's end, observed for that item alone.
    private var ending: (any NSObjectProtocol)?

    func hold(_ url: URL?) {
        player?.pause()
        if let ending { NotificationCenter.default.removeObserver(ending) }
        ending = nil
        guard let url else {
            player?.replaceCurrentItem(with: nil)
            return
        }

        let item = AVPlayerItem(url: url)
        made().replaceCurrentItem(with: item)
        observeEnd(of: item)
        readLength(of: item)
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    /// Exactly where it was asked, so five seconds is five seconds.
    func seek(to seconds: Double) {
        player?.seek(to: Self.time(seconds), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func isPlayable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isPlayable)) == true
    }

    func length(of url: URL) async -> Double? {
        Self.seconds(try? await AVURLAsset(url: url).load(.duration))
    }

    // MARK: - Mechanics

    private func made() -> AVPlayer {
        if let player { return player }

        let made = AVPlayer()
        made.actionAtItemEnd = .pause
        observe(made)
        player = made
        return made
    }

    /// The status can be reported on any queue, so it is read again on the
    /// main actor rather than taken from the change.
    private func observe(_ player: AVPlayer) {
        playingObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.playingChanged() }
        }
        ticks = player.addPeriodicTimeObserver(forInterval: Self.time(AppPlayer.tick), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.moved(to: time) }
        }
    }

    private func playingChanged() {
        guard let player else { return }

        events?.playbackPlayingChanged(player.timeControlStatus != .paused)
    }

    private func moved(to time: CMTime) {
        guard time.isNumeric else { return }

        events?.playbackMoved(to: max(time.seconds, 0))
    }

    private func observeEnd(of item: AVPlayerItem) {
        ending = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.events?.playbackEnded() }
        }
    }

    /// The length arrives once AVFoundation has read it, and only for the
    /// item still held by then.
    private func readLength(of item: AVPlayerItem) {
        Task { [weak self] in
            guard let seconds = Self.seconds(try? await item.asset.load(.duration)) else { return }
            guard let self, player?.currentItem === item else { return }

            events?.playbackLengthRead(seconds)
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A length as seconds, where it is a real, positive one.
    private static func seconds(_ time: CMTime?) -> Double? {
        guard let time, time.isNumeric, time.seconds > 0 else { return nil }

        return time.seconds
    }
}
