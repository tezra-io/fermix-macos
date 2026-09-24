import AppKit
import SwiftUI
import Testing

@testable import FermixAppCore

@Suite("Native authentication parity")
@MainActor
struct AuthenticationParityTests {
    @Test("connected browser providers retain a reconnect action", arguments: ["openai_codex", "xai"])
    func connectedProvidersCanReconnect(_ provider: String) {
        let doors = ProviderRowProjection.detailDoors(for: provider, detections: nil)

        #expect(doors.contains(ProviderDoor(verb: .signIn, available: true)))
    }

    /// Claude's detail always offers all of its ways in (owner directive of
    /// 2026-09-20: "for claude, the sign-in option should still be there, in
    /// addition to import token and also the api").
    ///
    /// Its sign-in is the adopted Claude Code one: `auth.start` opens no
    /// browser for Anthropic, so there is no browser door to draw and none is.
    /// That door used to vanish on a Mac with no Claude Code sign-in, which left
    /// the detail with no sign-in in it and nothing to say one existed. It
    /// stays now, unavailable until the daemon detects one. The API key is the
    /// third way in, and `detailBlocks` puts it behind the disclosure.
    @Test("Claude's detail always draws its Claude Code sign-in, ready only once it is detected")
    func claudeReplacementActions() throws {
        let detected = ProviderRowProjection.detailDoors(
            for: "anthropic", detections: try ManagementValueFixture.detections()
        )
        let undetected = ProviderRowProjection.detailDoors(for: "anthropic", detections: nil)

        #expect(detected == [
            ProviderDoor(verb: .importClaudeCode, available: true),
            ProviderDoor(verb: .addSetupToken, available: true)
        ])
        #expect(undetected == [
            ProviderDoor(verb: .importClaudeCode, available: false),
            ProviderDoor(verb: .addSetupToken, available: true)
        ])
        #expect(ProviderRowProjection.secretID(for: .addSetupToken, rows: []) == "anthropic_setup_token")
        // A button the daemon refuses on every click is the defect
        // `browserSignInProviders` records, so no browser door is invented.
        #expect(!(detected + undetected).contains { $0.verb == .signIn })
        #expect(ProviderRowProjection.detailDoors(for: "openai", detections: nil).isEmpty)
    }

    /// The other half of the rule. Beside a browser sign-in an adopted one is a
    /// shortcut, so it is drawn only when it would work: Codex always has the
    /// browser to lead with, and an unready second button there is just noise.
    @Test("a provider with a browser sign-in offers an adopted sign-in only once it is detected")
    func codexImportIsOfferedOnlyWhenDetected() throws {
        let golden = try ManagementValueFixture.detections()
        #expect(golden.result(for: .codexCLI)?.present == false, "the golden detects no Codex sign-in")

        for detections in [nil, golden] {
            let doors = ProviderRowProjection.detailDoors(for: "openai_codex", detections: detections)

            #expect(doors == [ProviderDoor(verb: .signIn, available: true)])
        }
        // Every door any provider draws is ready, except the one sign-in a Mac
        // may not have yet.
        for provider in ["openai_codex", "xai", "anthropic", "openai", "openrouter", "mistral", "ollama"] {
            for door in ProviderRowProjection.detailDoors(for: provider, detections: nil) where !door.available {
                #expect(door.verb == .importClaudeCode, "\(provider) draws \(door.verb.rawValue) unready")
            }
        }
    }

    /// The row keeps its own rule: its one verb has to work when it is clicked,
    /// so it leads with the Claude Code sign-in only once that is detected and
    /// with the setup token otherwise. The detail is where the unready door is
    /// explained; a row has nowhere to explain anything.
    @Test("a row never leads with a door its detail draws as unready")
    func rowsLeadOnlyWithDoorsThatWork() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        var checked = 0

        for detections in [nil, try ManagementValueFixture.detections()] {
            for published in state.providers {
                let verb = ProviderRowProjection.verb(for: published, detections: detections)
                let doors = ProviderRowProjection.detailDoors(for: published.id, detections: detections)
                guard let door = doors.first(where: { $0.verb == verb }) else { continue }

                checked += 1
                #expect(door.available, "\(published.id) leads with \(verb.rawValue), which is not ready")
            }
        }

        #expect(checked >= 4, "only \(checked) rows led with a sign-in door")
    }

    /// One popup, and short enough that it never scrolls (owner directive of
    /// 2026-09-20). A sheet is drawn inside the window it belongs to, so its
    /// own height has to fit the default window with the toolbar above it, for
    /// every provider the goldens publish. Measured rather than estimated: the
    /// sheet sizes to its content, so the daemon adding a row is what would
    /// move this.
    @Test("every provider's detail fits the default window without scrolling")
    func providerDetailFitsTheDefaultWindow() async throws {
        let harness = try SettingsHarness()
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        await harness.model.loadProviderSections(for: state.providers)
        // What is left of the window under its toolbar.
        let room = WindowMetrics.mainDefaultSize.height - 60

        // Twice: before the detections are read, which is a Mac with no Claude
        // Code sign-in, and after, read the way the pane reads them. The first
        // is the taller Claude, because the door that is not ready yet carries
        // a line saying what makes it ready.
        var claude: [CGFloat] = []
        for detected in [false, true] {
            if detected { await harness.model.refreshDetections([.claudeCode, .codexCLI, .existingPrimary]) }

            let rows = ProviderRowProjection.rows(
                providers: state.providers,
                detections: harness.model.detections.value,
                signingIn: nil,
                descriptorRows: harness.model.providerDescriptorRows(for: state.providers)
            )
            #expect(rows.count == state.providers.count)

            for row in rows {
                let shut = providerDetailHeight(row, keyStored: false, model: harness.model)
                // A stored key opens the key door with the sheet, which is the
                // tallest the detail gets.
                let open = providerDetailHeight(row, keyStored: true, model: harness.model)

                #expect(shut > 0, "\(row.id) measured nothing")
                #expect(open >= shut, "\(row.id)")
                #expect(open <= room, "\(row.id) needs \(open) points of a \(room)-point window")
                if row.id == "anthropic" { claude.append(open) }
            }
        }

        // Non-vacuity: both Claudes were measured, and they differ by the line.
        let doors = ProviderRowProjection.detailDoors(for: "anthropic", detections: harness.model.detections.value)
        #expect(doors.map(\.available) == [true, true], "the goldens no longer detect a Claude Code sign-in")
        #expect(claude.count == 2)
        #expect(try #require(claude.first) > (try #require(claude.last)), "the unready door drew no caption")

        let rows = ProviderRowProjection.rows(
            providers: state.providers,
            detections: harness.model.detections.value,
            signingIn: nil,
            descriptorRows: harness.model.providerDescriptorRows(for: state.providers)
        )
        // And the key door is really there to open on a provider that signs in,
        // and really absent on one that only takes a key.
        let signsIn = try #require(rows.first { $0.id == "xai" })
        let keyOnly = try #require(rows.first { $0.id == "openrouter" })
        #expect(
            providerDetailHeight(signsIn, keyStored: true, model: harness.model)
                > providerDetailHeight(signsIn, keyStored: false, model: harness.model)
        )
        #expect(
            providerDetailHeight(keyOnly, keyStored: true, model: harness.model)
                == providerDetailHeight(keyOnly, keyStored: false, model: harness.model)
        )
    }

    private func providerDetailHeight(_ row: ProviderRowModel, keyStored: Bool, model: SettingsModel) -> CGFloat {
        let measured = ProviderRowModel(
            id: row.id, label: row.label, status: row.status, verb: row.verb, primary: row.primary,
            configured: row.configured, presentKey: keyStored, secretID: row.secretID
        )
        let sheet = ProviderDetailSheet(
            row: measured, model: model, confirmPrimary: { _ in }, requestAuth: { _ in }, dismiss: {}
        )

        return NSHostingView(rootView: sheet).fittingSize.height
    }

    @Test("plugin auth completion refreshes the catalogue and clears its sign-in state")
    func pluginAuthCompletionRefreshesCatalogue() async throws {
        let harness = try SettingsHarness()
        let runner = harness.model.makeJobRunner()
        #expect(await harness.model.perform(.signIn, on: "notes", runner: runner) == nil)
        runner.dismiss()
        let completed = try ManagementValueFixture.job(kind: "auth", status: "completed", phase: nil)

        await harness.model.pluginJobFinished(completed)

        #expect(harness.gateway.calls.contains(.v2(.pluginsList)))
        #expect(harness.model.plugins.value != nil)
        #expect(harness.model.signingInProvider == nil)
        #expect(!harness.gateway.calls.contains(.v2(.authLogout)))
    }

    @Test("only terminal plugin checks refresh the catalogue")
    func pluginCheckCompletionRefreshesCatalogue() async throws {
        let harness = try SettingsHarness()
        await harness.model.pluginJobFinished(try ManagementValueFixture.job(kind: "plugin_check"))
        #expect(!harness.gateway.calls.contains(.v2(.pluginsList)))

        await harness.model.pluginJobFinished(
            try ManagementValueFixture.job(kind: "plugin_check", status: "completed", phase: nil)
        )
        #expect(harness.gateway.calls.filter { $0 == .v2(.pluginsList) }.count == 1)
    }

    /// The token editor is the credential slot of a plugin whose credential is
    /// a token, which is the daemon's `auth_kind` and nothing the app infers.
    ///
    /// This measured the detail's height, which a token row made taller. The
    /// detail is one size now, so the decision is asked directly: it is the one
    /// projection the detail switches on.
    @Test("OAuth and keyless plugin details omit the API-token editor")
    func pluginTokenEditorMatchesCredentialKind() throws {
        #expect(try Self.detail(authKind: "api_key").row.tokenSlot == .leading)
        #expect(try Self.detail(authKind: "oauth").row.tokenSlot == .none)
        #expect(try Self.detail(authKind: nil).row.tokenSlot == .none)
    }

    /// One size for every plugin and every page, so the sheet does not move as
    /// it turns from the detail to a page and back. A detail sized to its rows
    /// grew with a token row and shrank without one, which is the jump.
    @Test("the plugin detail is one size whatever it draws")
    func pluginDetailKeepsOneSize() throws {
        for authKind in ["api_key", "oauth", nil] {
            let detail = try Self.detail(authKind: authKind)
            let view = IntegrationDetailSheet(
                name: detail.row.name,
                model: detail.harness.model,
                runner: detail.harness.model.makeJobRunner(),
                dismiss: {}
            )

            #expect(NSHostingView(rootView: view).fittingSize == SheetMetrics.pickerSize, "\(authKind ?? "none")")
        }
    }

    /// The golden catalogue's first plugin, with the credential kind under
    /// test, loaded into a model the detail can read it back from.
    private static func detail(
        authKind: String?
    ) throws -> (harness: SettingsHarness, row: IntegrationRowModel) {
        let harness = try SettingsHarness()
        let fixture = try #require(try ManagementFixtures.load(.success).first { $0.name == "plugins_list" })
        var result = try #require(try fixture.object("response")["result"] as? [String: Any])
        let plugins = try #require(result["plugins"] as? [[String: Any]])
        var plugin = try #require(plugins.first)
        plugin["auth_kind"] = authKind as Any? ?? NSNull()
        result["plugins"] = [plugin]
        let catalog = try JSONDecoder().decode(
            ManagementPluginCatalog.self, from: JSONSerialization.data(withJSONObject: result)
        )
        harness.model.plugins = .loaded(catalog)

        return (harness, try #require(IntegrationRowProjection.rows(catalog).first))
    }
}
