import Foundation
import Testing

@testable import FermixAppCore

/// Doctor: typed check rows from `doctor.start` / `doctor.get` / `doctor.cancel`,
/// a local scope that runs on its own, and a network scope that runs only when
/// the user asks for it.
@Suite("Doctor surface")
@MainActor
struct DoctorSurfaceTests {
    @Test("opening Doctor runs the local scope and nothing else")
    func localRunsOnOpen() async throws {
        let harness = try DoctorHarness()

        await harness.model.runLocal()

        #expect(harness.gateway.calls.first == .doctorStart(.local))
        #expect(!harness.gateway.calls.contains(.doctorStart(.network)))
    }

    /// The network scope costs real requests against real endpoints, so it never
    /// starts by itself, and the button says what it will do.
    @Test("the network scope runs only on an explicit action, and its label says so")
    func networkIsExplicit() async throws {
        let harness = try DoctorHarness()

        await harness.model.runLocal()
        #expect(!harness.gateway.calls.contains(.doctorStart(.network)))

        await harness.model.runNetwork()
        #expect(harness.gateway.calls.contains(.doctorStart(.network)))
        #expect(harness.model.networkActionTitle == ProductStrings[.doctorNetworkRun])
        #expect(ProductStrings[.doctorNetworkBody].contains("30 seconds"))
    }

    @Test("a running session is polled until it reaches a terminal status")
    func pollsUntilTerminal() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [
            try ManagementValueFixture.doctorSession(status: "running", checks: []),
            try ManagementValueFixture.doctorSession(status: "running", checks: [("provider_auth", "passed")]),
            try ManagementValueFixture.doctorSession(status: "completed")
        ]

        await harness.model.runLocal()

        #expect(harness.gateway.calls == [
            .doctorStart(.local),
            .doctorGet("doctor:abc123"),
            .doctorGet("doctor:abc123")
        ])
        #expect(harness.model.phase == .finished)
    }

    @Test("cancelling a run stops the polling and reports the cancelled session")
    func cancelStopsTheRun() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [
            try ManagementValueFixture.doctorSession(status: "running", checks: []),
            try ManagementValueFixture.doctorSession(status: "cancelled", checks: [])
        ]

        await harness.model.start(scope: .local)
        await harness.model.cancel()

        #expect(harness.gateway.calls.contains(.doctorCancel("doctor:abc123")))
        #expect(harness.model.session?.status == .cancelled)
        #expect(harness.model.phase == .finished)
    }

    @Test("cancelling with nothing running asks the daemon nothing")
    func cancelWithNothingRunning() async throws {
        let harness = try DoctorHarness()

        await harness.model.cancel()

        #expect(harness.gateway.calls.isEmpty)
    }

    /// A run is declared before the daemon has issued its session id. Cancel
    /// inside that window must address no session at all: the finished run's id
    /// belongs to a session that is already terminal, and cancelling it would
    /// report the new run as over while it kept probing real endpoints.
    @Test("cancelling before the daemon issues a session id cancels nothing")
    func cancelInsideTheStartWindow() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [
            try ManagementValueFixture.doctorSession(id: "doctor:local", status: "completed"),
            try ManagementValueFixture.doctorSession(id: "doctor:network", status: "completed")
        ]
        await harness.model.runLocal()
        #expect(harness.model.session?.sessionId == "doctor:local")

        let gate = AsyncGate()
        harness.gateway.startGate = { await gate.wait() }
        let starting = Task { await harness.model.start(scope: .network) }
        while !harness.model.isRunning { await Task.yield() }

        await harness.model.cancel()

        #expect(!harness.gateway.calls.contains(.doctorCancel("doctor:local")))
        #expect(harness.model.isRunning, "the network run is still in flight")

        gate.release()
        await starting.value
    }

    /// Every one of the eight statuses keeps its own vocabulary. The letters
    /// are the row's accessibility value now, not an on-screen pill, and a
    /// status this build has never seen keeps its own wire value rather than
    /// being folded into a neighbour.
    @Test("all eight published statuses keep their own status words")
    func everyStatusRenders() {
        let expected: [(ManagementCheckStatus, ProductStringKey)] = [
            (.passed, .doctorPillPass),
            (.warning, .doctorPillWarn),
            (.failed, .doctorPillFail),
            (.unavailable, .doctorPillUnavailable),
            (.skipped, .doctorPillSkipped),
            (.cancelled, .doctorPillCancelled),
            (.timedOut, .doctorPillTimedOut),
            (.notApplicable, .doctorPillNotApplicable)
        ]

        for (status, key) in expected {
            #expect(CheckBadge.forStatus(status).letters == ProductStrings[key], "\(status.wireValue)")
        }
        #expect(CheckBadge.forStatus(.unrecognized("quarantined")).letters == "QUARANTINED")
    }

    /// `not_applicable` is its own class: an app-managed install has checks that
    /// simply do not apply, and folding them into pass would claim a result the
    /// daemon never produced.
    @Test("a not-applicable check renders N/A and counts as neither pass nor fail")
    func notApplicableIsItsOwnClass() throws {
        let session = try ManagementValueFixture.doctorSession(
            checks: [("binary_integrity", "not_applicable"), ("provider_auth", "passed")]
        )
        let rows = DoctorProjection.rows(for: session)

        #expect(rows.first { $0.id == "binary_integrity" }?.badge.letters == "N/A")
        #expect(DoctorProjection.banner(for: session).tone == .pass)
    }

    @Test("the banner states what the run found, and where the answers came from")
    func bannerWording() throws {
        let healthy = try ManagementValueFixture.doctorSession(checks: [("a", "passed"), ("b", "passed")])
        let oneWarning = try ManagementValueFixture.doctorSession(checks: [("a", "passed"), ("b", "warning")])
        let failing = try ManagementValueFixture.doctorSession(checks: [("a", "failed")])

        #expect(DoctorProjection.banner(for: healthy).title == ProductStrings[.doctorBannerHealthy])
        #expect(DoctorProjection.banner(for: oneWarning).title == ProductStrings[.doctorBannerHealthyWithWarning])
        #expect(DoctorProjection.banner(for: oneWarning).tone == .warn)
        #expect(DoctorProjection.banner(for: failing).tone == .fail)
        #expect(DoctorProjection.banner(for: healthy).explainer == ProductStrings[.doctorBannerExplainer])
    }

    /// One failure is the commonest result Doctor has, and it counted like
    /// every other: `1 checks failed`. The warning half of the same banner
    /// already had a sentence for one.
    @Test("one failed check is counted in the singular and two are not")
    func bannerCountsOneFailure() throws {
        let one = try ManagementValueFixture.doctorSession(checks: [("a", "failed"), ("b", "passed")])
        let two = try ManagementValueFixture.doctorSession(checks: [("a", "failed"), ("b", "failed")])

        #expect(DoctorProjection.banner(for: one).title == ProductStrings[.doctorBannerFailingOne])
        #expect(DoctorProjection.banner(for: one).tone == .fail)
        #expect(DoctorProjection.banner(for: two).title == "2 checks failed")
        #expect(DoctorProjection.banner(for: two).tone == .fail)
    }

    /// The daemon's ids are single snake_case words and its summaries are
    /// written to sit beside them, the way `fermix doctor` prints them. The
    /// row keeps that pairing: the check's name is the title, the summary is
    /// the detail, and VoiceOver hears both after the status word.
    @Test("a check row is titled by its check and carries the summary as detail")
    func rowTitleAndDetail() throws {
        let session = try ManagementValueFixture.doctorSession(checks: [("provider_auth", "passed")])

        let row = try #require(DoctorProjection.rows(for: session).first)

        #expect(row.title == "Provider auth")
        #expect(row.detail == "provider_auth reported passed")

        // A check with no v2 remediation speaks its status and its finding, and
        // never a wire code: `daemon_socket.warning` under a `Remedy:` label is
        // the quirk M34 §5.8 lists as fixed.
        #expect(row.remediationTitle == nil)
        #expect(row.accessibilityValue == ProductStrings.commaPair(row.badge.letters, row.detail))
    }

    /// A remediation code is never rendered. It is a wire token, and the row
    /// that showed it read `Remedy: daemon_socket.warning` under a user-facing
    /// label (M34 §5.8).
    @Test("a check with a remediation code and no remediation renders no code")
    func remediationCodeIsNeverRendered() throws {
        let session = try ManagementValueFixture.doctorSession(checks: [("codex_login", "warning")])

        let row = try #require(DoctorProjection.rows(for: session).first)

        #expect(row.remediationTitle == nil)
        #expect(row.remediationBody == nil)
        #expect(!row.accessibilityValue.contains("codex_login."))
    }

    /// The letter pill is gone: a check row draws exactly one visual status
    /// indicator (the disc), and the state still reaches VoiceOver in words
    /// because the accessibility value leads with the status vocabulary.
    @Test("a check row has one status indicator and still speaks its state")
    func oneIndicatorAndASpokenState() throws {
        let view = try SourceTree.swiftFiles(matching: "Doctor/DoctorView.swift")

        #expect(view.count == 1)
        #expect(view.first?.text.contains("statusDisc") == true)
        #expect(view.first?.text.contains("LetterPill") == false, "the letter pill is a second indicator")

        let session = try ManagementValueFixture.doctorSession(
            checks: [("provider_auth", "passed"), ("codex_login", "warning")]
        )
        for row in DoctorProjection.rows(for: session) {
            #expect(row.accessibilityValue.hasPrefix(row.badge.letters), "\(row.id) does not speak its state")
        }
    }

    /// M34 §3.2 drops the right rail: the network run and the two support
    /// actions are toolbar commands, and the surface draws no rail of its own.
    @Test("Doctor draws no right rail and takes its actions from the toolbar")
    func noRightRail() throws {
        let view = try SourceTree.swiftFiles(matching: "Doctor/DoctorView.swift")
        let text = try #require(view.first?.text)

        #expect(!text.contains("private var rail"), "the right rail survives")
        #expect(text.contains("SurfaceToolbar("), "Doctor's actions are not in the toolbar")

        let toolbar = CommandTable.toolbar(for: .doctor)
        #expect(toolbar.secondary.contains(.runNetworkChecks))
        #expect(toolbar.more == [.exportSupportBundle, .revealLogFolder])
    }

    /// A failed row carries the daemon's own remediation title. The engine
    /// writes it; the app never composes one.
    @Test("a v2 remediation reaches the row as its title")
    func remediationTitleReachesTheRow() throws {
        let session = try ManagementValueFixture.doctorSession(
            checks: [("screen_recording", "failed")],
            remediation: (
                title: "Allow screen recording",
                kind: "system_settings",
                target: "com.apple.preference.security"
            )
        )

        let row = try #require(DoctorProjection.rows(for: session).first)

        #expect(row.remediationTitle == "Allow screen recording")
        #expect(row.action == .openSystemSettings("com.apple.preference.security"))
        #expect(row.action?.title == "Open System Settings")
        // The remediation's title *and* its body reach VoiceOver: the title
        // says what to do and the body says how, and dropping the body left the
        // row with a heading and nothing under it.
        #expect(row.accessibilityValue.contains("Allow screen recording"))
        #expect(row.remediationBody?.isEmpty == false)
    }

    /// The action kinds are the daemon's closed set; the coverage is this
    /// build's, and it is declared rather than inferred. A kind whose surface
    /// does not exist yet renders as remediation text with no button.
    ///
    /// The case set comes from the wire vocabulary rather than from a list
    /// written here, so a kind the engine publishes later fails this gate until
    /// somebody classifies it instead of falling silently into "no button".
    @Test("only the remediation kinds this build can perform become buttons")
    func remediationActionCoverage() throws {
        // `settings_pane` moved into the performable set with decision D1: the
        // pane it names is a presentation of this same window now, so the row
        // carries a button instead of a sentence with nowhere to go.
        // `instructions` opens the sheet of commands Home's Attention row opens,
        // or Recovery, depending on the catalogue entry it names; `restart` is
        // the one Restart sheet and `reload` is `settings.reload` (M34 §15.2).
        //
        // `job` is deferred, and not because a job has no surface: the engine's
        // remediation table publishes no job remediation at all, and a job is
        // not startable from a bare target — `job.*` addresses a run that
        // already exists and every start verb has its own method and its own
        // parameters. The branch that guessed a capability install from the
        // target is gone.
        let performable = ["system_settings", "settings_pane", "instructions", "restart", "reload"]
        let deferred = ["none", "job"]

        for published in ManagementRemediationActionKind.publishedValues.keys {
            #expect(
                performable.contains(published) != deferred.contains(published),
                "\(published) is published by the engine and classified in neither set"
            )
        }
        #expect(
            Set(performable + deferred) == Set(ManagementRemediationActionKind.publishedValues.keys),
            "the declared sets name a kind the engine does not publish"
        )

        for kind in performable + deferred {
            // The target has to be one each kind can actually resolve: a pane
            // slug for `settings_pane`, a catalogue entry for `instructions`, an
            // identifier for `system_settings`, and none at all for the two that
            // name a surface of their own. A target outside the set a kind can
            // resolve carries no button, which is the other half of this gate.
            let target = Self.resolvableTarget(for: kind)
            let session = try ManagementValueFixture.doctorSession(
                checks: [("a_check", "failed")],
                remediation: (title: "Fix it", kind: kind, target: target)
            )
            let row = try #require(DoctorProjection.rows(for: session).first)

            #expect(row.remediationTitle == "Fix it", "\(kind)")
            #expect((row.action != nil) == performable.contains(kind), "\(kind)")
        }
    }

    /// A target each kind can actually resolve.
    private static func resolvableTarget(for kind: String) -> String? {
        switch kind {
        case "settings_pane": return SettingsPane.providers.slug
        case "instructions": return CoexistenceInstructions.legacyServiceUnitRemoval
        // The engine publishes these two with `target: null`: the surface is
        // the app's own and there is nothing left to name.
        case "restart", "reload": return nil
        default: return "target"
        }
    }

    /// Every remediation the vendored doctor fixtures publish resolves to an
    /// action this build performs.
    ///
    /// The engine's table emits `restart`, `reload`, two `instructions` targets
    /// and `settings_pane`; the app rendered a button for none of the first
    /// three, so the golden's own restart remediation drew nothing although the
    /// app has had the restart flow all along.
    @Test("every remediation the fixtures publish resolves to an action")
    func fixtureRemediationsAllResolve() throws {
        var resolved = 0

        for fixture in try ManagementFixtures.load(.success, from: .management)
        where (try? fixture.string("method"))?.hasPrefix("doctor.") == true {
            let session: ManagementDoctorSession = try ManagementValueFixture.decode(
                String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: try #require(try fixture.object("response")["result"])
                    ),
                    as: UTF8.self
                ),
                as: ManagementDoctorSession.self
            )

            for check in session.checks where check.remediation != nil {
                #expect(
                    DoctorProjection.action(for: check) != nil,
                    "\(fixture.name)/\(check.id) publishes a remediation nothing can perform"
                )
                resolved += 1
            }
        }

        #expect(resolved > 0, "the fixtures publish remediations to resolve")
    }

    /// The four destinations the engine's own remediation table names, each
    /// resolved to the surface that owns it.
    @Test("each remediation the engine emits resolves to the surface that owns it")
    func engineRemediationsResolveToTheirSurfaces() throws {
        let published: [(kind: String, target: String?, action: DoctorRowAction)] = [
            ("restart", nil, .restartDaemon),
            ("reload", nil, .reloadSettings),
            (
                "instructions",
                DoctorProjection.externalConfigChangeRecovery,
                .openRecovery
            ),
            (
                "instructions",
                CoexistenceInstructions.legacyServiceUnitRemoval,
                .showInstructions(CoexistenceInstructions.legacyServiceUnitRemoval)
            ),
            ("settings_pane", SettingsPane.providers.slug, .openSettings(.providers))
        ]

        for entry in published {
            let session = try ManagementValueFixture.doctorSession(
                checks: [("a_check", "warning")],
                remediation: (title: "Fix it", kind: entry.kind, target: entry.target)
            )
            let check = try #require(session.checks.first)

            #expect(
                DoctorProjection.action(for: check) == entry.action,
                "\(entry.kind)/\(entry.target ?? "null")"
            )
        }
    }

    /// The other half of the coverage gate: a target the kind cannot resolve
    /// carries no button rather than one that would open nothing.
    @Test("a remediation target this build cannot resolve carries no button")
    func unresolvableTargetsCarryNoButton() throws {
        for kind in ["instructions", "job", "settings_pane"] {
            let session = try ManagementValueFixture.doctorSession(
                checks: [("a_check", "failed")],
                remediation: (title: "Fix it", kind: kind, target: "not_a_target")
            )
            let row = try #require(DoctorProjection.rows(for: session).first)

            #expect(row.action == nil, "\(kind)")
        }
    }

    /// A `settings_pane` remediation opens that pane inside this window, and
    /// its button reads exactly as an Attention row's deep link does: one
    /// resolver for "Open Providers", not two spellings of it.
    @Test("a settings-pane remediation opens the pane it names")
    func settingsPaneRemediation() throws {
        let harness = try DoctorHarness()
        let session = try ManagementValueFixture.doctorSession(
            checks: [("provider_config", "failed")],
            remediation: (title: "Connect a provider", kind: "settings_pane", target: "providers")
        )
        let row = try #require(DoctorProjection.rows(for: session).first)

        #expect(row.action == .openSettings(.providers))
        #expect(row.action?.title == "Open Providers")
        #expect(row.action?.title == AttentionAction.openSettings(.providers).title)

        harness.model.perform(.openSettings(.providers))

        #expect(harness.openedPanes == [.providers])
    }

    /// A pane slug this build does not publish carries no button rather than
    /// landing on a neighbour: the row still shows the daemon's own title.
    @Test("an unknown pane slug carries no button")
    func unknownSettingsPane() throws {
        let session = try ManagementValueFixture.doctorSession(
            checks: [("a_check", "failed")],
            remediation: (title: "Fix it", kind: "settings_pane", target: "teleport")
        )
        let row = try #require(DoctorProjection.rows(for: session).first)

        #expect(row.remediationTitle == "Fix it")
        #expect(row.action == nil)
    }

    /// Against a daemon one release behind there is no remediation object at
    /// all, and the row falls back to nothing invented: the remediation code
    /// the v1 contract already carried.
    @Test("a check with no v2 remediation says only what the daemon said")
    func withoutRemediation() throws {
        let session = try ManagementValueFixture.doctorSession(checks: [("codex_login", "warning")])
        let row = try #require(DoctorProjection.rows(for: session).first)

        #expect(row.remediationTitle == nil)
        #expect(row.remediationBody == nil)
        #expect(row.action == nil)
    }

    /// The export is a toolbar command and a File-menu command, so the request
    /// is the model's rather than a `@State` one of them cannot reach.
    @Test("the support bundle is requested through the model, not a view's state")
    func exportRequestLivesOnTheModel() async throws {
        let harness = try DoctorHarness()

        harness.model.requestSupportBundle()
        try await harness.settle()

        #expect(harness.gateway.calls.contains(.diagnostics))
        #expect(harness.model.pendingBundle != nil)

        harness.model.clearPendingBundle()
        #expect(harness.model.pendingBundle == nil)
    }

    /// The identifier is the daemon's; nothing here composes one.
    @Test("the system settings action opens the pane the daemon named")
    func systemSettingsAction() throws {
        let harness = try DoctorHarness()

        harness.model.openSystemSettings("com.apple.preference.security")

        #expect(harness.settingsOpener.opened == ["com.apple.preference.security"])
        #expect(harness.model.supportMessage == nil)
    }

    /// A pane macOS will not open is a failure with somewhere to be said. A
    /// button that appears to work and does nothing is the outcome this row
    /// exists to prevent.
    @Test("a pane macOS refuses is reported rather than silently doing nothing")
    func systemSettingsRefusal() throws {
        let harness = try DoctorHarness(settingsPaneOpens: false)

        harness.model.openSystemSettings("com.apple.preference.nonexistent")

        #expect(harness.settingsOpener.opened == ["com.apple.preference.nonexistent"])
        #expect(harness.model.supportMessage == ProductStrings[.doctorSettingsPaneUnavailable])
    }

    @Test("a refused start is reported rather than leaving an empty list")
    func startFailureIsReported() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorFailure = ManagementError.daemon(
            ManagementFailure(
                code: .busy,
                message: "another Doctor session is running",
                details: ManagementScalarMap(values: [:])
            )
        )

        await harness.model.runLocal()

        #expect(harness.model.phase == .failed("another Doctor session is running"))
    }

    /// The polling loop is bounded: a session that never reaches a terminal
    /// status stops being polled rather than looping forever.
    @Test("polling a session that never finishes is bounded")
    func pollingIsBounded() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [try ManagementValueFixture.doctorSession(status: "running", checks: [])]

        await harness.model.runLocal()

        let polls = harness.gateway.calls.filter { $0 == .doctorGet("doctor:abc123") }.count
        #expect(polls == DoctorPolicy.maximumPolls)
        #expect(harness.model.phase == .failed(ProductStrings[.doctorRunStalled]))
    }
}

/// The SUPPORT card: the two accent actions §5.9 specifies, and the one §10.4
/// calls the floor.
@Suite("Doctor support")
@MainActor
struct DoctorSupportTests {
    @Test("open log folder reveals the daemon's own log directory")
    func openLogFolderRevealsTheLogDirectory() throws {
        let harness = try DoctorHarness()

        harness.model.openLogFolder()

        #expect(harness.revealer.revealed.map(\.path) == ["/tmp/fermix-home-fixture/logs"])
        #expect(harness.model.supportMessage == nil)
    }

    /// A home the app has not recorded yet has no log folder. Saying so is the
    /// point: a button that silently does nothing is worse than a sentence.
    @Test("with no recorded home the action says so instead of opening nothing")
    func openLogFolderWithoutAHome() throws {
        let harness = try DoctorHarness(logFolderFailure: BootstrapStoreError.absent(path: "/nowhere"))

        harness.model.openLogFolder()

        #expect(harness.revealer.revealed.isEmpty)
        #expect(harness.model.supportMessage == ProductStrings[.doctorSupportHomeUnavailable])
    }

    /// The bundle is the daemon's own bounded, field-allowlisted, scrubbed
    /// diagnostics object. Nothing here reads a file or adds a field.
    @Test("exporting the support bundle writes the daemon's diagnostics")
    func exportWritesDaemonDiagnostics() async throws {
        let harness = try DoctorHarness()

        let bundle = await harness.model.exportSupportBundle()

        #expect(harness.gateway.calls.contains(.diagnostics))
        let text = try #require(bundle.map { String(decoding: $0, as: UTF8.self) })
        #expect(text.contains("\"schema_version\""))
        #expect(text.contains("fermix_app_engine"))
        #expect(harness.model.supportMessage == nil)
    }

    @Test("a refused export reports the daemon's own sentence")
    func exportFailureIsReported() async throws {
        let harness = try DoctorHarness(diagnostics: nil)

        let bundle = await harness.model.exportSupportBundle()

        #expect(bundle == nil)
        #expect(harness.model.supportMessage?.isEmpty == false)
    }

    @Test("both accent actions carry the copy the redline publishes")
    func supportCopy() {
        #expect(ProductStrings[.doctorSupportExport] == "Export support bundle")
        #expect(ProductStrings[.doctorSupportOpenLogFolder] == "Open log folder")
    }
}

@MainActor
final class DoctorHarness {
    let gateway = FakeDaemonGateway()
    let revealer = RecordingFolderRevealer()
    let settingsOpener: RecordingSystemSettingsOpener
    let model: DoctorModel
    /// The Fermix panes a remediation asked this window to show (decision D1).
    let panes = RecordingPaneOpener()

    var openedPanes: [SettingsPane] { panes.opened }

    init(
        logFolderFailure: (any Error)? = nil,
        diagnostics: ManagementDiagnostics? = try? ManagementValueFixture.diagnostics(),
        settingsPaneOpens: Bool = true
    ) throws {
        settingsOpener = RecordingSystemSettingsOpener(opens: settingsPaneOpens)
        gateway.doctorScript = [try ManagementValueFixture.doctorSession()]
        gateway.diagnostics = diagnostics
        model = DoctorModel(
            gateway: gateway,
            logFolder: {
                if let logFolderFailure { throw logFolderFailure }
                return URL(fileURLWithPath: "/tmp/fermix-home-fixture/logs", isDirectory: true)
            },
            settingsFile: {
                if let logFolderFailure { throw logFolderFailure }
                return URL(fileURLWithPath: "/tmp/fermix-home-fixture/config.toml", isDirectory: false)
            },
            revealer: revealer,
            settingsOpener: settingsOpener,
            openSettingsPane: { [panes] pane in panes.record(pane) },
            sleeper: NoWaitSleeper()
        )
    }

    /// Lets a detached request task finish without a wall-clock wait.
    func settle() async throws {
        for _ in 0..<16 {
            await Task.yield()
        }
    }
}

/// Records the Fermix settings panes a remediation asked this window to show.
/// A class so the harness can hand the closure in before it is itself built.
@MainActor
final class RecordingPaneOpener {
    private(set) var opened: [SettingsPane] = []

    func record(_ pane: SettingsPane) {
        opened.append(pane)
    }
}

/// Records the System Settings panes Doctor asked macOS to open, and answers
/// whatever the scenario says macOS did. The suite never opens a real one.
final class RecordingSystemSettingsOpener: SystemSettingsOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String] = []

    /// What macOS answered. A refusal is a real outcome — an identifier the
    /// running system has no pane for — so a scenario can ask for it.
    let opens: Bool

    init(opens: Bool = true) {
        self.opens = opens
    }

    var opened: [String] { lock.withLock { identifiers } }

    func open(_ identifier: String) -> Bool {
        lock.withLock { identifiers.append(identifier) }

        return opens
    }
}

/// Records the folders Doctor asked the Finder to reveal.
final class RecordingFolderRevealer: FolderRevealing, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [URL] = []

    var revealed: [URL] { lock.withLock { folders } }

    func reveal(_ url: URL) {
        lock.withLock { folders.append(url) }
    }
}

/// Consumes the poll interval instantly, so a bounded poll is provable without
/// spending its wall-clock time.
struct NoWaitSleeper: Sleeping {
    func sleep(seconds: TimeInterval) async throws {}
}
