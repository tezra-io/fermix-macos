import Foundation
import Testing

@testable import FermixAppCore

/// What a Grok call reports played of each playback id, from the player's own
/// timeline. The daemon cuts an interrupted reply at these numbers, paces the
/// reply by them, and closes the socket on one that goes backwards or passes
/// what it sent, so every case here is a number the wire would carry.
///
/// A report and a completion change the timeline, so each is taken before it
/// is checked: `#expect` reads its expression as a value.
@Suite("Playback timeline")
struct PlaybackTimelineTests {
    /// 100 ms of audio at 24 kHz.
    private static let tenth: Int64 = 2_400

    private func progress(_ id: String, _ playedMs: Int, drained: Bool) -> RealtimePlaybackProgress {
        RealtimePlaybackProgress(playbackId: id, playedMs: playedMs, drained: drained)
    }

    @Test("a chunk reports what has played as the player moves, and drains when it finishes")
    func chunkPlaysThenDrains() {
        var timeline = PlaybackTimeline()
        let serial = timeline.schedule("p1", frames: 2 * Self.tenth, now: nil)

        let started = timeline.report(now: 0)
        #expect(started == PlaybackProgressReport(changed: [progress("p1", 0, drained: false)], unplayed: true))

        let playing = timeline.report(now: Self.tenth)
        #expect(playing.changed == [progress("p1", 100, drained: false)])

        // The player is past the chunk, but only its completion says it is done.
        let past = timeline.report(now: 3 * Self.tenth)
        #expect(past.changed == [progress("p1", 200, drained: false)])

        let drained = timeline.finish(through: serial)
        let finished = timeline.report(now: 3 * Self.tenth)
        #expect(drained)
        #expect(finished == PlaybackProgressReport(changed: [progress("p1", 200, drained: true)], unplayed: false))
    }

    @Test("a report says only what changed since the last one")
    func reportsOnlyChanges() {
        var timeline = PlaybackTimeline()
        _ = timeline.schedule("p1", frames: 2 * Self.tenth, now: nil)

        let first = timeline.report(now: Self.tenth)
        let again = timeline.report(now: Self.tenth)

        #expect(first.changed.count == 1)
        #expect(again == PlaybackProgressReport(changed: [], unplayed: true))
    }

    /// The wire refuses `played_ms` below one already reported. A position read
    /// across a player that restarted under the timeline goes backwards; the
    /// report must not.
    @Test("what has played never goes backwards")
    func playedNeverRegresses() {
        var timeline = PlaybackTimeline()
        _ = timeline.schedule("p1", frames: 4 * Self.tenth, now: nil)

        let ahead = timeline.report(now: 3 * Self.tenth)
        let behind = timeline.report(now: Self.tenth)
        let unread = timeline.report(now: nil)

        #expect(ahead.changed == [progress("p1", 300, drained: false)])
        #expect(behind.changed.isEmpty)
        #expect(unread.changed.isEmpty)
    }

    /// The wire refuses `played_ms` beyond the audio sent under the id, and the
    /// daemon measures what it sent in whole bytes: a part of a millisecond
    /// never rounds up past it.
    @Test("what has played rounds down to whole milliseconds")
    func playedRoundsDown() {
        var timeline = PlaybackTimeline()
        let serial = timeline.schedule("p1", frames: 47, now: nil)

        let drained = timeline.finish(through: serial)
        let report = timeline.report(now: 47)

        #expect(drained)
        #expect(report.changed == [progress("p1", 1, drained: true)])
    }

    @Test("chunks under one id add up, and the id drains only when its last chunk finishes")
    func chunksOfOneIdAddUp() {
        var timeline = PlaybackTimeline()
        let first = timeline.schedule("p1", frames: Self.tenth, now: nil)
        let second = timeline.schedule("p1", frames: Self.tenth, now: 0)

        let firstDrained = timeline.finish(through: first)
        let halfway = timeline.report(now: Self.tenth + 1_200)
        #expect(firstDrained == false)
        #expect(halfway.changed == [progress("p1", 150, drained: false)])

        let secondDrained = timeline.finish(through: second)
        let finished = timeline.report(now: 2 * Self.tenth)
        #expect(secondDrained)
        #expect(finished.changed == [progress("p1", 200, drained: true)])
    }

    /// The player plays in order, so a completion settles every chunk before
    /// it, whose own completion may not have been heard yet.
    @Test("a completion settles every chunk before it")
    func completionSettlesEarlierChunks() {
        var timeline = PlaybackTimeline()
        _ = timeline.schedule("p1", frames: Self.tenth, now: nil)
        let last = timeline.schedule("p2", frames: Self.tenth, now: 0)

        let drained = timeline.finish(through: last)
        let report = timeline.report(now: nil)

        #expect(drained)
        #expect(
            report == PlaybackProgressReport(
                changed: [progress("p1", 100, drained: true), progress("p2", 100, drained: true)],
                unplayed: false
            )
        )
    }

    /// A chunk queued behind another starts where that one ends; one that
    /// arrives after the queue ran dry starts where the player is.
    @Test("a chunk starts where the queue ends, or where the player is once it ran dry")
    func chunkStartsWhereItCanPlay() {
        var timeline = PlaybackTimeline()
        let first = timeline.schedule("p1", frames: Self.tenth, now: nil)
        _ = timeline.finish(through: first)
        _ = timeline.report(now: Self.tenth)

        // The player kept running through a gap of 200 ms.
        _ = timeline.schedule("p2", frames: Self.tenth, now: 3 * Self.tenth)

        let arrived = timeline.report(now: 3 * Self.tenth)
        let halfway = timeline.report(now: 3 * Self.tenth + 1_200)

        #expect(arrived.changed == [progress("p2", 0, drained: false)])
        #expect(halfway.changed == [progress("p2", 50, drained: false)])
    }

    /// A stop is where the daemon cuts the reply: it keeps what had played, the
    /// rest never plays, and so the id is never drained.
    @Test("a stop keeps what had played and drains nothing")
    func stopKeepsWhatPlayed() {
        var timeline = PlaybackTimeline()
        _ = timeline.schedule("p1", frames: Self.tenth, now: nil)
        _ = timeline.schedule("p1", frames: 2 * Self.tenth, now: 0)

        timeline.stop(now: Self.tenth + 1_200)
        let stopped = timeline.report(now: nil)
        let later = timeline.report(now: 10 * Self.tenth)

        #expect(stopped == PlaybackProgressReport(changed: [progress("p1", 150, drained: false)], unplayed: false))
        #expect(later.changed.isEmpty, "nothing plays after a stop")
    }

    /// macOS stopped the player under queued chunks (a device change). None of
    /// them will play now, and the daemon waits on every frame it sent, so the
    /// call would stall: they count as played and the timeline starts over.
    @Test("a player that restarted under queued chunks counts them played")
    func restartCountsQueuedChunksPlayed() {
        var timeline = PlaybackTimeline()
        _ = timeline.schedule("p1", frames: 2 * Self.tenth, now: nil)
        _ = timeline.report(now: Self.tenth)

        timeline.restart()
        _ = timeline.schedule("p1", frames: Self.tenth, now: nil)
        let restarted = timeline.report(now: 0)
        let playing = timeline.report(now: 1_200)

        #expect(restarted.changed == [progress("p1", 200, drained: false)])
        #expect(playing.changed == [progress("p1", 250, drained: false)])
    }
}
