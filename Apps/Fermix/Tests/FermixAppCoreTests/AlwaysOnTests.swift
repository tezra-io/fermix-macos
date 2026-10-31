import Foundation
import Testing

@testable import FermixAppCore

/// `home.status` pictures as the wire carries them: the contract's golden,
/// with the places a case is about replaced, so every shape a test projects
/// is one the schema's keys spell.
enum HomeFixture {
    static func golden() throws -> [String: Any] {
        let record = try #require(
            try ManagementFixtures.load(.success, from: .management).first { $0.name == "home_status" }
        )
        return try #require(try record.object("response")["result"] as? [String: Any])
    }

    /// The golden primary with nothing under way: no window, no server that
    /// checked in and no move, which is where a case starts from.
    static func status(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> ManagementHomeStatus {
        var picture = try golden()
        picture["enrollment"] = NSNull()
        picture["candidates"] = [Any]()
        picture["move"] = NSNull()
        change(&picture)

        return try JSONDecoder().decode(
            ManagementHomeStatus.self,
            from: try JSONSerialization.data(withJSONObject: picture)
        )
    }

    /// A desktop's picture: the device role, the marker, and the primary it
    /// reaches as the rail reports it, by the link's word and sentence.
    static func device(connected: Bool, link: String? = nil, sentence: String? = nil) throws -> ManagementHomeStatus {
        try status { picture in
            picture["role"] = "device"
            picture["moved"] = ["to": "fermix-vm", "moved_at": "2026-10-27T08:00:00Z", "epoch": 5]
            picture["primary"] = [
                "name": "fermix-vm",
                "connected": connected,
                "status": link ?? (connected ? "connected" : "unreachable"),
                "since": connected ? "2026-10-27T08:01:00Z" : NSNull(),
                "epoch": 5,
                "sentence": sentence ?? (connected
                    ? "Connected to fermix-vm."
                    : "The server fermix-vm is unreachable. Fermix keeps your message until it is back.")
            ] as [String: Any]
        }
    }

    /// A linked desktop that carries its server's own picture, the golden
    /// primary changed as a case needs, or the sentence for why it is missing.
    static func desktop(
        missing: String? = nil,
        server change: (inout [String: Any]) -> Void = { _ in }
    ) throws -> ManagementHomeStatus {
        var server = try golden()
        server["enrollment"] = NSNull()
        server["candidates"] = [Any]()
        server["move"] = NSNull()
        server["secrets_missing"] = [Any]()
        change(&server)

        return try status { picture in
            picture["role"] = "device"
            picture["moved"] = ["to": "fermix-vm", "moved_at": "2026-10-27T08:00:00Z", "epoch": 5]
            picture["move"] = ["phase": "done", "candidate": "fermix-vm", "sentence": "This home moved to fermix-vm; this computer is now a desktop of it."]
            picture["secrets_missing"] = [Any]()
            var own = picture["snapshots"] as? [String: Any] ?? [:]
            own["configured"] = false
            own["recipient_set"] = false
            own["targets"] = [Any]()
            own["sentence"] = "Snapshots are the primary's to write; this engine runs in the device role."
            picture["snapshots"] = own
            picture["primary_home"] = missing == nil ? server : NSNull()
            picture["primary_missing"] = missing ?? NSNull()
        }
    }

    static let serverAway = "The server fermix-vm is unreachable. Fermix keeps your message until it is back."

    /// A readiness report with one item that blocks.
    static let blocked = ManagementMoveReadiness(
        ready: false,
        items: [
            ManagementReadinessItem(
                id: "keychain_secrets",
                status: .block,
                sentence: "Fermix could not read anthropic_api_key from this computer's keychain."
            )
        ]
    )

    static func moving(_ phase: String, role: String = "primary") throws -> ManagementHomeStatus {
        try status { picture in
            picture["role"] = role
            picture["move"] = ["phase": phase, "candidate": "fermix-vm", "sentence": "The move stands at \(phase)."]
        }
    }

    static let candidate: [String: Any] = [
        "candidate_id": "cand-4f2a9c1e7b3d5a60",
        "name": "fermix-vm",
        "os": "linux",
        "arch": "arm64",
        "version": "0.18.0",
        "node_id": String(repeating: "a", count: 64),
        "instance": [
            "provider": "aws",
            "instance_id": "i-0abc1234def567890",
            "region": "eu-west-1",
            "account_id": "123456789012"
        ],
        "snapshots": NSNull(),
        "enrolled_at": "2026-10-27T09:00:00Z",
        "expires_at": "2026-10-28T09:00:00Z"
    ]

    static func window(_ state: String, candidates: [[String: Any]] = []) throws -> ManagementHomeStatus {
        try status { picture in
            picture["enrollment"] = ["state": state, "expires_at": "2026-10-27T09:10:00Z"]
            picture["candidates"] = candidates
        }
    }

    static let handout = EnrollmentHandout(code: "fxenroll1.invented-code-for-a-test", expiresAt: "2026-10-27T09:10:00Z")
}

/// A pane model over the daemon double, with the polls a case allows.
@MainActor
struct AlwaysOnHarness {
    let gateway: FakeDaemonGateway
    let settings: SettingsModel
    let model: AlwaysOnModel

    init(polls: Int = 0) throws {
        gateway = try SettingsFixture.gateway()
        gateway.hello = try FakeDaemonGateway.fixtureResult(named: "hello", as: ManagementHello.self)
        settings = SettingsFixture.model(gateway: gateway)
        model = AlwaysOnModel(settings: settings, sleeper: LimitedSleeper(allowing: polls))
        AlwaysOnHarness.retained.append(settings)
    }

    /// The settings model each case built, kept for the run: the pane model's
    /// reference to it is unowned, as in the app.
    static var retained: [SettingsModel] = []
}

@Suite("Always On")
@MainActor
struct AlwaysOnTests {
    // MARK: - The contract's own shapes

    @Test("the golden picture decodes, and a primary home is the primary stage")
    func goldenPicture() throws {
        let home = try FakeDaemonGateway.fixtureResult(named: "home_status", as: ManagementHomeStatus.self)

        #expect(home.role == .primary)
        #expect(home.epoch == 4)
        #expect(home.moved == nil && home.primary == nil)
        #expect(home.secretsMissing == ["anthropic_api_key"])
        #expect(home.primaryHome == nil && home.primaryMissing == nil)
        #expect(home.snapshots.configured && home.snapshots.recipientSet)
        #expect(home.snapshots.targets.map(\.lastResult) == [.verified])
        #expect(home.snapshots.targets.first?.lastVerified?.name == "20261027T093000Z-e4.fxsnap")
        #expect(AlwaysOnStage.stage(.loaded(home)) == .primary)

        // The golden home used its window, holds the server that checked in,
        // and undid a move to it: the steps review that server, under the
        // daemon's sentence about the undone move.
        #expect(home.enrollment?.state == .used)
        #expect(home.candidates.map(\.name) == ["north-box"])
        #expect(home.move?.phase == .aborted)
        #expect(AlwaysOnSetupStep.step(home, handout: nil, moveRequested: false, restarting: false) == .review(home.candidates))
        #expect(AlwaysOnSetupStep.undoneMove(home) == "The move to north-box was undone; this home is still the primary.")
        #expect(AlwaysOnSetupStep.step(try HomeFixture.status(), handout: nil, moveRequested: false, restarting: false) == .choose)
    }

    @Test("the paired devices name their kind, a desktop its switch, and the phones are the phone rows")
    func deviceKinds() throws {
        let list = try FakeDaemonGateway.fixtureResult(named: "mobile_devices_list", as: ManagementMobileDevices.self)
        let switched = try FakeDaemonGateway.fixtureResult(named: "mobile_devices_set_executor", as: ManagementMobileDevice.self)

        #expect(list.devices.map(\.kind) == [.phone, .desktop])
        #expect(list.devices.map(\.executor) == [nil, true])
        #expect(list.phones.map(\.name) == ["Sam's phone"])
        #expect(switched.kind == .desktop && switched.executor == false)
    }

    @Test("the enrollment, the servers that checked in and a started move decode as the contract publishes them")
    func moveAnswers() throws {
        let code = try FakeDaemonGateway.fixtureResult(named: "home_enroll_open", as: ManagementEnrollmentCode.self)
        let held = try FakeDaemonGateway.fixtureResult(named: "home_candidates_list", as: ManagementCandidates.self)
        let started = try FakeDaemonGateway.fixtureResult(named: "home_move_start", as: ManagementMoveStarted.self)

        #expect(code.code.hasPrefix("fxenroll1."))
        #expect(code.expiresAt == "2026-10-27T09:40:00Z")
        #expect(held.candidates.map(\.candidateId) == ["cand-5e2a9c1f7b3d4086"])
        #expect(
            held.candidates.first?.instance
                == ManagementCandidateInstance(provider: "aws", instanceId: "i-0a1b2c3d4e5f60718", region: "eu-central-1", accountId: "111122223333")
        )
        #expect(started.moveId.hasPrefix("mv-"))
        #expect(started.candidate == held.candidates.first)
    }

    @Test("the snapshot answers decode: a run started, and a recovery key with its short id")
    func snapshotAnswers() throws {
        let run = try FakeDaemonGateway.fixtureResult(named: "home_snapshots_run", as: ManagementSnapshotsStarted.self)
        let key = try FakeDaemonGateway.fixtureResult(named: "home_snapshots_passphrase", as: ManagementRecoveryKey.self)

        #expect(run.started && run.snapshots.running)
        #expect(key.keyId == "08c15ca36dd935c4")
        #expect(key.recipient.hasPrefix("fxsnap1."))
    }

    @Test("a forwarded call while the server is out of reach says the daemon's sentence, naming it")
    func primaryUnreachableSentence() throws {
        let refusal = try ManagementRefusal.published("primary_unreachable")

        #expect(ManagementMessage.code(of: refusal) == .primaryUnreachable)
        #expect(
            ManagementMessage.sentence(for: refusal)
                == "The server fermix-vm is unreachable. Fermix keeps your message until it is back."
        )
        #expect(SettingsReadState<ManagementHomeStatus>.failure(refusal) == .unavailable(ManagementMessage.sentence(for: refusal)))
    }

    // MARK: - Projections

    @Test("a linked desktop draws its server, connected, with the rail's sentence and since when")
    func linkedDesktop() throws {
        let home = try HomeFixture.device(connected: true)
        let line = try #require(AlwaysOnPrimaryLine.line(home))

        #expect(AlwaysOnStage.stage(.loaded(home)) == .device)
        #expect(line == AlwaysOnPrimaryLine(name: "fermix-vm", tone: .pass, sentence: "Connected to fermix-vm.", since: "2026-10-27T08:01:00Z"))
    }

    @Test("an unlinked desktop draws its server in the daemon's words, with no time")
    func unlinkedDesktop() throws {
        let line = try #require(AlwaysOnPrimaryLine.line(try HomeFixture.device(connected: false)))

        #expect(line.tone == .warn)
        #expect(line.since == nil)
        #expect(line.sentence == "The server fermix-vm is unreachable. Fermix keeps your message until it is back.")

        // A desktop with no link reported names the server its marker names,
        // and says nothing the daemon did not.
        let markerOnly = try HomeFixture.status { picture in
            picture["role"] = "device"
            picture["moved"] = ["to": "fermix-vm", "moved_at": "2026-10-27T08:00:00Z", "epoch": 5]
        }
        #expect(AlwaysOnPrimaryLine.line(markerOnly) == AlwaysOnPrimaryLine(name: "fermix-vm", tone: .neutral, sentence: nil, since: nil))
        #expect(AlwaysOnPrimaryLine.line(try HomeFixture.status()) == nil)
    }

    @Test("a move under way is drawn in its own words in every pending phase, and followed")
    func pendingPhases() async throws {
        for phase in ["requested", "streaming", "committing", "aborting"] {
            let home = try HomeFixture.moving(phase)
            let step = AlwaysOnSetupStep.step(home, handout: nil, moveRequested: false, restarting: false)

            #expect(step == .moving(try #require(home.move)), "\(phase)")
            #expect(home.move?.phase.isPending == true, "\(phase)")
        }
    }

    @Test("a move that ended is not drawn as moving, and an undone one says so above the steps")
    func endedPhases() throws {
        let done = try HomeFixture.moving("done")
        let aborted = try HomeFixture.moving("aborted")

        #expect(AlwaysOnSetupStep.step(done, handout: nil, moveRequested: false, restarting: false) == .choose)
        #expect(AlwaysOnSetupStep.step(aborted, handout: nil, moveRequested: false, restarting: false) == .choose)
        #expect(AlwaysOnSetupStep.undoneMove(aborted) == "The move stands at aborted.")
        #expect(AlwaysOnSetupStep.undoneMove(done) == nil)
        for phase in [ManagementMovePhase.done, .aborted, .expired, .failed] {
            #expect(!phase.isPending, "\(phase.wireValue)")
        }
        for phase in [ManagementMovePhase.enrolling, .enrolled, .receiving, .staged, .activating] {
            #expect(phase.isPending, "\(phase.wireValue)")
        }
        // The engine about to restart, as a desktop or back as the primary,
        // is no ending: only the engine that comes back writes one.
        #expect(ManagementMovePhase(wireValue: "committed") == .committed)
        #expect(ManagementMovePhase(wireValue: "undoing") == .undoing)
        for phase in [ManagementMovePhase.committed, .undoing] {
            #expect(phase.isPending, "\(phase.wireValue)")
            #expect(
                AlwaysOnSetupStep.step(try HomeFixture.moving(phase.wireValue), handout: nil, moveRequested: false, restarting: false)
                    == .moving(try #require(try HomeFixture.moving(phase.wireValue).move))
            )
        }
    }

    @Test("a role this build does not know is named, never folded onto a known one")
    func unknownRole() throws {
        let home = try HomeFixture.status { $0["role"] = "observer" }
        let candidate = try HomeFixture.status { $0["role"] = "candidate" }

        #expect(AlwaysOnStage.stage(.loaded(home)) == .unknownRole("observer"))
        #expect(AlwaysOnStage.stage(.loaded(candidate)) == .candidate)
    }

    @Test("the steps follow the window: waiting, servers that checked in, and a code spent")
    func enrollmentSteps() throws {
        let open = try HomeFixture.window("open")
        let checkedIn = try HomeFixture.window("used", candidates: [HomeFixture.candidate])

        #expect(AlwaysOnSetupStep.step(open, handout: HomeFixture.handout, moveRequested: false, restarting: false) == .code(HomeFixture.handout))
        #expect(AlwaysOnSetupStep.step(open, handout: nil, moveRequested: false, restarting: false) == .waiting)
        #expect(AlwaysOnSetupStep.step(checkedIn, handout: HomeFixture.handout, moveRequested: false, restarting: false) == .review(checkedIn.candidates))
        #expect(AlwaysOnSetupStep.spendsCode(checkedIn))
        #expect(AlwaysOnSetupStep.spendsCode(try HomeFixture.window("expired")))
        #expect(!AlwaysOnSetupStep.spendsCode(open))
    }

    @Test("a server's instance facts decode as it reported them")
    func candidateFacts() throws {
        let candidate = try #require(try HomeFixture.window("used", candidates: [HomeFixture.candidate]).candidates.first)

        #expect(candidate.instance == ManagementCandidateInstance(provider: "aws", instanceId: "i-0abc1234def567890", region: "eu-west-1", accountId: "123456789012"))
        #expect(candidate.candidateId == "cand-4f2a9c1e7b3d5a60")
    }

    @Test("recovery: a failed target is amber, a verified point is named, and Back up now only where configured")
    func recovery() throws {
        let golden = try HomeFixture.status()
        let failing = try HomeFixture.status { picture in
            var snapshots = picture["snapshots"] as? [String: Any] ?? [:]
            var target = (snapshots["targets"] as? [[String: Any]])?.first ?? [:]
            target["last_result"] = "failed"
            target["last_error"] = "S3 refused the upload: AccessDenied."
            snapshots["targets"] = [target]
            picture["snapshots"] = snapshots
        }
        let device = try HomeFixture.status { picture in
            var snapshots = picture["snapshots"] as? [String: Any] ?? [:]
            snapshots["configured"] = false
            picture["snapshots"] = snapshots
        }

        #expect(AlwaysOnRecoveryProjection.tone(golden.snapshots) == .pass)
        #expect(AlwaysOnRecoveryProjection.tone(failing.snapshots) == .warn)
        #expect(failing.snapshots.targets.first?.lastError == "S3 refused the upload: AccessDenied.")
        #expect(AlwaysOnRecoveryProjection.offersBackup(golden.snapshots))
        #expect(!AlwaysOnRecoveryProjection.offersBackup(device.snapshots))

        let target = try #require(golden.snapshots.targets.first)
        #expect(AlwaysOnRecoveryProjection.verifiedLine(target) { _ in "09:30" } == String(format: ProductStrings[.alwaysOnRecoveryLastVerifiedFormat], "09:30"))
    }

    // MARK: - The passphrase

    @Test("the passphrase is sent only when it is typed twice the same, and the mismatch waits for the second")
    func passphraseMatchRule() {
        var entry = RecoveryPassphraseEntry()
        #expect(!entry.matches && entry.passphrase == nil && !entry.showsMismatch)

        entry.first = "invented-lighthouse-meridian"
        #expect(!entry.matches && !entry.showsMismatch)

        entry.second = "invented-lighthouse"
        #expect(!entry.matches && entry.showsMismatch && entry.passphrase == nil)

        entry.second = "invented-lighthouse-meridian"
        #expect(entry.matches && !entry.showsMismatch)
        #expect(entry.passphrase == "invented-lighthouse-meridian")

        entry.clear()
        #expect(entry == RecoveryPassphraseEntry())
    }

    // MARK: - The model

    @Test("the code is held only while the pane shows it, and nothing reads it again")
    func codeShownOnce() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.enrollmentResult = ManagementEnrollmentCode(code: HomeFixture.handout.code, expiresAt: HomeFixture.handout.expiresAt)
        harness.gateway.homeStatusScript = [.success(try HomeFixture.window("open"))]

        await harness.model.openEnrollment()

        #expect(harness.model.handout == HomeFixture.handout)
        #expect(harness.model.setupStep == .code(HomeFixture.handout))
        #expect(harness.model.moves, "the window is followed while no server has checked in")

        harness.model.forgetCode()

        #expect(harness.model.handout == nil)
        #expect(harness.model.setupStep == .waiting)
        await harness.model.refresh()
        #expect(harness.model.handout == nil, "no read brings a handed code back")
    }

    @Test("a server checking in spends the code the pane held")
    func checkInSpendsTheCode() async throws {
        let harness = try AlwaysOnHarness(polls: 1)
        harness.gateway.enrollmentResult = ManagementEnrollmentCode(code: HomeFixture.handout.code, expiresAt: HomeFixture.handout.expiresAt)
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.window("open")),
            .success(try HomeFixture.window("open")),
            .success(try HomeFixture.window("used", candidates: [HomeFixture.candidate]))
        ]
        await harness.model.openEnrollment()

        await harness.model.follow()

        #expect(harness.model.handout == nil)
        #expect(harness.model.setupStep == .review(try HomeFixture.window("used", candidates: [HomeFixture.candidate]).candidates))
    }

    @Test("a refused window says the daemon's sentence and holds no code")
    func refusedEnrollment() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.v2Failures[.homeEnrollOpen] = ManagementRefusal.daemon(.unavailable, "The requested management capability is unavailable.")

        await harness.model.openEnrollment()

        #expect(harness.model.handout == nil)
        #expect(harness.model.enrollRefusal == "The requested management capability is unavailable.")
    }

    @Test("the move sends the chosen server and the passphrase once, then follows the engine")
    func startMove() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.homeStatusScript = [.success(try HomeFixture.window("used", candidates: [HomeFixture.candidate]))]
        await harness.model.refresh()

        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        #expect(harness.gateway.moveStarts == [MoveStart(candidateId: "cand-4f2a9c1e7b3d5a60", passphrase: "invented-lighthouse-meridian")])
        #expect(harness.gateway.moveStarts.first?.keepAsDesktop == true, "the Mac that moves stays a desktop")
        #expect(harness.model.moveRequested)
        #expect(harness.model.chosenCandidate == nil)
        #expect(harness.model.moves)
        #expect(harness.model.setupStep == .restarting)
    }

    @Test("a refused move keeps the server chosen and says the daemon's sentence")
    func refusedMove() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.v2Failures[.homeMoveStart] = try ManagementRefusal.published("invalid_params_with_sentence")
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")

        await harness.model.startMove(passphrase: "short")

        #expect(!harness.model.moveRequested)
        #expect(harness.model.chosenCandidate == "cand-4f2a9c1e7b3d5a60")
        #expect(harness.model.moveRefusal == ManagementMessage.sentence(for: try ManagementRefusal.published("invalid_params_with_sentence")))
    }

    /// The engine's own order: it restarts into the device role, streams,
    /// records `committed` and restarts again, and only the desktop that comes
    /// back writes `done`. Every picture between is followed, each restart is
    /// re-read as any restart is, and the follow ends on `done` alone.
    @Test("the move is followed across both of the engine's restarts, through committed, until the engine that came back says done")
    func moveAcrossRestart() async throws {
        let harness = try AlwaysOnHarness(polls: 8)
        let away = Result<ManagementHomeStatus, any Error>.failure(
            ManagementError.transport(.daemonNotListening(path: "/tmp/fermix-test/daemon.sock"))
        )
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.window("used", candidates: [HomeFixture.candidate])),
            away,
            .success(try HomeFixture.moving("streaming", role: "device")),
            .success(try HomeFixture.moving("streaming", role: "device")),
            .success(try HomeFixture.moving("committed", role: "device")),
            away,
            .success(try HomeFixture.desktop())
        ]
        await harness.model.refresh()
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")
        let negotiationsBefore = harness.gateway.calls.filter { $0 == .negotiate }.count

        await harness.model.follow()

        #expect(!harness.model.moveRequested, "the move ended on done")
        #expect(!harness.model.restarting)
        #expect(harness.model.stage == .device)
        #expect(harness.model.status.value?.move?.phase == .done)
        #expect(
            harness.gateway.calls.filter { $0 == .v2(.settingsSections) }.count == 2,
            "each of the two restarts re-read what Settings shows"
        )
        #expect(harness.gateway.calls.filter { $0 == .negotiate }.count >= negotiationsBefore)
        #expect(!harness.model.moves)
    }

    @Test("an ending is read from the engine that came back, so Settings is read again even where no read fell in its restart")
    func endingIsTheEngineThatCameBack() async throws {
        let harness = try AlwaysOnHarness(polls: 4)
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.window("used", candidates: [HomeFixture.candidate])),
            .success(try HomeFixture.moving("committed", role: "device")),
            .success(try HomeFixture.moving("committed", role: "device")),
            .success(try HomeFixture.desktop())
        ]
        await harness.model.refresh()
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        await harness.model.follow()

        #expect(!harness.model.moveRequested)
        #expect(
            harness.gateway.calls.filter { $0 == .v2(.settingsSections) }.count == 2,
            "the role change and the ending each re-read Settings"
        )
    }

    @Test("an undone move is followed through undoing until the primary that came back says aborted, under its sentence")
    func undoneMoveAcrossRestart() async throws {
        let harness = try AlwaysOnHarness(polls: 6)
        let aborted = try HomeFixture.status { picture in
            picture["candidates"] = [HomeFixture.candidate]
            picture["move"] = [
                "phase": "aborted",
                "candidate": "fermix-vm",
                "sentence": "The move to fermix-vm was undone; this home is still the primary."
            ]
        }
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.window("used", candidates: [HomeFixture.candidate])),
            .success(try HomeFixture.moving("aborting", role: "device")),
            .success(try HomeFixture.moving("undoing", role: "device")),
            .success(try HomeFixture.moving("undoing", role: "device")),
            .failure(ManagementError.transport(.daemonNotListening(path: "/tmp/fermix-test/daemon.sock"))),
            .success(aborted)
        ]
        await harness.model.refresh()
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        await harness.model.follow()

        #expect(!harness.model.moveRequested)
        #expect(harness.model.stage == .primary)
        #expect(harness.model.setupStep == .review(aborted.candidates))
        #expect(AlwaysOnSetupStep.undoneMove(aborted) == "The move to fermix-vm was undone; this home is still the primary.")
    }

    @Test("opening the pane while the engine restarts for a move says restarting and keeps the last picture, not a refusal")
    func openingThePaneDuringTheRestart() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.window("used", candidates: [HomeFixture.candidate])),
            .failure(ManagementError.transport(.daemonNotListening(path: "/tmp/fermix-test/daemon.sock")))
        ]
        await harness.model.refresh()
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        // The pane is opened again: its first read meets the engine away.
        await harness.model.refresh()

        #expect(harness.model.restarting)
        #expect(harness.model.status.value != nil, "the last picture stays")
        #expect(harness.model.stage == .primary)
        #expect(harness.model.setupStep == .restarting)
    }

    @Test("a move found under way on the picture is followed across the restart as one asked for here")
    func moveFoundUnderWay() async throws {
        let harness = try AlwaysOnHarness(polls: 4)
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.moving("streaming", role: "device")),
            .success(try HomeFixture.moving("committed", role: "device")),
            .failure(ManagementError.transport(.daemonNotListening(path: "/tmp/fermix-test/daemon.sock"))),
            .success(try HomeFixture.desktop())
        ]
        await harness.model.refresh()

        await harness.model.follow()

        #expect(!harness.model.moveRequested)
        #expect(harness.model.status.value?.move?.phase == .done)
        #expect(harness.gateway.calls.contains(.v2(.settingsSections)), "the engine that came back was re-read")
    }

    @Test("while the engine is away for the move the pane says it is restarting, not that it refused")
    func restartingIsNotARefusal() async throws {
        let harness = try AlwaysOnHarness(polls: 0)
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.window("used", candidates: [HomeFixture.candidate])),
            .failure(ManagementError.transport(.daemonNotListening(path: "/tmp/fermix-test/daemon.sock")))
        ]
        await harness.model.refresh()
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        await harness.model.follow()

        #expect(harness.model.restarting)
        #expect(harness.model.status.value != nil, "the last picture stays while the engine is away")
        #expect(harness.model.setupStep == .restarting)
    }

    @Test("Back up now starts a snapshot and reads the picture again; a refusal is the daemon's sentence")
    func backUpNow() async throws {
        let harness = try AlwaysOnHarness()

        await harness.model.backUpNow()

        #expect(harness.gateway.calls.contains(.v2(.homeSnapshotsRun)))
        #expect(harness.model.status.value?.snapshots.configured == true)
        #expect(harness.model.backupRefusal == nil)

        let refused = try AlwaysOnHarness()
        refused.gateway.v2Failures[.homeSnapshotsRun] = try ManagementRefusal.published("unavailable")
        await refused.model.backUpNow()
        #expect(refused.model.backupRefusal == ManagementMessage.sentence(for: try ManagementRefusal.published("unavailable")))
    }

    @Test("the recovery passphrase is sent once and the snapshots section read again")
    func recoveryPassphrase() async throws {
        let harness = try AlwaysOnHarness()

        let taken = await harness.model.setRecoveryPassphrase("invented-lighthouse-meridian")

        #expect(taken)
        #expect(harness.gateway.recoveryPassphrases == ["invented-lighthouse-meridian"])
        #expect(harness.gateway.readSections.contains(AlwaysOnSections.snapshots))
        #expect(
            harness.model.passphraseNotice
                == "Snapshots from now on open with this passphrase (key 08c15ca36dd935c4); those written before now open only with the earlier passphrase."
        )
    }

    @Test("a desktop's switch is sent by its id, and a refusal stays under its row")
    func executorSwitch() async throws {
        let harness = try AlwaysOnHarness()

        await harness.model.setExecutor(false, deviceId: "c41e9d27-5a8b-4f63-9e20-7d1b3c5a8f94")

        #expect(harness.gateway.executorWrites == [ExecutorWrite(deviceId: "c41e9d27-5a8b-4f63-9e20-7d1b3c5a8f94", executor: false)])
        #expect(harness.model.executorRefusals.isEmpty)

        harness.gateway.v2Failures[.mobileDevicesSetExecutor] = try ManagementRefusal.published("invalid_params_with_sentence")
        await harness.model.setExecutor(true, deviceId: "c41e9d27-5a8b-4f63-9e20-7d1b3c5a8f94")
        #expect(harness.model.executorRefusals["c41e9d27-5a8b-4f63-9e20-7d1b3c5a8f94"] != nil)
    }

    @Test("a primary with desktops lists each with its switch")
    func primaryWithDesktops() throws {
        let home = try HomeFixture.status { picture in
            picture["desktops"] = [[
                "device_id": "c41e9d27-5a8b-4f63-9e20-7d1b3c5a8f94",
                "name": "Studio Mac",
                "connected": true,
                "since": "2026-10-27T08:01:00Z",
                "executor": true
            ] as [String: Any]]
        }

        #expect(AlwaysOnStage.stage(.loaded(home)) == .primary)
        #expect(home.desktops == [ManagementHomeDesktop(deviceId: "c41e9d27-5a8b-4f63-9e20-7d1b3c5a8f94", name: "Studio Mac", connected: true, since: "2026-10-27T08:01:00Z", executor: true)])
    }

    // MARK: - The readiness report

    @Test("the readiness golden decodes: each fact in order with its status and the daemon's sentence")
    func readinessGolden() throws {
        let report = try FakeDaemonGateway.fixtureResult(named: "home_move_readiness", as: ManagementMoveReadiness.self)

        #expect(report.ready)
        #expect(
            report.items.map(\.id)
                == ["keychain_secrets", "engine_version", "disk", "s3_size", "plugins", "stays_here", "cutover_gap", "serves_nothing"]
        )
        #expect(report.items.map(AlwaysOnReadinessProjection.tone) == [.pass, .pass, .pass, .pass, .pass, .warn, .warn, .warn])
        #expect(report.items.allSatisfy { !$0.sentence.isEmpty })
        #expect(AlwaysOnReadinessProjection.tone(try #require(HomeFixture.blocked.items.first)) == .fail)
    }

    @Test("choosing a server reads its readiness report, and the move starts only once it is read and nothing blocks")
    func readinessGatesTheMove() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.homeStatusScript = [.success(try HomeFixture.window("used", candidates: [HomeFixture.candidate]))]
        await harness.model.refresh()
        #expect(!harness.model.mayStartMove, "nothing is chosen, so nothing may start")

        harness.gateway.readinessResult = HomeFixture.blocked
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")

        #expect(harness.gateway.readinessAsked == ["cand-4f2a9c1e7b3d5a60"])
        #expect(harness.model.readiness == .loaded(HomeFixture.blocked))
        #expect(!harness.model.mayStartMove)

        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")
        #expect(harness.gateway.moveStarts.isEmpty, "a report that blocks keeps the move from starting")
        #expect(!harness.model.moveRequested)

        harness.gateway.readinessResult = nil
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        #expect(harness.model.mayStartMove)

        harness.model.withdrawChoice()
        #expect(harness.model.readiness == .unread)
        #expect(!harness.model.mayStartMove)
    }

    @Test("a readiness report the daemon refuses says its sentence and keeps the move from starting")
    func refusedReadiness() async throws {
        let harness = try AlwaysOnHarness()
        let refusal = try ManagementRefusal.published("unavailable_home_owner_decision")
        harness.gateway.v2Failures[.homeMoveReadiness] = refusal

        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        #expect(harness.model.readiness == .unavailable(ManagementMessage.sentence(for: refusal)))
        #expect(!harness.model.mayStartMove)
        #expect(harness.gateway.moveStarts.isEmpty)
    }

    // MARK: - Secrets, the server's recovery, and replacing it

    @Test("the secrets the home could not resolve are named in Recovery: the primary's own, and on a desktop the server's")
    func secretsMissing() throws {
        let golden = try FakeDaemonGateway.fixtureResult(named: "home_status", as: ManagementHomeStatus.self)
        let desktop = try HomeFixture.desktop { $0["secrets_missing"] = ["telegram_bot_token"] }

        #expect(AlwaysOnRecoveryProjection.secretsMissing(golden) == ["anthropic_api_key"])
        #expect(AlwaysOnRecoveryProjection.secretsMissing(desktop) == ["telegram_bot_token"])
        #expect(AlwaysOnRecoveryProjection.secretsMissing(try HomeFixture.desktop(missing: HomeFixture.serverAway)).isEmpty)
        #expect(
            String(format: ProductStrings[.alwaysOnSecretsMissingFormat], "anthropic_api_key").contains("anthropic_api_key")
        )
    }

    @Test("a desktop's Recovery is the server's own, reached through it, or the daemon's sentence while it is missing")
    func desktopRecoverySource() throws {
        let linked = try HomeFixture.desktop()
        let server = try #require(linked.server)

        #expect(linked.snapshots.targets.isEmpty, "a desktop's own status file is a retired copy")
        #expect(AlwaysOnRecoveryProjection.source(linked) == .snapshots(server.snapshots, setsKey: true))
        #expect(AlwaysOnRecoveryProjection.offersBackup(server.snapshots))
        #expect(
            AlwaysOnRecoveryProjection.source(try HomeFixture.desktop(missing: HomeFixture.serverAway))
                == .missing(HomeFixture.serverAway)
        )

        let unlinked = try HomeFixture.status { picture in
            picture["role"] = "device"
            picture["moved"] = ["to": "fermix-vm", "moved_at": "2026-10-27T08:00:00Z", "epoch": 5]
        }
        #expect(AlwaysOnRecoveryProjection.source(unlinked) == .snapshots(unlinked.snapshots, setsKey: false))
        let primary = try HomeFixture.status()
        #expect(AlwaysOnRecoveryProjection.source(primary) == .snapshots(primary.snapshots, setsKey: true))
    }

    @Test("a desktop replaces its server through the server's own picture, and the server is not kept as a desktop")
    func replaceTheServer() async throws {
        let harness = try AlwaysOnHarness(polls: 4)
        let review = try HomeFixture.desktop { server in
            server["enrollment"] = ["state": "used", "expires_at": "2026-10-27T09:40:00Z"]
            server["candidates"] = [HomeFixture.candidate]
        }
        let requested = try HomeFixture.desktop { server in
            server["move"] = [
                "phase": "requested",
                "candidate": "fermix-vm",
                "sentence": "The move to fermix-vm starts when Fermix restarts."
            ]
        }
        let away = try HomeFixture.desktop(missing: HomeFixture.serverAway)
        harness.gateway.homeStatusScript = [
            .success(review), .success(away), .success(requested), .success(away), .success(try HomeFixture.desktop())
        ]
        await harness.model.refresh()

        #expect(harness.model.replacesServer)
        #expect(harness.model.setupStep == .review(try #require(review.server).candidates))
        #expect(harness.model.setupPicture == review.server)

        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        #expect(harness.gateway.readinessAsked == ["cand-4f2a9c1e7b3d5a60"])
        #expect(
            harness.gateway.moveStarts
                == [MoveStart(candidateId: "cand-4f2a9c1e7b3d5a60", passphrase: "invented-lighthouse-meridian", keepAsDesktop: false)]
        )
        #expect(harness.model.replaceRequested && !harness.model.moveRequested)

        await harness.model.refresh()
        #expect(harness.model.setupStep == .restarting, "the server is away while it hands Fermix over")
        #expect(harness.model.moves)

        await harness.model.follow()

        #expect(!harness.model.replaceRequested, "the new server answered with no move under way")
        #expect(harness.gateway.calls.contains(.v2(.settingsSections)), "every setting is the new server's, read again")
        #expect(harness.model.setupStep == .choose)
        #expect(!harness.model.moves)
    }

    @Test("a desktop whose own move is still under way draws that move, not the server's replacement")
    func desktopOwnMoveFirst() async throws {
        let harness = try AlwaysOnHarness()
        let committing = try HomeFixture.moving("committed", role: "device")
        harness.gateway.homeStatusScript = [.success(committing)]

        await harness.model.refresh()

        #expect(!harness.model.replacesServer)
        #expect(harness.model.setupStep == .moving(try #require(committing.move)))
    }

    @Test("Back up now on a desktop asks the server, and the server's picture is read again")
    func backUpOnADesktop() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.homeStatusScript = [.success(try HomeFixture.desktop())]

        await harness.model.backUpNow()

        #expect(harness.gateway.calls.contains(.v2(.homeSnapshotsRun)))
        #expect(harness.model.status.value?.server?.snapshots.configured == true)
    }

    // MARK: - This Mac while the server is away

    @Test("Settings lists this Mac's own sections while the server's are missing, says why, and reads the index again once the server answers")
    func composedInventory() async throws {
        let harness = try AlwaysOnHarness()
        let golden = try FakeDaemonGateway.fixtureResult(named: "settings_sections", as: ManagementSettingsInventory.self)
        let local: Set<String> = ["engine", "sandbox", "computer_use", "computer_history", "channels.imessage"]
        let missing = "The server fermix-vm did not answer in time; its settings return when it is back."
        harness.gateway.settingsSectionsResult = ManagementSettingsInventory(
            sections: golden.sections.filter { local.contains($0.id) },
            primaryMissing: missing
        )

        await harness.settings.loadInventory()

        #expect(harness.settings.primaryMissing == missing)
        #expect(harness.settings.sections(for: .alwaysOn).map(\.id) == [AlwaysOnSections.engine])
        #expect(harness.settings.sections(for: .providers).isEmpty)

        // The server answers again: the pane's next read of the home brings
        // the whole index back.
        harness.gateway.settingsSectionsResult = nil
        harness.gateway.homeStatusScript = [.success(try HomeFixture.desktop())]
        await harness.model.refresh()

        #expect(harness.settings.primaryMissing == nil)
        #expect(harness.settings.sections(for: .alwaysOn).map(\.id) == [AlwaysOnSections.engine, AlwaysOnSections.snapshots])
    }

    @Test("a window opened on an index without the server's sections reads the index again")
    func partialIndexIsReadAgain() async throws {
        let harness = try AlwaysOnHarness()
        harness.gateway.settingsSectionsResult = ManagementSettingsInventory(sections: [], primaryMissing: HomeFixture.serverAway)

        await harness.settings.windowAppeared()
        await harness.settings.windowAppeared()
        #expect(harness.gateway.calls.filter { $0 == .v2(.settingsSections) }.count == 2)

        harness.gateway.settingsSectionsResult = nil
        await harness.settings.windowAppeared()
        await harness.settings.windowAppeared()
        #expect(harness.gateway.calls.filter { $0 == .v2(.settingsSections) }.count == 3, "a whole index is read once")
    }

    // MARK: - The snapshots' new words

    @Test("a target waiting for a desktop is no failure, says why, and each verified point names its key")
    func waitingTargetAndKey() throws {
        let waiting = "Your Studio Mac is not connected; the snapshot waits for the next run."
        let home = try HomeFixture.status { picture in
            var snapshots = picture["snapshots"] as? [String: Any] ?? [:]
            var target = (snapshots["targets"] as? [[String: Any]])?.first ?? [:]
            target["id"] = "desktop"
            target["label"] = "Studio Mac"
            target["last_result"] = "waiting"
            target["waiting"] = waiting
            snapshots["targets"] = [target]
            picture["snapshots"] = snapshots
        }
        let target = try #require(home.snapshots.targets.first)

        #expect(target.lastResult == .waiting)
        #expect(target.waiting == waiting)
        #expect(AlwaysOnRecoveryProjection.tone(target) == .neutral)
        #expect(AlwaysOnRecoveryProjection.tone(home.snapshots) == .pass)
        #expect(target.lastVerified?.keyId == "08c15ca36dd935c4")
        #expect(AlwaysOnRecoveryProjection.keyLine(target) == String(format: ProductStrings[.alwaysOnRecoveryKeyFormat], "08c15ca36dd935c4"))
    }

    // MARK: - The engine's last round: deadlines, lost answers, the link's word

    @Test("a move's readiness and its start wait 65 s, past a desktop's 60 s wait for its server; the home's other calls keep theirs")
    func moveCallsWaitLonger() {
        let policy = DefaultManagementTimeoutPolicy()

        #expect(policy.timeout(for: .homeMoveReadiness) == .seconds(65))
        #expect(policy.timeout(for: .homeMoveStart) == .seconds(65))
        for method in [ManagementMethod.homeStatus, .homeEnrollOpen, .homeCandidatesList, .homeSnapshotsStatus,
                       .homeSnapshotsRun, .homeSnapshotsPassphrase, .deviceGrantsList, .deviceGrantsRemove] {
            #expect(policy.timeout(for: method) == DefaultManagementTimeoutPolicy.standard, "\(method.rawValue)")
        }
    }

    @Test("a start whose answer was lost on its way from the server is no failure: its sentence shows and the server's picture is followed")
    func unconfirmedStart() async throws {
        let harness = try AlwaysOnHarness(polls: 4)
        let review = try HomeFixture.desktop { server in
            server["enrollment"] = ["state": "used", "expires_at": "2026-10-27T09:40:00Z"]
            server["candidates"] = [HomeFixture.candidate]
        }
        let lost = try ManagementRefusal.published("unconfirmed")
        harness.gateway.homeStatusScript = [
            .success(review),
            .success(try HomeFixture.desktop(missing: HomeFixture.serverAway)),
            .success(try HomeFixture.desktop())
        ]
        harness.gateway.v2Failures[.homeMoveStart] = lost
        await harness.model.refresh()
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")

        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        #expect(ManagementMessage.code(of: lost) == .unconfirmed)
        #expect(harness.model.moveRefusal == nil, "a lost answer is not a refusal")
        #expect(harness.model.moveNotice == ManagementMessage.sentence(for: lost))
        #expect(harness.model.moveNotice?.contains("did not confirm in time") == true)
        #expect(harness.model.replaceRequested)
        #expect(harness.model.chosenCandidate == nil)

        await harness.model.follow()

        #expect(!harness.model.replaceRequested, "the server answered again, with no move under way")
        #expect(harness.model.moveNotice == nil)
    }

    @Test("the link's word draws its dot: renewing quietly, an outage or a stale server amber, a revoked link red")
    func linkWord() throws {
        let cases: [(String, Bool, StatusTone, Bool)] = [
            ("connected", true, .pass, false),
            ("renewing", false, .neutral, false),
            ("unreachable", false, .warn, true),
            ("stale", false, .warn, true),
            ("revoked", false, .fail, true)
        ]
        for (word, connected, tone, attention) in cases {
            let sentence = "The link to fermix-vm is \(word)."
            let home = try HomeFixture.device(connected: connected, link: word, sentence: sentence)
            let line = try #require(AlwaysOnPrimaryLine.line(home))

            #expect(home.primary?.status == ManagementPrimaryLinkState(wireValue: word), "\(word)")
            #expect(line.tone == tone, "\(word)")
            #expect(line.attention == attention, "\(word)")
            #expect(line.sentence == sentence, "\(word): drawn by its own sentence")
        }
    }

    @Test("an ending the engine could not record is shown in its own sentence while the pane keeps reading, which retries it")
    func unrecordedEnding() async throws {
        let harness = try AlwaysOnHarness(polls: 1)
        let unrecorded = try HomeFixture.status { picture in
            picture["role"] = "device"
            picture["move"] = [
                "phase": "committed",
                "candidate": "fermix-vm",
                "sentence": "This home moved to fermix-vm; this computer is now a desktop of it. Fermix could not record that here (/Users/ana/.fermix/.move/phase.json: permission denied); it tries again each time this status is read."
            ]
        }
        harness.gateway.homeStatusScript = [
            .success(try HomeFixture.window("used", candidates: [HomeFixture.candidate])),
            .failure(ManagementError.transport(.daemonNotListening(path: "/tmp/fermix-test/daemon.sock"))),
            .success(unrecorded)
        ]
        await harness.model.refresh()
        await harness.model.choose(candidate: "cand-4f2a9c1e7b3d5a60")
        await harness.model.startMove(passphrase: "invented-lighthouse-meridian")

        await harness.model.follow()

        #expect(!harness.model.restarting, "the engine answered: it is back, not restarting")
        #expect(harness.model.moveRequested, "the pane keeps reading, and each read tries the record again")
        #expect(harness.model.setupStep == .moving(try #require(unrecorded.move)))
    }

    // MARK: - The folders the server may read on this Mac

    @Test("This Mac lists the folders the server may read here, in the daemon's words, and removes one by its folder")
    func readGrants() async throws {
        let harness = try AlwaysOnHarness()

        await harness.model.refreshGrants()

        let listed = try #require(harness.model.grants.value)
        #expect(listed.grants.map(\.path) == ["/Users/ana/Downloads", "/Users/ana/Taxes"])
        #expect(listed.sentence == "The server may read 2 folders on this computer beyond what its sandbox allows.")

        await harness.model.removeGrant(path: "/Users/ana/Downloads")

        #expect(harness.gateway.grantRemovalsAsked == ["/Users/ana/Downloads"])
        #expect(harness.model.grantNotice == "The server can no longer read that folder on this computer.")
        #expect(harness.model.grantRefusals.isEmpty)
        #expect(harness.gateway.calls.filter { $0 == .v2(.deviceGrantsList) }.count == 2, "the list is read again after a removal")
        #expect(harness.model.grantRemovals.isEmpty)
    }

    @Test("a removal the daemon refuses says its sentence under that folder")
    func refusedGrantRemoval() async throws {
        let harness = try AlwaysOnHarness()
        let refusal = try ManagementRefusal.published("unavailable_device_owner_decision")
        harness.gateway.v2Failures[.deviceGrantsRemove] = refusal

        await harness.model.removeGrant(path: "/Users/ana/Taxes")

        #expect(harness.model.grantRefusals["/Users/ana/Taxes"] == ManagementMessage.sentence(for: refusal))
        #expect(harness.model.grantNotice == nil)
    }

    @Test("the recovery key's footer is drawn as the engine words it, which names no command")
    func recoveryKeyFooter() throws {
        let section = try FakeDaemonGateway.fixtureResult(
            selecting: ["section": AlwaysOnSections.snapshots],
            as: ManagementSettingsSectionRows.self
        )
        let key = try #require(section.rows.first { $0.key == "snapshots_recipient" })
        let footer = try #require(key.footer)

        #expect(!footer.contains("fermix "), "\(footer)")
        #expect(!ProductCopyRules.namesACommandLine(footer))
    }

    // MARK: - Whether the pane is drawn

    @Test("the pane is drawn where hello lists the home, and a route to it is refused where it does not")
    func paneGate() async throws {
        let harness = try AlwaysOnHarness()
        await harness.settings.refreshCueGate()

        #expect(harness.settings.draws(.alwaysOn))
        #expect(!harness.settings.refusesRoute(to: .alwaysOn))

        let older = try SettingsFixture.gateway()
        let settings = SettingsFixture.model(gateway: older)
        await settings.refreshCueGate()

        #expect(!settings.draws(.alwaysOn))
        #expect(settings.refusesRoute(to: .alwaysOn))
    }

    @Test("an N-1 daemon is the newer-engine state, never an empty pane")
    func n1Daemon() async throws {
        let gateway = try SettingsFixture.n1Gateway()
        let settings = SettingsFixture.model(gateway: gateway)
        let model = AlwaysOnModel(settings: settings, sleeper: NoWaitSleeper())

        await model.refresh()

        #expect(model.stage == .requiresNewerEngine)
    }

    @Test("the pane's copy keeps the voice rules and names no command the app runs for the owner")
    func copy() {
        for key in ProductStringKey.allCases where key.rawValue.hasPrefix("alwaysOn.") {
            #expect(ProductCopyRules.violations(in: ProductStrings[key]).isEmpty, "\(key.rawValue)")
            #expect(!ProductCopyRules.namesACommandLine(ProductStrings[key]), "\(key.rawValue)")
        }
        #expect(SettingsPane.alwaysOn.title == "Always On")
        #expect(AlwaysOnGuide.url.absoluteString == "https://fermix.ai/docs/always-on")
    }
}

/// The chat after a move: a device card is drawn and answered as the others.
@Suite("Always On chat")
@MainActor
struct AlwaysOnChatTests {
    /// The card the engine sends for a command it would run on a desktop,
    /// shaped as `Companion.Output.approval/1` writes it.
    static let deviceCard = Data(
        """
        {"type":"approval","approval_id":"device-Zq3","kind":"device","text":"Run this command on your Studio Mac? It runs there, inside that computer's own sandbox.\\nComputer: Studio Mac\\nCommand: ls -la ~/Documents","token":"opaque-token","ttl_s":60,"approve_command":"/confirm opaque-token","deny_command":"/deny opaque-token"}
        """.utf8
    )

    @Test("a device card is held and drawn with its computer and command, and answered by its routes")
    func deviceApproval() throws {
        let event = try CompanionServerEvent.decode(Self.deviceCard)
        guard case .approval(let card) = event else {
            Issue.record("a device card decoded as \(event.wireType)")
            return
        }
        var chat = CompanionChat()
        _ = CompanionReducer.receive(event, into: &chat)

        #expect(card.kind == "device")
        #expect(chat.approvals == [card])
        #expect(card.text.contains("Computer: Studio Mac"))
        #expect(card.text.contains("Command: ls -la ~/Documents"))

        let items = ChatTimeline.items(rows: [], turn: nil, approvals: chat.approvals, pending: [], lastError: nil)
        #expect(items == [.approval(card, answering: false)])

        let approve = CompanionReducer.answer("device-Zq3", approve: true, clientMsgId: "mac-1", into: &chat)
        let deny = CompanionReducer.answer("device-Zq3", approve: false, clientMsgId: "mac-2", into: &chat)
        #expect(approve == [.command(clientMsgId: "mac-1", profileId: "main", name: "confirm", args: "opaque-token")])
        #expect(deny == [.command(clientMsgId: "mac-2", profileId: "main", name: "deny", args: "opaque-token")])
    }
}
