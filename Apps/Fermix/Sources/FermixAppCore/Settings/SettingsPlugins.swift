import Foundation

/// The plugin actions (M34 §5.6).
///
/// Every word on an integration row is the daemon's. What lives here is which
/// method each action calls, which is a property of the app's own flows and not
/// of the registry's vocabulary.
extension SettingsModel {

    public func refreshPlugins() async {
        plugins = .loading
        do {
            plugins = .loaded(try await gateway.plugins())
            noteServed()
        } catch {
            plugins = .failure(error)
            noteReconcile(error)
        }
    }

    /// Auth and checks publish new connection facts when their jobs end.
    public func pluginJobFinished(_ job: ManagementJob) async {
        guard job.status.isTerminal, job.kind == .auth || job.kind == .pluginCheck else { return }

        if job.kind == .auth { await signInFinished() }
        await refreshPlugins()
    }

    /// Runs one integration action, addressed by the id the daemon published.
    ///
    /// Answers the daemon's sentence on a refusal and nil on success; the
    /// install and the checks are jobs, and the rest are calls that answer with
    /// the row.
    public func perform(
        _ action: ManagementPluginAction,
        on name: String,
        runner: JobRunner
    ) async -> String? {
        precondition(!name.isEmpty, "an integration action names its plugin")
        precondition(
            !action.isAnsweredBySheet,
            "\(action.wireValue) is answered by a sheet, never performed"
        )

        switch action {
        case .install:
            await startPluginInstall(name: name, on: runner)
            return runner.failure
        case .check:
            await startPluginCheck(name: name, on: runner)
            return runner.failure
        case .enable:
            return await write { try await self.gateway.enablePlugin(name: name) }
        case .disable:
            return await write { try await self.gateway.disablePlugin(name: name) }
        case .disconnect:
            return await write { try await self.gateway.disconnectPlugin(name: name) }
        case .signIn:
            return await startPluginSignIn(name: name, runner: runner)
        case .addToken, .replaceToken, .setUpClient, .chooseWorkspace:
            preconditionFailure("\(action.wireValue) is answered by a sheet, never performed")
        // A row from a newer daemon can carry an id this build has no method
        // for. Nothing draws a button for it, so reaching this is a defect at
        // the call site rather than a button that quietly does nothing.
        case .unrecognized(let value):
            preconditionFailure("\(value) is not a plugin action this build performs")
        }
    }

    /// What a switch-on left behind (M34 §5.6).
    ///
    /// Three answers, because there are three things the page does next: state
    /// the daemon's refusal, put the row's own next step in front of the
    /// person, or nothing at all.
    public enum IntegrationEnableOutcome: Equatable {
        case refused(String)
        case configure(IntegrationRowModel)
        case done
    }

    /// The leading methods a person has to carry out themselves.
    ///
    /// The daemon publishes what a row leads with; these four are the ids whose
    /// method is a door the operator has to walk through, so the row's detail —
    /// where the daemon's own verb button lives — is opened on them. Every
    /// other id is either something the daemon does on its own (`check`) or
    /// something the switch just did (`enable`, `install`), and a sheet over
    /// one of those is a sheet to dismiss.
    public static let stepsNeedingTheOperator: Set<ManagementPluginAction> = [
        .signIn, .addToken, .setUpClient, .chooseWorkspace
    ]

    /// The row's switch, both ways, and what the page does after it.
    ///
    /// Enabling something is not the same as finishing it: the daemon publishes
    /// the state it is left in, and an installed plugin with nothing configured
    /// read as a plain `on` for as long as nobody looked at that field. So the
    /// answer is re-read here, and a next step that needs the operator opens
    /// the row's detail rather than being left for them to find.
    ///
    /// Nothing is started: opening the detail is where the daemon's own verb
    /// button lives, and a sign-in this app raised by itself would be a browser
    /// window nobody asked for.
    public func setPluginEnabled(
        _ isOn: Bool,
        on name: String,
        runner: JobRunner
    ) async -> IntegrationEnableOutcome {
        precondition(!name.isEmpty, "an integration switch names its plugin")

        if let sentence = await perform(isOn ? .enable : .disable, on: name, runner: runner) {
            return .refused(sentence)
        }
        guard isOn else { return .done }

        return nextStep(after: name)
    }

    /// What the daemon's own answer says is left to do on one row, once its
    /// switch is on.
    ///
    /// Read from the catalogue the enable re-read rather than from the row the
    /// switch was drawn from: the row that went in is the state before the
    /// write, and this is the state after it.
    public func nextStep(after name: String) -> IntegrationEnableOutcome {
        precondition(!name.isEmpty, "a next step names its plugin")

        guard let row = IntegrationRowProjection.row(named: name, in: plugins.value),
              let action = row.primaryAction,
              Self.stepsNeedingTheOperator.contains(action)
        else { return .done }

        return .configure(row)
    }

    /// The install the consent sheet started has ended.
    ///
    /// Enabling something not yet installed is one gesture, so this finishes
    /// it: a run that worked is followed by the enable the switch asked for. A
    /// refusal answers with the daemon's own sentence and enables nothing —
    /// either way the catalogue is re-read, because the install moved it.
    public func pluginInstallCompleted(name: String, on runner: JobRunner) async -> String? {
        precondition(!name.isEmpty, "an install completion names its plugin")

        guard runner.failure == nil else {
            await refreshPlugins()
            return runner.failure
        }

        return await perform(.enable, on: name, runner: runner)
    }

    public func startWorkspaceDiscovery(name: String, on runner: JobRunner) async {
        precondition(!name.isEmpty, "a workspace discovery names its plugin")

        do {
            let job = try await gateway.startWorkspaceDiscovery(name: name)
            runner.start(job)
            note(job)
        } catch {
            runner.adopt(failure: ManagementMessage.sentence(for: error))
            noteReconcile(error)
        }
    }

    /// Binds one plugin to one workspace under one access profile.
    ///
    /// The daemon republishes the binding on the plugin row, so the catalogue is
    /// re-read once the job is started: the row's workspace label is the
    /// daemon's answer and never the label this sheet happened to send.
    public func startWorkspaceSelection(
        name: String,
        profile: String,
        workspace: ManagementPluginWorkspace,
        on runner: JobRunner
    ) async -> String? {
        precondition(!name.isEmpty, "a workspace selection names its plugin")
        precondition(!profile.isEmpty, "a workspace selection names its access profile")

        guard !writesBlocked else { return ProductStrings[.settingsExternalChangeBody] }

        do {
            let job = try await gateway.startWorkspaceSelection(
                name: name,
                profile: profile,
                workspaceId: workspace.id,
                label: workspace.label
            )
            runner.start(job)
            note(job)
            await refreshPlugins()
            return nil
        } catch {
            noteReconcile(error)
            return ManagementMessage.sentence(for: error)
        }
    }

    /// Writes one plugin setting. The value is the descriptor's, so this is the
    /// same optimistic-then-confirmed shape every other write has.
    public func setPluginSetting(
        name: String,
        key: String,
        value: ManagementSettingValue
    ) async -> String? {
        precondition(!name.isEmpty, "a plugin setting names its plugin")
        precondition(!key.isEmpty, "a plugin setting names its key")

        return await write { try await self.gateway.setPluginSetting(name: name, key: key, value: value) }
    }

    public func setOAuthClient(
        provider: String,
        clientId: String,
        redirectPort: Int?
    ) async -> String? {
        precondition(!provider.isEmpty, "an OAuth client names its provider")
        precondition(!clientId.isEmpty, "an OAuth client needs its identifier")

        guard !writesBlocked else { return ProductStrings[.settingsExternalChangeBody] }

        do {
            _ = try await gateway.setOAuthClient(
                provider: provider,
                clientId: clientId,
                redirectPort: redirectPort
            )
            await refreshPlugins()
            return nil
        } catch {
            noteReconcile(error)
            return ManagementMessage.sentence(for: error)
        }
    }

    /// A plugin's own sign-in, which is the same browser hop a provider takes.
    private func startPluginSignIn(name: String, runner: JobRunner) async -> String? {
        await startSignIn(provider: "\(Self.pluginAuthPrefix)\(name)", on: runner)
    }

    /// The `auth.start` provider spelling for a plugin, which M34 §7.3
    /// publishes as `plugin:<name>`. The same prefix is the `secret.set` id
    /// family for a plugin's own token, which is why it is written once.
    public static let pluginAuthPrefix = "plugin:"

    /// The `secret.set` id family for a sign-in client's own secret, which
    /// M34 §7.3 publishes as `oauth_client:<provider>`.
    public static let oauthClientSecretPrefix = "oauth_client:"

    public static func pluginSecretId(_ name: String) -> String {
        precondition(!name.isEmpty, "a plugin secret is addressed by plugin name")

        return pluginAuthPrefix + name
    }

    /// One plugin write, with the external-change gate every write passes.
    private func write(_ call: @escaping () async throws -> ManagementPluginRow) async -> String? {
        guard !writesBlocked else { return ProductStrings[.settingsExternalChangeBody] }

        do {
            _ = try await call()
            await refreshPlugins()
            return nil
        } catch {
            noteReconcile(error)
            return ManagementMessage.sentence(for: error)
        }
    }
}
