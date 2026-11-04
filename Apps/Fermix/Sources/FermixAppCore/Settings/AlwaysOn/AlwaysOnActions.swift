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
        case .learnMore: open(action.url)
        case .update: checkForUpdates?()
        default: await ask(action)
        }
    }

    /// Opens what the action needs, its confirm, or, with neither, sends it.
    private func ask(_ action: ManagementHomeAction) async {
        guard let ask = AlwaysOnAsk.asking(for: action) else { return await act(action, input: nil) }

        asking = ask
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
    /// that moved. A move back answers `moving` and nothing restarts here:
    /// it restarts this Mac's engine later, as the home is put in place, and
    /// the chat's reconnect and the notice after it read the screen then, as
    /// after any restart. A refusal is the engine's sentence under the
    /// action, and the summary is read again: a press drawn on an older
    /// screen is `changed`, and a step the server took whose answer was lost
    /// is `unconfirmed`, which is no failure. The sheet or the confirm
    /// closes either way.
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
            closeAsk()
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

    /// The page the engine gave the address of: Learn more's. A browser that
    /// could not open it is said under the action.
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
