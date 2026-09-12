import Foundation

/// The gateway's protocol v2 calls.
///
/// Each negotiates once, exactly as the v1 calls do, and then delegates. The
/// per-method version gate lives in the client, so a surface that asks for a
/// v2-only method against an N-1 daemon gets `methodRequiresNewerEngine` here
/// without a byte leaving the socket.
extension ManagementGateway {

    // MARK: - Setup

    public func setupState() async throws -> ManagementSetupState {
        try await negotiated().setupState()
    }

    public func detect(_ targets: [ManagementDetectTarget]) async throws -> ManagementDetections {
        try await negotiated().detect(targets)
    }

    // MARK: - Settings

    public func settingsSections() async throws -> ManagementSettingsInventory {
        try await negotiated().settingsSections()
    }

    public func settings(section: String) async throws -> ManagementSettingsSectionRows {
        try await negotiated().settings(section: section)
    }

    public func applySettings(
        section: String,
        values: [String: ManagementSettingValue]
    ) async throws -> ManagementSettingsApplied {
        try await negotiated().applySettings(section: section, values: values)
    }

    public func reloadSettings() async throws -> ManagementSettingsReloaded {
        try await negotiated().reloadSettings()
    }

    // MARK: - Secrets

    public func setSecret(id: String, value: String) async throws -> ManagementSecretState {
        try await negotiated().setSecret(id: id, value: value)
    }

    public func clearSecret(id: String) async throws -> ManagementSecretState {
        try await negotiated().clearSecret(id: id)
    }

    // MARK: - Providers

    public func setPrimaryProvider(
        _ provider: String
    ) async throws -> ManagementPrimaryProviderResult {
        try await negotiated().setPrimaryProvider(provider)
    }

    public func providerModels(
        provider: String,
        live: Bool,
        query: String?,
        cursor: String?,
        limit: Int?
    ) async throws -> ManagementProviderModels {
        try await negotiated().providerModels(
            provider: provider,
            live: live,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }

    public func startProviderProbe(provider: String) async throws -> ManagementJob {
        try await negotiated().startProviderProbe(provider: provider)
    }

    // MARK: - Jobs

    public func job(id: String) async throws -> ManagementJob {
        try await negotiated().job(id: id)
    }

    public func cancelJob(id: String) async throws -> ManagementJob {
        try await negotiated().cancelJob(id: id)
    }

    public func jobs() async throws -> ManagementJobList {
        try await negotiated().jobs()
    }

    // MARK: - Authentication

    public func startAuth(provider: String) async throws -> ManagementAuthStart {
        try await negotiated().startAuth(provider: provider)
    }

    public func startAuthImport(
        source: ManagementAuthImportSource
    ) async throws -> ManagementJob {
        try await negotiated().startAuthImport(source: source)
    }

    public func logOut(provider: String) async throws -> ManagementRestartOnly {
        try await negotiated().logOut(provider: provider)
    }

    // MARK: - Plugins

    public func plugins() async throws -> ManagementPluginCatalog {
        try await negotiated().plugins()
    }

    public func startPluginInstall(name: String) async throws -> ManagementJob {
        try await negotiated().startPluginInstall(name: name)
    }

    public func startPluginCheck(name: String) async throws -> ManagementJob {
        try await negotiated().startPluginCheck(name: name)
    }

    public func startWorkspaceDiscovery(name: String) async throws -> ManagementJob {
        try await negotiated().startWorkspaceDiscovery(name: name)
    }

    public func startWorkspaceSelection(
        name: String,
        profile: String,
        workspaceId: String,
        label: String
    ) async throws -> ManagementJob {
        try await negotiated().startWorkspaceSelection(
            name: name,
            profile: profile,
            workspaceId: workspaceId,
            label: label
        )
    }

    public func enablePlugin(name: String) async throws -> ManagementPluginRow {
        try await negotiated().enablePlugin(name: name)
    }

    public func disablePlugin(name: String) async throws -> ManagementPluginRow {
        try await negotiated().disablePlugin(name: name)
    }

    public func disconnectPlugin(name: String) async throws -> ManagementPluginRow {
        try await negotiated().disconnectPlugin(name: name)
    }

    public func setOAuthClient(
        provider: String,
        clientId: String,
        redirectPort: Int?
    ) async throws -> ManagementPluginOAuthClientRow {
        try await negotiated().setOAuthClient(
            provider: provider,
            clientId: clientId,
            redirectPort: redirectPort
        )
    }

    public func setPluginSetting(
        name: String,
        key: String,
        value: ManagementSettingValue
    ) async throws -> ManagementPluginRow {
        try await negotiated().setPluginSetting(name: name, key: key, value: value)
    }

    // MARK: - Capabilities, meetings, computer use

    public func startCapabilityInstall(
        target: ManagementCapabilityTarget
    ) async throws -> ManagementJob {
        try await negotiated().startCapabilityInstall(target: target)
    }

    public func startMeetingsSignIn() async throws -> ManagementJob {
        try await negotiated().startMeetingsSignIn()
    }

    public func startComputerUseGrant() async throws -> ManagementJob {
        try await negotiated().startComputerUseGrant()
    }

    public func computerUsePermissions() async throws -> ManagementComputerUsePermissions {
        try await negotiated().computerUsePermissions()
    }
}
