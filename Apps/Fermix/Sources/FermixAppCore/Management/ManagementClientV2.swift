import Foundation

/// The protocol v2 calls (M34 §7.3).
///
/// Each is one line over `send`, which is where the negotiation gate, the
/// parameter ceiling and the correlation check already live. A method whose
/// minimum the negotiated version does not reach is refused here, before a byte
/// is written, with `methodRequiresNewerEngine`.
extension ManagementClient {

    // MARK: - Setup

    public func setupState() async throws -> ManagementSetupState {
        try await send(.setupStateGet, params: ManagementEmptyParams(), as: ManagementSetupState.self)
    }

    /// Probes exactly the targets named and nothing else.
    public func detect(_ targets: [ManagementDetectTarget]) async throws -> ManagementDetections {
        guard !targets.isEmpty else {
            throw ManagementError.invalidParameter(.empty(field: "targets"))
        }
        return try await send(
            .setupDetect,
            params: ManagementDetectParams(targets: targets),
            as: ManagementDetections.self
        )
    }

    // MARK: - Settings

    public func settingsSections() async throws -> ManagementSettingsInventory {
        try await send(
            .settingsSections,
            params: ManagementEmptyParams(),
            as: ManagementSettingsInventory.self
        )
    }

    public func settings(section: String) async throws -> ManagementSettingsSectionRows {
        try await send(
            .settingsGet,
            params: ManagementSectionParams(section: try requireText(section, field: "section")),
            as: ManagementSettingsSectionRows.self
        )
    }

    /// Applies changed keys only. An empty change set is refused here rather
    /// than sent, because a write with nothing to write is a caller defect.
    public func applySettings(
        section: String,
        values: [String: ManagementSettingValue]
    ) async throws -> ManagementSettingsApplied {
        guard !values.isEmpty else {
            throw ManagementError.invalidParameter(.empty(field: "values"))
        }
        return try await send(
            .settingsApply,
            params: ManagementSettingsApplyParams(
                section: try requireText(section, field: "section"),
                values: values
            ),
            as: ManagementSettingsApplied.self
        )
    }

    public func reloadSettings() async throws -> ManagementSettingsReloaded {
        try await send(
            .settingsReload,
            params: ManagementEmptyParams(),
            as: ManagementSettingsReloaded.self
        )
    }

    // MARK: - Secrets

    /// The one call whose parameters may carry a secret, one secret per call.
    public func setSecret(id: String, value: String) async throws -> ManagementSecretState {
        try await send(
            .secretSet,
            params: ManagementSecretSetParams(
                id: try requireText(id, field: "id"),
                value: try requireText(value, field: "value")
            ),
            as: ManagementSecretState.self
        )
    }

    public func clearSecret(id: String) async throws -> ManagementSecretState {
        try await send(
            .secretClear,
            params: ManagementSecretIdentifierParams(id: try requireText(id, field: "id")),
            as: ManagementSecretState.self
        )
    }

    // MARK: - Providers

    public func setPrimaryProvider(
        _ provider: String
    ) async throws -> ManagementPrimaryProviderResult {
        try await send(
            .providersSetPrimary,
            params: ManagementProviderParams(
                provider: try requireText(provider, field: "provider")
            ),
            as: ManagementPrimaryProviderResult.self
        )
    }

    public func providerModels(
        provider: String,
        live: Bool,
        query: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> ManagementProviderModels {
        if let limit, !(1...ManagementModelPage.maximumLimit).contains(limit) {
            throw ManagementError.invalidParameter(.outOfRange(field: "limit"))
        }
        return try await send(
            .providersModelsList,
            params: ManagementModelListParams(
                provider: try requireText(provider, field: "provider"),
                live: live,
                query: query,
                cursor: cursor,
                limit: limit
            ),
            as: ManagementProviderModels.self
        )
    }

    public func startProviderProbe(provider: String) async throws -> ManagementJob {
        try await send(
            .providersProbeStart,
            params: ManagementProviderParams(
                provider: try requireText(provider, field: "provider")
            ),
            as: ManagementJob.self
        )
    }

    // MARK: - Jobs

    public func job(id: String) async throws -> ManagementJob {
        try await send(
            .jobGet,
            params: ManagementJobParams(jobId: try requireText(id, field: "job_id")),
            as: ManagementJob.self
        )
    }

    public func cancelJob(id: String) async throws -> ManagementJob {
        try await send(
            .jobCancel,
            params: ManagementJobParams(jobId: try requireText(id, field: "job_id")),
            as: ManagementJob.self
        )
    }

    public func jobs() async throws -> ManagementJobList {
        try await send(.jobList, params: ManagementEmptyParams(), as: ManagementJobList.self)
    }

    // MARK: - Authentication

    public func startAuth(provider: String) async throws -> ManagementAuthStart {
        try await send(
            .authStart,
            params: ManagementProviderParams(
                provider: try requireText(provider, field: "provider")
            ),
            as: ManagementAuthStart.self
        )
    }

    public func startAuthImport(
        source: ManagementAuthImportSource
    ) async throws -> ManagementJob {
        try await send(
            .authImportStart,
            params: ManagementAuthImportParams(source: source),
            as: ManagementJob.self
        )
    }

    public func logOut(provider: String) async throws -> ManagementRestartOnly {
        try await send(
            .authLogout,
            params: ManagementProviderParams(
                provider: try requireText(provider, field: "provider")
            ),
            as: ManagementRestartOnly.self
        )
    }

    // MARK: - Plugins

    public func plugins() async throws -> ManagementPluginCatalog {
        try await send(
            .pluginsList,
            params: ManagementEmptyParams(),
            as: ManagementPluginCatalog.self
        )
    }

    public func startPluginInstall(name: String) async throws -> ManagementJob {
        try await pluginJob(.pluginsInstallStart, name: name)
    }

    public func startPluginCheck(name: String) async throws -> ManagementJob {
        try await pluginJob(.pluginsCheckStart, name: name)
    }

    public func startWorkspaceDiscovery(name: String) async throws -> ManagementJob {
        try await pluginJob(.pluginsWorkspacesDiscoverStart, name: name)
    }

    public func startWorkspaceSelection(
        name: String,
        profile: String,
        workspaceId: String,
        label: String
    ) async throws -> ManagementJob {
        try await send(
            .pluginsWorkspaceSelectStart,
            params: ManagementWorkspaceSelectParams(
                name: try requireText(name, field: "name"),
                profile: try requireText(profile, field: "profile"),
                workspaceId: try requireText(workspaceId, field: "workspace_id"),
                // No `requireText`: the schema permits an empty label, so a
                // workspace whose provider names it with nothing is a workspace
                // this client would refuse to select at all.
                label: label
            ),
            as: ManagementJob.self
        )
    }

    public func enablePlugin(name: String) async throws -> ManagementPluginRow {
        try await pluginVerb(.pluginsEnable, name: name)
    }

    public func disablePlugin(name: String) async throws -> ManagementPluginRow {
        try await pluginVerb(.pluginsDisable, name: name)
    }

    public func disconnectPlugin(name: String) async throws -> ManagementPluginRow {
        try await pluginVerb(.pluginsDisconnect, name: name)
    }

    /// Registers an OAuth client. The client secret is not a parameter here: it
    /// arrives through `secret.set` under the `oauth_client:<provider>` id.
    public func setOAuthClient(
        provider: String,
        clientId: String,
        redirectPort: Int? = nil
    ) async throws -> ManagementPluginOAuthClientRow {
        if let redirectPort, !(1...65535).contains(redirectPort) {
            throw ManagementError.invalidParameter(.outOfRange(field: "redirect_port"))
        }
        return try await send(
            .pluginsOAuthClientSet,
            params: ManagementOAuthClientParams(
                provider: try requireText(provider, field: "provider"),
                clientId: try requireText(clientId, field: "client_id"),
                redirectPort: redirectPort
            ),
            as: ManagementPluginOAuthClientRow.self
        )
    }

    public func setPluginSetting(
        name: String,
        key: String,
        value: ManagementSettingValue
    ) async throws -> ManagementPluginRow {
        try await send(
            .pluginsSettingSet,
            params: ManagementPluginSettingParams(
                name: try requireText(name, field: "name"),
                key: try requireText(key, field: "key"),
                value: value
            ),
            as: ManagementPluginRow.self
        )
    }

    // MARK: - Capabilities, meetings, computer use

    public func startCapabilityInstall(
        target: ManagementCapabilityTarget
    ) async throws -> ManagementJob {
        try await send(
            .capabilitiesInstallStart,
            params: ManagementCapabilityInstallParams(target: target),
            as: ManagementJob.self
        )
    }

    public func startMeetingsSignIn() async throws -> ManagementJob {
        try await send(
            .meetingsSigninStart,
            params: ManagementEmptyParams(),
            as: ManagementJob.self
        )
    }

    public func startComputerUseGrant() async throws -> ManagementJob {
        try await send(
            .computerUseGrantStart,
            params: ManagementEmptyParams(),
            as: ManagementJob.self
        )
    }

    public func computerUsePermissions() async throws -> ManagementComputerUsePermissions {
        try await send(
            .computerUsePermissionsGet,
            params: ManagementEmptyParams(),
            as: ManagementComputerUsePermissions.self
        )
    }

    // MARK: - The two plugin shapes

    private func pluginJob(
        _ method: ManagementMethod,
        name: String
    ) async throws -> ManagementJob {
        try await send(
            method,
            params: ManagementPluginNameParams(name: try requireText(name, field: "name")),
            as: ManagementJob.self
        )
    }

    private func pluginVerb(
        _ method: ManagementMethod,
        name: String
    ) async throws -> ManagementPluginRow {
        try await send(
            method,
            params: ManagementPluginNameParams(name: try requireText(name, field: "name")),
            as: ManagementPluginRow.self
        )
    }
}

/// The published page bounds of `providers.models.list`, so an oversized page is
/// refused before it is sent.
public enum ManagementModelPage {
    public static let maximumLimit = 200
}
