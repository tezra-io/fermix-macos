import AppKit
import SwiftUI
import Testing

@testable import FermixAppCore

@Suite("Native authentication parity")
@MainActor
struct AuthenticationParityTests {
    @Test("connected browser providers retain a reconnect action", arguments: ["openai_codex", "xai"])
    func connectedProvidersCanReconnect(_ provider: String) {
        #expect(ProviderRowProjection.detailAuthVerbs(for: provider, detections: nil).contains(.signIn))
    }

    @Test("Claude account replacement offers detected import and its setup-token slot")
    func claudeReplacementActions() throws {
        let detected = ProviderRowProjection.detailAuthVerbs(
            for: "anthropic", detections: try ManagementValueFixture.detections()
        )
        #expect(detected == [.importClaudeCode, .addSetupToken])
        #expect(ProviderRowProjection.detailAuthVerbs(for: "anthropic", detections: nil) == [.addSetupToken])
        #expect(ProviderRowProjection.secretID(for: .addSetupToken, rows: []) == "anthropic_setup_token")
        #expect(!detected.contains(.signIn))
        #expect(ProviderRowProjection.detailAuthVerbs(for: "openai", detections: nil).isEmpty)
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

    @Test("OAuth and keyless plugin details omit the API-token editor")
    func pluginTokenEditorMatchesCredentialKind() throws {
        let apiKey = try detailHeight(authKind: "api_key")
        let oauth = try detailHeight(authKind: "oauth")
        let keyless = try detailHeight(authKind: nil)

        #expect(apiKey > oauth, "the API-key detail includes its additional credential row")
        #expect(apiKey > keyless)
        #expect(abs(oauth - keyless) < 1)
    }

    private func detailHeight(authKind: String?) throws -> CGFloat {
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
        let row = try #require(catalog.plugins.first)
        let view = IntegrationDetailSheet(
            name: row.name, model: harness.model, runner: harness.model.makeJobRunner(), dismiss: {}
        )
        return NSHostingView(rootView: view).fittingSize.height
    }
}
