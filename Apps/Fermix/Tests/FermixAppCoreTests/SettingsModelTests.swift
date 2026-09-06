import Foundation
import Testing

@testable import FermixAppCore

/// The one settings model (M34 §8).
///
/// Every case here is about a rule the design states and a view body cannot
/// show: what a payload carries, what a refusal does to the control, and what a
/// bounded poll ends in.
@Suite("Settings model")
@MainActor
struct SettingsModelTests {

    // MARK: - Payloads

    /// A write carries the keys that changed and nothing else, so a save never
    /// re-submits a value nobody touched.
    @Test("a write payload carries the changed key only")
    func changedKeysOnly() async throws {
        let harness = try SettingsHarness()

        await harness.model.apply(section: "realtime", key: "realtime_voice", value: .text("marin"))

        #expect(harness.gateway.appliedSettings.count == 1)
        #expect(harness.gateway.appliedSettings.first?.section == "realtime")
        #expect(harness.gateway.appliedSettings.first?.values == ["realtime_voice": .text("marin")])
    }

    /// The changed half of a section's drafts is what a pane commits: a draft
    /// equal to the daemon's own value is not a change.
    @Test("an untouched row is not part of the changed set")
    func unchangedRowsAreNeverSent() async throws {
        let harness = try SettingsHarness()
        await harness.model.loadSection("realtime")

        harness.model.setDraft(.flag(true), for: SettingsDraftKey(section: "realtime", key: "realtime_enabled"))
        harness.model.setDraft(.text("marin"), for: SettingsDraftKey(section: "realtime", key: "realtime_voice"))

        // The golden publishes `realtime_enabled` as false and the voice as
        // `marin`, so exactly one of the two drafts is a change.
        #expect(harness.model.changedValues(in: "realtime") == ["realtime_enabled": .flag(true)])
    }

    /// The Voice pane's route slug is `voice` and its section is `realtime`.
    ///
    /// They are two vocabularies and only one of them goes on the wire: the
    /// daemon serves that pane as `realtime` and answers `invalid_params` for
    /// `voice`, so a pane that addressed its own slug would read nothing and
    /// save nothing. The pane never names a section itself — it reads the ids
    /// the inventory published for it — and this is the case that proves the
    /// one it gets is `realtime`.
    @Test("the Voice pane reads and writes realtime, never its own slug")
    func voicePaneAddressesTheRealtimeSection() async throws {
        let harness = try SettingsHarness()
        await harness.model.loadInventory()

        #expect(harness.model.sections(for: .voice).map(\.id) == ["realtime", "transcription"])
        #expect(SettingsPane.voice.slug == "voice", "the route and the sidebar keep the slug")

        await harness.model.paneAppeared(.voice)

        #expect(harness.gateway.readSections == ["realtime", "transcription"])

        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(true))

        #expect(harness.gateway.appliedSettings.map(\.section) == ["realtime"])
        #expect(!harness.gateway.readSections.contains("voice"))
        #expect(!harness.gateway.appliedSettings.contains { $0.section == "voice" })
    }

    /// Null is a value with a meaning: it asks the daemon to forget the key.
    @Test("clearing a row sends null rather than an empty value")
    func nullToForget() async throws {
        let harness = try SettingsHarness()

        await harness.model.apply(section: "realtime", key: "realtime_voice", value: .absent)

        #expect(harness.gateway.appliedSettings.first?.values == ["realtime_voice": .absent])

        let encoded = try JSONEncoder().encode(ManagementSettingValue.absent)
        #expect(String(data: encoded, encoding: .utf8) == "null")
    }

    // MARK: - Results

    /// The restart requirement and its reasons come off every write result and
    /// then off the setup state the write re-reads, so the banner names the
    /// daemon's own sentences and never one the app composed. The re-read is
    /// the last word, which is why these are the setup state's two.
    @Test("a write result carries the restart reasons into the banner")
    func restartReasons() async throws {
        let harness = try SettingsHarness()

        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))

        #expect(harness.model.restart.required)
        #expect(harness.model.restart.reasons.map(\.section) == ["providers", "realtime"])
        #expect(
            harness.model.restart.reasons.map(\.sentence) == [
                "Provider settings changed since Fermix started.",
                "Voice settings changed since Fermix started."
            ]
        )

        let banner = SettingsBannerState.resolve(
            configState: harness.model.configState,
            restart: harness.model.restart,
            sentence: nil
        )
        #expect(banner == .restart(harness.model.restart.reasons))
    }

    /// Against a daemon the bundle is ahead of, every pane refuses and the
    /// restart that applies the bundled engine is the one action. Without this
    /// the panes stated the problem and offered nothing, so the `Finish updating
    /// Fermix` sheet was unreachable in exactly the state it exists for
    /// (M34 §7.1).
    ///
    /// It leads the restart case: such a daemon reports no restart requirement
    /// of its own, so nothing else would draw a banner at all.
    @Test("a daemon behind the bundle puts the finish-updating banner on every pane")
    func newerEngineBanner() throws {
        let banner = SettingsBannerState.resolve(
            configState: .clear,
            restart: ManagementRestartState(required: false, reasons: []),
            sentence: nil,
            engine: EngineReconcile(builds: Self.upgradedBuilds, methodsRefused: true)
        )

        #expect(banner == .finishUpdating)
    }

    /// The other half of the same refusal, and the owner's dev loop
    /// (2026-09-04): the daemon in memory already *is* the engine this copy
    /// ships, so a restart brings the same engine back. The banner says so and
    /// offers nothing, where it used to offer `Restart` and change nothing.
    @Test("a refusal a restart cannot fix draws the engine-behind banner with no action")
    func engineBehindBanner() async throws {
        let harness = try SettingsHarness(gateway: SettingsFixture.n1Gateway())

        await harness.model.refreshSetupState()

        #expect(harness.model.requiresNewerEngine)
        #expect(!harness.model.isFinishingUpdate, "the running daemon is the bundled engine")

        let banner = SettingsBannerState.resolve(
            configState: harness.model.configState,
            restart: harness.model.restart,
            sentence: nil,
            engine: harness.model.engineReconcile
        )
        #expect(banner == .engineBehindApp)
        #expect(harness.model.newerEngineSentence == ProductStrings[.settingsEngineBehindApp])
    }

    /// The build comparison this suite's newer-engine cases run against: the
    /// bundle ships an engine the running daemon is not.
    private static let upgradedBuilds = EngineReconcileOutcome.pendingEngineRestart(
        running: EngineBuild(buildId: "1", productVersion: "0.9.0"),
        bundled: EngineBuild(buildId: "2", productVersion: "0.10.0")
    )

    /// A restart finished, so the negotiated window goes with it: it belongs to
    /// the daemon that just exited, and every read below is gated against it
    /// (M34 §7.2).
    @Test("a completed restart drops the negotiated window before re-reading")
    func restartDropsTheNegotiatedWindow() async throws {
        let harness = try SettingsHarness(gateway: SettingsFixture.n1Gateway())

        await harness.model.refreshSetupState()
        #expect(harness.model.requiresNewerEngine)

        // The engine that came back serves what this build speaks.
        harness.gateway.hello = try ManagementValueFixture.hello()
        await harness.model.restartCompleted()

        #expect(!harness.model.requiresNewerEngine, "the stale window refused every read after the restart")
        #expect(harness.model.setupState.value != nil)
    }

    /// Changes the operator did not type are the daemon's sentences, surfaced
    /// rather than inferred. The golden write reports none, so the daemon's own
    /// shape is scripted with one: an empty list would prove only that nothing
    /// is drawn when there is nothing to draw.
    @Test("a write result carries the daemon's side effects")
    func sideEffects() async throws {
        let harness = try SettingsHarness()

        #expect(harness.gateway.settingsAppliedResult == nil)
        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(true))
        #expect(harness.model.sideEffects.isEmpty, "the golden write reports no side effect")

        harness.gateway.settingsAppliedResult = try Self.appliedWithSideEffect(
            "Voice notes were turned on with voice."
        )
        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(true))

        #expect(harness.model.sideEffects == ["Voice notes were turned on with voice."])
    }

    /// The golden `settings.apply` answer, carrying one side effect. Built from
    /// the contract's own record rather than from a literal, so only the field
    /// under test is this test's.
    private static func appliedWithSideEffect(_ sentence: String) throws -> ManagementSettingsApplied {
        let fixture = try #require(
            try ManagementFixtures.load(.success).first { $0.name == "settings_apply" }
        )
        var result = try #require(try fixture.object("response")["result"] as? [String: Any])
        result["side_effects"] = [sentence]

        return try JSONDecoder().decode(
            ManagementSettingsApplied.self,
            from: try JSONSerialization.data(withJSONObject: result)
        )
    }

    /// A refusal puts the control back where the daemon had it and shows why
    /// under the row.
    @Test("a refused apply reverts the control and shows the daemon's sentence")
    func refusedApplyReverts() async throws {
        let harness = try SettingsHarness()
        harness.gateway.v2Failures[.settingsApply] = ManagementRefusal.daemon(
            .invalidParams,
            "A voice named marin is not one this model offers."
        )

        await harness.model.apply(section: "realtime", key: "realtime_voice", value: .text("marin"))

        let key = SettingsDraftKey(section: "realtime", key: "realtime_voice")
        #expect(harness.model.drafts[key] == nil, "the draft is gone, so the row shows the daemon's value")
        #expect(harness.model.message(for: key) == "A voice named marin is not one this model offers.")
    }

    // MARK: - The external-change gate

    /// While the settings file has changed outside Fermix, nothing is written:
    /// the reload is the one action, and the write after it succeeds.
    @Test("external_change blocks every write until the reload is taken")
    func externalChangeBlocksWrites() async throws {
        let harness = try SettingsHarness()
        harness.gateway.v2Failures[.settingsApply] = ManagementRefusal.daemon(
            .externalChange,
            "The settings file changed outside Fermix."
        )

        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))
        #expect(harness.model.configState == .externalChange)
        #expect(harness.model.writesBlocked)

        // The second write never reaches the socket.
        harness.gateway.appliedSettings = []
        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))
        #expect(harness.gateway.appliedSettings.isEmpty)

        harness.gateway.v2Failures[.settingsApply] = nil
        #expect(await harness.model.reloadFromDisk() == nil)
        #expect(harness.model.configState == .clear)
        #expect(!harness.model.writesBlocked)

        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))
        #expect(harness.gateway.appliedSettings.count == 1)
    }

    /// A file the daemon cannot read is a different state: no reload action,
    /// and the parser's own sentence.
    ///
    /// Driven by the contract's own `config_unreadable` record, which keeps
    /// `message` at the fixed `The settings file could not be read.` and puts
    /// the parser's line in `details.sentence`. Against a fake that put the
    /// sentence in `message`, this passed while the banner and the Recovery
    /// screen showed two near-identical lines and never
    /// `config.toml [fermix_core.providers] openai must be a table.`
    @Test("config_unreadable is never answered with a reload button")
    func configUnreadableRoutesToRecovery() async throws {
        let harness = try SettingsHarness()
        let published = try ManagementRefusal.published("config_unreadable")
        let sentence = try #require(ManagementMessage.details(of: published)?.sentence)
        harness.gateway.v2Failures[.settingsApply] = published

        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))

        #expect(harness.model.configState == .configUnreadable)
        #expect(harness.model.configUnreadable)
        #expect(!harness.model.writesBlocked, "only external_change refuses writes")
        #expect(harness.model.configSentence == sentence, "the parser's own line, not the code's")
        #expect(
            harness.model.configSentence != "The settings file could not be read.",
            "the fixed message would say nothing about what is wrong"
        )

        let banner = SettingsBannerState.resolve(
            configState: harness.model.configState,
            restart: harness.model.restart,
            sentence: harness.model.configSentence
        )
        #expect(banner == .configUnreadable(sentence))
    }

    /// Every refusal a write earns is shown in the daemon's own words, under
    /// the row that earned it.
    ///
    /// `invalid_params` is one code over a whole family of refusals — every
    /// settings validation, every unwritable key — and its `message` is the same
    /// sentence for all of them. Rendering that alone put `Request parameters
    /// are invalid.` under a row whose real refusal was a sentence the daemon
    /// had already written.
    @Test("a refused write shows the daemon's own sentence under the row")
    func refusedWriteShowsTheDaemonsSentence() async throws {
        let harness = try SettingsHarness()
        let published = try ManagementRefusal.published("invalid_params_with_sentence")
        let sentence = try #require(ManagementMessage.details(of: published)?.sentence)
        harness.gateway.v2Failures[.settingsApply] = published

        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))

        let key = SettingsDraftKey(section: "realtime", key: "realtime_enabled")

        #expect(harness.model.message(for: key) == sentence)
        #expect(harness.model.message(for: key) != "Request parameters are invalid.")
    }

    /// A result whose shape is not the one the vendored contract publishes is
    /// drift, not an outage, and it says so.
    ///
    /// It used to render as `The daemon could not be reached` and reach no log
    /// at all, which on a contract vendored from an uncommitted upstream tree is
    /// exactly the failure that has to be visible.
    @Test("a result shape the contract does not publish reads as drift")
    func resultShapeMismatchIsNotAnOutage() async throws {
        let harness = try SettingsHarness()
        let drift = ManagementError.malformedEnvelope(
            .resultShapeMismatch(method: .setupStateGet, field: "coexistence.config_state")
        )
        harness.gateway.v2Failures[.setupStateGet] = drift

        await harness.model.refreshSetupState()

        #expect(harness.model.setupState.value == nil)
        #expect(ManagementMessage.sentence(for: drift) != ProductStrings[.daemonErrorUnreachable])
        #expect(ManagementMessage.sentence(for: drift) == ProductStrings[.daemonErrorUnexpectedShape])
        // The log line names the method and the field, which is the whole point
        // of keeping the typed error rather than a sentence.
        #expect(ManagementMessage.diagnostic(for: drift).contains("setup.state.get"))
        #expect(ManagementMessage.diagnostic(for: drift).contains("coexistence.config_state"))
    }

    // MARK: - Secrets

    /// Storing or clearing a plugin's own token, or a sign-in client's secret,
    /// re-reads the catalogue that reports whether it is there.
    ///
    /// Neither presence is published on a descriptor row: the detail sheet reads
    /// `credential_present` off `plugins.list` and the client sheet reads
    /// `configured` off the same catalogue. Re-reading only the descriptor
    /// sections left both saying `Add…` over a secret that had just been stored,
    /// until something else happened to refresh the page.
    @Test("a plugin or client secret re-reads the catalogue that reports it")
    func pluginSecretsReReadTheCatalogue() async throws {
        for id in [SettingsModel.pluginSecretId("gmail"), OAuthClientSheet.secretId(for: "google")] {
            let harness = try SettingsHarness()

            #expect(await harness.model.setSecret(id: id, value: "not-a-real-secret") == nil)
            #expect(harness.gateway.calls.contains(.v2(.pluginsList)), "\(id) left the catalogue stale")

            let cleared = try SettingsHarness()
            #expect(await cleared.model.clearSecret(id: id) == nil)
            #expect(cleared.gateway.calls.contains(.v2(.pluginsList)), "\(id) left the catalogue stale")
        }

        // A registry key is not one of those two families, so it re-reads the
        // sections that publish it and asks the catalogue for nothing.
        let plain = try SettingsHarness()
        #expect(await plain.model.setSecret(id: "openai_api_key", value: "sk-not-real") == nil)
        #expect(!plain.gateway.calls.contains(.v2(.pluginsList)))
    }

    /// A store that refuses leaves the sheet open, because the value never
    /// reached the store and closing would lose what was typed.
    @Test("secret_store_failed answers a sentence so the sheet stays open")
    func secretStoreFailedKeepsTheSheetOpen() async throws {
        let harness = try SettingsHarness()
        harness.gateway.v2Failures[.secretSet] = ManagementRefusal.daemon(
            .secretStoreFailed,
            "The keychain is locked."
        )

        let sentence = await harness.model.setSecret(id: "openai_api_key", value: "sk-live")

        #expect(sentence == "The keychain is locked.")
        #expect(harness.gateway.storedSecrets == [SecretWrite(id: "openai_api_key", value: "sk-live")])
    }

    @Test("a stored secret answers nothing to show, so the sheet closes")
    func secretStored() async throws {
        let harness = try SettingsHarness()

        #expect(await harness.model.setSecret(id: "openai_api_key", value: "sk-live") == nil)
        #expect(harness.model.restart.required)
    }

    // MARK: - Jobs

    @Test("a job poll follows the run to a completed status")
    func jobPollingCompletes() async throws {
        let harness = try SettingsHarness()
        harness.gateway.jobScript = [
            try ManagementValueFixture.job(status: "running"),
            try ManagementValueFixture.job(status: "completed", phase: nil)
        ]

        let runner = harness.model.makeJobRunner()
        runner.start(try ManagementValueFixture.job(status: "running"))
        await runner.drainPendingWork()

        #expect(runner.job?.status == .completed)
        #expect(runner.failure == nil)
        #expect(harness.gateway.polledJobs.count == 2)
    }

    /// The sentence a run shows for its current step is per KIND, and the
    /// runner is where that is resolved.
    ///
    /// `binding` on an `auth` job is opening the loopback port that receives the
    /// reply; `binding` on a `plugin_workspace_select` job is tying the plugin
    /// to the workspace. Keyed on the phase alone, the workspace sheet told the
    /// operator it was opening a local port.
    @Test("a run's step sentence is the one for its own kind")
    func jobPhaseSentenceIsPerKind() async throws {
        let harness = try SettingsHarness()
        let auth = harness.model.makeJobRunner()
        let workspace = harness.model.makeJobRunner()

        auth.start(try ManagementValueFixture.job(kind: "auth", phase: "binding"))
        workspace.start(
            try ManagementValueFixture.job(kind: "plugin_workspace_select", phase: "binding")
        )

        #expect(auth.phase?.isEmpty == false)
        #expect(workspace.phase?.isEmpty == false)
        #expect(auth.phase != workspace.phase, "one word, two steps, two sentences")

        // A pair the contract does not publish draws nothing rather than a
        // sentence belonging to another kind's step.
        let wrong = harness.model.makeJobRunner()
        wrong.start(try ManagementValueFixture.job(kind: "provider_probe", phase: "binding"))
        #expect(wrong.phase == nil)
    }

    @Test("a failed job carries the daemon's own sentence")
    func jobPollingFails() async throws {
        let harness = try SettingsHarness()
        harness.gateway.jobScript = [
            try ManagementValueFixture.job(
                status: "failed",
                phase: nil,
                failure: (code: "unavailable", sentence: "cosign is not on the daemon's path.")
            )
        ]

        let runner = harness.model.makeJobRunner()
        runner.start(try ManagementValueFixture.job(status: "running"))
        await runner.drainPendingWork()

        #expect(runner.job?.status == .failed)
        #expect(runner.failure == "cosign is not on the daemon's path.")
    }

    @Test("cancelling a job asks the daemon and follows what it answers")
    func jobCancels() async throws {
        let harness = try SettingsHarness()
        let runner = harness.model.makeJobRunner()
        runner.start(try ManagementValueFixture.job(status: "running"))
        runner.dismiss()

        await runner.cancelJob()

        #expect(harness.gateway.calls.contains(.v2(.jobCancel)))
        #expect(runner.job?.status == .cancelled)
    }

    /// The bound is the daemon's own budget. A job that never reaches a
    /// terminal status ends the poll rather than holding the runner open.
    @Test("a job that never finishes ends at the daemon's budget")
    func jobPollingTimesOut() async throws {
        let harness = try SettingsHarness()
        harness.gateway.jobScript = [try ManagementValueFixture.job(status: "running", budgetMs: 2_000)]

        let runner = harness.model.makeJobRunner()
        runner.start(try ManagementValueFixture.job(status: "running", budgetMs: 2_000))
        await runner.drainPendingWork()

        #expect(runner.job?.status == .running)
        #expect(runner.failure == ProductStrings[.settingsJobTimedOut])
        // 2 s of budget at 500 ms a poll, plus the one that proves it is over.
        #expect(harness.gateway.polledJobs.count == 5)
    }

    /// Dismissing a view stops the polling and leaves the run alone, which is
    /// what makes re-attaching safe.
    @Test("a dismissed runner re-attaches to the run through job.list")
    func jobReattaches() async throws {
        let harness = try SettingsHarness()
        let runner = harness.model.makeJobRunner()

        // The fixture's job list carries one running provider probe and one
        // failed install: only the running one is adoptable.
        await runner.attach(kind: .providerProbe)

        #expect(runner.job?.kind == .providerProbe)
        #expect(runner.isRunning)
        runner.dismiss()

        let idle = harness.model.makeJobRunner()
        await idle.attach(kind: .pluginInstall)
        #expect(idle.job == nil, "a run that already ended is never re-adopted")
    }

    // MARK: - The newer-engine sentence

    /// The finish-updating versus engine-behind split has one owner, and every
    /// surface that says anything about it reads that one value.
    ///
    /// The two states need different words and one of them must offer no
    /// restart at all: on an app that is ahead of the engine it ships, a restart
    /// brings the same engine back. Three surfaces hard-coded the
    /// finish-updating line, so in that state they offered exactly that (owner
    /// report of 2026-09-04).
    @Test("the newer-engine sentence has one owner and two states")
    func newerEngineSentenceHasOneOwner() throws {
        let build = { (id: String) in EngineBuild(buildId: id, productVersion: "0.0.0") }
        let finishing = EngineReconcile(
            builds: .pendingEngineRestart(running: build("running"), bundled: build("bundled")),
            methodsRefused: true
        )
        let behind = EngineReconcile(builds: .aligned, methodsRefused: true)

        #expect(finishing.isFinishingUpdate)
        #expect(finishing.newerEngineSentence == ProductStrings[.settingsRequiresNewerEngine])
        #expect(behind.engineBehindApp)
        #expect(behind.newerEngineSentence == ProductStrings[.settingsEngineBehindApp])
        #expect(finishing.newerEngineSentence != behind.newerEngineSentence)

        // The assistant's block reads the same value rather than a key of its
        // own, so a screen cannot name the state the other one is in.
        #expect(
            OnboardingBlock.requiresNewerEngine.message(newerEngine: behind.newerEngineSentence)
                == behind.newerEngineSentence
        )
        #expect(
            OnboardingBlock.requiresNewerEngine.message(newerEngine: finishing.newerEngineSentence)
                == finishing.newerEngineSentence
        )
    }

    // MARK: - Detections

    /// Detections change the verb a provider row leads with, and never add a
    /// row or a screen.
    @Test("a detected sign-in changes the verb rather than the row set")
    func detectionsChangeVerbs() async throws {
        let harness = try SettingsHarness()
        await harness.model.refreshSetupState()

        let providers = try #require(harness.model.setupState.value?.providers)
        let before = ProviderRowProjection.rows(
            providers: providers,
            detections: nil,
            signingIn: nil,
            descriptorRows: [:]
        )

        await harness.model.refreshDetections([.claudeCode, .codexCLI])
        let after = ProviderRowProjection.rows(
            providers: providers,
            detections: harness.model.detections.value,
            signingIn: nil,
            descriptorRows: [:]
        )

        #expect(before.map(\.id) == after.map(\.id), "a detection never adds or removes a row")
        // Without Claude Code on the Mac, Anthropic's door is the setup token.
        // Its `auth_modes` carry `oauth` and `auth.start` refuses it, so a row
        // that read the mode led with a `Sign in` the daemon answered `This
        // provider has no browser sign-in.` on every click.
        #expect(before.first { $0.id == "anthropic" }?.verb == .addSetupToken)
        #expect(after.first { $0.id == "anthropic" }?.verb == .importClaudeCode)
    }

    /// A sign-in in flight is the one status word no daemon field reports, so
    /// the model holds it and gives it back.
    @Test("a sign-in in flight shows as Signing in")
    func signingInStatus() async throws {
        let harness = try SettingsHarness()
        await harness.model.refreshSetupState()
        let providers = try #require(harness.model.setupState.value?.providers)

        let rows = ProviderRowProjection.rows(
            providers: providers,
            detections: nil,
            signingIn: "anthropic",
            descriptorRows: [:]
        )

        #expect(rows.first { $0.id == "anthropic" }?.status == ProductStrings[.providerStatusSigningIn])
    }

    // MARK: - The N-1 window

    /// Against a daemon one release behind, every settings surface renders the
    /// designed state rather than an error or an empty pane (M34 §7.1).
    @Test("an N-1 daemon puts every pane into the newer-engine state")
    func newerEngineState() async throws {
        let harness = try SettingsHarness(gateway: try SettingsFixture.n1Gateway())

        await harness.model.windowAppeared()

        #expect(harness.model.requiresNewerEngine)
        #expect(harness.model.inventory == .requiresNewerEngine)
        #expect(harness.model.setupState == .requiresNewerEngine)
        #expect(harness.model.sections(for: .voice).isEmpty)
    }

    // MARK: - Panes

    /// The window remembers the pane it was left on, and the first open with no
    /// record lands on Providers.
    @Test("the last pane is restored from the store and written back on change")
    func lastPaneIsRestored() throws {
        let store = FakeSettingsPaneStore(lastSettingsPane: "sandbox")
        let harness = try SettingsHarness(store: store)

        #expect(harness.model.selectedPane == .sandbox)

        harness.model.selectedPane = .voice
        #expect(store.lastSettingsPane == "voice")

        let fresh = try SettingsHarness(store: FakeSettingsPaneStore())
        #expect(fresh.model.selectedPane == .providers)
    }

    /// A pane reads the sections the daemon assigned to it, and only those.
    @Test("a pane appearing reads its own sections and nothing else")
    func paneReadsItsOwnSections() async throws {
        let harness = try SettingsHarness()
        await harness.model.loadInventory()

        await harness.model.paneAppeared(.voice)

        // The inventory fixture puts `realtime` and `transcription` under Voice
        // and `sandbox` under Sandbox.
        #expect(harness.gateway.readSections == ["realtime", "transcription"])
    }

    /// A successful apply never shows the operator the old value again: the
    /// section keeps its rows while it is re-read, and the draft holds the new
    /// value until the daemon's own has landed, so nothing blinks backwards.
    @Test("a successful apply never shows the value it just replaced")
    func applyNeverBlinksBackwards() async throws {
        let harness = try SettingsHarness()
        await harness.model.loadSection("realtime")

        let seen = ObservedReload()
        let model = harness.model
        let key = SettingsDraftKey(section: "realtime", key: "realtime_voice")
        harness.gateway.settingsGate = { @Sendable in
            await MainActor.run {
                seen.rows = model.section("realtime").value?.rows.count
                seen.draft = model.drafts[key]
            }
        }

        await harness.model.apply(section: "realtime", key: "realtime_voice", value: .text("marin"))

        #expect(seen.rows != nil, "the section kept its rows while it was re-read")
        #expect(seen.draft == .text("marin"), "the control held the new value until the daemon's landed")
        #expect(harness.model.drafts.isEmpty, "the draft is dropped once the daemon's value is in")
    }

    /// The sidebar search covers pane titles, the keywords beside them, and the
    /// labels of rows already read.
    @Test("the sidebar search matches titles, keywords and read row labels")
    func searchMatches() async throws {
        let harness = try SettingsHarness()
        await harness.model.loadInventory()

        #expect(harness.model.panes(matching: "voice", in: .capabilities) == [.voice])
        #expect(harness.model.panes(matching: "zoom", in: .capabilities) == [.meetings])
        #expect(harness.model.panes(matching: "", in: .system) == [.sandbox, .permissions])
        #expect(harness.model.panes(matching: "nothing here", in: .assistant).isEmpty)

        // A row label only matches once the pane's section has been read.
        #expect(!harness.model.rowsMatch("Talk to Fermix", in: .voice))
        await harness.model.paneAppeared(.voice)
        #expect(harness.model.rowsMatch("Talk to Fermix", in: .voice))
    }
}

/// What the window was showing at the moment the daemon was re-read. A class so
/// the gate closure can write to it from outside the test's own frame.
final class ObservedReload: @unchecked Sendable {
    var rows: Int?
    var draft: ManagementSettingValue?
}

/// The model with every seam behind a double.
@MainActor
struct SettingsHarness {
    let gateway: FakeDaemonGateway
    let model: SettingsModel

    init(
        gateway: FakeDaemonGateway? = nil,
        store: FakeSettingsPaneStore? = nil
    ) throws {
        self.gateway = try gateway ?? SettingsFixture.gateway()
        self.model = SettingsFixture.model(gateway: self.gateway, store: store)
    }
}
