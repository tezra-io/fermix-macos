import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// Home: the status header, and the Background, Attention and Runtime sections
/// of M34 §3.2. Every row comes from `hello`, `overview.get` and
/// `setup.state.get`; there is no activity feed and nothing reads model-facing
/// memory.
@Suite("Home surface")
@MainActor
struct HomeSurfaceTests {
    @Test("background changes redraw Home and refresh its daemon snapshot", arguments: [false, true])
    func backgroundChangesRefreshHome(enabled: Bool) async throws {
        let harness = try HomeHarness()
        let offline = ManagementError.transport(.socketMissing(path: "/tmp/test-daemon.sock"))
        harness.loginItems.preregister(.agent, as: enabled ? .notRegistered : .enabled)
        harness.gateway.negotiateFailure = enabled ? offline : nil
        await harness.model.refresh()

        var redraws = 0
        var refresh: Task<Void, Never>?
        let subscription = harness.model.objectWillChange.sink { _ in redraws += 1 }
        harness.coordinator.readDaemonCondition = { [model = harness.model] in
            refresh = Task { @MainActor in await model.refresh() }
        }
        defer {
            subscription.cancel()
            harness.coordinator.readDaemonCondition = nil
        }

        // Registration changes in Service Management without publishing a
        // HomeModel notification. The coordinator must announce completion.
        harness.loginItems.preregister(.agent, as: enabled ? .enabled : .notRegistered)
        harness.gateway.negotiateFailure = enabled ? nil : offline
        harness.coordinator.setBackgroundService(enabled: enabled)
        try await harness.coordinator.drainPendingWork()
        await refresh?.value

        #expect(redraws > 0)
        #expect(harness.model.backgroundServiceEnabled == enabled)
        #expect(!harness.model.transactionInFlight)
        #expect(harness.model.snapshot.statusTitle == ProductStrings[
            enabled ? .homeStatusRunning : .daemonStateNotRunning
        ])
    }

    private func snapshot(
        provider: String? = "openai_codex",
        channelEnabled: Bool = true,
        channelStatus: String = "ok",
        readiness: String = "ready",
        health: String = "ok",
        restartRequired: Bool = false,
        attention: AttentionSection = .rows([]),
        update: UpdateAvailability = .unknown,
        setup: ManagementSetupState? = nil
    ) throws -> HomeSnapshot {
        HomeSnapshot(
            hello: try ManagementValueFixture.hello(),
            overview: try ManagementValueFixture.overview(
                provider: provider,
                channelEnabled: channelEnabled,
                channelStatus: channelStatus,
                readiness: readiness,
                health: health,
                restartRequired: restartRequired
            ),
            attention: attention,
            update: update,
            setup: setup
        )
    }

    @Test("a running daemon reads as running, with a humane uptime")
    func runningHeader() throws {
        let home = try snapshot()

        #expect(home.statusTitle == ProductStrings[.homeStatusRunning])
        #expect(home.statusTone == .pass)
        #expect(home.uptime == "for 3 days 4 hours")
    }

    /// The daemon owns "ready". M34 §4 makes `readiness.status` answer ready
    /// exactly when no gating failure remains, so Swift gains no second
    /// definition of it.
    @Test("the header follows the daemon's own readiness status")
    func setupRequiredHeader() throws {
        let home = try snapshot(readiness: "setup_required")

        #expect(home.statusTitle == ProductStrings[.homeStatusSetupRequired])
        #expect(home.statusTone == .warn)
        #expect(!home.setupComplete)
    }

    /// The daemon mints two status words, `ready` and `setup_required`, and
    /// reserves a third. Everything else this screen says is keyed on "not
    /// ready": `attention` is the name of a section here and never a state the
    /// daemon reports, so a word the app invented cannot be mistaken for one it
    /// was told.
    @Test("anything the daemon does not call ready reads as not ready")
    func anyOtherStatusIsNotReady() throws {
        #expect(try snapshot(readiness: "ready").setupComplete)

        for status in ["setup_required", "degraded", "attention"] {
            let home = try snapshot(readiness: status)

            #expect(!home.setupComplete, "\(status) read as ready")
            #expect(home.statusTone == .warn, "\(status)")
        }
    }

    @Test("a daemon that cannot be reached says so rather than drawing a healthy header")
    func unreachableHeader() {
        let home = HomeSnapshot.unreachable(attention: .unavailable("the socket is not there"))

        #expect(home.statusTitle == ProductStrings[.daemonStateNotRunning])
        #expect(home.statusTone == .fail)
        #expect(home.unreachable)
    }

    // MARK: - Runtime

    /// M34 §3.2 names seven labelled facts, and Skills and Tools are counts
    /// only: the operator split, the hidden-capability count and the policy
    /// groups are Doctor's evidence.
    @Test("runtime rows are the seven published facts, in order")
    func runtimeRows() throws {
        let home = try snapshot()

        #expect(home.runtime.map(\.id) == [
            "engine", "protocol", "uptime", "provider", "channels", "skills", "tools"
        ])
        #expect(home.runtime.first?.detail == "0.9.0")
    }

    /// `overview.get` names the provider by its wire key. `setup.state.get` is
    /// the one place the daemon publishes a label for it, and it is the same
    /// label the assistant's rows and the Providers pane draw, so Home says
    /// what they say instead of printing a key beside six rows of English.
    @Test("the provider row reads the daemon's own label, not the wire key")
    func providerRowIsLabelled() throws {
        let setup = try ManagementValueFixture.setupState()
        let home = try snapshot(setup: setup)

        #expect(
            home.runtime.first { $0.id == "provider" }?.detail
                == "OpenAI Codex (ChatGPT) · gpt-5.6-sol"
        )
    }

    /// A key the setup state does not list has no published label, so the row
    /// says the daemon's own word. It is the only name that machine has for it,
    /// and it is visibly a key rather than a spelling the app invented.
    @Test("a provider the setup state does not name keeps the daemon's own word")
    func unlabelledProviderKeepsItsWord() throws {
        let setup = try ManagementValueFixture.setupState()
        let home = try snapshot(provider: "some_engine", setup: setup)

        #expect(home.runtime.first { $0.id == "provider" }?.detail == "Some_engine · gpt-5.6-sol")
    }

    @Test("skills and tools are counts, and tools folds the built-in and MCP registries")
    func capabilityCounts() throws {
        let home = try snapshot()

        #expect(home.runtime.first { $0.id == "skills" }?.detail == "12")
        // The fixture publishes 40 built-in plus 3 MCP.
        #expect(home.runtime.first { $0.id == "tools" }?.detail == "43")
    }

    /// A fact inside a grouped form is a `LabeledContent`: no icon, no trailing
    /// meta, no tone. The debug metas are Doctor's.
    @Test("runtime rows carry no decoration")
    func runtimeRowsAreLabelledFacts() throws {
        for row in try snapshot().runtime {
            #expect(row.meta == nil, "\(row.id) carries a meta")
            #expect(row.systemImage == nil, "\(row.id) carries an icon")
        }
    }

    @Test("the protocol row states the version the daemon published")
    func protocolRow() throws {
        let home = HomeSnapshot(
            hello: try ManagementValueFixture.hello(maximum: 1),
            overview: try ManagementValueFixture.overview(),
            attention: .rows([]),
            update: .unknown
        )

        #expect(home.runtime.first { $0.id == "protocol" }?.detail == "v1")
    }

    @Test("with nothing to report, Runtime draws its empty line rather than a blank section")
    func runtimeEmptyState() {
        let home = HomeSnapshot.unreachable(attention: .unavailable("the socket is not there"))

        #expect(home.runtime.isEmpty)
        #expect(home.runtimeEmpty.message == ProductStrings[.homeRuntimeEmpty])
    }

    // MARK: - Attention

    @Test("a healthy daemon needs no attention and says so")
    func nothingNeedsAttention() throws {
        let home = try snapshot()

        #expect(home.attention.rows.isEmpty)
        #expect(home.attentionEmpty.message == ProductStrings[.homeAttentionEmpty])
    }

    /// The three sources M34 §3.2 publishes, in the order it publishes them:
    /// readiness failures (gating first), then the pending restart, then the
    /// standing coexistence descriptors.
    @Test("attention rows come from readiness, restart and coexistence, in that order")
    func attentionRowOrder() throws {
        let rows = AttentionProjection.rows(for: try FakeDaemonGateway.fixtureResult(named: "setup_state_get", as: ManagementSetupState.self))

        // The golden's own home: one gating failure (personalization), one
        // advisory (an enabled channel with no credential), a pending restart,
        // and the legacy service unit. The ACL probe is unmeasured, which is
        // not the same answer as clear, so it raises no row.
        #expect(rows.map(\.id) == [
            "personalization",
            "channel:whatsapp",
            "restart_pending",
            "legacy_service_unit"
        ])
    }

    /// The row's wording is keyed on the failure's `detail_key` alone, never on
    /// the pane: five channel failures and the voice companion collapse onto
    /// two panes, so a pane key could not tell Telegram from Slack.
    @Test("a row is worded by its detail key, and a provider family names the provider")
    func rowsAreKeyedByDetailKey() throws {
        let state = try FakeDaemonGateway.fixtureResult(named: "setup_state_get", as: ManagementSetupState.self)
        // The product's own name for the id, read off the same snapshot the row
        // came from: the daemon's own provider label, never `Connect
        // Openai_codex` and never a marketing name Swift invented (M34 §3.2).
        let inventory = try FakeDaemonGateway.fixtureResult(
            named: "settings_sections",
            as: ManagementSettingsInventory.self
        )
        let rows = AttentionProjection.rows(
            for: state,
            names: AttentionNames(state: state, sections: inventory.sections)
        )
        // The parameterised provider family, which no pane key could tell from
        // the other four provider details. The golden's own home has its
        // provider connected, so the row is built from the same detail key the
        // daemon would send.
        let credentials = AttentionCatalogue.row(
            for: AttentionDetail(detailKey: "provider:missing_credentials:anthropic"),
            names: AttentionNames(state: state, sections: inventory.sections)
        )

        #expect(credentials.title == "Connect Anthropic", "the daemon's own label, not the id")
        #expect(credentials.body == ProductStrings[.attentionProviderCredentialsBody])

        // The advisory half, keyed the same way: a channel row names its own
        // channel, which a pane key could not have told from Slack's.
        let channel = try #require(rows.first { $0.id == "channel:whatsapp" })
        #expect(channel.title.contains("WhatsApp"), "the row names the channel, not its wire key")
    }

    /// A restart row carries the daemon's own reason sentences: the app never
    /// composes its own reason for a restart.
    @Test("the restart row quotes the daemon's reasons and offers the restart")
    func restartRowQuotesTheDaemon() throws {
        let rows = AttentionProjection.rows(for: try FakeDaemonGateway.fixtureResult(named: "setup_state_get", as: ManagementSetupState.self))
        let restart = try #require(rows.first { $0.id == "restart_pending" })

        #expect(restart.body.contains("Provider settings changed since Fermix started."))
        #expect(restart.body.contains("Voice settings changed since Fermix started."))
        #expect(restart.action == .restartDaemon)
    }

    /// Attention is a protocol v2 section. Against a daemon that refuses it, it
    /// renders the designed state, never an error and never an empty list that
    /// would read as "nothing is wrong".
    ///
    /// Which of the two states is the build comparison's answer, not the
    /// refusal's: this bundle ships the very engine that is refusing, so no
    /// restart can help and the row must not offer one (owner report of
    /// 2026-09-04).
    @Test("a refusal a restart cannot fix leaves Attention in the engine-behind state")
    func attentionAgainstAnOlderDaemon() async throws {
        let harness = try HomeHarness(protocolCeiling: 1)

        await harness.model.refresh()

        #expect(harness.model.snapshot.attention == .engineBehindApp)
        #expect(harness.model.snapshot.runtime.isEmpty == false, "the rest of Home keeps working")
    }

    /// And the same refusal on a Mac whose bundle really does ship a newer
    /// engine keeps the restart: there the restart is the remedy.
    @Test("a refusal the bundle can fix keeps the restart on the Attention row")
    func attentionWhenTheBundleShipsANewerEngine() async throws {
        let harness = try HomeHarness(protocolCeiling: 1, reconciler: EngineReconcilerFixture.upgraded())

        await harness.model.refresh()

        #expect(harness.model.snapshot.attention == .requiresNewerEngine)
    }

    /// The two non-row states are rows too. An empty list would read as
    /// "nothing is wrong", which is the one thing neither of them means.
    @Test("the newer-engine and refused states each draw one line with no action")
    func nonRowStatesStillDrawALine() {
        let older = AttentionSection.requiresNewerEngine.displayRows
        #expect(older.count == 1)
        #expect(older.first?.title == ProductStrings[.homeAttentionNewerEngineTitle])
        #expect(older.first?.body == ProductStrings[.daemonErrorRequiresNewerEngine])
        // The one action that clears it. The `Finish updating Fermix` sheet
        // exists for exactly this state, and a row with no action made it
        // unreachable (M34 §7.1, §7.2).
        #expect(older.first?.action == .restartDaemon)

        // The other half of the split: the same refusal on a bundle that ships
        // no newer engine offers nothing, because a restart brings the same
        // engine back (owner report of 2026-09-04).
        let behind = AttentionSection.engineBehindApp.displayRows
        #expect(behind.count == 1)
        #expect(behind.first?.body == ProductStrings[.settingsEngineBehindApp])
        #expect(behind.first?.action == nil)

        let refused = AttentionSection.unavailable("another write is in flight").displayRows
        #expect(refused.count == 1)
        #expect(refused.first?.body == "another write is in flight")
        #expect(refused.first?.action == nil)

        #expect(AttentionSection.rows([]).displayRows.isEmpty)
    }

    @Test("a refused setup state is reported in the daemon's own words")
    func attentionRefusal() async throws {
        let harness = try HomeHarness()
        harness.gateway.v2Failure = ManagementError.daemon(
            ManagementFailure(
                code: .busy,
                message: "another write is in flight",
                details: ManagementScalarMap(values: [:])
            )
        )

        await harness.model.refresh()

        #expect(harness.model.snapshot.attention == .unavailable("another write is in flight"))
    }

    /// Every detail key the closed set carries resolves to a described gap.
    ///
    /// The set is the whole published table plus one member of each
    /// parameterised family, not just the two keys the fixture happens to
    /// contain: a coverage gate driven by a fixture would pass with most of the
    /// catalogue emptied. The fixture loop stays as the contract half — a key
    /// the contract publishes and this build has never seen fails here.
    @Test("every key in the closed set, and each family, has copy of its own")
    func catalogueCoversTheClosedSet() {
        let synthesised: [AttentionDetail] = [
            .providerCredentials(provider: "anthropic"),
            .channel(name: "telegram")
        ]

        for detail in Array(AttentionDetail.publishedKeys.values) + synthesised {
            let row = AttentionCatalogue.row(for: detail)

            #expect(!row.title.isEmpty, "\(detail.wireKey)")
            #expect(!row.body.isEmpty, "\(detail.wireKey)")
            #expect(row.title != detail.wireKey, "\(detail.wireKey) renders its raw wire key as a title")
            #expect(row.body != ProductStrings[.attentionUnrecognizedBody], "\(detail.wireKey) has no copy")
        }
    }

    @Test("every detail key in the contract's own fixtures has copy")
    func catalogueCoversTheContract() throws {
        let state = try FakeDaemonGateway.fixtureResult(named: "setup_state_get", as: ManagementSetupState.self)

        for failure in state.readiness.failures {
            let detail = AttentionDetail(detailKey: failure.detailKey)

            if case .unrecognized = detail {
                Issue.record("\(failure.detailKey) has no catalogue entry")
                continue
            }

            let row = AttentionCatalogue.row(for: detail)
            #expect(!row.title.isEmpty, "\(failure.detailKey)")
            #expect(!row.body.isEmpty, "\(failure.detailKey)")
        }
    }

    @Test("every published detail key round-trips through its wire spelling")
    func detailKeysRoundTrip() {
        for (key, detail) in AttentionDetail.publishedKeys {
            #expect(AttentionDetail(detailKey: key) == detail, "\(key)")
            #expect(detail.wireKey == key, "\(key)")
        }

        #expect(AttentionDetail(detailKey: "channel:slack") == .channel(name: "slack"))
        #expect(AttentionDetail(detailKey: "channel:slack").wireKey == "channel:slack")
        #expect(AttentionDetail(detailKey: "provider:missing_credentials:xai").wireKey
            == "provider:missing_credentials:xai")
    }

    /// Every gap that a pane can clear carries a deep link into that pane
    /// (decision D1). Before it, those rows carried no action at all, because
    /// there was no surface to send anyone to.
    @Test("every gap a pane can clear carries a deep link into that pane")
    func attentionDeepLinks() {
        let expected: [(AttentionDetail, SettingsPane)] = [
            (.personalization, .personality),
            (.providerUnknown, .providers),
            (.providerMultiplePrimary, .providers),
            (.providerInvalidAuthMode, .providers),
            (.providerCredentials(provider: "anthropic"), .providers),
            (.channel(name: "telegram"), .channels),
            (.voiceRealtime, .voice)
        ]

        for (detail, pane) in expected {
            #expect(
                AttentionCatalogue.action(for: detail) == .openSettings(pane),
                "\(detail.wireKey) does not link to \(pane.slug)"
            )
        }

        // Every gap carries exactly one action, including the three answered
        // outside a pane: the legacy unit opens the sheet of commands, an
        // unreadable settings file opens itself in the Finder, and a key the
        // keychain will not hand over is rewritten by `Replace…` on its
        // provider row (M34 §15.2).
        #expect(AttentionCatalogue.action(for: .restartPending) == .restartDaemon)
        #expect(AttentionCatalogue.action(for: .externalConfigChange) == .reloadSettings)
        #expect(AttentionCatalogue.action(for: .configUnreadable) == .revealSettingsFile)
        #expect(AttentionCatalogue.action(for: .legacyServiceUnit) == .showInstructions)
        #expect(AttentionCatalogue.action(for: .secretACLRestricted) == .openSettings(.providers))
        for detail in [AttentionDetail.configUnreadable, .legacyServiceUnit, .secretACLRestricted] {
            #expect(AttentionCatalogue.action(for: detail) != nil, "\(detail.wireKey)")
        }
    }

    /// The removal sheet is built from the unit the DAEMON reported, not from a
    /// filesystem probe and a path composed in Swift.
    ///
    /// The daemon owns the home. A unit it reports under a `HOME` this app
    /// cannot see is exactly the case the probe answered with `Fermix cannot
    /// find that service` — while Home's own Attention row, one line above, was
    /// already drawing the daemon's path.
    @Test("the removal instructions are built from the unit the daemon reported")
    func coexistenceInstructionsComeFromTheDaemon() throws {
        let systemUnit = try ManagementValueFixture.decode(
            #"{"present": true, "scope": "system", "path": "/Library/LaunchDaemons/io.tezra.fermix.plist"}"#,
            as: ManagementLegacyServiceUnit.self
        )
        let userUnit = try ManagementValueFixture.decode(
            #"{"present": true, "scope": "user", "path": "/elsewhere/io.tezra.fermix.plist"}"#,
            as: ManagementLegacyServiceUnit.self
        )
        let absent = try ManagementValueFixture.decode(
            #"{"present": false, "scope": null, "path": null}"#,
            as: ManagementLegacyServiceUnit.self
        )

        let system = try #require(
            CoexistenceInstructions.legacyServiceUnit(unit: systemUnit, cli: Self.noLauncher)
        )
        let user = try #require(
            CoexistenceInstructions.legacyServiceUnit(unit: userUnit, cli: Self.noLauncher)
        )

        #expect(system.id == CoexistenceInstructions.legacyServiceUnitRemoval)
        #expect(system.commands.contains { $0.contains("/Library/LaunchDaemons") })
        #expect(system.commands.allSatisfy { $0.hasPrefix("sudo ") }, "a system unit needs rights")
        // The daemon's own path, wherever it is, rather than one composed under
        // this app's account.
        #expect(user.commands.contains { $0.contains("/elsewhere/io.tezra.fermix.plist") })
        #expect(!user.commands.contains { $0.hasPrefix("sudo ") })

        // Nothing to remove, nothing to show; and a report with no path is not
        // a sheet, because the path is one of the commands.
        #expect(CoexistenceInstructions.legacyServiceUnit(unit: absent, cli: Self.noLauncher) == nil)
        #expect(CoexistenceInstructions.legacyServiceUnit(unit: nil, cli: Self.noLauncher) == nil)
    }

    /// The golden home reports one, so the sheet has something to draw from the
    /// same snapshot the Attention row reads its path from.
    @Test("the golden home's legacy unit yields the sheet the attention row points at")
    func goldenLegacyUnitYieldsInstructions() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let unit = state.coexistence.legacyServiceUnit
        let instructions = try #require(
            CoexistenceInstructions.legacyServiceUnit(unit: unit, cli: Self.noLauncher)
        )
        let row = try #require(
            AttentionProjection.rows(for: state).first { $0.id == "legacy_service_unit" }
        )

        let path = try #require(unit.path)

        #expect(unit.present)
        #expect(row.body.contains(path), "the row names the daemon's own path")
        #expect(instructions.commands.contains { $0.contains(path) })
    }

    /// A bundle with no linked launcher, which is the state the raw launchd
    /// commands are for. It decides the SHAPE of the commands, never the path or
    /// the scope: those are the daemon's.
    private static let noLauncher = CLILinkPlan.launcherMissing(path: "/usr/local/bin/fermix")

    /// The deep link reads as one sentence naming the pane, from the one
    /// resolver Doctor's remediation button also reads.
    @Test("a deep link is titled by the pane it opens")
    func deepLinkTitles() {
        #expect(AttentionAction.openSettings(.providers).title == "Open Providers")
        #expect(AttentionAction.openSettings(.channels).title == "Open Channels")
        #expect(AttentionAction.openSettings(.codingAgents).title == "Open Coding agents")

        for pane in SettingsPane.allCases {
            #expect(AttentionAction.openSettings(pane).title.contains(pane.title), "\(pane.slug)")
        }
    }

    /// A key this build has never seen keeps the daemon's own name for it and
    /// gets the catalogue's own sentence, never a stranger's.
    @Test("an unknown detail key is named rather than folded onto a neighbour")
    func unknownDetailKey() {
        let detail = AttentionDetail(detailKey: "quota:exceeded")
        let row = AttentionCatalogue.row(for: detail)

        #expect(detail == .unrecognized("quota:exceeded"))
        #expect(row.title == "quota:exceeded")
        #expect(row.body == ProductStrings[.attentionUnrecognizedBody])
        #expect(row.action == nil)
    }

    /// An empty family suffix is not a family member: it is a key this build
    /// does not understand, and pretending otherwise would render "Connect ".
    @Test("a family key with no member is unrecognised, not an empty member")
    func emptyFamilyMember() {
        #expect(AttentionDetail(detailKey: "provider:missing_credentials:")
            == .unrecognized("provider:missing_credentials:"))
        #expect(AttentionDetail(detailKey: "channel:") == .unrecognized("channel:"))
    }

    /// The copy gate M34 §6 asks for: no Attention string sends the operator to
    /// a command line.
    @Test("no attention string names a command line, a config file, or an environment variable")
    func attentionCopyIsNative() {
        let keys = ProductStringKey.allCases.filter { $0.rawValue.hasPrefix("attention.") }

        #expect(!keys.isEmpty)
        for key in keys {
            let value = ProductStrings[key]

            #expect(!value.contains("mix fermix.setup"), "\(key.rawValue)")
            #expect(!value.contains("config.toml"), "\(key.rawValue)")
            #expect(!value.contains("_API_KEY"), "\(key.rawValue)")
            #expect(!value.contains("$"), "\(key.rawValue)")
        }
    }

    // MARK: - Update summary

    @Test("the update summary reports only what the seam can observe")
    func updateSummaryIsHonest() throws {
        #expect(try snapshot(update: .unknown).updateSummary == ProductStrings[.homeUpdateUnknown])
        #expect(try snapshot(update: .upToDate(lastCheckedAt: nil)).updateSummary == ProductStrings[.homeUpdateCurrent])

        let available = try snapshot(update: .available(version: "0.9.1", releaseClass: .normal)).updateSummary
        #expect(available.contains("0.9.1"))

        // The one untruth this surface exists to avoid: a check that did not
        // complete never reads as up to date (M34 §6, R2).
        let failed = try snapshot(update: .checkFailed(lastCheckedAt: nil)).updateSummary
        #expect(failed == ProductStrings[.homeUpdateCheckFailed])
        #expect(failed != ProductStrings[.homeUpdateCurrent])
    }

    @Test("a build with no updater behind it claims nothing")
    func unwiredUpdaterClaimsNothing() {
        #expect(!UnwiredUpdater().canCheckForUpdates)
    }

    /// An offered update reaches the menu bar through the section Home already
    /// draws, so the glyph and the window cannot disagree about whether
    /// something is waiting (M34 §6, R2).
    @Test("an available update badges the menu bar through Home's own section")
    func availableUpdateBadgesTheMenuBar() async throws {
        let harness = try HomeHarness()
        harness.updates.reported = .available(version: "0.2.0", releaseClass: .normal)

        await harness.model.refresh()

        #expect(harness.model.snapshot.attention.displayRows.contains { $0.id == "update_available" })
        #expect(harness.appModel.needsAttention)
    }

    /// A staged update says so on the same row: from that point quitting
    /// replaces the bundle, and nothing else on the screen would tell anyone.
    @Test("a staged update says the replacement happens on quit")
    func stagedUpdateSaysWhenItInstalls() async throws {
        let harness = try HomeHarness()
        harness.updates.reported = .staged(version: "0.2.0")

        await harness.model.refresh()

        #expect(harness.model.snapshot.attention.displayRows.contains { $0.id == "update_staged" })
    }

    /// Asking for a check is what raises the updater's own alert, and what
    /// brings one that is already showing back into focus.
    @Test("the update row asks the updater rather than drawing a second alert")
    func updateRowAsksTheUpdater() throws {
        let harness = try HomeHarness()

        harness.model.perform(.showUpdate)

        #expect(harness.updates.checks == 1)
    }

    // MARK: - Actions

    @Test("the model reads hello, overview and the setup state, in that order")
    func modelRefresh() async throws {
        let harness = try HomeHarness()

        await harness.model.refresh()

        // The section index comes with them, once: it is where a channel gap's
        // own name is published, and without it a row reads `Connect whatsapp`.
        #expect(harness.gateway.calls == [.negotiate, .overview, .v2(.setupStateGet), .v2(.settingsSections)])
        #expect(harness.model.snapshot.statusTitle == ProductStrings[.homeStatusRunning])
    }

    @Test("a daemon that cannot be reached leaves Home truthful rather than blank")
    func modelReportsAFailure() async throws {
        let harness = try HomeHarness()
        harness.gateway.negotiateFailure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        await harness.model.refresh()

        #expect(harness.model.snapshot.statusTitle == ProductStrings[.daemonStateNotRunning])
        #expect(harness.model.snapshot.statusTone == .fail)
    }

    /// The header and Attention have to agree. An unreachable daemon reported no
    /// gaps because nothing could ask it, and the empty state's "nothing needs
    /// your attention" is the one sentence that claims the opposite.
    @Test("an unreachable daemon leaves Attention carrying the refusal, never the empty state")
    func unreachableAttentionIsNotAnAllClear() async throws {
        let harness = try HomeHarness()
        harness.gateway.negotiateFailure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        await harness.model.refresh()

        let rows = harness.model.snapshot.attention.displayRows
        #expect(rows.count == 1)
        #expect(rows.first?.title == ProductStrings[.homeAttentionUnavailableTitle])
        #expect(rows.first?.body == ManagementMessage.sentence(for:
            ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))))
        #expect(rows.first?.action == nil)
        #expect(rows.first?.title != ProductStrings[.homeAttentionEmpty])
    }

    /// The same rule before the first read: Home has asked nothing, so it says
    /// that rather than drawing the all-clear.
    @Test("before the first read Attention says nothing has been read")
    func attentionBeforeTheFirstRead() throws {
        let harness = try HomeHarness()

        let rows = harness.model.snapshot.attention.displayRows
        #expect(rows.count == 1)
        #expect(rows.first?.body == ProductStrings[.homeAttentionUnread])
    }

    /// The two login registrations are independent in both directions: turning
    /// the GUI's off never touches the daemon's.
    @Test("the GUI login toggle never changes the background service")
    func loginTogglesAreIndependent() async throws {
        let harness = try HomeHarness()
        try harness.loginItems.register(.agent)

        harness.model.setOpenAtLogin(true)
        #expect(harness.loginItems.status(.mainApp) == .enabled)
        #expect(harness.loginItems.status(.agent) == .enabled)

        harness.model.setOpenAtLogin(false)
        #expect(harness.loginItems.status(.mainApp) == .notRegistered)
        #expect(harness.loginItems.status(.agent) == .enabled, "the daemon's registration is untouched")
    }

    /// The third switch in the Background section. It is a way in rather than a
    /// registration: hiding the item leaves both registrations alone, and macOS
    /// remembers the answer under the item's own autosave name, so Home reads
    /// the item rather than a copy that could drift from a Command-drag.
    @Test("the menu bar switch hides the item and changes neither registration")
    func menuBarToggleIsIndependent() async throws {
        let harness = try HomeHarness()
        try harness.loginItems.register(.agent)
        try harness.loginItems.register(.mainApp)

        #expect(harness.model.menuBarItemShown)

        harness.model.setMenuBarItemShown(false)

        #expect(harness.statusItem.isVisible == false)
        #expect(harness.model.menuBarItemShown == false)
        #expect(harness.loginItems.status(.mainApp) == .enabled)
        #expect(harness.loginItems.status(.agent) == .enabled)
        #expect(harness.lifecycle.calls.isEmpty, "hiding the item touched the daemon")

        harness.model.setMenuBarItemShown(true)
        #expect(harness.model.menuBarItemShown)
    }

    /// The switch reads through to the item, so a Command-drag off the bar
    /// while Home is open changes the answer under it. The item reports every
    /// change to its own visibility, and Home redraws from that one notice
    /// whether it made the change or the user did.
    @Test("a removal the app did not make redraws the switch")
    func menuBarRemovalRedrawsTheSwitch() throws {
        let harness = try HomeHarness()
        var redraws = 0
        let published = harness.model.objectWillChange.sink { _ in redraws += 1 }

        harness.statusItem.isVisible = false

        #expect(redraws == 1)
        #expect(harness.model.menuBarItemShown == false)

        harness.model.setMenuBarItemShown(true)
        #expect(redraws == 2)

        published.cancel()
    }

    /// Two edges point back at Home, and only the composition builds either:
    /// the item's visibility notice, which redraws the switch above, and the
    /// login launch's read, which is the only read of the daemon a launch that
    /// opens no window makes. Both fail silently — a switch that stops
    /// redrawing, a menu bar with nothing to draw — so they are gated here
    /// rather than left to a surface test that would never notice.
    @Test("the composition wires both of Home's callbacks into it")
    func compositionWiresHomesCallbacks() throws {
        let composition = try #require(try SourceTree.swiftFiles(matching: "App/AppComposition.swift").first)

        #expect(composition.text.contains("menuBar.onMenuBarItemShownChanged ="))
        #expect(composition.text.contains("surfaces.home.menuBarItemVisibilityChanged()"))
        #expect(composition.text.contains("coordinator.readDaemonCondition ="))
        #expect(composition.text.contains("surfaces.home.refresh()"))
    }

    // MARK: - What the read tells the menu bar

    /// Home's refresh is the only read of the daemon an ordinary launch makes,
    /// so it is what has to answer the condition. Left unanswered, the app sits
    /// on the starting glyph and a status line reading "Fermix is starting" for
    /// the whole session, against a daemon that has been up for days.
    @Test("a successful read moves the menu bar and the status line off starting")
    func refreshResolvesTheDaemonCondition() async throws {
        let harness = try HomeHarness()
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(
            failures: false,
            restartRequired: false
        )
        #expect(harness.appModel.daemon == .starting)

        await harness.model.refresh()

        #expect(harness.appModel.daemon == .running)
        #expect(harness.appModel.needsAttention == false)
        #expect(harness.appModel.menuGlyph == .running)
        #expect(harness.statusLine() != .starting)
    }

    /// The other half of the same read. A daemon nothing could reach is stopped,
    /// which the glyph carries as its own mark and the status line says in
    /// words.
    @Test("a read that reaches nothing puts the glyph on its stopped state")
    func unreachableReadStopsTheGlyph() async throws {
        let harness = try HomeHarness()
        harness.gateway.negotiateFailure = ManagementError.transport(.socketMissing(path: "/tmp/daemon.sock"))

        await harness.model.refresh()

        #expect(harness.appModel.daemon == .stopped)
        #expect(harness.appModel.menuGlyph == .attention)
        #expect(harness.statusLine() == .notRunning)
    }

    /// The badge is the Attention section itself, so the glyph and the window
    /// can never disagree about whether something needs looking at. It has to
    /// clear as well as raise: a badge nothing can take away is one nobody
    /// reads.
    @Test("the rows Home draws are what badges the glyph, and a clean read clears it")
    func attentionRowsDriveTheBadge() async throws {
        // The golden fixture carries a gating readiness failure and a pending
        // restart, which is exactly what an operator with a gap sees.
        let harness = try HomeHarness()

        await harness.model.refresh()

        #expect(!harness.model.snapshot.attention.displayRows.isEmpty)
        #expect(harness.appModel.needsAttention)
        #expect(harness.appModel.menuGlyph == .attention)

        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(
            failures: false,
            restartRequired: false
        )
        await harness.model.refresh()

        #expect(harness.model.snapshot.attention.displayRows.isEmpty)
        #expect(harness.appModel.needsAttention == false)
        #expect(harness.appModel.menuGlyph == .running)
    }

    @Test("the background-service switch runs the lifecycle transaction, not a process kill")
    func serviceActionRunsTheTransaction() async throws {
        let harness = try HomeHarness()
        harness.model.setBackgroundService(false)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.lifecycle.calls == [.disable])
    }

    /// A restart is never automatic (M34 §5.10): the row asks, and the sheet is
    /// where the daemon's reasons and the work it would interrupt are read
    /// before anything is drained.
    @Test("the restart row asks rather than restarting on the click")
    func restartActionOpensTheSheet() async throws {
        let harness = try HomeHarness()
        harness.model.perform(.restartDaemon)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.appModel.restartSheetShown)
        #expect(harness.lifecycle.calls.isEmpty)
    }

    /// The same sheet under a different title: the engine reconcile is a
    /// restart that finishes an update, and Home learns that from the build-id
    /// comparison rather than from a v2 method refusing (M34 §7.2).
    @Test("the sheet the engine reconcile opens is the finish-updating one")
    func pendingReconcileTitlesTheSheet() async throws {
        let aligned = try HomeHarness()
        await aligned.model.refresh()
        #expect(!aligned.model.isFinishingUpdate)

        let upgraded = try HomeHarness(reconciler: EngineReconcilerFixture.upgraded())
        await upgraded.model.refresh()

        #expect(upgraded.model.isFinishingUpdate)
    }

    /// The reload re-records the daemon's baseline, which is what lets the next
    /// write succeed, so Home re-reads afterwards rather than leaving the
    /// banner standing over stale state.
    @Test("the reload action asks the daemon and then re-reads Home")
    func reloadActionRefreshes() async throws {
        let harness = try HomeHarness()

        harness.model.perform(.reloadSettings)
        try await harness.settle()

        #expect(harness.gateway.calls.contains(.v2(.settingsReload)))
        #expect(harness.model.actionMessage == nil)
    }
}

@MainActor
final class HomeHarness {
    let gateway = FakeDaemonGateway()
    let loginItems = FakeLoginItemService()
    let lifecycle = FakeLifecycleController()
    let appModel = AppModel()
    let windows = FakeWindowHost()
    let coordinator: AppCoordinator
    let model: HomeModel
    let settings: SettingsModel
    /// What the update seam answers. The harness owns it so a case can state
    /// what a check found without a feed behind it.
    let updates = FakeUpdateChecker()
    /// The status item, without a status bar, so the Background section's third
    /// switch has something real to write to.
    let statusItem = FakeStatusItem()
    let menuBar: MenuBarController

    init(protocolCeiling: Int? = nil, reconciler: EngineReconciler = EngineReconcilerFixture.aligned()) throws {
        gateway.hello = try ManagementValueFixture.hello(maximum: protocolCeiling)
        gateway.overviewResult = try ManagementValueFixture.overview()
        settings = SettingsFixture.model(gateway: gateway, loginItems: loginItems)

        coordinator = AppCoordinator(
            model: appModel,
            windows: WindowCoordinator(host: windows),
            voice: FakeVoiceController(),
            lifecycle: lifecycle,
            updates: FakeUpdateReconciler(),
            gate: ServiceMutationGate(),
            bootstrap: { .present },
            termination: FakeTerminationRequester(),
            settings: settings,
            presentation: SettingsPresentation()
        )
        menuBar = MenuBarController(model: appModel, item: statusItem)
        model = HomeModel(
            gateway: gateway,
            services: ServiceController(loginItems: loginItems),
            coordinator: coordinator,
            updates: updates,
            settings: settings,
            reconciler: reconciler,
            menuBar: menuBar
        )
        // The same edge the composition builds: the item reports every change to
        // its own visibility, and Home redraws the switch from that.
        menuBar.onMenuBarItemShownChanged = { [weak model] in model?.menuBarItemVisibilityChanged() }
    }

    /// The status item's first row, read from the same facts Home just
    /// resolved. It is a second surface on the one answer, so a condition that
    /// never leaves `starting` shows up here too.
    func statusLine() -> StatusLine {
        StatusMenuSource(
            model: appModel,
            snapshot: { [model] in model.snapshot },
            reconcile: { [model] in model.engineReconcile }
        ).line()
    }

    /// Lets a detached action task finish without a wall-clock wait.
    func settle() async throws {
        for _ in 0..<16 {
            await Task.yield()
        }
    }
}
