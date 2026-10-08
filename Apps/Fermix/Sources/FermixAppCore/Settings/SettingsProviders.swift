import Foundation

/// The provider actions (M34 §5.1).
///
/// Sign-in is a browser hop: the daemon mints the authorize url once and this
/// hands it to the system browser and then follows the job. The url is never
/// logged, never persisted, and never put on the pasteboard.
extension SettingsModel {

    /// The descriptor's current selection includes an unconfirmed UI draft;
    /// the setup snapshot supplies the mode for providers with no mode picker.
    public func providerAuthMode(_ provider: String) -> String? {
        precondition(!provider.isEmpty, "an authentication mode names its provider")
        let section = ProviderRowProjection.sectionId(for: provider)
        guard let row = self.section(section).value?.rows.first(where: {
            $0.key == ProviderRowProjection.authModeKey
        }) else {
            return setupState.value?.providers.first { $0.id == provider }?.authMode
        }

        return DescriptorValue.optional(value(of: row, in: section))
    }

    /// Settings shows the credential editor for the chosen mode. The original
    /// descriptors stay intact so onboarding can still offer API-key entry.
    public func providerCredentialExclusions(_ provider: String) -> Set<String> {
        precondition(!provider.isEmpty, "credential visibility names its provider")
        guard providerAuthMode(provider) == ProviderRowProjection.oauthMode else { return [] }

        let rows = section(ProviderRowProjection.sectionId(for: provider)).value?.rows ?? []
        return Set(rows.filter { $0.kind == .secret }.map(\.key))
    }

    /// Makes this provider the one every conversation uses. The side effects
    /// come back as the daemon's own sentences, so the pane can show what
    /// changed that the operator did not type.
    public func setPrimary(_ provider: String) async -> String? {
        precondition(!provider.isEmpty, "a primary provider is named")

        guard !writesBlocked else { return ProductStrings[.settingsExternalChangeBody] }

        do {
            let result = try await gateway.setPrimaryProvider(provider)
            apply(restart: result.restart)
            sideEffects = result.sideEffects
            await refreshSetupState()
            saves.send()
            return nil
        } catch {
            noteReconcile(error)
            return ManagementMessage.sentence(for: error)
        }
    }

    /// Starts a browser sign-in and follows it. Answers the daemon's sentence
    /// where the flow could not start at all.
    ///
    /// It opens no browser: the surface that waits on the sign-in does, once it
    /// is on screen (`openSignIn(on:)`). Opened here, the browser came up
    /// first and the waiting sheet presented after it, over the browser, so a
    /// person was pulled back to Fermix before they had approved anything
    /// (owner report of 2026-10-03).
    public func startSignIn(provider: String, on runner: JobRunner) async -> String? {
        precondition(!provider.isEmpty, "a sign-in names its provider")
        guard !startingSignIn, !runner.isRunning else { return nil }

        startingSignIn = true
        defer { startingSignIn = false }

        do {
            let started = try await gateway.startAuth(provider: provider)
            signingInProvider = provider
            runner.start(
                started.job,
                authorizeURL: started.authorizeURL.flatMap(URL.init(string:)),
                expiresInMs: started.expiresInMs
            )
            note(started.job)

            return nil
        } catch {
            signingInProvider = nil
            noteReconcile(error)
            let sentence = ManagementMessage.sentence(for: error)
            runner.adopt(failure: sentence)
            return sentence
        }
    }

    /// Opens the browser for a sign-in the first time the surface waiting on it
    /// is drawn, and does nothing after: the browser is the last thing a click
    /// brings forward. One call for every such surface, the provider sign-in
    /// sheet and a plugin's wait, so none of them opens the url its own way.
    public func openSignIn(on runner: JobRunner) {
        guard let url = runner.takeUnopenedBrowserURL() else { return }

        runner.browserOpened(opener.open(url))
    }

    /// Reopens the authorization URL minted for this run without starting a job.
    public func reopenSignIn(on runner: JobRunner) {
        guard let url = runner.activeBrowserURL() else { return }

        runner.browserOpened(opener.open(url))
    }

    /// Adopts a sign-in this Mac already has. The keychain prompt this can raise
    /// waits for a person, which is why it is a job and why the row says so
    /// before the click.
    public func startAuthImport(
        source: ManagementAuthImportSource,
        provider: String,
        on runner: JobRunner
    ) async -> String? {
        precondition(!provider.isEmpty, "a credential import names its provider")
        guard !startingSignIn, !runner.isRunning else { return nil }

        startingSignIn = true
        defer { startingSignIn = false }

        do {
            let started = try await gateway.startAuthImport(source: source)
            signingInProvider = provider
            runner.start(started)
            note(started)
            return nil
        } catch {
            signingInProvider = nil
            noteReconcile(error)
            let sentence = ManagementMessage.sentence(for: error)
            runner.adopt(failure: sentence)
            return sentence
        }
    }

    /// Forgets the local session. For OpenAI Codex the daemon also revokes the
    /// ChatGPT session upstream, so Fermix is disconnected from the account and
    /// not only from this Mac; nothing else is revoked.
    public func logOut(provider: String) async -> String? {
        precondition(!provider.isEmpty, "a sign-out names its provider")

        do {
            apply(restart: try await gateway.logOut(provider: provider).restart)
            await refreshSetupState()
            return nil
        } catch {
            noteReconcile(error)
            return ManagementMessage.sentence(for: error)
        }
    }

    /// A sign-in ended, however it ended. The status word goes back to what the
    /// daemon reports rather than staying on `Signing in` forever.
    public func signInFinished() async {
        signingInProvider = nil
        await refreshSetupState()
    }

    /// Opens ChatGPT's usage settings, where a person sees what Fermix used of
    /// their plan and caps it. Answers a sentence where the browser could not
    /// open.
    public func openChatGPTUsage() -> String? {
        opener.open(ProviderRowProjection.chatGPTUsageURL) ? nil : ProductStrings[.providerSignInOpenFailed]
    }

    /// What a completed sign-in for this provider ends on: the way to ChatGPT's
    /// usage settings for OpenAI Codex, which the sign-in sheet reads as
    /// OpenAI's plan notice, and nil for every other provider, whose sheet
    /// closes when it completes.
    ///
    /// OpenAI asks that a completed ChatGPT sign-in say the plan is in use and
    /// where to manage it. One answer for both sheets that follow a sign-in, the
    /// Providers pane's and Connect your AI's, so neither decides alone which
    /// sign-ins end on it.
    public func manageUsage(after provider: String) -> (() -> String?)? {
        precondition(!provider.isEmpty, "a sign-in names its provider")
        guard provider == ProviderRowProjection.chatGPTProvider else { return nil }

        return { self.openChatGPTUsage() }
    }

    /// One page of models. A live fetch that fails answers `unavailable`; it
    /// never degrades to the catalog under a live label, so the sheet says so.
    public func models(
        provider: String,
        live: Bool,
        query: String?,
        cursor: String?
    ) async -> ModelListingOutcome {
        precondition(!provider.isEmpty, "a model listing names its provider")

        do {
            return .page(
                try await gateway.providerModels(
                    provider: provider,
                    live: live,
                    query: query,
                    cursor: cursor,
                    limit: Self.modelPageSize
                )
            )
        } catch {
            noteReconcile(error)
            return .refused(ManagementMessage.sentence(for: error))
        }
    }

    /// The published page size for a model listing. One page per scroll, so a
    /// provider with thousands of models never arrives in one frame.
    public static let modelPageSize = 50
}

/// One page of models, or the daemon's refusal.
///
/// A named pair rather than `Result`, because the failure half is the daemon's
/// own sentence and not an error this side of the socket can act on.
public enum ModelListingOutcome: Equatable, Sendable {
    case page(ManagementProviderModels)
    case refused(String)
}
