import Foundation
import Testing

@testable import FermixAppCore

/// Always On as this build knows it (M75): the home's management calls read
/// from the contract's goldens, the Settings pane that draws the engine's own
/// rows under `always_on`, and a desktop's inventory while its server's
/// sections are missing.
@Suite("Always On")
@MainActor
struct AlwaysOnTests {
    // MARK: - The home's answers

    @Test("the home's goldens decode under the Swift names")
    func homeGoldensDecode() throws {
        let home: ManagementHomeStatus = try Self.golden("home_status")
        #expect(home.role == .primary && home.epoch == 4)
        #expect(home.primary == nil && home.primaryHome == nil && home.primaryMissing == nil)
        #expect(home.enrollment == ManagementEnrollmentWindow(state: .used, expiresAt: "2026-10-27T09:22:00Z"))
        #expect(home.candidates.map(\.candidateId) == ["cand-5e2a9c1f7b3d4086"])
        #expect(home.move?.phase == .aborted && home.move?.phase.isPending == false)

        let target = try #require(home.snapshots.targets.first)
        #expect(target.id == "s3" && target.lastResult == .verified)
        #expect(target.lastVerified?.keyId == "08c15ca36dd935c4")
        #expect(home.snapshots.recipientSet && home.snapshots.intervalHours == 6)

        let candidates: ManagementCandidates = try Self.golden("home_candidates_list")
        let candidate = try #require(candidates.candidates.first)
        #expect(candidate.instance == ManagementCandidateInstance(provider: "hetzner", instanceId: "61839204", region: "fsn1", accountId: nil))
        #expect(candidate.enrolledAt == "2026-10-27T09:12:00Z")

        let readiness: ManagementMoveReadiness = try Self.golden("home_move_readiness")
        #expect(readiness.ready)
        #expect(readiness.items.first { $0.id == "stays_here" }?.status == .warn)

        let started: ManagementMoveStarted = try Self.golden("home_move_start")
        #expect(started.moveId == "mv-01a17cb1f5c04c1e9a7b" && started.keepAsDesktop)

        let key: ManagementRecoveryKey = try Self.golden("home_snapshots_passphrase")
        #expect(key.keyId == "08c15ca36dd935c4")
        let run: ManagementSnapshotsStarted = try Self.golden("home_snapshots_run")
        #expect(run.started && run.snapshots.running)
        let code: ManagementEnrollmentCode = try Self.golden("home_enroll_open")
        #expect(code.code.hasPrefix("fxenroll1.") && code.expiresAt == "2026-10-27T09:40:00Z")
    }

    @Test("a linked desktop's status carries its server, and the server's own picture or why it is missing")
    func linkedDesktopStatus() throws {
        let server = try Self.goldenObject("home_status")
        var desktop = server
        desktop["role"] = "device"
        desktop["primary"] = [
            "name": "north-box", "connected": false, "status": "renewing", "since": NSNull(),
            "epoch": 5, "sentence": "Connecting to north-box."
        ] as [String: Any]
        desktop["primary_home"] = server

        let linked = try Self.decode(ManagementHomeStatus.self, desktop)
        #expect(linked.role == .device)
        #expect(linked.primary?.status == .renewing && linked.primary?.epoch == 5 && linked.primary?.since == nil)
        #expect(linked.server == (try Self.golden("home_status") as ManagementHomeStatus))

        desktop["primary_home"] = NSNull()
        desktop["primary_missing"] = "The server north-box did not answer in time."
        let missing = try Self.decode(ManagementHomeStatus.self, desktop)
        #expect(missing.server == nil && missing.primaryMissing == "The server north-box did not answer in time.")
    }

    @Test("a desktop a move paired is a device of kind desktop, and the phones are the rest")
    func desktopDevice() throws {
        let devices: ManagementMobileDevices = try Self.golden("mobile_devices_list")

        #expect(devices.devices.map(\.kind) == [.phone, .desktop])
        #expect(devices.phones.map(\.name) == ["Sam's phone"])
        #expect(ManagementMobileDeviceKind(wireValue: "watch") == .unrecognized("watch"))
    }

    /// The two move calls walk the whole home before they answer, and a
    /// desktop forwarding either waits 60 s for its server.
    @Test("a move's review and its start wait 65 seconds, and the home's other calls the usual time")
    func moveCallsWaitLonger() {
        let policy = DefaultManagementTimeoutPolicy()

        #expect(DefaultManagementTimeoutPolicy.move == .seconds(65))
        for method in [ManagementMethod.homeMoveReadiness, .homeMoveStart] {
            #expect(policy.timeout(for: method) == DefaultManagementTimeoutPolicy.move, "\(method.rawValue)")
        }
        for method in [ManagementMethod.homeStatus, .homeEnrollOpen, .homeCandidatesList, .homeSnapshotsRun] {
            #expect(policy.timeout(for: method) == DefaultManagementTimeoutPolicy.standard, "\(method.rawValue)")
        }
    }

    // MARK: - The pane

    @Test("the pane is drawn where the daemon lists home.status, first under System, as the engine's snapshot rows")
    func paneDrawnFromTheEngine() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway)

        await harness.model.windowAppeared()
        await harness.model.paneAppeared(.alwaysOn)

        #expect(harness.model.drawsAlwaysOnPane)
        #expect(harness.model.panes(matching: "", in: .system) == [.alwaysOn, .sandbox, .secrets, .permissions])
        #expect(harness.model.panes(matching: "snapshots", in: .system) == [.alwaysOn], "the pane answers its keywords")
        #expect(harness.model.sections(for: .alwaysOn).map(\.id) == ["snapshots"])
        #expect(gateway.readSections.contains("snapshots"))
        #expect(harness.model.section("snapshots").value?.rows.first?.key == "snapshots_recipient")
        #expect(!harness.model.refusesRoute(to: .alwaysOn))
    }

    @Test("a daemon that does not list home.status draws no pane, refuses the route, and a restored selection goes to the first pane")
    func noPaneWithoutTheHome() async throws {
        let gateway = try SettingsFixture.gateway()
        let harness = try SettingsHarness(gateway: gateway, store: FakeSettingsPaneStore(lastSettingsPane: "always_on"))
        #expect(harness.model.selectedPane == .alwaysOn)
        #expect(!harness.model.refusesRoute(to: .alwaysOn), "before the methods are read the route is taken")

        await harness.model.windowAppeared()

        #expect(!harness.model.drawsAlwaysOnPane)
        #expect(!harness.model.panes(matching: "", in: .system).contains(.alwaysOn))
        #expect(harness.model.refusesRoute(to: .alwaysOn))
        #expect(harness.model.selectedPane == .providers)
    }

    /// The sentence a desktop's engine composes its inventory with while its
    /// server does not answer.
    private static let missing = "The server north-box is unreachable. Fermix keeps your message until it is back."

    @Test("a desktop's inventory without its server's sections says why, and is read again until the server's are back")
    func desktopInventoryWithoutTheServer() async throws {
        let gateway = try Self.gateway()
        let whole: ManagementSettingsInventory = try Self.golden("settings_sections")
        let own = ["sandbox", "computer_use", "computer_history", "channels.imessage"]
        gateway.settingsSectionsResult = ManagementSettingsInventory(
            sections: whole.sections.filter { own.contains($0.id) },
            primaryMissing: Self.missing
        )
        let harness = try SettingsHarness(gateway: gateway)

        await harness.model.windowAppeared()

        #expect(harness.model.primaryMissing == Self.missing)
        #expect(harness.model.sections(for: .alwaysOn).isEmpty)
        #expect(!harness.model.sections(for: .sandbox).isEmpty, "this Mac's own sections are still drawn")

        gateway.settingsSectionsResult = nil
        await harness.model.windowAppeared()
        await harness.model.windowAppeared()

        #expect(harness.model.primaryMissing == nil)
        #expect(harness.model.sections(for: .alwaysOn).map(\.id) == ["snapshots"])
        #expect(gateway.calls.filter { $0 == .v2(.settingsSections) }.count == 2, "a whole inventory is not read again")
    }

    // MARK: - Fixtures

    static func golden<Value: Decodable>(_ name: String) throws -> Value {
        try FakeDaemonGateway.fixtureResult(named: name, as: Value.self)
    }

    static func goldenObject(_ name: String) throws -> [String: Any] {
        let fixture = try #require(try ManagementFixtures.load(.success, from: .management).first { $0.name == name })
        return try #require(try fixture.object("response")["result"] as? [String: Any])
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ object: [String: Any]) throws -> Value {
        try JSONDecoder().decode(type, from: try JSONSerialization.data(withJSONObject: object))
    }

    /// A gateway whose `hello` is the contract's own, which lists every home
    /// method.
    static func gateway() throws -> FakeDaemonGateway {
        let gateway = try SettingsFixture.gateway()
        gateway.hello = try golden("hello")

        return gateway
    }
}
