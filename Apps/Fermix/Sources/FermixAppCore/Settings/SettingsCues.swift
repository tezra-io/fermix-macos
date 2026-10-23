import Foundation

/// The `cue_source:<ref>:<field>` secret family (M60 app surface §3.5): what
/// the owner types for a source, one value per `secret.set`.
public enum CueSecretId {
    public static let prefix = "cue_source:"

    public static func id(ref: String, field: ManagementCueSecretField) -> String {
        precondition(!ref.isEmpty, "a source secret names its source")
        precondition(field.isTyped, "Fermix makes \(field.wireValue); the owner never stores it")

        return "\(prefix)\(ref):\(field.wireValue)"
    }

    /// The source an id stores a value for, or nil for every other family.
    public static func ref(of id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }

        let rest = id.dropFirst(prefix.count)
        guard let colon = rest.lastIndex(of: ":"), colon != rest.startIndex else { return nil }

        return String(rest[..<colon])
    }
}

/// A refusal the daemon gave a cue write, with the form field it names where
/// it named one: the value's key, or `ref` or `name`. The form marks that
/// field rather than raising an alert.
public struct CueRefusal: Equatable, Sendable, Error {
    public let sentence: String
    public let field: String?

    public init(sentence: String, field: String?) {
        precondition(!sentence.isEmpty, "a refusal states why")
        self.sentence = sentence
        self.field = field
    }
}

/// One secret typed into the add form, stored once the source exists.
public struct CueTypedSecret: Equatable, Sendable {
    public let field: ManagementCueSecretField
    public let value: String

    public init(field: ManagementCueSecretField, value: String) {
        precondition(field.isTyped, "only a typed secret is stored")
        precondition(!value.isEmpty, "a blank secret is never sent")
        self.field = field
        self.value = value
    }
}

/// What an add left behind.
public enum CueSourceAddOutcome: Equatable, Sendable {
    /// The daemon refused the add, so nothing was written.
    case refused(CueRefusal)
    /// The source exists. `token` is a new local push source's first token,
    /// handed out once, for the view to show and forget. A typed secret that
    /// could not be stored is the store's refusal, under its field.
    case added(ref: String, token: String?, unstored: CueRefusal?)
}

/// The default filter model's two keys, which the daemon takes together
/// only (M60 app surface §4.6): "Pick a provider and a model, or clear
/// both."
public enum CueFilterPair {
    public static let section = "cues"
    public static let providerKey = "filter_provider"
    public static let modelKey = "filter_model"

    /// The write as the daemon takes it. A model is sent with the provider
    /// in force; clearing the provider clears the model with it. Every other
    /// write passes through unchanged.
    public static func completing(
        _ changes: [String: ManagementSettingValue],
        in section: String,
        rows: [ManagementSettingRow]
    ) -> [String: ManagementSettingValue] {
        guard section == Self.section else { return changes }

        var paired = changes
        if changes[modelKey] != nil, changes[providerKey] == nil,
           let provider = rows.first(where: { $0.key == providerKey }) {
            paired[providerKey] = provider.value
        }
        if changes[providerKey] == .text(""), changes[modelKey] == nil {
            paired[modelKey] = .text("")
        }

        return paired
    }
}

/// Cues in Settings (M60 app surface §4): which method each control calls,
/// in which order. Every word on a cue row is the daemon's; what lives here
/// is the reads, the writes, and the one gate that decides whether the pane
/// is drawn at all.
extension SettingsModel {

    // MARK: - Whether the pane is drawn

    /// The pane is drawn only where the daemon publishes the `cues` section,
    /// lists `cues.status` in its `hello`, and says cues are part of this
    /// build. With any of the three missing there is no pane, no row and no
    /// notice: cues are optional (§4.1).
    public var drawsCuesPane: Bool {
        servedMethods.contains(.cuesStatus)
            && !sections(for: .cues).isEmpty
            && cueStatus.value?.available == true
    }

    /// Whether a route to this pane lands on Providers instead: Cues, on a
    /// daemon this window has read and found without the method, the section
    /// or cues in its build. Where none of that has been read yet, the gate
    /// read the window makes as it appears decides (`refreshCueGate`), which
    /// falls back the same way, so a link opened at launch is not refused on
    /// a guess.
    public func refusesRoute(to pane: SettingsPane) -> Bool {
        guard pane == .cues else { return false }

        if !servedMethods.isEmpty, !servedMethods.contains(.cuesStatus) { return true }
        if inventory.value != nil, sections(for: .cues).isEmpty { return true }
        return cueStatus.value?.available == false
    }

    /// Reads what the gate needs: the methods `hello` lists, then, where both
    /// the method and the section are there, `cues.status`. A restored
    /// selection of a pane the daemon does not draw goes back to the first
    /// pane, so the window never opens on nothing.
    public func refreshCueGate() async {
        do {
            publish(try await gateway.servedMethods(), to: \.servedMethods)
        } catch {
            noteRead(error, "hello methods")
            return
        }

        if servedMethods.contains(.cuesStatus), !sections(for: .cues).isEmpty {
            await refreshCueStatus()
        }
        if selectedPane == .cues, !drawsCuesPane {
            selectedPane = .providers
        }
    }

    // MARK: - Reads

    /// Everything the pane shows below its switches: the status, the three
    /// lists and the proposals waiting. Each is its own read, so one the
    /// daemon refuses (watchers with memory off) leaves the others drawn.
    public func refreshCues() async {
        await refreshCueStatus()
        await refreshCueSources()
        await refreshCueWatchers()
        await refreshCueMandates()
        await refreshCueProposals()
    }

    public func refreshCueStatus() async {
        await read(\.cueStatus, "cues.status") { try await self.gateway.cuesStatus() }
    }

    public func refreshCueSources() async {
        await read(\.cueSources, "cues.sources.list") { try await self.gateway.cueSources() }
    }

    public func refreshCueWatchers() async {
        await read(\.cueWatchers, "cues.watchers.list") { try await self.gateway.cueWatchers() }
    }

    public func refreshCueMandates() async {
        await read(\.cueMandates, "cues.mandates.list") { try await self.gateway.cueMandates() }
    }

    /// The proposals waiting for the owner, which "Waiting for you" lists.
    public func refreshCueProposals() async {
        await read(\.cueProposals, "cues.proposals.list") { try await self.gateway.cueProposals(.waiting) }
    }

    public func refreshCueMandateChoices() async {
        await read(\.cueMandateChoices, "cues.mandates.choices") { try await self.gateway.cueMandateChoices() }
    }

    /// One source's detail: its fields, its gaps and its refused requests.
    public func readCueSource(_ ref: String) async {
        precondition(!ref.isEmpty, "a source is read by name")

        if cueSourceDetails[ref]?.value == nil { publish(.loading, to: \.cueSourceDetails[ref]) }
        do {
            let detail = try await gateway.cueSource(ref: ref)
            publish(.loaded(detail), to: \.cueSourceDetails[ref])
            keep(detail.source)
        } catch {
            publish(.failure(error), to: \.cueSourceDetails[ref])
            noteRead(error, "cues.sources.get")
        }
    }

    /// One watcher's purpose and instructions, the owner's own words.
    public func readCueWatcher(_ name: String) async {
        precondition(!name.isEmpty, "a watcher is read by name")

        if cueWatcherDetails[name]?.value == nil { publish(.loading, to: \.cueWatcherDetails[name]) }
        do {
            publish(.loaded(try await gateway.cueWatcher(name: name).watcher), to: \.cueWatcherDetails[name])
        } catch {
            publish(.failure(error), to: \.cueWatcherDetails[name])
            noteRead(error, "cues.watchers.get")
        }
    }

    /// The add form for one choice, after a short pause, so a run of changes
    /// to the kind, the preset and the check asks once. A request superseded
    /// while it waits is cancelled by its caller and asks nothing.
    public func cueSourceForm(
        _ request: ManagementCueFormRequest,
        pause: TimeInterval
    ) async -> Result<ManagementCueSourceForm, CueRefusal>? {
        do {
            try await sleeper.sleep(seconds: pause)
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        do {
            return .success(try await gateway.cueSourceForm(request))
        } catch {
            noteReconcile(error)
            let field = ManagementMessage.details(of: error)?.field
            return .failure(CueRefusal(sentence: ManagementMessage.sentence(for: error), field: field))
        }
    }

    public func cueSource(_ ref: String) -> ManagementCueSource? {
        cueSources.value?.sources.first { $0.ref == ref }
    }

    public func cueMandate(_ name: String) -> ManagementCueMandate? {
        cueMandates.value?.mandates.first { $0.name == name }
    }

    public func cueWatcher(_ name: String) -> ManagementCueWatcher? {
        cueWatchers.value?.watchers.first { $0.name == name }
    }

    /// Opens Chat, at a proposal's card where one is named. The composition
    /// hands the way over (`openChat`).
    public func showChat(at proposalId: String?) {
        guard let openChat else { preconditionFailure("the composition hands Settings the way to Chat") }

        openChat(proposalId)
    }

    // MARK: - The default filter model

    /// The provider the daemon has in force for the default filter model,
    /// empty for none.
    public var savedFilterProvider: String {
        let row = section(CueFilterPair.section).value?.rows.first { $0.key == CueFilterPair.providerKey }
        return row.map { DescriptorValue.text($0.value) } ?? ""
    }

    /// Shows a provider just chosen in its pop-up while its model is picked.
    /// Nothing is written until the model is.
    public func holdFilterProvider(_ provider: String) {
        precondition(!provider.isEmpty, "None is written, never held")
        setDraft(.text(provider), for: filterProviderKey)
    }

    /// The model listing closed: the pop-up shows the daemon's provider again.
    public func dropFilterProviderDraft() {
        setDraft(nil, for: filterProviderKey)
    }

    /// None: both keys cleared in one `settings.apply`.
    public func clearFilterModel() async {
        await apply(section: CueFilterPair.section, changes: [CueFilterPair.providerKey: .text("")])
    }

    /// Writes the pair in one `settings.apply`.
    public func applyFilterModel(provider: String, model chosen: String) async {
        precondition(!provider.isEmpty && !chosen.isEmpty, "a filter model names its provider and its model")

        await apply(
            section: CueFilterPair.section,
            changes: [CueFilterPair.providerKey: .text(provider), CueFilterPair.modelKey: .text(chosen)]
        )
    }

    private var filterProviderKey: SettingsDraftKey {
        SettingsDraftKey(section: CueFilterPair.section, key: CueFilterPair.providerKey)
    }

    // MARK: - Source writes

    /// Adds a source, then stores each secret typed for it, one `secret.set`
    /// each, stopping at the first refusal. The list is read again either
    /// way, so a source left waiting for its secret says so in the daemon's
    /// words.
    public func addCueSource(_ spec: ManagementCueSourceSpec, secrets: [CueTypedSecret]) async -> CueSourceAddOutcome {
        let added: ManagementCueSourceAdded
        switch await cueWrite({ try await self.gateway.addCueSource(spec) }) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let answer): added = answer
        }

        let unstored = await store(secrets, ref: spec.ref)
        await refreshCueSources()
        await refreshCueStatus()
        return .added(ref: spec.ref, token: added.token, unstored: unstored)
    }

    /// Changes the fields named, then reads the source's detail again.
    public func updateCueSource(_ ref: String, values: [String: ManagementCueValue]) async -> CueRefusal? {
        guard !values.isEmpty else { return nil }

        switch await cueWrite({ try await self.gateway.updateCueSource(ref: ref, values: values) }) {
        case .failure(let refusal):
            return refusal
        case .success(let answer):
            keep(answer.source)
            await readCueSource(ref)
            return nil
        }
    }

    /// Removes a source. Answers the daemon's refusal, or the sentences for
    /// any secret it could not delete, which the pane says once.
    public func removeCueSource(_ ref: String) async -> Result<[String], CueRefusal> {
        let answer = await cueWrite { try await self.gateway.removeCueSource(ref: ref) }
        guard case .success(let removed) = answer else { return answer.map(\.left) }

        publish(.unread, to: \.cueSourceDetails[ref])
        await refreshCueSources()
        await refreshCueWatchers()
        await refreshCueStatus()
        return .success(removed.left)
    }

    /// The source's switch, both ways.
    public func setCueSourceEnabled(_ isOn: Bool, ref: String) async -> CueRefusal? {
        let answer = await cueWrite {
            isOn ? try await self.gateway.enableCueSource(ref: ref) : try await self.gateway.disableCueSource(ref: ref)
        }
        switch answer {
        case .failure(let refusal):
            return refusal
        case .success(let row):
            keep(row.source)
            await refreshCueStatus()
            return nil
        }
    }

    /// A fresh token for a local push source, handed out once for the view
    /// to show and forget. Never kept here.
    public func newCueSourceToken(_ ref: String) async -> Result<String, CueRefusal> {
        let answer = await cueWrite { try await self.gateway.newCueSourceToken(ref: ref) }
        if case .success = answer { await readCueSource(ref) }

        return answer.map(\.token)
    }

    /// A webhook's address, asked on every press and never kept: the view
    /// copies its path and forgets it.
    public func cueSourceAddress(_ ref: String) async -> Result<ManagementCueSourceAddress, CueRefusal> {
        let answer = await cueWrite { try await self.gateway.cueSourceAddress(ref: ref) }
        if case .success = answer, cueSource(ref)?.hasURL == false { await refreshCueSources() }

        return answer
    }

    // MARK: - Mandate writes

    public func addCueMandate(_ name: String, values: [String: ManagementCueValue]) async -> CueRefusal? {
        switch await cueWrite({ try await self.gateway.addCueMandate(name: name, values: values) }) {
        case .failure(let refusal):
            return refusal
        case .success:
            await refreshCueMandates()
            await refreshCueStatus()
            return nil
        }
    }

    public func updateCueMandate(_ name: String, values: [String: ManagementCueValue]) async -> CueRefusal? {
        guard !values.isEmpty else { return nil }

        return await mandateWrite { try await self.gateway.updateCueMandate(name: name, values: values) }
    }

    public func setCueMandateEnabled(_ isOn: Bool, name: String) async -> CueRefusal? {
        await mandateWrite {
            isOn ? try await self.gateway.enableCueMandate(name: name) : try await self.gateway.disableCueMandate(name: name)
        }
    }

    public func approveCueMandate(_ name: String) async -> CueRefusal? {
        await mandateWrite { try await self.gateway.approveCueMandate(name: name) }
    }

    public func removeCueMandate(_ name: String) async -> CueRefusal? {
        switch await cueWrite({ try await self.gateway.removeCueMandate(name: name) }) {
        case .failure(let refusal):
            return refusal
        case .success:
            await refreshCueMandates()
            await refreshCueStatus()
            return nil
        }
    }

    // MARK: - One write

    /// Stores each typed secret in the form's order, stopping at the first
    /// refusal, which names the field it was typed in.
    private func store(_ secrets: [CueTypedSecret], ref: String) async -> CueRefusal? {
        for secret in secrets {
            if let sentence = await setSecret(id: CueSecretId.id(ref: ref, field: secret.field), value: secret.value) {
                return CueRefusal(sentence: sentence, field: secret.field.wireValue)
            }
        }

        return nil
    }

    private func mandateWrite(
        _ request: @escaping () async throws -> ManagementCueMandateAnswer
    ) async -> CueRefusal? {
        switch await cueWrite(request) {
        case .failure(let refusal):
            return refusal
        case .success(let answer):
            keep(answer.mandate)
            await refreshCueStatus()
            return nil
        }
    }

    /// One cue write, with the external-change gate every write passes. A
    /// refusal is the daemon's sentence and the field its `details.field`
    /// names.
    private func cueWrite<Answer: Sendable>(
        _ request: @escaping () async throws -> Answer
    ) async -> Result<Answer, CueRefusal> {
        guard !writesBlocked else {
            return .failure(CueRefusal(sentence: ProductStrings[.settingsExternalChangeBody], field: nil))
        }

        do {
            return .success(try await request())
        } catch {
            let field = ManagementMessage.details(of: error)?.field
            return .failure(CueRefusal(sentence: refusal(error), field: field))
        }
    }

    /// One cue read, by the rule every read follows: a value on screen stays
    /// while it is read again, and a refusal is the daemon's sentence.
    private func read<Value: Equatable & Sendable>(
        _ state: ReferenceWritableKeyPath<SettingsModel, SettingsReadState<Value>>,
        _ what: String,
        _ request: @escaping () async throws -> Value
    ) async {
        beginRead(state)
        do {
            publish(.loaded(try await request()), to: state)
        } catch {
            publish(.failure(error), to: state)
            noteRead(error, what)
        }
    }

    /// Puts a row a write answered in place of the one of its name. A row the
    /// list does not hold yet waits for the list's own next read.
    private func keep(_ source: ManagementCueSource) {
        guard let list = cueSources.value,
              let index = list.sources.firstIndex(where: { $0.ref == source.ref })
        else { return }

        var sources = list.sources
        sources[index] = source
        publish(.loaded(ManagementCueSourceList(sources: sources, canAdd: list.canAdd, limits: list.limits)), to: \.cueSources)
    }

    private func keep(_ mandate: ManagementCueMandate) {
        guard let list = cueMandates.value,
              let index = list.mandates.firstIndex(where: { $0.name == mandate.name })
        else { return }

        var mandates = list.mandates
        mandates[index] = mandate
        publish(.loaded(ManagementCueMandateList(mandates: mandates, canAdd: list.canAdd, limits: list.limits)), to: \.cueMandates)
    }
}
