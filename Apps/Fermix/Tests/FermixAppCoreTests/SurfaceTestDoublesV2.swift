import Foundation
import Testing

@testable import FermixAppCore

/// The daemon double's protocol v2 half.
///
/// Every answer is decoded from the vendored contract's own golden success
/// fixtures, so a surface built on this double is built on the shapes the
/// engine publishes rather than on a Swift literal a test wrote. Two knobs
/// steer it: `v2Failure` forces a refusal, and the scripted `hello`'s window
/// decides whether the daemon can serve v2 at all.
extension FakeDaemonGateway {

    // MARK: - Setup

    func setupState() async throws -> ManagementSetupState {
        if let setupStateGate { await setupStateGate() }

        // The refusal gate and the call record still run, so a scripted answer
        // changes what the daemon said and never whether it was asked.
        let published: ManagementSetupState = try answer(.setupStateGet, "setup_state_get")

        if let providerReadiness { return try providerReadiness.setupState() }

        return setupStateResult ?? published
    }

    /// The targets are recorded because they are the call: the daemon probes
    /// what it was asked and nothing else, so a surface that asks for more than
    /// it renders is a probe nobody ordered.
    func detect(_ targets: [ManagementDetectTarget]) async throws -> ManagementDetections {
        detectedTargets.append(targets)

        return try answer(.setupDetect, "setup_detect")
    }

    // MARK: - Settings

    func settingsSections() async throws -> ManagementSettingsInventory {
        try answer(.settingsSections, "settings_sections")
    }

    /// One section's rows, from the record the contract publishes *for that
    /// section*. Answering every section with one record would let a pane pass
    /// a test while rendering rows that belong to another pane.
    func settings(section: String) async throws -> ManagementSettingsSectionRows {
        readSections.append(section)
        if let settingsGate { await settingsGate() }

        record(.v2(.settingsGet))
        if let failure = v2Failures[.settingsGet] { throw failure }
        if let v2Failure { throw v2Failure }
        try checkNegotiation(for: .settingsGet)

        if let providerSettings, providerSettings.section == section { return try providerSettings.read() }

        return try FakeDaemonGateway.fixtureResult(
            selecting: ["section": section],
            as: ManagementSettingsSectionRows.self
        )
    }

    /// One write, refused for a section the daemon does not have.
    ///
    /// The daemon answers `invalid_params {field: section}` for a section that
    /// is not in its own inventory, and this double accepted anything: so About
    /// you wrote its assistant name to an `agent` section for the whole life of
    /// the screen and every gate in the suite passed. The inventory is the
    /// contract's own `settings_sections` golden, so the next wrong id fails
    /// here rather than on a live daemon.
    func applySettings(
        section: String,
        values: [String: ManagementSettingValue]
    ) async throws -> ManagementSettingsApplied {
        appliedSettings.append(SettingsWrite(section: section, values: values))
        try FakeDaemonGateway.refuseUnpublishedSection(section)
        let published: ManagementSettingsApplied = try answer(.settingsApply, "settings_apply")
        if let providerSettings, providerSettings.section == section { try providerSettings.apply(values) }

        return settingsAppliedResult ?? published
    }

    /// The sections the contract's own inventory publishes. A write to anything
    /// else earns the daemon's own refusal.
    static func refuseUnpublishedSection(_ section: String) throws {
        let inventory: ManagementSettingsInventory = try fixtureResult(
            named: "settings_sections",
            as: ManagementSettingsInventory.self
        )
        guard !inventory.sections.contains(where: { $0.id == section }) else { return }

        throw ManagementError.daemon(
            ManagementFailure(
                code: .invalidParams,
                message: "Request parameters are invalid.",
                details: ManagementErrorDetails(values: [
                    "field": .string("section"),
                    "sentence": .string("This section is not published by this daemon.")
                ])
            )
        )
    }

    func reloadSettings() async throws -> ManagementSettingsReloaded {
        try answer(.settingsReload, "settings_reload")
    }

    // MARK: - Secrets

    func setSecret(id: String, value: String) async throws -> ManagementSecretState {
        storedSecrets.append(SecretWrite(id: id, value: value))
        // The engine's own first-provider promotion runs inside the write that
        // stores a provider key, in one snapshot rather than two.
        providerReadiness?.storedSecret(id)

        return try answer(.secretSet, "secret_set")
    }

    func clearSecret(id: String) async throws -> ManagementSecretState {
        try answer(.secretClear, "secret_clear")
    }

    // MARK: - Providers

    func setPrimaryProvider(_ provider: String) async throws -> ManagementPrimaryProviderResult {
        try answer(.providersSetPrimary, "providers_set_primary")
    }

    func providerModels(
        provider: String,
        live: Bool,
        query: String?,
        cursor: String?,
        limit: Int?
    ) async throws -> ManagementProviderModels {
        try answer(.providersModelsList, "providers_models_list")
    }

    func startProviderProbe(provider: String) async throws -> ManagementJob {
        try answer(.providersProbeStart, "providers_probe_start")
    }

    // MARK: - Jobs

    /// One poll. A scripted run is consumed in order and the last entry stands
    /// once it is exhausted, which is what a finished job actually does.
    func job(id: String) async throws -> ManagementJob {
        polledJobs.append(id)
        guard !jobScript.isEmpty else { return try answer(.jobGet, "job_get_completed") }

        record(.v2(.jobGet))
        if let failure = v2Failures[.jobGet] { throw failure }
        if let v2Failure { throw v2Failure }

        let job = jobScript[min(jobIndex, jobScript.count - 1)]
        jobIndex += 1
        if let jobGate { await jobGate() }

        return job
    }

    func cancelJob(id: String) async throws -> ManagementJob {
        try answer(.jobCancel, "job_cancel")
    }

    func jobs() async throws -> ManagementJobList {
        try answer(.jobList, "job_list")
    }

    // MARK: - Authentication

    func startAuth(provider: String) async throws -> ManagementAuthStart {
        let started: ManagementAuthStart = try answer(.authStart, "auth_start")
        if let authStartGate { await authStartGate() }
        // The job's finish is what promotes, and this double's job is already
        // complete by the time the runner polls it.
        providerReadiness?.signedIn(provider)

        return started
    }

    func startAuthImport(source: ManagementAuthImportSource) async throws -> ManagementJob {
        let started: ManagementJob = try answer(.authImportStart, "auth_import_start")
        if let authStartGate { await authStartGate() }

        return started
    }

    func logOut(provider: String) async throws -> ManagementRestartOnly {
        try answer(.authLogout, "auth_logout")
    }

    // MARK: - Plugins

    func plugins() async throws -> ManagementPluginCatalog {
        // The refusal gate and the call record still run, so a scripted answer
        // changes what the daemon said and never whether it was asked.
        let published: ManagementPluginCatalog = try answer(.pluginsList, "plugins_list")

        return pluginsResult ?? published
    }

    func startPluginInstall(name: String) async throws -> ManagementJob {
        try answer(.pluginsInstallStart, "plugins_install_start")
    }

    func startPluginCheck(name: String) async throws -> ManagementJob {
        try answer(.pluginsCheckStart, "plugins_check_start")
    }

    func startWorkspaceDiscovery(name: String) async throws -> ManagementJob {
        try answer(.pluginsWorkspacesDiscoverStart, "plugins_workspaces_discover_start")
    }

    func startWorkspaceSelection(
        name: String,
        profile: String,
        workspaceId: String,
        label: String
    ) async throws -> ManagementJob {
        try answer(.pluginsWorkspaceSelectStart, "plugins_workspace_select_start")
    }

    func enablePlugin(name: String) async throws -> ManagementPluginRow {
        try answer(.pluginsEnable, "plugins_enable")
    }

    func disablePlugin(name: String) async throws -> ManagementPluginRow {
        try answer(.pluginsDisable, "plugins_disable")
    }

    func disconnectPlugin(name: String) async throws -> ManagementPluginRow {
        try answer(.pluginsDisconnect, "plugins_disconnect")
    }

    func setOAuthClient(
        provider: String,
        clientId: String,
        redirectPort: Int?
    ) async throws -> ManagementPluginOAuthClientRow {
        try answer(.pluginsOAuthClientSet, "plugins_oauth_client_set")
    }

    func setPluginSetting(
        name: String,
        key: String,
        value: ManagementSettingValue
    ) async throws -> ManagementPluginRow {
        try answer(.pluginsSettingSet, "plugins_setting_set")
    }

    // MARK: - Capabilities, meetings, computer use

    func startCapabilityInstall(
        target: ManagementCapabilityTarget
    ) async throws -> ManagementJob {
        try answer(.capabilitiesInstallStart, "capabilities_install_start")
    }

    func startMeetingsSignIn() async throws -> ManagementJob {
        try answer(.meetingsSigninStart, "meetings_signin_start")
    }

    func startComputerUseGrant() async throws -> ManagementJob {
        try answer(.computerUseGrantStart, "computer_use_grant_start")
    }

    func computerUsePermissions() async throws -> ManagementComputerUsePermissions {
        try answer(.computerUsePermissionsGet, "computer_use_permissions_get")
    }

    // MARK: - One answer

    /// Record the call, apply the version gate, then decode the named fixture.
    private func answer<Value: Decodable>(
        _ method: ManagementMethod,
        _ fixture: String
    ) throws -> Value {
        record(.v2(method))
        if let failure = v2Failures[method] { throw failure }
        if let v2Failure { throw v2Failure }
        try checkNegotiation(for: method)

        return try FakeDaemonGateway.fixtureResult(named: fixture, as: Value.self)
    }

    /// The double's version gate: the one ladder the live client runs, applied
    /// to the scripted `hello`, so the two cannot disagree about what an N-1
    /// daemon serves.
    private func checkNegotiation(for method: ManagementMethod) throws {
        _ = try ManagementNegotiation.negotiate(
            method: method,
            contract: try ManagementContract.vendored(),
            daemon: try negotiatedRange()
        )
    }

    static func fixtureResult<Value: Decodable>(
        named name: String,
        as type: Value.Type
    ) throws -> Value {
        let fixtures = try ManagementFixtures.load(.success, from: .management)
        guard let record = fixtures.first(where: { $0.name == name }),
              let result = try record.object("response")["result"] else {
            throw Defect.fixtureMissing(method: name)
        }

        return try JSONDecoder().decode(
            Value.self,
            from: try JSONSerialization.data(withJSONObject: result)
        )
    }

    /// The record the contract publishes for one set of request params.
    ///
    /// The same `selector` the app's fixture home reads, so the double and the
    /// debug launch answer one section identically.
    static func fixtureResult<Value: Decodable>(
        selecting selector: [String: String],
        as type: Value.Type
    ) throws -> Value {
        let fixtures = try ManagementFixtures.load(.success, from: .management)
        let matching = try fixtures.first { fixture in
            // The app's own rule, called rather than restated, so the double
            // and the debug launch answer one section identically.
            FixtureManagementTransport.selector(
                method: try fixture.string("method"),
                result: try fixture.object("response")["result"] as Any
            ) == selector
        }
        guard let record = matching, let result = try record.object("response")["result"] else {
            throw Defect.fixtureMissing(method: selector.description)
        }

        return try JSONDecoder().decode(
            Value.self,
            from: try JSONSerialization.data(withJSONObject: result)
        )
    }
}


/// One `settings.apply` payload, as the surface sent it.
struct SettingsWrite: Equatable {
    let section: String
    let values: [String: ManagementSettingValue]
}

/// One `secret.set` payload. Recorded so a test can prove a blank is never sent
/// and that the value reached exactly one method.
struct SecretWrite: Equatable {
    let id: String
    let value: String
}

/// Building the daemon's own refusals, so a surface's refusal path is driven by
/// the shapes the contract publishes rather than by a bare `Error`.
enum ManagementRefusal {
    static func daemon(_ code: ManagementErrorCode, _ message: String) -> ManagementError {
        .daemon(
            ManagementFailure(
                code: code,
                message: message,
                details: ManagementErrorDetails(values: [:])
            )
        )
    }

    /// The refusal the contract publishes under one error name, verbatim.
    ///
    /// A fake that puts its sentence in `message` proves the fake's own shape.
    /// The daemon keeps `message` fixed per code and puts the sentence that says
    /// what happened in `details.sentence`, so a case about what an operator
    /// reads has to be driven by the published record.
    static func published(_ name: String) throws -> ManagementError {
        let fixture = try #require(
            try ManagementFixtures.load(.errors, from: .management).first { $0.name == name }
        )
        let error = try #require(try fixture.object("response")["error"] as? [String: Any])

        return .daemon(
            try JSONDecoder().decode(
                ManagementFailure.self,
                from: try JSONSerialization.data(withJSONObject: error)
            )
        )
    }
}


/// A daemon whose provider readiness is derived rather than declared.
///
/// The gate the engine actually applies is "is the PRIMARY provider
/// configured", and `PrimaryConfig` defaults to `openai` when nothing has been
/// chosen — so on a fresh home a successful sign-in for some other provider
/// left the gate standing and Continue went on refusing. The engine now runs
/// one first-provider promotion on both doors; this models that, so a test can
/// assert the block clears from the daemon's own next answer rather than from a
/// result the test swapped in.
final class FakeProviderReadiness: @unchecked Sendable {
    private let lock = NSLock()
    /// The provider the daemon would call primary, and whether it is usable.
    private var primary: String?
    private var configured = false
    /// The secret id each provider's key is stored under, as `settings.get`
    /// publishes it. Only what a case needs.
    private let secretSlots: [String: String]

    init(secretSlots: [String: String] = ["anthropic": "anthropic_api_key"]) {
        self.secretSlots = secretSlots
    }

    /// The provider the daemon reports as primary, or nil on a fresh home.
    var primaryProvider: String? { lock.withLock { primary } }

    /// A browser sign-in finished. The engine promotes the first configured
    /// provider, so a home with no primary gets this one.
    func signedIn(_ provider: String) {
        lock.withLock {
            guard primary == nil else { return }

            primary = provider
            configured = true
        }
    }

    /// A provider key was stored, which is the other door onto the same
    /// promotion.
    func storedSecret(_ id: String) {
        guard let provider = secretSlots.first(where: { $0.value == id })?.key else { return }

        signedIn(provider)
    }

    /// The daemon's answer, with the gate derived from the two facts above.
    func setupState() throws -> ManagementSetupState {
        let (chosen, usable) = lock.withLock { (primary, configured) }
        let gate = chosen ?? "openai"
        let failures = usable
            ? ""
            : """
              {
                "component": "provider",
                "gating": true,
                "pane": "providers",
                "detail_key": "provider:missing_credentials:\(gate)"
              }
              """

        return try ManagementValueFixture.decode(
            """
            {
              "readiness": {
                "status": "\(usable ? "ready" : "setup_required")",
                "failures": [\(failures)]
              },
              "restart": {"required": false, "reasons": []},
              "providers": [
                {
                  "id": "anthropic",
                  "label": "Anthropic",
                  "auth_modes": ["api_key", "oauth"],
                  "auth_mode": "api_key",
                  "configured": \(usable && chosen == "anthropic"),
                  "primary": \(chosen == "anthropic"),
                  "present_key": \(usable && chosen == "anthropic"),
                  "default_model": null,
                  "reasoning_effort": null,
                  "fast": null,
                  "account_label": null,
                  "token_state": null
                },
                {
                  "id": "openai_codex",
                  "label": "OpenAI Codex (ChatGPT)",
                  "auth_modes": ["oauth"],
                  "auth_mode": "oauth",
                  "configured": \(usable && chosen == "openai_codex"),
                  "primary": \(chosen == "openai_codex"),
                  "present_key": false,
                  "default_model": null,
                  "reasoning_effort": null,
                  "fast": null,
                  "account_label": null,
                  "token_state": \(usable && chosen == "openai_codex" ? "\"valid\"" : "null")
                }
              ],
              "channels": [],
              "personalization": {
                "present": {"user_name": true, "timezone": true, "communication_style": true}
              },
              "features": {
                "voice": false,
                "voice_notes": false,
                "meetings": false,
                "computer_use": false,
                "computer_history": {"enabled": false, "installed": false, "ready": false}
              },
              "profile": "general",
              "coexistence": {
                "legacy_service_unit": {"present": false, "scope": null, "path": null},
                "config_state": "clear",
                "secret_acl_restricted": {"present": null, "keys": []}
              }
            }
            """,
            as: ManagementSetupState.self
        )
    }
}
