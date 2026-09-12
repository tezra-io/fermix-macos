import Foundation

@testable import FermixAppCore

/// Every call the client can make, with the arguments the golden request frames
/// carry.
///
/// One table, two readers: the fixture suite replays it to prove each call emits
/// the frame the contract publishes, and the negotiation suite replays it to
/// prove the version gate covers the whole catalog rather than one method
/// somebody remembered. A method added without an entry fails the coverage
/// assertion in the first, so the second cannot silently shrink.
///
/// It is the only such table. The client suite read a second copy of the v1
/// half while a second schema shipped; one schema means one table.
enum ManagementV2Calls {
    /// The golden requests this client makes no call for, for either schema.
    ///
    /// `setup.session.create` stays in the schema for the daemon's own browser
    /// door and has no app caller since the hosted Setup pane was deleted
    /// (M34 §8). It is declared rather than dropped, so a method that loses its
    /// caller by accident still fails the coverage assertion.
    static let unexercised: Set<String> = ["setup_session_create"]

    /// Each golden request, mapped to the call that must produce it.
    static let byFixture: [String: @Sendable (ManagementClient) async throws -> Void] = [
        "hello": { _ = try await $0.hello() },
        "hello_without_params": { _ = try await $0.hello() },
        "overview_get": { _ = try await $0.overview() },
        "doctor_start_default_scope": { _ = try await $0.startDoctor() },
        "doctor_start_network_scope": { _ = try await $0.startDoctor(scope: .network) },
        "doctor_get": { _ = try await $0.doctorSession(id: "doctor:9Fj2mQ7bT1xK") },
        "doctor_cancel": { _ = try await $0.cancelDoctorSession(id: "doctor:9Fj2mQ7bT1xK") },
        "logs_query_default_tail": { _ = try await $0.queryLogs(ManagementLogsQuery()) },
        "logs_query_filtered": {
            _ = try await $0.queryLogs(
                ManagementLogsQuery(
                    limit: 50,
                    level: .warning,
                    subsystem: "realtime",
                    search: "socket",
                    direction: .backward
                )
            )
        },
        "logs_query_next_page": {
            _ = try await $0.queryLogs(
                ManagementLogsQuery(
                    limit: 200,
                    direction: .backward,
                    cursor: "eyJhbmNob3IiOjIwMCwiZmluZ2VycHJpbnQiOjExODgxMjkxM30"
                )
            )
        },
        "lifecycle_prepare": { _ = try await $0.prepareLifecycle() },
        "lifecycle_commit": { _ = try await $0.commitLifecycle(leaseId: "lease_Qm5xR2t7Vd9pLk3A") },
        "lifecycle_cancel": { _ = try await $0.cancelLifecycle(leaseId: "lease_Qm5xR2t7Vd9pLk3A") },
        "diagnostics_build": { _ = try await $0.buildDiagnostics() },

        "setup_state_get": { _ = try await $0.setupState() },
        "setup_detect": {
            _ = try await $0.detect([
                .existingPrimary, .claudeCode, .codexCLI, .ollama, .harnessVendors, .meetbot
            ])
        },
        "settings_sections": { _ = try await $0.settingsSections() },
        // The Voice pane's section is `realtime`. `voice` is the pane slug the
        // route and the sidebar carry, and the daemon refuses it as a section.
        "settings_get": { _ = try await $0.settings(section: "realtime") },
        "settings_apply": {
            _ = try await $0.applySettings(
                section: "realtime",
                values: ["realtime_enabled": .flag(true)]
            )
        },
        "settings_apply_list_value": {
            _ = try await $0.applySettings(
                section: "sandbox",
                values: ["sandbox_env_allow": .list(["HOME", "PATH"])]
            )
        },
        "settings_reload": { _ = try await $0.reloadSettings() },
        "secret_set": {
            _ = try await $0.setSecret(id: "openai_api_key", value: "sk-fixture-not-a-real-key")
        },
        // The fourth secret family. It is a different mechanism behind the same
        // method (the auth store, not the keychain), which is exactly why the
        // contract publishes its own request and its own answer for it.
        "secret_set_anthropic_setup_token": {
            _ = try await $0.setSecret(
                id: "anthropic_setup_token",
                value: "sk-ant-oat-fixture-not-a-real-token"
            )
        },
        "secret_clear": { _ = try await $0.clearSecret(id: "openai_api_key") },
        "providers_set_primary": { _ = try await $0.setPrimaryProvider("anthropic") },
        "providers_models_list": {
            _ = try await $0.providerModels(
                provider: "anthropic",
                live: false,
                query: "opus",
                limit: 50
            )
        },
        "providers_probe_start": { _ = try await $0.startProviderProbe(provider: "anthropic") },
        "job_get": { _ = try await $0.job(id: "job:2Kd9mQ") },
        "job_cancel": { _ = try await $0.cancelJob(id: "job:2Kd9mQ") },
        "job_list": { _ = try await $0.jobs() },
        "auth_start": { _ = try await $0.startAuth(provider: "openai_codex") },
        "auth_import_start": { _ = try await $0.startAuthImport(source: .claudeCode) },
        "auth_logout": { _ = try await $0.logOut(provider: "xai") },
        "plugins_list": { _ = try await $0.plugins() },
        "plugins_install_start": { _ = try await $0.startPluginInstall(name: "notion") },
        "plugins_check_start": { _ = try await $0.startPluginCheck(name: "gmail") },
        "plugins_workspaces_discover_start": {
            _ = try await $0.startWorkspaceDiscovery(name: "eden")
        },
        "plugins_workspace_select_start": {
            _ = try await $0.startWorkspaceSelection(
                name: "eden",
                profile: "retrieval",
                workspaceId: "ws_studio",
                label: "Studio"
            )
        },
        "plugins_enable": { _ = try await $0.enablePlugin(name: "gmail") },
        "plugins_disable": { _ = try await $0.disablePlugin(name: "gmail") },
        "plugins_disconnect": { _ = try await $0.disconnectPlugin(name: "gmail") },
        "plugins_oauth_client_set": {
            _ = try await $0.setOAuthClient(
                provider: "google",
                clientId: "1042.apps.googleusercontent.com",
                redirectPort: 1455
            )
        },
        "plugins_setting_set": {
            _ = try await $0.setPluginSetting(
                name: "obsidian",
                key: "OBSIDIAN_VAULT_PATH",
                value: .text("/Users/owner/Vault")
            )
        },
        "capabilities_install_start": {
            _ = try await $0.startCapabilityInstall(target: .computerUseSidecar)
        },
        "meetings_signin_start": { _ = try await $0.startMeetingsSignIn() },
        "computer_use_grant_start": { _ = try await $0.startComputerUseGrant() },
        "computer_use_permissions_get": { _ = try await $0.computerUsePermissions() }
    ]

}
