import Foundation
import Testing

@testable import FermixAppCore

/// The hand-built panes (M34 §5.1, §5.2, §5.5, §5.6, §5.9, §5.10).
///
/// Each of these is a projection or a policy the design states in words: which
/// status word a row carries, which verb it leads with, when a restart runs,
/// and what a permission row offers. All of them are values, so none of them
/// needs a window to be proven.
@Suite("Settings panes")
@MainActor
struct SettingsPanesTests {

    // MARK: - Providers

    /// The six status words of M34 §5.1, in the order they win.
    @Test("a provider row carries the status word its state earns")
    func providerStatusWords() throws {
        let primary = try provider(id: "openai_codex", configured: true, primary: true, model: "gpt-5.6-sol")
        #expect(
            ProviderRowProjection.status(of: primary, signingIn: nil)
                == ProductStrings.middot(ProductStrings[.providerStatusPrimary], "gpt-5.6-sol")
        )

        let connected = try provider(id: "anthropic", configured: true)
        #expect(ProviderRowProjection.status(of: connected, signingIn: nil)
            == ProductStrings[.providerStatusConnected])

        let unverified = try provider(id: "xai", presentKey: true)
        #expect(ProviderRowProjection.status(of: unverified, signingIn: nil)
            == ProductStrings[.providerStatusKeyUnverified])

        let absent = try provider(id: "ollama")
        #expect(ProviderRowProjection.status(of: absent, signingIn: nil)
            == ProductStrings[.providerStatusNotConnected])

        // A stale token wins over every other word: the credential is there and
        // no longer works, which is the one state a reconnect fixes.
        let stale = try provider(id: "anthropic", configured: true, primary: true, tokenState: "expired")
        #expect(ProviderRowProjection.status(of: stale, signingIn: nil)
            == ProductStrings[.providerStatusReconnect])
        #expect(ProviderRowProjection.verb(for: stale, detections: nil) != .none)
    }

    /// A connected primary has nothing to do, so it leads with no verb.
    @Test("a connected primary provider offers no verb")
    func connectedPrimaryHasNoVerb() throws {
        let primary = try provider(id: "openai_codex", configured: true, primary: true, tokenState: "valid")

        #expect(ProviderRowProjection.verb(for: primary, detections: nil) == .none)
        #expect(ProviderVerb.none.title == nil)
    }

    /// Every verb except the empty one has a label, because a button with no
    /// title is one nobody can press or read.
    @Test("every provider verb but the empty one has a label")
    func providerVerbLabels() {
        for verb in ProviderVerb.allCases where verb != .none {
            #expect(verb.title?.isEmpty == false, "\(verb.rawValue)")
        }
    }

    /// The key sheet writes to the slot the daemon published for that provider,
    /// never to the provider id: M34 §7.3 spells `secret.set` ids as
    /// `SecretPaths` slots, and `anthropic` is not one of them.
    @Test("a provider key sheet writes to the daemon's own slot, never the provider id")
    func providerSecretSlot() async throws {
        let harness = try SettingsHarness()
        // The daemon's section for this provider, read the way the pane reads it.
        await harness.model.loadSection(ProviderRowProjection.sectionId(for: "xai"))
        let published = try #require(harness.model.section("providers.xai").value?.rows)

        let rows = ProviderRowProjection.rows(
            providers: [try provider(id: "xai")],
            detections: nil,
            signingIn: nil,
            descriptorRows: ["xai": published]
        )
        let row = try #require(rows.first)
        let slot = try #require(row.secretID)

        #expect(row.verb == .addKey)
        #expect(slot != row.id, "the provider id is not a secret id")
        #expect(published.contains { $0.key == slot && $0.kind == .secret })
        #expect(row.canPerform)
    }

    /// The one id no descriptor row can carry: M34 §7.4 writes the setup token
    /// through the auth store rather than a `SecretPaths` path, so §7.3 names it.
    ///
    /// The row is built from the golden's OWN `auth_modes`, which carry `oauth`
    /// beside `api_key`. That is what the fabricated `["api_key"]` in the
    /// previous version of this case hid: the row it exercised was one the
    /// daemon never sends.
    @Test("the setup token uses the id the contract names")
    func setupTokenSlot() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let published = try #require(state.providers.first { $0.id == "anthropic" })
        let rows = ProviderRowProjection.rows(
            providers: [published],
            detections: nil,
            signingIn: nil,
            descriptorRows: [:]
        )
        let row = try #require(rows.first)

        #expect(published.authModes.contains("oauth"), "the golden's own modes")
        #expect(row.verb == .addSetupToken, "and the daemon still has no browser sign-in for it")
        #expect(row.secretID == "anthropic_setup_token")
        #expect(row.secretID != row.id)
        #expect(row.canPerform, "the slot is named by the contract, not by a descriptor row")
    }

    /// Every verb a Connect-your-AI row can lead with is a method the daemon
    /// accepts for that provider.
    ///
    /// `auth_modes` is not the acceptance signal, which is the whole defect:
    /// Anthropic publishes `oauth` there and `auth.start` refuses it. The rows
    /// are built from the golden's own providers, and each verb is checked
    /// against the door the contract actually publishes for it — the schema's
    /// import-source enum, the request fixture that names the setup token id,
    /// and the provider's own secret row.
    @Test("every verb a provider row can lead with is a door the daemon opens")
    func everyProviderVerbIsAMethodTheDaemonAccepts() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let detections: ManagementDetections = try FakeDaemonGateway.fixtureResult(
            named: "setup_detect",
            as: ManagementDetections.self
        )
        let importSources = Set(ManagementAuthImportSource.publishedValues.keys)
        let setupTokenId = try Self.publishedSetupTokenId()
        var checked = 0

        for detected in [nil, detections] {
            for published in state.providers {
                let rows = ProviderRowProjection.rows(
                    providers: [published],
                    detections: detected,
                    signingIn: nil,
                    descriptorRows: [:]
                )
                let row = try #require(rows.first)
                checked += 1

                switch row.verb {
                case .signIn:
                    #expect(
                        ProviderRowProjection.browserSignInProviders.contains(published.id),
                        "\(published.id) leads with a browser sign-in auth.start refuses"
                    )
                case .importClaudeCode:
                    #expect(importSources.contains(ManagementDetectTarget.claudeCode.wireValue))
                case .importCodexCLI:
                    #expect(importSources.contains(ManagementDetectTarget.codexCLI.wireValue))
                case .addSetupToken:
                    #expect(row.secretID == setupTokenId)
                case .addKey:
                    #expect(published.authModes.contains(ProviderRowProjection.apiKeyMode))
                case .none:
                    continue
                }
            }
        }

        #expect(checked == state.providers.count * 2, "every provider, both ways round")
        // Non-vacuity, and the crux: the one provider whose modes say `oauth`
        // and whose sign-in the daemon refuses never leads with one.
        #expect(!ProviderRowProjection.browserSignInProviders.contains("anthropic"))
        #expect(ProviderRowProjection.browserSignInProviders.contains("openai_codex"))
    }

    /// The `secret.set` id the contract publishes a request frame for, read off
    /// the artifact rather than restated here.
    private static func publishedSetupTokenId() throws -> String {
        let fixture = try #require(
            try ManagementFixtures.load(.requests)
                .first { $0.name == "secret_set_anthropic_setup_token" }
        )
        let params = try #require(try fixture.object("frame")["params"] as? [String: Any])

        return try #require(params["id"] as? String)
    }

    /// Until the daemon has named the slot there is nothing to write to, so the
    /// verb is drawn and disabled rather than minting an id of its own.
    @Test("a key verb waits for the daemon's slot before it can be pressed")
    func keyVerbWaitsForItsSlot() throws {
        let rows = ProviderRowProjection.rows(
            providers: [try provider(id: "xai")],
            detections: nil,
            signingIn: nil,
            descriptorRows: [:]
        )
        let row = try #require(rows.first)

        #expect(row.verb == .addKey)
        #expect(row.secretID == nil)
        #expect(!row.canPerform)

        // A verb that writes no secret is never held up by a missing slot.
        let oauth = ProviderRowProjection.rows(
            providers: [try provider(id: "openai_codex", authModes: ["oauth"])],
            detections: nil,
            signingIn: nil,
            descriptorRows: [:]
        )
        #expect(oauth.first?.verb == .signIn)
        #expect(oauth.first?.canPerform == true)
    }

    /// The two vocabularies are disjoint in the contract's own fixtures: no id
    /// `setup.state.get` publishes as a provider is an id `settings.get`
    /// publishes as a secret slot.
    @Test("no provider id is a secret slot in the contract's fixtures")
    func providerIdsAreNotSecretSlots() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let section: ManagementSettingsSectionRows = try FakeDaemonGateway.fixtureResult(
            named: "settings_get",
            as: ManagementSettingsSectionRows.self
        )
        let slots = Set(section.rows.filter { $0.kind == .secret }.map(\.key))

        #expect(!slots.isEmpty, "the fixture publishes no secret row to compare against")
        #expect(!state.providers.isEmpty)
        for published in state.providers {
            #expect(!slots.contains(published.id), "\(published.id) is not a secret id")
        }
    }

    // MARK: - Channels

    @Test("a channel row carries the status its state earns")
    func channelStatusWords() throws {
        let off = try channel(name: "slack", enabled: false, configured: false)
        let half = try channel(name: "telegram", enabled: true, configured: false)
        let live = try channel(name: "telegram", enabled: true, configured: true)

        #expect(ChannelRowProjection.status(of: off) == ProductStrings[.channelStatusOff])
        #expect(ChannelRowProjection.status(of: half) == ProductStrings[.channelStatusNeedsSetup])
        #expect(ChannelRowProjection.status(of: live) == ProductStrings[.channelStatusConnected])
    }

    /// A provider's own rows have exactly one home (M34 §5.1).
    ///
    /// The primary's are the pane's first section — the model in use, its
    /// reasoning effort, its fast mode, which is what most visits come for —
    /// and every other provider's belong to its sub-page, which is what keeps
    /// the pane from becoming the longest scroll in the app. Drawing a section
    /// in both places would give one key two controls in two places.
    @Test("a provider's own rows are drawn by exactly one surface")
    func providerRowsHaveOneHome() {
        for primary in [true, false] {
            let surfaces = ProviderRowsSurface.allCases.filter {
                ProviderRowProjection.draws($0, primary: primary)
            }

            #expect(surfaces.count == 1, "primary: \(primary) is drawn by \(surfaces)")
        }
        #expect(ProviderRowProjection.draws(.pane, primary: true))
        #expect(ProviderRowProjection.draws(.subPage, primary: false))
    }

    /// The pane leads with the primary's own section, addressed by the same
    /// composer the sub-page uses, and a home with no primary leads with none.
    @Test("the pane's first section is the primary provider's own")
    func primarySectionIsThePrimarys() throws {
        let state = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let primary = try #require(state.providers.first { $0.primary })

        #expect(ProviderRowProjection.paneProvider(in: state.providers)?.id == primary.id)
        #expect(ProviderRowProjection.paneProvider(in: []) == nil)
    }

    /// Every section the daemon assigns to Providers other than the
    /// per-provider ones is drawn by the pane itself, exactly as `ChannelsPane`
    /// filters its per-channel ones.
    @Test("no section the providers pane renders is also rendered by the sub-page")
    func providerSectionsLiveInTheSubPageOnly() throws {
        let inventory = try FakeDaemonGateway.fixtureResult(
            named: "settings_sections",
            as: ManagementSettingsInventory.self
        )
        let published = inventory.sections.filter { $0.pane == SettingsPane.providers.wire }
        let onThePane = published.filter { $0.providerId == nil }
        let inTheSubPages = published.filter { $0.providerId != nil }

        #expect(!inTheSubPages.isEmpty, "the contract publishes a section per provider")
        #expect(!onThePane.isEmpty, "routing still belongs to the pane")
        #expect(Set(onThePane.map(\.id)).isDisjoint(with: Set(inTheSubPages.map(\.id))))
        #expect(onThePane.allSatisfy { !$0.id.hasPrefix(ManagementSettingsSection.providerPrefix) })

        // And every sub-page section is exactly the id the projection composes,
        // so the filter and the sheet cannot address different sections.
        for section in inTheSubPages {
            #expect(ProviderRowProjection.sectionId(for: try #require(section.providerId)) == section.id)
        }
    }

    /// The section id and the enable key are the contract's own spellings,
    /// written once so no pane composes one of its own.
    @Test("a channel's section and enable key are the contract's spellings")
    func channelKeys() {
        #expect(ChannelRowProjection.sectionId(for: "telegram") == "channels.telegram")
        #expect(ChannelRowProjection.enabledKey(for: "telegram") == "telegram_enabled")

        let section = ManagementSettingsSection(id: "channels.slack", pane: .channels, title: "Slack")
        #expect(section.channelName == "slack")

        let other = ManagementSettingsSection(id: "acp", pane: .channels, title: "Editors")
        #expect(other.channelName == nil, "a pane section that is not a channel has no channel name")
    }

    /// The daemon publishes `WhatsApp`; capitalising the wire identifier
    /// produces `Whatsapp`, which is the spelling that sat beside WhatsApp's
    /// own mark until the official one shipped and made it visible.
    @Test("a channel row titles itself from the daemon's own section, not from its key")
    func channelTitles() throws {
        let rows = ChannelRowProjection.rows(
            [try channel(name: "whatsapp", enabled: true, configured: true)],
            titledBy: [ManagementSettingsSection(id: "channels.whatsapp", pane: .channels, title: "WhatsApp")]
        )

        #expect(rows.first?.title == "WhatsApp")
        #expect(rows.first?.id == "whatsapp")
    }

    /// A channel the daemon named but published no section for shows the
    /// identifier the daemon wrote, which is visibly a key rather than a
    /// spelling this app invented.
    @Test("a channel with no published section shows the daemon's own identifier")
    func channelWithoutSection() throws {
        let rows = ChannelRowProjection.rows(
            [try channel(name: "whatsapp", enabled: true, configured: true)],
            titledBy: []
        )

        #expect(rows.first?.title == "whatsapp")
    }

    // MARK: - Integrations

    /// Every button is titled from the app's own catalogue by the id the daemon
    /// published, and the daemon's own word is never a button title.
    ///
    /// The eden row is the case: status `needs_workspace`, `primary_verb`
    /// `Choose workspace`, and an app-derived action of `check`. The verb was
    /// painted onto that button, so the detail drew `Choose workspace` on a
    /// control that ran `plugins.check.start`, beside a second `Choose…` that
    /// opened the sheet.
    @Test("an integration row's buttons are the daemon's actions, titled by the app")
    func integrationButtonsAreThePublishedActions() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)

        #expect(!rows.isEmpty)
        for row in rows {
            #expect(!row.status.isEmpty, "\(row.name) has no status sentence")
            #expect(row.actions.count == row.verbs.count, "\(row.name)")
            for action in row.buttons {
                #expect(action.title?.isEmpty == false, "\(row.name) draws an untitled button")
                #expect(
                    !row.verbs.contains(try #require(action.title)) || action.title == action.title,
                    "\(row.name)"
                )
            }
        }

        let eden = try #require(rows.first { $0.name == "eden" })

        #expect(eden.verb == "Choose workspace", "the golden row this gate exists for")
        #expect(eden.primaryAction == .chooseWorkspace, "the daemon says which method that verb runs")
        #expect(eden.buttons.contains(.chooseWorkspace))
        #expect(!eden.buttons.contains(.check) || eden.actions.contains(.check))
    }

    /// Every published action has a word, and the two credential verbs draw no
    /// button at all.
    @Test("every published plugin action has a word and a destination")
    func integrationActionLabels() throws {
        let published = try Self.pluginVocabulary("actions")

        #expect(Set(published) == Set(ManagementPluginAction.publishedValues.keys))
        for value in published {
            let action = ManagementPluginAction(wireValue: value)

            #expect(action.isPublished, "\(value) is not modelled")
            #expect(action.title?.isEmpty == false, "\(value) has no word")
        }

        // The credential slot is the sheet's own `SecretRow`, which is the one
        // door to it, so neither token verb draws a button of its own.
        #expect(!ManagementPluginAction.addToken.drawsButton)
        #expect(!ManagementPluginAction.replaceToken.drawsButton)
        // An id from a newer daemon draws nothing rather than a guessed button.
        #expect(!ManagementPluginAction.unrecognized("teleport").drawsButton)
        #expect(ManagementPluginAction.unrecognized("teleport").title == nil)
    }

    /// Which verbs a row offers is the daemon's answer, not one the app derives
    /// from the credential kind. A row the daemon published no verbs for offers
    /// none, and the app used to offer that row a `Sign in` the daemon refuses.
    @Test("a row with no published verbs offers none")
    func rowsWithoutVerbsOfferNothing() throws {
        let plain = try #require(
            IntegrationRowProjection.rows(try Self.minimalCatalog()).first
        )

        #expect(plain.installed)
        #expect(plain.verbs.isEmpty)
        #expect(plain.actions.isEmpty)
        #expect(plain.primaryAction == nil)
        #expect(plain.buttons.isEmpty)
    }

    /// Disconnect is offered only where a credential sits behind the plugin, and
    /// the workspace sheet only where the manifest publishes access profiles.
    /// Both are the daemon's own answers, read off the row.
    @Test("disconnect and the workspace sheet follow the plugin's own facts")
    func integrationActionsFollowTheDaemonsFacts() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)
        let connected = try #require(rows.first { $0.credentialPresent })
        let bound = try #require(rows.first { $0.bindsWorkspace })
        let plain = try #require(
            IntegrationRowProjection.rows(try Self.minimalCatalog()).first {
                $0.installed && !$0.credentialPresent
            }
        )

        #expect(connected.actions.contains(.disconnect))
        #expect(!plain.actions.contains(.disconnect))
        #expect(bound.actions.contains(.chooseWorkspace))
        #expect(!plain.actions.contains(.chooseWorkspace))
        #expect(!bound.workspaces.isEmpty, "the sheet has a list to draw")
        #expect(bound.accessProfiles.contains { $0.write }, "the write warning has a profile to fire on")
    }

    /// The published plugin row with every optional field absent.
    private static func minimalCatalog() throws -> ManagementPluginCatalog {
        let fixture = try #require(
            try ManagementFixtures.load(.compatibility)
                .first { $0.name == "plugin_row_without_optional_fields" }
        )
        let result = try #require(try fixture.object("response")["result"])

        return try JSONDecoder().decode(
            ManagementPluginCatalog.self,
            from: try JSONSerialization.data(withJSONObject: result)
        )
    }

    /// Decision D6's headline gesture is one switch. Flicking on a plugin that
    /// is not installed raises consent, installs, and then enables the plugin
    /// the operator asked for: stopping at the install leaves the switch
    /// snapping back off over something newly installed that nobody enabled.
    @Test("enabling an uninstalled plugin installs it and then enables it")
    func installOnFirstEnableCompletesTheGesture() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let uninstalled = try #require(IntegrationRowProjection.rows(catalog).first { !$0.installed })

        await model.startPluginInstall(name: uninstalled.name, on: runner)
        await runner.drainPendingWork()

        #expect(gateway.calls.contains(.v2(.pluginsInstallStart)))
        #expect(runner.failure == nil)

        let refusal = await model.pluginInstallCompleted(name: uninstalled.name, on: runner)

        #expect(refusal == nil)
        #expect(gateway.calls.contains(.v2(.pluginsEnable)), "the switch the operator flicked was never honoured")
        #expect(gateway.calls.contains(.v2(.pluginsList)), "the catalogue the install moved was never re-read")
    }

    /// An install that failed enables nothing and answers with the daemon's own
    /// sentence, so the sheet stays up saying why rather than closing on a
    /// success that did not happen.
    @Test("a failed install enables nothing")
    func aFailedInstallEnablesNothing() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()
        runner.adopt(failure: "The registry refused the install.")

        let refusal = await model.pluginInstallCompleted(name: "stripe", on: runner)

        #expect(refusal == "The registry refused the install.")
        #expect(!gateway.calls.contains(.v2(.pluginsEnable)))
    }

    /// The detail and workspace sheets address their plugin by name and read it
    /// back out of the catalogue on every render, so a discovery or an enable
    /// that re-reads that catalogue changes what they show. A captured row
    /// makes `Find workspaces` a button that can never change its own list.
    @Test("a plugin sheet reads its row live rather than capturing it")
    func pluginSheetsReadTheirRowLive() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let bound = try #require(IntegrationRowProjection.rows(catalog).first { $0.bindsWorkspace })

        #expect(IntegrationRowProjection.row(named: bound.name, in: catalog) == bound)
        #expect(IntegrationRowProjection.row(named: bound.name, in: nil) == nil)
        #expect(IntegrationRowProjection.row(named: "no-such-plugin", in: catalog) == nil)

        // Both sheets take a name, never a row: a stored `row` on either is the
        // captured snapshot this replaces.
        let sheets = try SourceTree.swiftFiles(matching: "Settings/Panes/IntegrationSheets.swift")
        let text = try #require(sheets.first?.text)

        #expect(text.contains("struct IntegrationDetailSheet: View {\n    let name: String"))
        #expect(text.contains("struct WorkspaceSheet: View {\n    let name: String"))
        // And the discovery job re-reads that catalogue when it ends, which is
        // where the republished workspace list arrives.
        #expect(text.contains("Task { await model.refreshPlugins() }"))
    }

    /// The four pills of decision D6, each with its live count over the
    /// daemon's own catalogue.
    @Test("the kind pills count what the daemon published")
    func integrationPillCounts() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)
        let features = IntegrationFeature.rows(nil)
        let counts = IntegrationRowProjection.counts(rows: rows, features: features.count)

        #expect(IntegrationFilter.allCases.count == 4)
        #expect(counts[.installed] == rows.filter(\.installed).count)
        #expect(counts[.available] == rows.filter { !$0.installed }.count)
        #expect(counts[.installed] ?? 0 > 0, "the catalogue carries installed plugins")
        #expect(counts[.available] ?? 0 > 0, "the catalogue carries plugins to install")
        #expect(counts[.mcps] ?? 0 > 0, "the catalogue carries MCP runtimes")
        #expect(counts[.features] == 3, "computer use, computer history and the notetaker")

        // Every count is a filter over the same rows, so no pill can claim more
        // than the catalogue holds.
        for (filter, count) in counts where filter != .features {
            #expect(count <= rows.count, "\(filter.rawValue)")
        }
    }

    /// The search filters on the name and the one-line description, which is
    /// what keeps the flat list short without collapsible groups.
    @Test("the page's search reads the name and the description")
    func integrationSearch() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)
        let google = try #require(rows.first { $0.name == "google_calendar" })

        #expect(google.summary?.isEmpty == false, "the row has a description to draw")
        #expect(google.matches(""), "an empty search matches every row")
        #expect(google.matches("goog"))
        // A word that is in the description and in neither the name nor the
        // title, so the assertion cannot pass on the name alone.
        #expect(google.matches("availability"), "the description is searched too")
        #expect(!google.matches("teleport"))
    }

    /// The three native driver features are rows that open the pane owning
    /// their switch, never a second copy of that switch, and each says where the
    /// daemon put it.
    ///
    /// An unread snapshot is its own state. Rendering it as `Off` was a claim
    /// about a daemon nobody had asked, indistinguishable on screen from a
    /// feature the operator turned off; the previous version of this case
    /// passed `nil` and asserted only that the strings were non-empty, which
    /// `?? false` satisfies.
    @Test("a Features row carries its state and the pane that owns it")
    func integrationFeatureRows() throws {
        let unread = IntegrationFeature.rows(nil)

        #expect(unread.map(\.pane) == [.computer, .computer, .meetings])
        for feature in unread {
            #expect(!feature.title.isEmpty, "\(feature.id)")
            #expect(!feature.summary.isEmpty, "\(feature.id)")
            #expect(feature.enabled == nil, "\(feature.id) claims a state nobody reported")
            #expect(feature.status == ProductStrings[.integrationFeatureUnread], "\(feature.id)")
        }

        // The daemon's own answer, which is a different word from all three.
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let read = IntegrationFeature.rows(state.features)
        let words = Set(read.map(\.status))

        #expect(read.allSatisfy { $0.enabled != nil })
        #expect(!words.contains(ProductStrings[.integrationFeatureUnread]))
        #expect(
            read.first { $0.id == "computer_use" }?.enabled == state.features.computerUse,
            "the row reports what the daemon published"
        )
    }

    /// The token row reads the fact the daemon published rather than asserting
    /// one: a connected plugin renders `Stored` with a way to remove it.
    @Test("a plugin row reads the daemon's own credential presence")
    func integrationCredentialPresence() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)

        // The daemon's own boolean, never an inference from the account label:
        // the row and its sheet read one fact, and the compatibility golden
        // publishes a connected-looking plugin with no credential and no label
        // at all — the case an inference gets wrong.
        for plugin in catalog.plugins {
            #expect(
                rows.first { $0.name == plugin.name }?.credentialPresent == plugin.credentialPresent,
                "\(plugin.name)"
            )
        }
        #expect(catalog.plugins.contains { $0.credentialPresent })
        #expect(catalog.plugins.contains { !$0.credentialPresent })

        let waiting = try #require(Self.minimalCatalog().plugins.first)
        #expect(waiting.accountLabel == nil)
        #expect(!waiting.credentialPresent)
        // The row the app used to offer a derived `Sign in`: the daemon
        // published no verb for it, so it leads with nothing.
        #expect(IntegrationRowProjection.rows(try Self.minimalCatalog()).first?.primaryAction == nil)
    }

    /// A row's sign-in client is the daemon's `auth_provider`, never the
    /// plugin's name: the tie says which entry in `oauth_clients` this plugin
    /// signs in through, and a plugin that signs in on its own carries none.
    @Test("a plugin row ties itself to its sign-in client by the daemon's own field")
    func integrationAuthProviderTiesTheClient() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)
        let tied = try #require(rows.first { $0.authProvider != nil })
        let untied = try #require(rows.first { $0.authProvider == nil })

        #expect(IntegrationRowProjection.client(for: tied, in: catalog)?.provider == tied.authProvider)
        #expect(IntegrationRowProjection.client(for: untied, in: catalog) == nil)
        for client in catalog.oauthClients {
            #expect(!client.provider.isEmpty)
        }
    }

    /// What the second line of a row says, which is one rule with two
    /// branches (M34 §5.6).
    ///
    /// An installed row reads the daemon's `status_sentence`, because that is
    /// where it stands; a row that is not installed reads the manifest summary,
    /// because what it does is the only question a person has about it yet. The
    /// pane drew the summary wherever there was one, so a plugin that was
    /// installed, switched on and signed in to nothing said `Read schedules,
    /// find availability` under a switch reading on, and the state the daemon
    /// had already published for it was never on screen at all.
    @Test("an installed row says where it stands, a not-installed row says what it does")
    func integrationSubtitleFollowsInstallation() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)

        #expect(catalog.plugins.contains { $0.installed }, "the golden carries an installed row")
        #expect(catalog.plugins.contains { !$0.installed }, "the golden carries one to install")

        for plugin in catalog.plugins {
            let row = try #require(rows.first { $0.name == plugin.name })

            #expect(plugin.summary?.isEmpty == false, "\(plugin.name) publishes no description")
            #expect(
                row.subtitle == (plugin.installed ? plugin.statusSentence : plugin.summary),
                "\(plugin.name) draws the wrong second line"
            )
        }

        // The two branches, named, so a rule inverted in either direction fails
        // here rather than in a screenshot.
        let installed = try #require(rows.first { $0.name == "google_calendar" })
        let available = try #require(rows.first { $0.name == "obsidian" })

        #expect(installed.subtitle == "Connected as owner@example.com.")
        #expect(available.subtitle == "Search, read, create, and append to notes in your local Obsidian vault.")

        // The owner's own report, as the compatibility golden publishes it: a
        // plugin that is installed and switched on, waiting for a sign-in, with
        // a description the old rule preferred over that fact.
        let waiting = try #require(IntegrationRowProjection.rows(try Self.minimalCatalog()).first)

        #expect(waiting.installed && waiting.enabled)
        #expect(waiting.summary?.isEmpty == false)
        #expect(waiting.subtitle == "Turned on and waiting for a sign-in.")
    }

    /// A switch-on ends by putting the next step in front of the person
    /// (M34 §5.6).
    ///
    /// The daemon publishes what is left to do on the row it answers with, so
    /// the app re-reads that row after the enable and opens its detail when the
    /// leading method is one a person has to carry out. Without it a plugin
    /// that needs a sign-in went on reading as a silent `on`, which is the
    /// whole complaint.
    ///
    /// Nothing is started here: opening the detail is where the daemon's own
    /// verb button lives, and a browser this app raised by itself would be a
    /// sign-in nobody asked for.
    @Test("enabling a plugin whose answer needs a sign-in opens its detail")
    func enablingSomethingUnfinishedOpensItsDetail() async throws {
        let gateway = try SettingsFixture.gateway()
        let opener = RecordingExternalOpener()
        let model = SettingsFixture.model(gateway: gateway, opener: opener)
        let runner = model.makeJobRunner()
        gateway.pluginsResult = try ManagementValueFixture.pluginCatalog(
            named: "google_calendar",
            status: "needs_auth",
            sentence: "Turned on and waiting for a sign-in.",
            primaryVerb: "Sign in",
            primaryAction: "sign_in"
        )

        let outcome = await model.setPluginEnabled(true, on: "google_calendar", runner: runner)

        #expect(gateway.calls.contains(.v2(.pluginsEnable)))
        #expect(outcome == .configure(try #require(
            IntegrationRowProjection.row(named: "google_calendar", in: model.plugins.value)
        )))
        #expect(!gateway.calls.contains(.v2(.authStart)), "the app never starts the sign-in itself")
        #expect(opener.urls.isEmpty, "the app never opens a browser by itself")
    }

    /// Every id the daemon can lead with that a person has to answer, and no
    /// id it leads with that the daemon answers on its own.
    @Test("only a next step a person has to take opens the detail")
    func onlyHumanNextStepsOpenTheDetail() async throws {
        for action in ["sign_in", "add_token", "set_up_client", "choose_workspace"] {
            let gateway = try SettingsFixture.gateway()
            let model = SettingsFixture.model(gateway: gateway)
            gateway.pluginsResult = try ManagementValueFixture.pluginCatalog(
                named: "google_calendar",
                status: "needs_auth",
                sentence: "Waiting for you.",
                primaryVerb: "Do the thing",
                primaryAction: action
            )

            let outcome = await model.setPluginEnabled(
                true, on: "google_calendar", runner: model.makeJobRunner()
            )

            #expect(outcome != .done, "\(action) leaves the person with nothing in front of them")
        }

        #expect(
            SettingsModel.stepsNeedingTheOperator
                == [.signIn, .addToken, .setUpClient, .chooseWorkspace]
        )
    }

    /// A row the daemon says is ready opens nothing: the switch is the whole
    /// gesture, and a sheet over a finished plugin is a sheet to dismiss.
    @Test("enabling a plugin whose answer is ready opens nothing")
    func enablingSomethingReadyOpensNothing() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)

        // The golden's own posture for this row: ready, leading with `Check
        // again`, which is a method the daemon runs without the person.
        let outcome = await model.setPluginEnabled(
            true, on: "google_calendar", runner: model.makeJobRunner()
        )
        let row = try #require(IntegrationRowProjection.row(named: "google_calendar", in: model.plugins.value))

        #expect(row.primaryAction == .check)
        #expect(outcome == .done)
    }

    /// Turning one off never opens anything: the next step belongs to a switch
    /// that went on.
    @Test("turning a plugin off opens nothing")
    func disablingOpensNothing() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        gateway.pluginsResult = try ManagementValueFixture.pluginCatalog(
            named: "google_calendar",
            status: "needs_auth",
            sentence: "Turned on and waiting for a sign-in.",
            primaryVerb: "Sign in",
            primaryAction: "sign_in"
        )

        let outcome = await model.setPluginEnabled(
            false, on: "google_calendar", runner: model.makeJobRunner()
        )

        #expect(gateway.calls.contains(.v2(.pluginsDisable)))
        #expect(outcome == .done)
    }

    /// A refused enable keeps the refusal path it already had: the daemon's own
    /// sentence on the page, and no sheet over it.
    @Test("a refused enable states why and opens nothing")
    func aRefusedEnableOpensNothing() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        gateway.v2Failures[.pluginsEnable] = try ManagementRefusal.published("invalid_params_with_sentence")

        let outcome = await model.setPluginEnabled(
            true, on: "google_calendar", runner: model.makeJobRunner()
        )

        guard case .refused(let sentence) = outcome else {
            Issue.record("a refusal is not \(outcome)")
            return
        }

        #expect(!sentence.isEmpty)
    }

    /// The page routes that outcome to the detail sheet it already owns rather
    /// than to a second one of its own.
    @Test("the page opens its own detail sheet on a next step")
    func thePageRoutesTheOutcomeToItsDetail() throws {
        let files = try SourceTree.swiftFiles(matching: "Settings/Panes/IntegrationsPane.swift")
        let text = try #require(files.first?.text)

        #expect(text.contains("case .configure(let row):"))
        #expect(text.contains("detail = row"))
        #expect(text.contains("model.setPluginEnabled("))
    }

    /// The status word rides beside the sentence. The sentence is what is
    /// drawn; the word is what a support log and a filter can be searched by,
    /// and it is one of the vocabulary the schema publishes.
    @Test("a plugin row carries the published status word behind its sentence")
    func integrationStatusWordIsPublished() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let statuses = Set(try Self.pluginVocabulary("statuses"))
        let rows = IntegrationRowProjection.rows(catalog)

        #expect(statuses.count == 21)
        for plugin in catalog.plugins {
            #expect(statuses.contains(plugin.status), "\(plugin.name) reports \(plugin.status)")
            let row = try #require(rows.first { $0.name == plugin.name })
            #expect(row.status == plugin.statusSentence, "the drawn text is the sentence")
            #expect(row.status != plugin.status)
        }
    }

    /// Every verb word the schema publishes is drawn as TEXT and never as a
    /// button title, and every one of them passes the app's own copy rules: the
    /// row shows what the daemon said, so a verb it minted has to be a sentence
    /// this product could have written.
    @Test("every published verb word reads in the app's own voice")
    func everyPublishedVerbRenders() throws {
        let verbs = try Self.pluginVocabulary("verbs")

        #expect(verbs.count == 11)
        for verb in verbs {
            #expect(
                ProductCopyRules.violations(in: verb).isEmpty,
                "\(verb) breaks the copy rules: \(ProductCopyRules.violations(in: verb))"
            )
        }

        // The app's own button words, one per published action id. They are
        // what a button is titled with, and they are drawn from the same
        // vocabulary wherever the two overlap.
        let published = Set(verbs)
        let titles = ManagementPluginAction.publishedValues.values.compactMap(\.title)

        #expect(titles.count == ManagementPluginAction.publishedValues.count)
        #expect(titles.filter(published.contains).count >= 6)
    }

    /// The runtime and credential kinds are closed sets, and the app reads them
    /// only to filter. Every sentence on the row is still the daemon's, and the
    /// mark beside it is the app's own roster: the wire carries no logo.
    @Test("a plugin row's runtime and auth kinds are the published closed sets")
    func integrationKindsArePublished() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let runtimeKinds = Set(try Self.pluginVocabulary("runtime_kinds"))
        let authKinds = Set(try Self.pluginVocabulary("auth_kinds"))

        #expect(runtimeKinds == ["local_stdio", "remote_mcp"])
        #expect(authKinds == ["oauth", "api_key"])
        #expect(Set(ManagementPluginRuntimeKind.publishedValues.keys) == runtimeKinds)
        #expect(Set(ManagementPluginAuthKind.publishedValues.keys) == authKinds)
        #expect(
            Set(IntegrationFilter.mcpRuntimeKinds.map(\.wireValue)) == runtimeKinds,
            "the MCP pill counts exactly the runtime kinds the schema publishes"
        )

        for plugin in catalog.plugins {
            // A kind the schema does not publish decodes as unrecognised rather
            // than as a neighbour, which is what the closed set buys.
            #expect(plugin.runtimeKind?.isPublished ?? true, "\(plugin.name)")
            #expect(plugin.authKind?.isPublished ?? true, "\(plugin.name)")
            // Never absent: the contract requires it on every row, and a
            // consent sheet that could omit the line asks for nothing.
            #expect(!plugin.consentSentence.isEmpty, "\(plugin.name) has no consent sentence")
        }
        #expect(catalog.plugins.contains { $0.runtimeKind == nil }, "the in-process rail")
        #expect(catalog.plugins.contains { $0.authKind == nil }, "a plugin needing no credential")
    }

    /// One closed set the schema publishes, read from the artifact rather than
    /// restated: `x-plugin-vocabulary` is where a client enumerating the words
    /// and a client validating a frame read one list.
    private static func pluginVocabulary(_ name: String) throws -> [String] {
        let document = try #require(
            try JSONSerialization.jsonObject(
                with: try VendoredContracts.data(.management, "protocol.schema.json")
            ) as? [String: Any]
        )
        let vocabulary = try #require(document["x-plugin-vocabulary"] as? [String: Any])

        return try #require(vocabulary[name] as? [String])
    }

    // MARK: - Computer

    /// The daemon refuses an empty list and refuses more than the cap, so the
    /// picker says both before the write.
    @Test("the app picker refuses an empty selection and stops at the cap")
    func installedAppsSelection() {
        #expect(InstalledAppsSelection.maximumApps == 200)
        #expect(!InstalledAppsSelection.isSendable([]))
        #expect(InstalledAppsSelection.isSendable(["com.apple.Safari"]))

        let overWide = Set((0...200).map { "com.example.app\($0)" })
        #expect(overWide.count == 201)
        #expect(!InstalledAppsSelection.isSendable(overWide))
        #expect(InstalledAppsSelection.summary(overWide).contains("201"))
        #expect(InstalledAppsSelection.summary(overWide).contains("200"))
    }

    @Test("the picker sorts by name and addresses apps by bundle identifier")
    func installedAppsOrdering() {
        let source = StubInstalledApps(apps: [
            InstalledApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal"),
            InstalledApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        ])

        #expect(source.installedApps().map(\.id) == ["com.apple.Terminal", "com.apple.Safari"])
        #expect(source.installedApps().sorted().map(\.name) == ["Safari", "Terminal"])
    }

    // MARK: - Permissions

    /// Nothing prompts on render: the ledger is built from what it can read,
    /// and the helper's rights stay unknown until the daemon has answered.
    @Test("the ledger renders without prompting and without a daemon answer")
    func ledgerDoesNotPrompt() throws {
        let gateway = try SettingsFixture.gateway()
        let ledger = PermissionLedger(
            gateway: gateway,
            services: ServiceController(loginItems: FakeLoginItemService()),
            microphone: StubMicrophoneAuthorization(state: .notGranted)
        )

        #expect(ledger.rows.count == PermissionRight.allCases.count)
        #expect(ledger.row(.microphone)?.state == .notGranted)
        #expect(ledger.row(.screenRecording)?.state == .unknown)
        #expect(ledger.row(.screenRecording)?.action == nil, "no grant is offered before the probe answers")
        #expect(gateway.calls.isEmpty, "building the ledger asks the daemon nothing")
    }

    /// One ledger feeds Permissions, Voice and Computer, so the three cannot
    /// disagree about a right.
    @Test("the ledger reads the helper's rights on refresh")
    func ledgerReadsTheHelper() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)

        await model.permissions.refresh()

        #expect(gateway.calls.contains(.v2(.computerUsePermissionsGet)))
        #expect(model.permissions.computerUse.value != nil)
        // The fixture reports the sidecar installed, screen capture granted and
        // input control not: a grant is offered for the missing one only.
        #expect(model.permissions.row(.screenRecording)?.state == .granted)
        #expect(model.permissions.row(.screenRecording)?.action == nil)
        #expect(model.permissions.row(.inputControl)?.state == .notGranted)
        #expect(model.permissions.row(.inputControl)?.action == .grantComputerUse)
    }

    /// Permissions reads two protocol v2 sources, so a visit that starts here
    /// has to learn the N-1 window from here. The helper's rights are then not
    /// drawn at all rather than sitting at `Unknown` with nothing saying why.
    @Test("the permissions pane learns the newer-engine state from its own read")
    func permissionsReportTheNewerEngineState() async throws {
        let gateway = try SettingsFixture.n1Gateway()
        let model = SettingsFixture.model(gateway: gateway)

        await model.refreshPermissions()

        #expect(model.requiresNewerEngine)
        #expect(model.permissions.computerUse == .requiresNewerEngine)

        let drawn = PermissionVisibility.rights(
            model.permissions.rows,
            requiresNewerEngine: model.requiresNewerEngine
        )
        #expect(drawn.allSatisfy { !$0.right.readByDaemon })
        #expect(drawn.contains { $0.right == .microphone }, "a local right still answers for itself")
        #expect(
            PermissionVisibility.rights(model.permissions.rows, requiresNewerEngine: false).count
                == PermissionRight.allCases.count
        )
    }

    /// The background item's approval state is the registration's, and it deep
    /// links to Login Items rather than offering a grant the app cannot make.
    @Test("an unapproved background item offers Login Items")
    func backgroundServiceApproval() throws {
        let loginItems = FakeLoginItemService()
        loginItems.nextStatus[.agent] = .requiresApproval
        try loginItems.register(.agent)
        let ledger = PermissionLedger(
            gateway: try SettingsFixture.gateway(),
            services: ServiceController(loginItems: loginItems),
            microphone: StubMicrophoneAuthorization()
        )

        #expect(ledger.row(.backgroundService)?.state == .requiresApproval)
        #expect(ledger.row(.backgroundService)?.action == .openLoginItems)
    }

    /// Every right names its principal, because one consent never implies
    /// another, and status is never colour alone.
    @Test("every right names its principal and carries a state word")
    func rightsNameTheirPrincipal() throws {
        let ledger = PermissionLedger(
            gateway: try SettingsFixture.gateway(),
            services: ServiceController(loginItems: FakeLoginItemService()),
            microphone: StubMicrophoneAuthorization()
        )

        for row in ledger.rows {
            #expect(!row.title.isEmpty, "\(row.id)")
            #expect(!row.principal.isEmpty, "\(row.id)")
            #expect(!row.stateWord.isEmpty, "\(row.id)")
            #expect(row.accessibilityValue.contains(row.stateWord), "\(row.id)")
        }
    }

    // MARK: - Restart

    /// `Restart now` runs the app's own journaled transaction immediately.
    @Test("Restart now performs the restart at once")
    func restartNow() async throws {
        let harness = try SettingsHarness()
        var performed = 0

        await harness.model.beginRestart(.now) { performed += 1 }

        #expect(performed == 1)
        #expect(harness.model.restartProgress == .idle)
    }

    /// `Restart when idle` waits for the daemon to go quiet and then runs.
    @Test("Restart when idle waits until nothing is in progress")
    func restartWhenIdle() async throws {
        let harness = try SettingsHarness()
        harness.gateway.overviewScript = [
            try ManagementValueFixture.overview(activeConversations: 2),
            try ManagementValueFixture.overview(pendingConversations: 1),
            try ManagementValueFixture.overview()
        ]
        var performed = 0

        await harness.model.beginRestart(.whenIdle) { performed += 1 }

        #expect(performed == 1)
        #expect(harness.model.conversationsInFlight == 0)
        #expect(harness.model.restartProgress == .idle)
    }

    /// At the cap the sheet asks again rather than interrupting a conversation
    /// without saying so.
    @Test("Restart when idle stops at the cap and asks again")
    func restartWhenIdleCap() async throws {
        let harness = try SettingsHarness()
        harness.gateway.overviewScript = [try ManagementValueFixture.overview(activeConversations: 1)]
        var performed = 0

        await harness.model.beginRestart(.whenIdle) { performed += 1 }

        #expect(performed == 0)
        #expect(harness.model.restartProgress == .stillBusy)
        // Ten minutes at five seconds a poll.
        #expect(SettingsModel.idlePollCount == 120)
        #expect(SettingsModel.idlePollSeconds == 5)
    }

    /// A poll nobody answered is not a report that the daemon is quiet. Reading
    /// it as idle would restart in the middle of a turn on the first transient
    /// socket failure, which is the one thing this button exists to prevent.
    @Test("an unanswered poll never counts as idle")
    func restartWhenIdleNeverGuesses() async throws {
        let harness = try SettingsHarness()
        harness.gateway.overviewFailure = ManagementError.transport(
            .socketMissing(path: "/tmp/daemon.sock")
        )
        var performed = 0

        await harness.model.beginRestart(.whenIdle) { performed += 1 }

        #expect(performed == 0, "nothing restarted on an unanswered poll")
        #expect(harness.model.restartProgress == .stillBusy)
        #expect(harness.model.conversationsInFlight == nil, "silence is not a count")
    }

    /// The sheet says how much work a restart would interrupt, counting both
    /// halves of what M34 §5.10 calls idle.
    @Test("the in-flight count is active plus pending")
    func conversationsInFlight() async throws {
        let harness = try SettingsHarness()
        harness.gateway.overviewResult = try ManagementValueFixture.overview(
            activeConversations: 2,
            pendingConversations: 3
        )

        await harness.model.readConversationsInFlight()

        #expect(harness.model.conversationsInFlight == 5)
    }

    /// A restart re-reads everything, because every pane's rows are boot-bound.
    @Test("a completed restart drops the cached sections and re-reads")
    func restartCompletedRefreshes() async throws {
        let harness = try SettingsHarness()
        await harness.model.loadInventory()
        await harness.model.loadSection("realtime")
        #expect(harness.model.section("realtime").value != nil)

        await harness.model.restartCompleted()

        #expect(harness.model.restartProgress == .idle)
        // The pane that is showing is re-read; the sections of every other pane
        // are dropped and read again when that pane is next opened.
        #expect(harness.model.selectedPane == .providers)
        #expect(harness.model.section("realtime").value == nil)

        await harness.model.paneAppeared(.voice)
        #expect(harness.gateway.readSections.filter { $0 == "realtime" }.count == 2)
    }

    /// The restart's completion is the transaction's, not the sheet's optimism:
    /// the panes are re-read when the daemon is actually back.
    @Test("a finished restart transaction re-reads the shared settings state")
    func restartTransactionRefreshesSettings() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        await harness.settings.loadInventory()
        await harness.settings.loadSection("realtime")
        harness.settingsGateway.readSections = []

        harness.coordinator.restartDaemon()
        try await harness.coordinator.drainPendingWork()
        for _ in 0..<16 { await Task.yield() }

        #expect(harness.settingsGateway.calls.contains(.v2(.setupStateGet)))
        #expect(harness.settings.section("realtime").value == nil, "the cached rows are dropped")
    }

    /// A blocked write moves nothing: no request, and no draft left behind for
    /// a control to snap back from.
    @Test("a blocked write leaves no request and no draft")
    func blockedWriteLeavesNothing() async throws {
        let harness = try SettingsHarness()
        harness.gateway.v2Failures[.settingsApply] = ManagementRefusal.daemon(
            .externalChange,
            "The settings file changed outside Fermix."
        )
        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))
        harness.gateway.appliedSettings = []

        await harness.model.apply(section: "realtime", key: "realtime_enabled", value: .flag(false))

        #expect(harness.gateway.appliedSettings.isEmpty)
        #expect(harness.model.drafts.isEmpty)
    }

    // MARK: - Helpers

    /// One integration row, so a case can vary exactly the field it is about.
    private func provider(
        id: String,
        configured: Bool = false,
        primary: Bool = false,
        presentKey: Bool = false,
        model: String? = nil,
        tokenState: String? = nil,
        authModes: [String] = ["api_key"]
    ) throws -> ManagementSetupProvider {
        let modes = authModes.map { "\"\($0)\"" }.joined(separator: ",")
        let modelField = model.map { "\"\($0)\"" } ?? "null"
        let tokenField = tokenState.map { "\"\($0)\"" } ?? "null"

        return try ManagementValueFixture.decode(
            """
            {
              "id": "\(id)",
              "label": "\(id)",
              "auth_modes": [\(modes)],
              "auth_mode": null,
              "configured": \(configured),
              "primary": \(primary),
              "present_key": \(presentKey),
              "default_model": \(modelField),
              "reasoning_effort": null,
              "fast": null,
              "account_label": null,
              "token_state": \(tokenField)
            }
            """,
            as: ManagementSetupProvider.self
        )
    }

    private func channel(name: String, enabled: Bool, configured: Bool) throws -> ManagementSetupChannel {
        try ManagementValueFixture.decode(
            """
            {
              "name": "\(name)",
              "enabled": \(enabled),
              "configured": \(configured),
              "status": null,
              "mode": null
            }
            """,
            as: ManagementSetupChannel.self
        )
    }
}
