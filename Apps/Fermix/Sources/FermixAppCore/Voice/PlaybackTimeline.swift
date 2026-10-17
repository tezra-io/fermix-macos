import Foundation

/// What the player has done with the audio sent under playback ids.
public struct PlaybackProgressReport: Equatable, Sendable {
    /// One entry per playback id whose progress changed since the last report.
    public let changed: [RealtimePlaybackProgress]
    /// Whether audio sent under a playback id is still queued to play.
    public let unplayed: Bool

    public static let none = PlaybackProgressReport(changed: [], unplayed: false)

    public init(changed: [RealtimePlaybackProgress], unplayed: Bool) {
        self.changed = changed
        self.unplayed = unplayed
    }
}

/// What has played of each playback id a call's audio arrived under (realtime
/// v3, a Grok call), on the player's own timeline.
///
/// The daemon paces a Grok reply by what the pet reports played, cuts a reply
/// the operator stopped at what was heard, and ends a call whose sent audio goes
/// unreported, so a report counts rendered audio and nothing else. Each chunk is
/// a segment on the player's timeline, in frames at 24 kHz: it starts where the
/// one before it ends, or where the player is now when the queue ran dry before
/// it arrived. A segment the player has finished counts whole, and the one
/// playing counts up to the player's position. A stop keeps what had played and
/// drops the rest, which will never play.
///
/// Pure, so the arithmetic is proven without an audio engine: `AudioController`
/// holds one on its queue and gives it the player's position.
struct PlaybackTimeline {
    /// PCM16 at 24 kHz mono, so 24 frames a millisecond.
    static let framesPerMillisecond: Int64 = 24

    private struct Segment {
        let serial: Int
        let playbackId: String
        let start: Int64
        let frames: Int64
    }

    private struct Account {
        /// Frames of this id's segments that have finished, or were stopped.
        var settled: Int64 = 0
        /// The most this id has been seen to have played. Only grows: the
        /// wire's `played_ms` may never go backwards, and a position read
        /// across a player that restarted under it would.
        var played: Int64 = 0
        /// Frames a stop dropped. An id with any is never drained again.
        var dropped: Int64 = 0
    }

    private var accounts: [String: Account] = [:]
    /// The ids in the order their audio began, so a report reads in that order.
    private var order: [String] = []
    /// Segments scheduled and not yet finished, in the order they play.
    private var pending: [Segment] = []
    private var nextSerial = 0
    private var reported: [String: RealtimePlaybackProgress] = [:]

    /// Whether audio sent under an id is still queued to play.
    var unplayed: Bool { !pending.isEmpty }

    /// A chunk under `playbackId` was scheduled. `now` is the player's
    /// position, nil when it is not playing: a player that is not playing
    /// begins its timeline at zero with this chunk. Answers the serial its
    /// completion names.
    mutating func schedule(_ playbackId: String, frames: Int64, now: Int64?) -> Int {
        let queueEnd = pending.last.map { $0.start + $0.frames } ?? 0
        let start = max(queueEnd, now ?? 0)

        nextSerial += 1
        pending.append(Segment(serial: nextSerial, playbackId: playbackId, start: start, frames: frames))

        if accounts[playbackId] == nil {
            accounts[playbackId] = Account()
            order.append(playbackId)
        }
        return nextSerial
    }

    /// The player finished the segment `serial` and everything before it. It
    /// plays them in order, so a completion settles every earlier segment too.
    /// Answers whether that drained an id: all its audio queued so far played.
    mutating func finish(through serial: Int) -> Bool {
        var finished: Set<String> = []
        while let segment = pending.first, segment.serial <= serial {
            pending.removeFirst()
            settle(segment.playbackId, frames: segment.frames)
            finished.insert(segment.playbackId)
        }

        return finished.contains { progress(of: $0).drained }
    }

    /// The player is starting again with nothing of its own queued, while
    /// segments are still pending here: macOS stopped it under them, which a
    /// device change does. None of them will play now, and the daemon waits on
    /// every frame it sent, so they count as played and the timeline begins
    /// again at zero.
    mutating func restart() {
        for segment in pending {
            settle(segment.playbackId, frames: segment.frames)
        }
        pending.removeAll()
    }

    /// Playback stopped at `now`: each pending segment keeps what it had
    /// played, and the rest is dropped.
    mutating func stop(now: Int64?) {
        for playbackId in order {
            observe(playbackId, played: playedSoFar(playbackId, now: now))
        }
        for segment in pending {
            let heard = Self.heard(segment, now: now)
            accounts[segment.playbackId]?.settled += heard
            accounts[segment.playbackId]?.dropped += segment.frames - heard
        }
        pending.removeAll()
    }

    /// What changed for each id since the last report, as of `now`.
    mutating func report(now: Int64?) -> PlaybackProgressReport {
        var changed: [RealtimePlaybackProgress] = []

        for playbackId in order {
            observe(playbackId, played: playedSoFar(playbackId, now: now))
            let progress = progress(of: playbackId)
            guard progress != reported[playbackId] else { continue }

            reported[playbackId] = progress
            changed.append(progress)
        }

        return PlaybackProgressReport(changed: changed, unplayed: unplayed)
    }

    // MARK: - Arithmetic

    private mutating func settle(_ playbackId: String, frames: Int64) {
        accounts[playbackId]?.settled += frames
        observe(playbackId, played: accounts[playbackId]?.settled ?? 0)
    }

    private mutating func observe(_ playbackId: String, played: Int64) {
        guard let account = accounts[playbackId], played > account.played else { return }

        accounts[playbackId]?.played = played
    }

    private func playedSoFar(_ playbackId: String, now: Int64?) -> Int64 {
        let settled = accounts[playbackId]?.settled ?? 0
        let playing = pending.lazy
            .filter { $0.playbackId == playbackId }
            .reduce(0) { $0 + Self.heard($1, now: now) }

        return settled + playing
    }

    /// Only an id with an account is ever in `order`.
    private func progress(of playbackId: String) -> RealtimePlaybackProgress {
        let account = accounts[playbackId] ?? Account()
        let drained = account.dropped == 0 && !pending.contains { $0.playbackId == playbackId }

        return RealtimePlaybackProgress(
            playbackId: playbackId,
            playedMs: Int(account.played / Self.framesPerMillisecond),
            drained: drained
        )
    }

    /// How much of a segment has played at `now`: none before it starts, all of
    /// it once the player is past its end.
    private static func heard(_ segment: Segment, now: Int64?) -> Int64 {
        guard let now else { return 0 }

        return min(max(now - segment.start, 0), segment.frames)
    }
}
