import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// Voice readiness (M56 §4.1): one value, from the last overview the app read,
/// with the app's own sentence beside the daemon's word, and the rules that
/// keep it fresh while a call control is on screen.
@Suite("Voice readiness")
@MainActor
struct VoiceReadinessTests {
    private func readiness(of word: String?) throws -> VoiceReadiness {
        HomeSnapshot(
            hello: try ManagementValueFixture.hello(),
            overview: try ManagementValueFixture.overview(voice: word),
            attention: .rows([]),
            update: .unknown
        ).voiceReadiness
    }

    // MARK: - The value

    /// The daemon publishes the word and the app answers it; nothing is
    /// derived from the socket counts beside it.
    @Test("readiness is the daemon's own word")
    func readinessIsTheDaemonsWord() throws {
        #expect(try readiness(of: "ready") == .ready)
        #expect(try readiness(of: "setup_required") == .setupRequired)
        #expect(try readiness(of: "degraded") == .degraded)
    }

    /// The pinned engine says `disabled` while voice is switched off, which is
    /// a fourth word the design does not list. Its one useful action is the
    /// pane where voice is switched on, so it reads as not set up.
    @Test("voice switched off reads as not set up")
    func disabledReadsAsNotSetUp() throws {
        #expect(try readiness(of: "disabled") == .setupRequired)
    }

    /// A word this build cannot read, or none at all, promises nothing: it is
    /// never mapped onto a neighbour that would begin a call or name a cause.
    @Test("a word this build cannot read, or no word, is unknown")
    func unreadableWordIsUnknown() throws {
        #expect(try readiness(of: "warming_up") == .unknown)
        #expect(try readiness(of: nil) == .unknown)
    }

    @Test("readiness is unknown before the first answer and after a read that found no daemon")
    func unknownWithoutAnAnswer() async throws {
        let harness = try HomeHarness()
        #expect(harness.model.voiceReadiness == .unknown)

        harness.gateway.overviewResult = try ManagementValueFixture.overview(voice: "ready")
        await harness.model.refresh()
        #expect(harness.model.voiceReadiness == .ready)

        harness.gateway.overviewFailure = ManagementError.transport(.socketMissing(path: "/tmp/test-daemon.sock"))
        await harness.model.refresh()
        #expect(harness.model.voiceReadiness == .unknown)
    }

    /// The daemon publishes the word, not a sentence, so each value that stops
    /// a call has the app's own words, in the copy rules' voice.
    @Test("each value that stops a call has the app's own sentence")
    func sentences() {
        #expect(VoiceReadiness.ready.sentence == nil)
        #expect(VoiceReadiness.setupRequired.sentence == ProductStrings[.voiceReadinessSetupRequired])
        #expect(VoiceReadiness.degraded.sentence == "Voice is not available right now")
        #expect(VoiceReadiness.unknown.sentence == "Checking voice")
        #expect(ProductStrings[.voiceReadinessSetUp] == "Set up voice")

        for key in [ProductStringKey.voiceReadinessSetupRequired, .voiceReadinessSetUp, .voiceReadinessDegraded, .voiceReadinessUnknown] {
            #expect(ProductCopyRules.violations(in: ProductStrings[key]).isEmpty, "\(key.rawValue)")
        }
    }

    /// A surface that draws readiness redraws when it moves, and only then.
    @Test("the reader publishes readiness as it moves, and only when it moves")
    func readinessChangesArePublished() async throws {
        let harness = try HomeHarness()
        var heard: [VoiceReadiness] = []
        let subscription = harness.model.voiceReadinessChanges.sink { heard.append($0) }
        defer { subscription.cancel() }

        harness.gateway.overviewResult = try ManagementValueFixture.overview(voice: "degraded")
        await harness.model.refresh()
        await harness.model.refresh()
        harness.gateway.overviewResult = try ManagementValueFixture.overview(voice: "ready")
        await harness.model.refresh()

        #expect(heard == [.degraded, .ready])
    }

    // MARK: - When the one reader reads

    /// Opening Chat or the Pet page is a route, and every route but Home's
    /// reads the daemon on its way in (Home's own view reads as it appears).
    @Test("Chat or the Pet page appearing reads the overview", arguments: [AppRoute.chat, .pet])
    func surfaceAppearingReads(route: AppRoute) async throws {
        let harness = try HomeHarness()
        harness.gateway.overviewResult = try ManagementValueFixture.overview(voice: "setup_required")
        var read: Task<Void, Never>?
        harness.coordinator.readDaemonCondition = { [model = harness.model] in
            read = Task { await model.refresh() }
        }
        defer { harness.coordinator.readDaemonCondition = nil }

        harness.coordinator.open(route)
        try await harness.coordinator.drainPendingWork()
        await read?.value

        #expect(harness.overviewReads == 1)
        #expect(harness.model.voiceReadiness == .setupRequired)
    }

    /// A save can be the one that sets voice up, so the reader reads after it
    /// rather than waiting for the next route.
    @Test("a settings save reads the overview")
    func settingsSaveReads() async throws {
        let harness = try HomeHarness()
        harness.gateway.overviewScript = [
            try ManagementValueFixture.overview(voice: "setup_required"),
            try ManagementValueFixture.overview(voice: "ready")
        ]
        await harness.model.refresh()
        #expect(harness.model.voiceReadiness == .setupRequired)

        await harness.settings.apply(section: "realtime", key: "realtime_voice", value: .text("marin"))
        await harness.settle { harness.model.voiceReadiness == .ready }

        #expect(harness.overviewReads == 2)
    }

    /// Start, restart and stop all end in the coordinator's one refresh.
    @Test("a lifecycle outcome reads the overview")
    func lifecycleOutcomeReads() async throws {
        let harness = try HomeHarness()
        harness.gateway.overviewScript = [
            try ManagementValueFixture.overview(voice: "degraded"),
            try ManagementValueFixture.overview(voice: "ready")
        ]
        await harness.model.refresh()
        var read: Task<Void, Never>?
        harness.coordinator.readDaemonCondition = { [model = harness.model] in
            read = Task { await model.refresh() }
        }
        defer { harness.coordinator.readDaemonCondition = nil }

        harness.coordinator.restartDaemon()
        try await harness.coordinator.drainPendingWork()
        await read?.value

        #expect(harness.lifecycle.calls == [.restart])
        #expect(harness.overviewReads == 2)
        #expect(harness.model.voiceReadiness == .ready)
    }

    /// Two minutes after the last read, the reader reads again while Chat or
    /// the Pet page is on screen, and stops reading once neither is.
    @Test("the two minute check reads while a call control shows, and not after it leaves", arguments: [AppRoute.chat, .pet])
    func twoMinuteCheck(route: AppRoute) async throws {
        let harness = try HomeHarness()
        await harness.model.refresh()
        #expect(harness.deadlines.scheduledDelays == [HomeModel.voiceReadinessInterval])
        #expect(HomeModel.voiceReadinessInterval == 120)

        harness.coordinator.open(route)
        try await harness.coordinator.drainPendingWork()
        harness.deadlines.fireAll()
        await harness.settle { harness.overviewReads == 2 && harness.deadlines.liveCount == 1 }
        #expect(harness.deadlines.scheduledDelays == [HomeModel.voiceReadinessInterval], "the read armed the next check")

        harness.coordinator.open(.home)
        try await harness.coordinator.drainPendingWork()
        harness.deadlines.fireAll()
        try await harness.settle()

        #expect(harness.overviewReads == 2, "Home is not a call control")
        #expect(harness.deadlines.scheduledDelays == [HomeModel.voiceReadinessInterval], "the check keeps looking")
    }

    /// The floating pet is a call control too, and it floats with no main
    /// window behind it.
    @Test("the two minute check reads while the floating pet shows")
    func twoMinuteCheckWithTheFloatingPet() async throws {
        let harness = try HomeHarness()
        await harness.model.refresh()

        harness.coordinator.setPetWindow(true)
        harness.deadlines.fireAll()
        await harness.settle { harness.overviewReads == 2 && harness.deadlines.liveCount == 1 }

        harness.coordinator.setPetWindow(false)
        harness.deadlines.fireAll()
        try await harness.settle()

        #expect(harness.overviewReads == 2)
    }

    /// The settings presentation is the primary window's other face: Chat
    /// behind it is not on screen.
    @Test("the two minute check does not read while Settings covers Chat")
    func twoMinuteCheckBehindSettings() async throws {
        let harness = try HomeHarness()
        await harness.model.refresh()
        harness.coordinator.open(.chat)
        try await harness.coordinator.drainPendingWork()
        harness.coordinator.openSettings()
        try await harness.coordinator.drainPendingWork()

        harness.deadlines.fireAll()
        try await harness.settle()

        #expect(harness.overviewReads == 1)
    }

    /// A call the daemon refuses is the freshest word there is about voice, so
    /// the reader reads at once rather than at the next route or tick.
    @Test("a call the daemon refuses reads the overview at once")
    func refusedCallReads() async throws {
        let harness = try HomeHarness()
        harness.gateway.overviewScript = [
            try ManagementValueFixture.overview(voice: "ready"),
            try ManagementValueFixture.overview(voice: "degraded")
        ]
        await harness.model.refresh()

        harness.call.beginTestCall()
        harness.call.apply(
            .error(RealtimeServerError(reason: "bridge_unavailable", kind: .bridgeUnavailable)),
            audioIsPlaying: false
        )
        await harness.settle { harness.model.voiceReadiness == .degraded }

        #expect(harness.overviewReads == 2)
    }

    /// The microphone failing is this Mac's answer, not the daemon's: it says
    /// nothing about voice readiness, so nothing is read for it.
    @Test("a failure the daemon did not name reads nothing")
    func unnamedFailureReadsNothing() async throws {
        let harness = try HomeHarness()
        await harness.model.refresh()

        harness.call.callStarting()
        harness.call.voiceCaptureFailed(ProductStrings[.voiceErrorNoInputDevice])
        try await harness.settle()

        #expect(harness.overviewReads == 1)
    }
}

extension HomeHarness {
    var overviewReads: Int { gateway.calls.filter { $0 == .overview }.count }

    /// Yields until `condition` holds: the reads a sink asks for are tasks.
    func settle(
        until condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "the read never came", sourceLocation: sourceLocation)
    }
}

/// Voice readiness as a test states it, with no daemon behind it.
@MainActor
final class FakeVoiceReadiness: VoiceReadinessReading {
    @Published var voiceReadiness: VoiceReadiness

    init(_ readiness: VoiceReadiness = .ready) {
        voiceReadiness = readiness
    }

    var voiceReadinessChanges: AnyPublisher<VoiceReadiness, Never> {
        $voiceReadiness.dropFirst().eraseToAnyPublisher()
    }
}
