import SwiftUI

/// The add and edit form of a source, as a value (M60 app surface §4.3).
///
/// The form is the daemon's: the kinds, the presets and the rows come from
/// `cues.sources.form` on an add and from `cues.sources.get`'s `values` on an
/// edit, and the app writes no field list per kind. What lives here is what
/// the owner set, what Add sends, which typed secrets are stored after it,
/// and where a refusal is drawn. A typed secret stays in this value until
/// Add and is never sent with the source.
public struct CueSourceFormState: Equatable, Sendable {
    /// The name row's key, which Add sends as the source's `ref`.
    public static let nameKey = "ref"
    /// The verification row, whose change asks for the form again.
    public static let verifyKey = "verify"

    /// The source an edit changes; nil on an add.
    public let editing: String?
    public private(set) var kind: String?
    public private(set) var preset: String?
    public private(set) var kinds: [ManagementCueSourceForm.Kind] = []
    public private(set) var presets: [ManagementCueSourceForm.Preset] = []
    public private(set) var rows: [ManagementSettingRow] = []
    public private(set) var consent: String?
    public private(set) var notes: [String] = []
    /// What the owner set, by row key. Never a secret.
    public var values: [String: ManagementSettingValue] = [:]
    /// What the owner typed into a secret row, by row key, until Add.
    public var secrets: [String: String] = [:]
    public var refusal: CueRefusal?

    public init() {
        editing = nil
    }

    /// An edit: the source's own fields, its name and kind fixed. Its
    /// secrets are stored from its detail, so they are not on this form.
    public init(editing detail: ManagementCueSourceDetail) {
        editing = detail.source.ref
        rows = detail.values.filter { $0.kind != .secret }
    }

    /// The choice the form is asked for: the preset where one is chosen,
    /// the kind otherwise, and the check where the owner set one.
    public var request: ManagementCueFormRequest {
        let verify = values[Self.verifyKey].map(DescriptorValue.text).flatMap { $0.isEmpty ? nil : $0 }
        if let preset { return ManagementCueFormRequest(preset: preset, verify: verify) }

        return ManagementCueFormRequest(kind: kind, verify: verify)
    }

    /// The presets of the kind chosen.
    public var kindPresets: [ManagementCueSourceForm.Preset] {
        presets.filter { $0.kind == kind }
    }

    /// The daemon's answer to `asked`. The first answer opens the sheet on the
    /// first kind with that kind's first preset, the common case and one a
    /// name and a URL complete. The rows are drawn only from an answer to the
    /// choice the sheet holds now, so one choice's fields never show under
    /// another while its own form is asked for. A value or a secret for a
    /// field the new form no longer has is dropped with the field.
    public mutating func take(_ form: ManagementCueSourceForm, answering asked: ManagementCueFormRequest) {
        kinds = form.kinds
        presets = form.presets
        if kind == nil {
            kind = form.kinds.first?.id
            preset = firstPreset(of: kind)
        }
        guard asked == request else { return }

        rows = form.rows
        consent = form.consentSentence
        notes = form.notes

        let keys = Set(form.rows.map(\.key))
        values = values.filter { keys.contains($0.key) }
        secrets = secrets.filter { keys.contains($0.key) }
    }

    /// A kind chosen in the segmented control: its first preset (None stays
    /// in the menu) and its own check, so neither a preset nor a check of
    /// another kind is asked for.
    public mutating func choose(kind: String) {
        guard kind != self.kind else { return }

        self.kind = kind
        preset = firstPreset(of: kind)
        values[Self.verifyKey] = nil
        refusal = nil
    }

    private func firstPreset(of kind: String?) -> String? {
        presets.first { $0.kind == kind }?.id
    }

    public mutating func choose(preset: String?) {
        self.preset = preset
        values[Self.verifyKey] = nil
        refusal = nil
    }

    /// A field changed. Its refusal goes with the value it was about.
    public mutating func set(_ value: ManagementSettingValue, for key: String) {
        values[key] = value
        if refusal?.field == key { refusal = nil }
    }

    public func value(of row: ManagementSettingRow) -> ManagementSettingValue {
        values[row.key] ?? row.value
    }

    /// The name typed, trimmed.
    public var name: String {
        values[Self.nameKey].map(DescriptorValue.text)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// What Add sends, or nil while there is nothing to add: no name yet, or
    /// no form answered.
    public var spec: ManagementCueSourceSpec? {
        guard editing == nil, !name.isEmpty else { return nil }

        let choice: ManagementCueSourceChoice
        if let preset {
            choice = .preset(preset)
        } else if let kind {
            choice = .kind(kind)
        } else {
            return nil
        }

        return ManagementCueSourceSpec(ref: name, choice: choice, values: changedValues.filter { $0.key != Self.nameKey })
    }

    /// The fields the owner changed from the form's own values, secrets
    /// aside: what Add sends beside the name, and what an edit sends.
    public var changedValues: [String: ManagementCueValue] {
        var changed: [String: ManagementCueValue] = [:]
        for row in rows where row.kind != .secret {
            guard let value = values[row.key], value != row.value else { continue }

            changed[row.key] = .setting(value)
        }

        return changed
    }

    /// The secrets typed, in the form's order: each one the owner may store.
    public var typedSecrets: [CueTypedSecret] {
        rows.compactMap { row in
            guard row.kind == .secret, let value = secrets[row.key], !value.isEmpty else { return nil }

            let field = ManagementCueSecretField(wireValue: row.key)
            return field.isTyped ? CueTypedSecret(field: field, value: value) : nil
        }
    }

    /// What Add sends and stores, or nil with a refusal under the row of a
    /// secret typed for a field this build cannot store. Sending the source
    /// without it would drop what was typed with nothing said, so nothing is
    /// sent until the value is cleared or the app is updated.
    public mutating func prepareAdd() -> (spec: ManagementCueSourceSpec, secrets: [CueTypedSecret])? {
        let unstorable = rows.first { row in
            row.kind == .secret && !(secrets[row.key] ?? "").isEmpty
                && !ManagementCueSecretField(wireValue: row.key).isTyped
        }
        if let unstorable {
            refusal = CueRefusal(sentence: ProductStrings[.cuesSourceSecretUnstorable], field: unstorable.key)
            return nil
        }

        return spec.map { ($0, typedSecrets) }
    }

    /// The daemon's refusal under the field it names.
    public func refusal(for key: String) -> String? {
        refusal?.field == key ? refusal?.sentence : nil
    }

    /// A refusal that names no row of the form, said under the form.
    public var formRefusal: String? {
        guard let refusal else { return nil }
        guard let field = refusal.field,
              rows.contains(where: { $0.key == field }) || field == "kind" || field == "preset"
        else { return refusal.sentence }

        return nil
    }
}

/// Where a secret copied off a page went, so it can be taken back.
///
/// Copying writes it for this Mac only, concealed and transient, and leaving
/// the page takes it back off the pasteboard unless something was copied
/// over it since: the phone pairing link's rules (§4.3).
public struct CueSecretCopy: Equatable, Sendable {
    public private(set) var changeCount: Int?

    public init() {}

    public mutating func copy(_ text: String, on pasteboard: CueSecretPasteboard) {
        changeCount = pasteboard.write(text)
    }

    public mutating func takeBack(on pasteboard: CueSecretPasteboard) {
        guard let changeCount else { return }

        pasteboard.withdraw(changeCount)
        self.changeCount = nil
    }
}

/// The pasteboard a secret is copied to: the system's, or a test's.
public struct CueSecretPasteboard: Sendable {
    public let write: @Sendable (String) -> Int
    public let withdraw: @Sendable (Int) -> Void

    public init(write: @escaping @Sendable (String) -> Int, withdraw: @escaping @Sendable (Int) -> Void) {
        self.write = write
        self.withdraw = withdraw
    }

    public static let system = CueSecretPasteboard(
        write: { Clipboard.writeSecret($0) },
        withdraw: { Clipboard.withdraw($0) }
    )
}

/// A question asked in place of the buttons it answers: the sentence, Cancel
/// and the one action.
struct CueQuestion: View {
    let text: String
    let action: ProductStringKey
    let busy: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(text)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(ProductStrings[.settingsSheetCancel], action: cancel)
                .buttonStyle(SecondaryButtonStyle(.row))
                .keyboardShortcut(.cancelAction)

            PrimaryAction(ProductStrings[action], size: .row, action: confirm)
                .disabled(busy)
        }
    }
}

/// The grouped form a page's sections are drawn in, the shape the channel
/// sheet gives its rows, sized to its content.
struct CuesPageForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .showsAmbientGround()
        .rowActions()
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The add form and the edit form of a source (§4.3): the deciding control
/// first, then the daemon's rows, its consent line and its notes.
struct CuesSourceFormPage: View {
    /// The section name a held row's Escape is keyed under. No settings
    /// section has it, so nothing is ever applied to it.
    static let heldSection = "cues.source.form"

    let page: CuesSheetPage
    @Binding var form: CueSourceFormState
    @ObservedObject var model: SettingsModel
    let added: (CueSourceAddOutcome) -> Void
    let back: () -> Void

    @State private var sending = false
    @State private var advancedShown = DescriptorRowFold.startsOpen

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            heading

            if form.editing == nil {
                kindPicker
            }

            if form.rows.isEmpty {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else {
                CuesPageForm { Section { rows } }
            }

            consent
            buttons
        }
        .task(id: form.request) {
            guard form.editing == nil else { return }

            await askForTheForm()
        }
    }

    @ViewBuilder
    private var heading: some View {
        if let ref = form.editing {
            IntegrationPageHeader(title: ProductStrings[.cuesEdit], parent: ref, back: back)
        } else {
            Text(ProductStrings[.cuesSourceAddTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
        }
    }

    private var kindPicker: some View {
        VStack(spacing: Spacing.xxs) {
            if !form.kinds.isEmpty {
                Picker(ProductStrings[.cuesSourceKind], selection: kindChoice) {
                    ForEach(form.kinds, id: \.id) { kind in
                        Text(kind.label).tag(kind.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let kind = form.kinds.first(where: { $0.id == form.kind }) {
                kindLine(kind)
            }
            if let refused = form.refusal(for: "kind") ?? form.refusal(for: "preset") {
                CueNote(text: refused, attention: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var rows: some View {
        if form.editing == nil, !form.kindPresets.isEmpty {
            Picker(ProductStrings[.cuesSourcePreset], selection: presetChoice) {
                Text(ProductStrings[.cuesSourcePresetNone]).tag("")
                ForEach(form.kindPresets, id: \.id) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
        }

        let fold = DescriptorRowFold(form.rows)
        ForEach(fold.open, id: \.key) { row in field(row) }

        if !fold.folded.isEmpty {
            AdvancedRowsToggle(shown: $advancedShown, title: .cuesMoreOptions)
            if advancedShown {
                ForEach(fold.folded, id: \.key) { row in field(row) }
            }
        }
    }

    @ViewBuilder
    private func field(_ row: ManagementSettingRow) -> some View {
        if row.kind == .secret {
            CueHeldSecretRow(row: row, value: secretBinding(row.key), refusal: form.refusal(for: row.key))
        } else {
            DescriptorRow(
                model: model,
                section: Self.heldSection,
                row: row,
                held: DescriptorHeldValue(
                    value: form.value(of: row),
                    refusal: form.refusal(for: row.key),
                    change: { form.set($0, for: row.key) }
                )
            )
        }
    }

    /// The kind's one line, with the daemon's notes for this choice behind
    /// the info beside it: a webhook's tunnel, a preset's content type.
    private func kindLine(_ kind: ManagementCueSourceForm.Kind) -> some View {
        DescriptorRowLabel(kind.sentence, info: form.notes.isEmpty ? nil : form.notes.joined(separator: "\n\n"))
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
    }

    /// What adding it means, in the daemon's words, and a refusal that names
    /// no field.
    @ViewBuilder
    private var consent: some View {
        if let consent = form.consent {
            CueNote(text: consent)
        }
        if let refused = form.formRefusal {
            CueNote(text: refused, attention: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)

            Button(ProductStrings[.settingsSheetCancel], action: back)
                .buttonStyle(SecondaryButtonStyle(.row))
                .keyboardShortcut(.cancelAction)

            PrimaryAction(
                ProductStrings[form.editing == nil ? .cuesSourcesAdd : .settingsSheetDone],
                size: .row,
                action: send
            )
            .disabled(sending || (form.editing == nil && form.spec == nil))
        }
    }

    private var kindChoice: Binding<String> {
        Binding(get: { form.kind ?? "" }, set: { form.choose(kind: $0) })
    }

    private var presetChoice: Binding<String> {
        Binding(get: { form.preset ?? "" }, set: { form.choose(preset: $0.isEmpty ? nil : $0) })
    }

    private func secretBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { form.secrets[key] ?? "" },
            set: { typed in
                form.secrets[key] = typed
                if form.refusal?.field == key { form.refusal = nil }
            }
        )
    }

    /// Asks for the form once changes to the kind, the preset or the check
    /// have rested. A newer request cancels this one while it waits.
    private func askForTheForm() async {
        let asked = form.request
        guard let answer = await model.cueSourceForm(asked, pause: CuesSheetMetrics.formPause) else { return }

        switch answer {
        case .success(let daemonForm): form.take(daemonForm, answering: asked)
        case .failure(let refused): form.refusal = refused
        }
    }

    private func send() {
        guard !sending else { return }

        sending = true
        Task {
            defer { sending = false }
            if let ref = form.editing {
                await update(ref)
            } else if let prepared = form.prepareAdd() {
                await add(prepared.spec, secrets: prepared.secrets)
            }
        }
    }

    private func add(_ spec: ManagementCueSourceSpec, secrets: [CueTypedSecret]) async {
        let outcome = await model.addCueSource(spec, secrets: secrets)
        guard case .refused(let refused) = outcome else {
            added(outcome)
            return
        }

        form.refusal = refused
    }

    private func update(_ ref: String) async {
        guard let refused = await model.updateCueSource(ref, values: form.changedValues) else {
            back()
            return
        }

        form.refusal = refused
    }
}

/// A secret row of the add form: the one secure input, held by the sheet
/// until Add, then stored with `secret.set` once the source exists.
struct CueHeldSecretRow: View {
    let row: ManagementSettingRow
    @Binding var value: String
    let refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            LabeledContent {
                SecretInput(label: row.label, value: $value, onSubmit: {})
            } label: {
                DescriptorRowLabel(row.label, info: row.explanation)
            }

            if let footer = row.footer, !footer.isEmpty {
                CueNote(text: footer)
            }
            if let refusal {
                CueNote(text: refusal, attention: true)
            }
        }
    }
}

/// What a source's detail asks in place.
enum CueSourceQuestion: Equatable {
    case newToken
    case remove
}

/// A source's detail (§4.3): its secrets, its address or its token, the
/// day's counts, its refusals and gaps in the daemon's sentences, and who
/// listens. Removing and a new token are asked in place.
struct CuesSourceDetailPage: View {
    let ref: String
    let at: ManagementCueSecretField?
    /// A token handed out on this page, shown once.
    let token: CueHandedToken?
    /// A secret the add could not store, said under its field.
    let unstored: CueRefusal?
    @ObservedObject var model: SettingsModel
    let hand: (CueHandedToken) -> Void
    let edit: (ManagementCueSourceDetail) -> Void
    let done: (String?) -> Void

    @State private var asking: CueSourceQuestion?
    @State private var busy = false
    @State private var refusal: String?
    @State private var address = CueSecretCopy()

    private var detail: ManagementCueSourceDetail? { model.cueSourceDetails[ref]?.value }
    private var source: ManagementCueSource? { model.cueSource(ref) ?? detail?.source }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let source {
                heading(source)
                CuesPageForm { facts(source) }
            } else {
                CueNote(text: ProductStrings[.cuesSourceGone])
            }

            if let refusal {
                CueNote(text: refusal, attention: true)
            }
            footer
        }
        .task { await model.readCueSource(ref) }
        .onDisappear { address.takeBack(on: .system) }
    }

    private func heading(_ source: ManagementCueSource) -> some View {
        CuesPageHeading(
            title: source.ref,
            status: source.statusSentence,
            tone: CueTone.source(source),
            attention: CueTone.isLoud(CueTone.source(source))
        ) {
            CuesSourceTile(source: source)
        } trailing: {
            if CueSourceProjection.switchShown(source) {
                Toggle(source.ref, isOn: Binding(get: { source.enabled }, set: { setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.integrationEnabled], source.ref))
            }
        }
    }

    /// The secrets first, then what the source is and did, then what it
    /// refused or missed where it refused or missed anything.
    @ViewBuilder
    private func facts(_ source: ManagementCueSource) -> some View {
        if !source.secrets.isEmpty {
            Section {
                ForEach(CueSourceProjection.secrets(source, first: at), id: \.field) { slot in
                    secretRow(slot, of: source)
                }
            }
        }

        Section {
            LabeledContent(ProductStrings[.cuesSourceKind]) { CueValue(text: source.label) }
            LabeledContent(ProductStrings[.cuesSourceItemsADay]) {
                CueValue(text: source.dailyBudget == 0 ? ProductStrings[.cuesNoLimit] : String(source.dailyBudget))
            }
            LabeledContent(ProductStrings[.cuesSourceLastDay]) { CueValue(text: CueSourceDetailWords.lastDay(source.counts)) }
            LabeledContent(ProductStrings[.cuesSourceListening]) {
                CueValue(text: source.listening.isEmpty ? ProductStrings[.cuesNone] : source.listening.joined(separator: ", "))
            }
        }

        if let detail, !detail.rejected.isEmpty || !detail.gaps.isEmpty {
            Section {
                if !detail.rejected.isEmpty {
                    CuesStackedFact(label: ProductStrings[.cuesSourceRefused], text: CueSourceDetailWords.lines(detail.rejected.map(\.sentence)))
                }
                if !detail.gaps.isEmpty {
                    CuesStackedFact(label: ProductStrings[.cuesSourceMissed], text: CueSourceDetailWords.lines(detail.gaps.map(\.sentence)))
                }
            }
        }
    }

    @ViewBuilder
    private func secretRow(_ slot: ManagementCueSecretSlot, of source: ManagementCueSource) -> some View {
        switch slot.field {
        case .key, .secret:
            SecretRow(label: slot.label, identifier: CueSecretId.id(ref: ref, field: slot.field), present: slot.present, model: model)
            if let unstored, unstored.field == slot.field.wireValue {
                CueNote(text: unstored.sentence, attention: true)
            }
        case .token:
            tokenRow(slot, of: source)
        case .pathSecret:
            addressRow(slot, of: source)
        case .unrecognized:
            LabeledContent(slot.label) { CueValue(text: ProductStrings[slot.present ? .settingsSecretStored : .cuesSourceNotStored]) }
        }
    }

    /// The token: whether one is stored, New token where the daemon offers
    /// it, and a token just handed out, shown once.
    @ViewBuilder
    private func tokenRow(_ slot: ManagementCueSecretSlot, of source: ManagementCueSource) -> some View {
        LabeledContent(slot.label) {
            HStack(spacing: Spacing.xs) {
                CueValue(text: ProductStrings[slot.present ? .settingsSecretStored : .cuesSourceNotStored])
                if source.actions.contains(.newToken) {
                    Button(ProductStrings[.cuesSourceNewToken]) { asking = .newToken }
                        .disabled(busy)
                        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesSourceNewToken], ref))
                }
            }
        }

        if asking == .newToken {
            CueQuestion(
                text: String(format: ProductStrings[.cuesSourceNewTokenConfirm], ref),
                action: .cuesSourceNewTokenDo,
                busy: busy,
                cancel: { asking = nil },
                confirm: newToken
            )
        }
        if let token, token.ref == ref {
            CueTokenBlock(token: token, port: model.cueStatus.value?.door.port)
        }
    }

    /// The address: whether it is made, and Copy URL where the daemon
    /// offers it, with where it goes behind the info. The address itself is
    /// never drawn and never kept.
    private func addressRow(_ slot: ManagementCueSecretSlot, of source: ManagementCueSource) -> some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                CueValue(text: ProductStrings[source.hasURL ? .cuesSourceAddressMade : .cuesSourceAddressNotMade])
                if source.actions.contains(.getURL) {
                    Button(ProductStrings[.cuesSourceCopyURL], action: copyAddress)
                        .disabled(busy)
                        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesSourceCopyURL], ref))
                }
            }
        } label: {
            DescriptorRowLabel(slot.label, info: ProductStrings[.cuesSourceAddressInfo])
        }
    }

    /// `Edit`, `Remove source…` and `Done`; or the removal asked in their
    /// place.
    @ViewBuilder
    private var footer: some View {
        if asking == .remove {
            CueQuestion(text: removeQuestion, action: .cuesRemoveDo, busy: busy, cancel: { asking = nil }, confirm: remove)
        } else {
            HStack(spacing: Spacing.s) {
                if let detail {
                    Button(ProductStrings[.cuesEdit]) { edit(detail) }
                        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesEdit], ref))
                }
                Button(ProductStrings[.cuesSourceRemove]) { asking = .remove }
                    .disabled(source == nil || busy)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesSourceRemove], ref))

                Spacer(minLength: 0)

                PrimaryAction(ProductStrings[.settingsSheetDone], size: .row) { done(nil) }
            }
            .buttonStyle(SecondaryButtonStyle(.row))
        }
    }

    private var removeQuestion: String {
        let asked = String(format: ProductStrings[.cuesSourceRemoveConfirm], ref)
        guard let listening = source?.listening, !listening.isEmpty else { return asked }

        return asked + " " + String(format: ProductStrings[.cuesSourceRemoveWatchersFormat], listening.joined(separator: ", "))
    }

    private func setEnabled(_ isOn: Bool) {
        Task { refusal = await model.setCueSourceEnabled(isOn, ref: ref)?.sentence }
    }

    private func newToken() {
        busy = true
        Task {
            defer { busy = false }
            asking = nil
            switch await model.newCueSourceToken(ref) {
            case .success(let value): hand(CueHandedToken(ref: ref, value: value))
            case .failure(let refused): refusal = refused.sentence
            }
        }
    }

    /// Asks for the address on each press and copies its path, by the
    /// token's pasteboard rules. Nothing of it is kept here.
    private func copyAddress() {
        busy = true
        Task {
            defer { busy = false }
            switch await model.cueSourceAddress(ref) {
            case .success(let made):
                refusal = nil
                address.copy(made.path, on: .system)
            case .failure(let refused):
                refusal = refused.sentence
            }
        }
    }

    private func remove() {
        busy = true
        Task {
            defer { busy = false }
            switch await model.removeCueSource(ref) {
            case .success(let left):
                done(left.isEmpty ? nil : left.joined(separator: " "))
            case .failure(let refused):
                asking = nil
                refusal = refused.sentence
            }
        }
    }
}

/// The words of a source's detail, from its published counts and sentences.
public enum CueSourceDetailWords {
    public static func lastDay(_ counts: ManagementCueSource.Counts) -> String {
        ProductStrings.middot(
            String(format: ProductStrings[.cuesSourceReceivedFormat], counts.received),
            String(format: ProductStrings[.cuesSourceRoutedFormat], counts.routed)
        )
    }

    /// The daemon's sentences, one a line, or None.
    public static func lines(_ sentences: [String]) -> String {
        sentences.isEmpty ? ProductStrings[.cuesNone] : sentences.joined(separator: "\n")
    }
}

/// A published value on a page, in the value colour.
struct CueValue: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Palette.secondary.color)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A token handed out, shown once (§4.3, §5.4): in a monospaced field that
/// is not selectable and is never an accessibility value, with Copy token,
/// the line that says it is shown once, and a push example that names the
/// door's port and leaves the token as a placeholder. Copy keeps it to this
/// Mac and out of clipboard history, and the token is taken back off the
/// pasteboard when this block leaves the sheet.
struct CueTokenBlock: View {
    /// The header the push example carries, with the token as a placeholder.
    static let exampleHeader = "'Authorization: Bearer <token>'"

    let token: CueHandedToken
    /// The door's port, from `cues.status`. No example without it.
    let port: Int?

    @State private var copied = CueSecretCopy()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.entryGap) {
            HStack(spacing: Spacing.s) {
                Text(token.value)
                    .fermixType(Typography.style(.mono))
                    .foregroundStyle(Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(String(format: ProductStrings[.cuesSourceTokenAccessibilityFormat], token.ref))

                Button(ProductStrings[.cuesSourceCopyToken]) { copied.copy(token.value, on: .system) }
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesSourceCopyToken], token.ref))
            }
            .padding(Spacing.xs)
            .background(Palette.chipFill.color, in: RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous))

            CueNote(text: ProductStrings[.cuesSourceTokenOnce], attention: true)

            if let port {
                Text(String(format: ProductStrings[.cuesSourcePushExampleFormat], port, token.ref, Self.exampleHeader))
                    .fermixType(Typography.style(.monoLog))
                    .foregroundStyle(Palette.secondary.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { copied.takeBack(on: .system) }
    }
}
