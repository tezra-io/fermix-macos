import Foundation
import Testing

@testable import FermixAppCore

/// A call whose audio arrives under playback ids, as a Grok call's does
/// (realtime v3): the pet plays every chunk the daemon sent, reports what has
/// played as `playback_progress`, and reports a stopped reply's progress
/// before the `interrupt` the daemon cuts it at. The whole stack runs on fakes:
/// the real session, coordinator and model over a recording socket.
@MainActor
@Suite("Voice playback progress")
struct VoicePlaybackProgressTests {
    private static func progress(_ id: String, _ playedMs: Int, drained: Bool = false) -> PlaybackProgressReport {
        PlaybackProgressReport(
            changed: [RealtimePlaybackProgress(playbackId: id, playedMs: playedMs, drained: drained)],
            unplayed: !drained
        )
    }

    /// A Grok call, ready and listening.
    private func grokCall() async -> VoiceCallHarness {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.socket.deliver(.callReady(RealtimeCallReady(engine: "xai_realtime", callId: "voice_live:1", captions: true)))
        harness.socket.deliver(.state(.listening))
        return harness
    }

    private func sentTypes(_ harness: VoiceCallHarness) throws -> [String] {
        try harness.socket.sentObjects().compactMap { $0["type"] as? String }
    }

    @Test("a chunk plays under its playback id, and what has played goes out as playback_progress")
    func chunkIsReportedAsItPlays() async throws {
        let harness = await grokCall()

        harness.socket.deliver(.audioDelta(base64: RelayedAudio.voice(1), playbackId: "p1"))
        #expect(harness.engine.calls.last == .play(RelayedAudio.voice(1), playbackId: "p1"))
        #expect(harness.call.voice.mode == .speaking)

        harness.engine.progressReports = [Self.progress("p1", 100)]
        harness.audioDeadlines.fireAll()

        let reports = try harness.socket.sentObjects().filter { $0["type"] as? String == "playback_progress" }
        #expect(reports.count == 1)
        #expect(
            reports.first == (try wireObject(
                .playbackProgress(RealtimePlaybackProgress(playbackId: "p1", playedMs: 100, drained: false))
            ))
        )
    }

    /// The daemon truncates the stopped reply at the last progress it has, so
    /// that progress must reach it before the `interrupt`.
    @Test("an interrupt sends what had played before the interrupt itself")
    func interruptReportsFirst() async throws {
        let harness = await grokCall()
        harness.socket.deliver(.audioDelta(base64: RelayedAudio.voice(1), playbackId: "p1"))

        harness.engine.progressReports = [Self.progress("p1", 420)]
        harness.coordinator.interrupt()

        let types = try sentTypes(harness)
        let progress = try #require(types.lastIndex(of: "playback_progress"))
        let interrupt = try #require(types.lastIndex(of: "interrupt"))
        #expect(progress < interrupt)
    }

    /// The daemon fences a stopped Grok reply itself and sends none of it after
    /// its `playback_stop`, so audio that follows is the next reply. Dropping it
    /// as the stopped one would leave audio the daemon sent unreported, and the
    /// daemon ends a call whose audio goes unreported.
    @Test("audio under a playback id after an interrupt is the next reply, and plays")
    func audioAfterAnInterruptPlays() async throws {
        let harness = await grokCall()
        harness.socket.deliver(.audioDelta(base64: RelayedAudio.voice(1), playbackId: "p1"))
        harness.coordinator.interrupt()

        harness.socket.deliver(.state(.speaking))
        harness.socket.deliver(.audioDelta(base64: RelayedAudio.voice(2), playbackId: "p2"))

        #expect(harness.engine.calls.last == .play(RelayedAudio.voice(2), playbackId: "p2"))
        #expect(harness.call.voice.mode == .speaking)
    }

    @Test("a playback_stop from the daemon sends what had played")
    func playbackStopReports() async throws {
        let harness = await grokCall()
        harness.socket.deliver(.audioDelta(base64: RelayedAudio.voice(1), playbackId: "p1"))

        harness.engine.progressReports = [Self.progress("p1", 300)]
        harness.socket.deliver(.playbackStop)

        #expect(try harness.sent("playback_progress") == 1)
        #expect(harness.audioDeadlines.liveCount == 0)
    }

    /// A report is a control frame of a call: after `call_stop` the daemon would
    /// answer one by closing the socket.
    @Test("nothing is reported once the call is stopping")
    func nothingAfterTheStop() async throws {
        let harness = await grokCall()
        harness.socket.deliver(.audioDelta(base64: RelayedAudio.voice(1), playbackId: "p1"))

        harness.coordinator.toggleCall()
        harness.engine.progressReports = [Self.progress("p1", 870, drained: true)]
        harness.engine.onPlaybackIdDrained?()
        harness.audioDeadlines.fireAll()

        #expect(try harness.sent("playback_progress") == 0)
    }

    /// The OpenAI engines send no playback id and refuse `playback_progress`,
    /// so their calls never start a report.
    @Test("a call whose audio carries no playback id reports nothing")
    func openAICallReportsNothing() async throws {
        let harness = VoiceCallHarness()
        await harness.beginCall()
        harness.socket.deliver(.state(.listening))

        harness.socket.deliver(.audioDelta(base64: RelayedAudio.voice(1)))
        #expect(harness.audioDeadlines.liveCount == 0, "no progress watch starts")
        harness.coordinator.interrupt()

        #expect(try harness.sent("playback_progress") == 0)
        #expect(harness.engine.calls.contains(.play(RelayedAudio.voice(1))))
    }
}
