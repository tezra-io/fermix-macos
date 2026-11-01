import Foundation

/// What a press of an action does (management PROTOCOL.md, *Acting on it:
/// `home.act`*): collect what the action needs, show its confirm, then send
/// one `home.act` with the action's id and key and draw the summary it
/// answers. The engine runs every step behind it; nothing here sequences a
/// call, follows a job or picks a server.
extension AlwaysOnModel {
    /// Runs one press of an action the screen offers.
    public func press(_ action: ManagementHomeAction) async {
        guard working == nil else { return }

        refusal = nil
        notice = nil
        switch action.id {
        case .learnMore, .openConsole: open(action.url)
        case .update: checkForUpdates?()
        default: await ask(action)
        }
    }

    /// Opens what the action needs, its confirm, or, with neither, sends it.
    private func ask(_ action: ManagementHomeAction) async {
        guard let ask = AlwaysOnAsk.asking(for: action) else { return await act(action, input: nil) }

        if case .token = ask, page.screen?.providers.isEmpty != false {
            log.error("\(action.id.wireValue, privacy: .public) asks for a token, and the summary lists no provider")
            refusal = ProductStrings[.daemonErrorUnexpectedShape]
            return
        }
        asking = ask
        if case .choice = ask { await readOptions() }
    }

    /// The press waiting on the owner was put down: nothing is sent.
    public func dismissAsk() {
        closeAsk()
    }

    /// The owner accepted the confirm of an action that collects nothing.
    /// The engine checks the action's key, so a confirm accepted on a
    /// screen that has since moved is answered `changed`.
    public func accept(_ action: ManagementHomeAction) async {
        guard working == nil else { return }

        closeAsk()
        await act(action, input: nil)
    }

    // MARK: - The token

    /// The provider the owner picked, where the summary lists more than one.
    public func pick(provider: ManagementHomeSummaryProvider) {
        picked = provider.id
    }

    /// Sends a pasted token for one provider. The provider is named only
    /// where the summary lists more than one; the engine takes the one there
    /// is otherwise. A refusal is the engine's sentence under the field,
    /// which stays while the summary still offers the action.
    public func submitToken(_ token: String, for provider: ManagementHomeSummaryProvider) async {
        guard case .token(let action)? = asking, working == nil else { return }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let listed = page.screen?.providers.count ?? 0
        await act(action, input: ManagementHomeActInput(token: trimmed, provider: listed > 1 ? provider.id : nil))
    }

    // MARK: - The choice

    /// What the provider in use sells, for the choice: the engine knows
    /// which one, so none is named.
    func readOptions() async {
        options = .loading
        do {
            options = .loaded(try await gateway.provisionOptions())
        } catch {
            options = .failure(error)
            settings.noteRead(error, "home.provision.options")
        }
    }

    /// Sends the size and place the owner chose, the recommendation unless
    /// changed; pressing the sheet's action is accepting its confirm.
    public func submitChoice(_ pick: ManagementProvisionPick) async {
        guard case .choice(let action)? = asking, working == nil else { return }

        await act(action, input: ManagementHomeActInput(type: pick.type, location: pick.location))
    }

    // MARK: - The recovery passphrase

    /// Sends the recovery passphrase. Where none is set it is typed twice,
    /// and two that differ send nothing: answers false, and the sheet says
    /// so. Pressing the sheet's action is accepting its confirm. The
    /// passphrase lives only in this one press.
    public func submitPassphrase(_ passphrase: String, again: String?) async -> Bool {
        guard case .passphrase(let action, let twice)? = asking, working == nil else { return false }
        guard !twice || passphrase == again else { return false }
        guard !passphrase.isEmpty else { return false }

        await act(action, input: ManagementHomeActInput(recoveryPassphrase: passphrase))
        return true
    }

    // MARK: - The one call

    /// Sends one press and draws the summary it answers. On the computer
    /// that sets Always On up, Move now's answer still reads the screen it
    /// was pressed on, since the engine restarts right after answering: the
    /// pane says it is restarting until the engine answers with a summary
    /// that moved. A linked desktop's replace answers `moving` and nothing
    /// restarts here. A refusal is the engine's sentence under the action,
    /// and the summary is read again: a press drawn on an older screen is
    /// `changed`, and a step the server took whose answer was lost is
    /// `unconfirmed`, which is no failure. A refused token keeps its field
    /// open under the sentence while the summary still offers the action;
    /// a sheet or a confirm closes.
    private func act(_ action: ManagementHomeAction, input: ManagementHomeActInput?) async {
        working = action.id
        defer { working = nil }
        do {
            let acted = try await gateway.homeAct(action.id, key: action.key, input: input)
            closeAsk()
            if case .ownServer(let code)? = acted.result { ownServer = code }
            if case .move? = acted.result, acted.summary.state != .moving { restartingFrom = acted.summary.key }
            await take(acted.summary)
        } catch {
            if asking?.isField != true { closeAsk() }
            say(error)
            settings.noteRead(error, "home.act \(action.id.wireValue)")
            await refresh()
        }
    }

    private func say(_ error: any Error) {
        let sentence = ManagementMessage.sentence(for: error)
        guard ManagementMessage.code(of: error) == .unconfirmed else {
            refusal = sentence
            return
        }
        notice = sentence
    }

    // MARK: - Pages the app opens itself

    public func forgetCode() {
        ownServer = nil
    }

    /// A page the engine gave the address of: Learn more, a provider's
    /// console or its part of the docs. A browser that could not open it is
    /// said under the action.
    public func open(_ url: URL?) {
        guard let url else {
            log.error("an action that opens a page came with no url")
            refusal = ProductStrings[.alwaysOnLinkOpenFailed]
            return
        }
        guard !settings.opener.open(url) else { return }

        refusal = ProductStrings[.alwaysOnLinkOpenFailed]
    }
}
