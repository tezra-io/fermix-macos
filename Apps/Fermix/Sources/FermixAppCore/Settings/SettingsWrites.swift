import Foundation

/// Every write the Settings surfaces make (M34 §5, §7.6).
///
/// Three rules hold for all of them. A payload carries the changed keys only.
/// Every apply is optimistic in the control and confirmed by the daemon, and a
/// refusal reverts the control and shows the daemon's sentence under the row.
/// Nothing is written at all while `config_state` stands at `external_change`:
/// the daemon refuses it, and so does this, because a control that is allowed
/// to move and then snaps back reads as a bug rather than as a refusal.
extension SettingsModel {

    // MARK: - Settings

    /// Writes one row. The value is already in the control: this confirms it,
    /// or puts it back.
    @discardableResult
    public func apply(
        section: String,
        key: String,
        value: ManagementSettingValue
    ) async -> Bool {
        await apply(section: section, changes: [key: value])
    }

    /// Writes the changed keys of one section. Unchanged rows are never sent,
    /// which is what keeps a save from re-submitting a value nobody touched.
    @discardableResult
    public func apply(section: String, changes: [String: ManagementSettingValue]) async -> Bool {
        precondition(!section.isEmpty, "a write names its section")
        guard !changes.isEmpty else { return true }
        let keys = changes.keys.map { SettingsDraftKey(section: section, key: $0) }

        guard !writesBlocked else {
            // Nothing moves: a control that is allowed to move and then snaps
            // back reads as a bug rather than as the refusal the banner above
            // it is already explaining.
            log.log("refusing a write while the settings file has changed outside Fermix")
            for key in keys {
                setMessage(ProductStrings[.settingsExternalChangeBody], for: key)
            }
            return false
        }

        for key in keys {
            setDraft(changes[key.key], for: key)
            setMessage(nil, for: key)
        }
        sideEffects = []

        do {
            let result = try await gateway.applySettings(section: section, values: changes)
            apply(restart: result.restart)
            sideEffects = result.sideEffects
            // The draft is dropped only once the daemon's own value has landed.
            // Dropping it first would show the stale value for the length of the
            // re-read, so every control would blink back before moving forward.
            await loadSection(section)
            clearDrafts(keys)
            await refreshSetupState()
            return true
        } catch {
            refuse(error, keys)
            return false
        }
    }

    /// The changed half of a section's drafts, against the values the daemon
    /// last published. This is what a pane commits when it commits at all.
    public func changedValues(in section: String) -> [String: ManagementSettingValue] {
        guard let rows = self.section(section).value?.rows else { return [:] }

        var changes: [String: ManagementSettingValue] = [:]
        for row in rows {
            let key = SettingsDraftKey(section: section, key: row.key)
            guard let draft = drafts[key], draft != row.value else { continue }

            changes[row.key] = draft
        }

        return changes
    }

    // MARK: - Secrets

    /// Stores one secret. The value crosses the socket in this one method and
    /// nowhere else, and a blank is never sent: the caller's sheet refuses it
    /// before this is reached.
    ///
    /// Answers the daemon's sentence on a refusal and nil on success, because
    /// the sheet stays open on a refusal so the operator can try again without
    /// retyping.
    public func setSecret(id: String, value: String) async -> String? {
        precondition(!id.isEmpty, "a secret is written by id")
        precondition(!value.isEmpty, "a blank secret is never sent")

        guard !writesBlocked else { return ProductStrings[.settingsExternalChangeBody] }

        do {
            let result = try await gateway.setSecret(id: id, value: value)
            apply(restart: result.restart)
            await reloadSurfacesHolding(secret: id)
            return nil
        } catch {
            return refusal(error)
        }
    }

    /// Forgets one secret. The keychain item goes first and the reference after,
    /// which is the daemon's order; the app only reports what it answered.
    public func clearSecret(id: String) async -> String? {
        precondition(!id.isEmpty, "a secret is cleared by id")

        guard !writesBlocked else { return ProductStrings[.settingsExternalChangeBody] }

        do {
            let result = try await gateway.clearSecret(id: id)
            apply(restart: result.restart)
            await reloadSurfacesHolding(secret: id)
            return nil
        } catch {
            return refusal(error)
        }
    }

    // MARK: - The external-change gate

    /// Re-reads the settings file the daemon refused to write over, which is
    /// also where the daemon re-records its own baseline. The write after this
    /// succeeds; without the re-record the refusal would stand until a restart.
    ///
    /// Answers the daemon's sentence on a refusal and nil on success.
    @discardableResult
    public func reloadFromDisk() async -> String? {
        do {
            let result = try await gateway.reloadSettings()
            apply(restart: result.restart)
            configState = result.configState
            sections.removeAll()
            await refreshSetupState()
            await paneAppeared(selectedPane)
            return nil
        } catch {
            let sentence = refusal(error)
            log.error("settings reload refused: \(sentence, privacy: .public)")
            return sentence
        }
    }

    // MARK: - Restart

    /// Reads how much work a restart would interrupt, before asking.
    ///
    /// Active plus pending, because M34 §5.10 calls the daemon idle only when
    /// both are zero, and a sheet that counted one of them would say a restart
    /// interrupts nothing while the other still holds a turn.
    public func readConversationsInFlight() async {
        do {
            let main = try await gateway.overview().agents.main
            conversationsInFlight = main.activeConversations + main.pendingConversations
        } catch {
            // Nothing answered, so nothing is claimed: the sheet drops the
            // count line rather than asserting a restart is free, and the idle
            // wait keeps waiting rather than reading silence as quiet.
            log.error(
                "conversations in flight unknown: \(ManagementMessage.sentence(for: error), privacy: .public)"
            )
            conversationsInFlight = nil
        }
    }

    /// Runs the restart the sheet asked for.
    ///
    /// This model owns *when*, never *how*: the restart itself is the app's
    /// journaled lifecycle transaction, which the caller performs.
    public func beginRestart(_ mode: RestartMode, perform: @escaping () -> Void) async {
        switch mode {
        case .now:
            restartProgress = .idle
            perform()
        case .whenIdle:
            restartProgress = .waitingForIdle
            guard await waitForIdle() else {
                restartProgress = .stillBusy
                return
            }

            restartProgress = .idle
            perform()
        }
    }

    public func cancelRestartWait() {
        restartProgress = .idle
    }

    /// Polls until nothing is in flight, to the published cap. Answers whether
    /// the daemon went idle inside it: at the cap the sheet asks again rather
    /// than interrupting a conversation without saying so.
    ///
    /// Only a poll that answered zero is idle. A poll nobody answered keeps the
    /// wait going and ends at the cap, because a transient socket failure is not
    /// a report that the daemon is quiet.
    private func waitForIdle() async -> Bool {
        for _ in 0..<Self.idlePollCount {
            await readConversationsInFlight()
            if conversationsInFlight == 0 { return true }

            do {
                try await sleeper.sleep(seconds: Self.idlePollSeconds)
            } catch {
                return false
            }
        }

        return false
    }

    /// The ten-minute cap of M34 §5.10, as a bounded number of polls.
    static let idlePollSeconds: TimeInterval = 5
    static let idlePollCount = 120

    // MARK: - Refusals

    /// Puts every control back where the daemon last had it and shows why.
    private func refuse(_ error: any Error, _ keys: [SettingsDraftKey]) {
        let sentence = refusal(error)
        revert(keys)
        for key in keys {
            setMessage(sentence, for: key)
        }
        log.error("settings write refused: \(sentence, privacy: .public)")
    }

    /// The daemon's own sentence, plus the two states a refusal can put the
    /// window into: the external-change banner, and the N-1 engine state.
    private func refusal(_ error: any Error) -> String {
        if ManagementMessage.code(of: error) == .externalChange {
            configState = .externalChange
        }
        let sentence = ManagementMessage.sentence(for: error)
        if ManagementMessage.code(of: error) == .configUnreadable {
            configState = .configUnreadable
            // The parser's own words, which `setup.state.get` does not carry.
            configSentence = sentence
        }
        noteReconcile(error)

        return sentence
    }

    private func revert(_ keys: [SettingsDraftKey]) {
        for key in keys {
            setDraft(nil, for: key)
        }
    }

    private func clearDrafts(_ keys: [SettingsDraftKey]) {
        for key in keys {
            setDraft(nil, for: key)
            setMessage(nil, for: key)
        }
    }

    /// Re-reads every surface that reports whether this secret is there, so
    /// `Stored` and `Add…` follow the write rather than the sheet's own
    /// optimism.
    ///
    /// One resolver, because there are three answers to "which surface holds
    /// this secret" and a secret written into the wrong one of them looked
    /// exactly like a write that did nothing: a descriptor row publishes it as a
    /// `secret` row, and the two prefixed families — a plugin's own token and a
    /// sign-in client's secret — are published on `plugins.list` instead, where
    /// no section re-read can reach them.
    private func reloadSurfacesHolding(secret id: String) async {
        for section in sectionsHolding(secret: id) {
            await loadSection(section)
        }

        if Self.isPluginSecret(id) {
            await refreshPlugins()
        }

        await refreshSetupState()
    }

    /// Whether this id belongs to the plugin catalogue rather than to a
    /// descriptor section. Both prefixes are the contract's own (M34 §7.3).
    static func isPluginSecret(_ id: String) -> Bool {
        id.hasPrefix(SettingsModel.pluginAuthPrefix)
            || id.hasPrefix(SettingsModel.oauthClientSecretPrefix)
    }

    private func sectionsHolding(secret id: String) -> [String] {
        sections.compactMap { entry in
            guard let rows = entry.value.value?.rows else { return nil }

            return rows.contains { $0.kind == .secret && $0.key == id } ? entry.key : nil
        }
    }
}
