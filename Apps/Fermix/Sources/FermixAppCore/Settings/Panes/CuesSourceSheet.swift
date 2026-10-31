import SwiftUI

/// The add and edit form of a source, as a value (M60 app surface §4.3,
/// simpler setup §3).
///
/// The form is the daemon's: the choices and the rows come from
/// `cues.sources.form` on an add and from `cues.sources.get`'s `values` on an
/// edit, and the app writes no field list per kind. An add is two steps:
/// what to watch, from the daemon's choices, then that choice's own rows.
/// What lives here is what the owner chose and set, what Add sends, which
/// typed secrets are stored after it, and where a refusal is drawn. A typed
/// secret stays in this value until Add and is never sent with the source.
public struct CueSourceFormState: Equatable, Sendable {
    /// The name row's key, which Add sends as the source's `ref`.
    public static let nameKey = "ref"
    /// The verification row, whose change asks for the form again.
    public static let verifyKey = "verify"

    /// The source an edit changes; nil on an add.
    public let editing: String?
    /// What the owner can watch, as the daemon lists it: nil until it
    /// answers, and empty from an engine that predates the choices.
    public private(set) var choices: [ManagementCueSourceForm.Choice]?
    /// The choice the fields are for: nil while the owner picks one.
    public private(set) var choice: ManagementCueSourceForm.Choice?
    public private(set) var rows: [ManagementSettingRow] = []
    public private(set) var requirement: ManagementCueSourceForm.Requirement?
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

    /// What the form is asked for: no choice for the first step, which
    /// answers the choices, then the choice's own form with the check where
    /// the owner set one.
    public var request: ManagementCueFormRequest {
        guard let choice else { return ManagementCueFormRequest() }

        let verify = values[Self.verifyKey].map(DescriptorValue.text).flatMap { $0.isEmpty ? nil : $0 }
        return choice.request(verify: verify)
    }

    /// How long a change rests before the form is asked for. The asks that
    /// open a step, with no rows to show yet, go at once, so it opens on
    /// what it asks rather than on a spinner.
    public var askPause: TimeInterval {
        rows.isEmpty ? 0 : CuesSheetMetrics.formPause
    }

    /// The choices drawn first, and the ones under Something else.
    public var featuredChoices: [ManagementCueSourceForm.Choice] { (choices ?? []).filter(\.featured) }
    public var otherChoices: [ManagementCueSourceForm.Choice] { (choices ?? []).filter { !$0.featured } }

    /// The daemon's answer to `asked`. Every answer carries the choices. The
    /// rows are drawn only from an answer to the choice the sheet holds now,
    /// so one choice's fields never show under another while its own form
    /// is asked for. A value or a secret for a field the new form no longer
    /// has is dropped with the field.
    public mutating func take(_ form: ManagementCueSourceForm, answering asked: ManagementCueFormRequest) {
        choices = form.choices
        guard choice != nil, asked == request else { return }

        rows = form.rows
        requirement = form.requirement
        consent = form.consentSentence
        notes = form.notes

        let keys = Set(form.rows.map(\.key))
        values = values.filter { keys.contains($0.key) }
        secrets = secrets.filter { keys.contains($0.key) }
    }

    /// A choice picked on the first step: its form starts empty.
    public mutating func choose(_ picked: ManagementCueSourceForm.Choice) {
        backToChoices()
        choice = picked
    }

    /// Back to the first step, keeping the choices and nothing else, so
    /// nothing typed for one choice reaches another.
    public mutating func backToChoices() {
        precondition(editing == nil, "an edit has no first step")

        let listed = choices
        self = CueSourceFormState()
        choices = listed
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

    /// What Add sends, or nil while there is nothing to add: no choice, or
    /// its form not answered yet. The name is optional: left empty, it is
    /// not sent and Fermix names the source.
    public var spec: ManagementCueSourceSpec? {
        guard editing == nil, let choice, !rows.isEmpty else { return nil }

        return ManagementCueSourceSpec(
            ref: name.isEmpty ? nil : name,
            choice: choice.addition,
            values: changedValues.filter { $0.key != Self.nameKey }
        )
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

    /// What the info beside the choice's line holds: the daemon's consent
    /// line, then its notes, or nil where it published neither.
    public var about: String? {
        let lines = ([consent] + notes.map(Optional.some)).compactMap { $0 }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// The daemon's refusal under the field it names.
    public func refusal(for key: String) -> String? {
        refusal?.field == key ? refusal?.sentence : nil
    }

    /// A refusal that names no row of the form, said under the form.
    public var formRefusal: String? {
        guard let refusal else { return nil }
        guard let field = refusal.field, rows.contains(where: { $0.key == field }) else { return refusal.sentence }

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
///
/// As tall as its rows where they fit the sheet, and otherwise as tall as the
/// sheet leaves it, with its rows scrolling: the sheet stops at the picker's
/// height (M34 §5.8), and a form the daemon makes long, such as a WebSocket
/// source's, would otherwise grow it past the window.
struct CuesPageForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            form.fixedSize(horizontal: false, vertical: true)
            form.scrollIndicators(.never)
        }
    }

    private var form: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .showsAmbientGround()
        .rowActions()
    }
}

/// The add form and the edit form of a source (§4.3, simpler setup §3). An
/// add asks what to watch first, from the daemon's choices, then only what
/// that choice needs, with its requirement under its fields; an edit draws
/// the source's own fields.
struct CuesSourceFormPage: View {
    /// The section name a held row's Escape is keyed under. No settings
    /// section has it, so nothing is ever applied to it.
    static let heldSection = "cues.source.form"

    let page: CuesSheetPage
    @Binding var form: CueSourceFormState
    @ObservedObject var model: SettingsModel
    let added: (CueSourceAddOutcome) -> Void
    /// Opens the page of the plugin a choice's requirement names.
    let openPlugin: (String) -> Void
    let back: () -> Void

    @State private var sending = false
    @State private var advancedShown = DescriptorRowFold.startsOpen
    @State private var othersShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            content
            formRefusal
            buttons
        }
        .task(id: form.request) {
            guard form.editing == nil else { return }

            await askForTheForm()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let ref = form.editing {
            IntegrationPageHeader(title: ProductStrings[.cuesEdit], parent: ref, back: back)
            fields
        } else if let choice = form.choice {
            choiceHeading(choice)
            fields
        } else {
            Text(ProductStrings[.cuesSourceAddTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
            choiceList
        }
    }

    /// The first step: the featured choices, then Something else, which
    /// shows the rest. An engine that publishes no choices says the one
    /// sentence every surface says about an engine behind the app.
    @ViewBuilder
    private var choiceList: some View {
        if let choices = form.choices {
            if choices.isEmpty {
                CueNote(text: model.newerEngineSentence, attention: true)
            } else {
                CuesPageForm { Section { choiceRows } }
            }
        } else if form.refusal == nil {
            ProgressView().controlSize(.small).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var choiceRows: some View {
        ForEach(form.featuredChoices, id: \.id) { choice in
            CueChoiceRow(choice: choice) { choose(choice) }
        }
        if !form.otherChoices.isEmpty {
            AdvancedRowsToggle(shown: $othersShown, title: .cuesSourceSomethingElse)
            if othersShown {
                ForEach(form.otherChoices, id: \.id) { choice in
                    CueChoiceRow(choice: choice) { choose(choice) }
                }
            }
        }
    }

    /// The second step's top: the choice's tile and label, and its line with
    /// what adding it means and the daemon's notes behind the info beside
    /// it.
    private func choiceHeading(_ choice: ManagementCueSourceForm.Choice) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            CueChoiceTile(choice: choice)

            VStack(alignment: .leading, spacing: 2) {
                Text(choice.label)
                    .fermixType(Typography.sheetTitle)
                    .foregroundStyle(Palette.ink.color)
                DescriptorRowLabel(choice.sentence, info: form.about)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        if form.rows.isEmpty {
            ProgressView().controlSize(.small).accessibilityHidden(true)
        } else {
            CuesPageForm { Section { rows } }
        }
    }

    /// The rows the choice opens, its requirement under them, then More
    /// options with the rest, the name among them.
    @ViewBuilder
    private var rows: some View {
        let fold = DescriptorRowFold(form.rows)
        ForEach(fold.open, id: \.key) { row in field(row) }

        if let requirement = form.requirement {
            CueRequirementLine(requirement: requirement) { openPlugin(requirement.plugin) }
        }
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

    /// A refusal that names no field of the form.
    @ViewBuilder
    private var formRefusal: some View {
        if let refused = form.formRefusal {
            CueNote(text: refused, attention: true)
        }
    }

    /// Cancel on every step; Back and Add source once a choice is made;
    /// Done on an edit. Add waits only for the choice's form, not for a
    /// name.
    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            if form.editing == nil, form.choice != nil {
                Button(ProductStrings[.cuesBack]) { form.backToChoices() }
                    .buttonStyle(SecondaryButtonStyle(.row))
            }

            Spacer(minLength: 0)

            Button(ProductStrings[.settingsSheetCancel], action: back)
                .buttonStyle(SecondaryButtonStyle(.row))
                .keyboardShortcut(.cancelAction)

            if form.editing != nil || form.choice != nil {
                PrimaryAction(
                    ProductStrings[form.editing == nil ? .cuesSourcesAdd : .settingsSheetDone],
                    size: .row,
                    action: send
                )
                .disabled(sending || (form.editing == nil && form.spec == nil))
            }
        }
    }

    /// A choice picked: its form starts empty, with More options closed.
    private func choose(_ choice: ManagementCueSourceForm.Choice) {
        form.choose(choice)
        advancedShown = DescriptorRowFold.startsOpen
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

    /// Asks for the choices as the sheet opens and for a choice's form as it
    /// is picked, each at once, and again once a change to the check has
    /// rested. A newer request cancels this one while it waits.
    private func askForTheForm() async {
        let asked = form.request
        guard let answer = await model.cueSourceForm(asked, pause: form.askPause) else { return }

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

/// One thing the owner can watch, on the add sheet's first step: its mark
/// or its kind's symbol, the daemon's label and line, and the chevron to
/// its fields.
struct CueChoiceRow: View {
    let choice: ManagementCueSourceForm.Choice
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Spacing.s) {
                CueChoiceTile(choice: choice)

                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label)
                        .fermixType(Typography.style(.callout).weight(.medium))
                        .foregroundStyle(Palette.ink.color)
                    CueNote(text: choice.sentence)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint.color)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ProductStrings.commaPair(choice.label, choice.sentence))
        // The hover fill a list row draws (`CueRow`).
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
        .background(
            hovering ? Palette.chipFill.color : .clear,
            in: RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
        )
        .padding(.horizontal, -Spacing.xs)
        .onHover { hovering = $0 }
    }
}

/// A choice's 28-point tile: the vendor's mark where the app ships one,
/// and its kind's symbol otherwise.
struct CueChoiceTile: View {
    let choice: ManagementCueSourceForm.Choice

    var body: some View {
        Group {
            if let mark = CueChoiceProjection.mark(for: choice) {
                VendorMarkView(mark: mark, kind: .plugin, size: IntegrationMetrics.tileSize)
            } else {
                VendorMarkView(symbol: CueChoiceProjection.symbol(for: choice), size: IntegrationMetrics.tileSize)
            }
        }
        .accessibilityHidden(true)
    }
}

/// How a choice is drawn: as a source of its preset or kind is.
public enum CueChoiceProjection {
    public static func mark(for choice: ManagementCueSourceForm.Choice) -> VendorMark? {
        CueSourceProjection.mark(forPreset: choice.preset)
    }

    public static func symbol(for choice: ManagementCueSourceForm.Choice) -> String {
        CueSourceProjection.symbol(for: ManagementCueSourceKind(wireValue: choice.kind))
    }
}

/// What a choice needs set up first, under its fields (simpler setup D4):
/// the daemon's sentence after its dot, and while a sign-in is owed, the
/// way to the plugin's page. Add stays open either way.
struct CueRequirementLine: View {
    let requirement: ManagementCueSourceForm.Requirement
    let openPlugin: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            CueStatusLine(text: requirement.sentence, tone: CueTone.requirement(requirement))

            Spacer(minLength: Spacing.s)

            if CueRequirementProjection.offersPlugin(requirement) {
                Button(ProductStrings[.cuesSourceOpenPlugin], action: openPlugin)
                    .buttonStyle(SecondaryButtonStyle(.row))
            }
        }
    }
}

/// What a requirement offers, from its published state.
public enum CueRequirementProjection {
    /// The plugin's page, while it asks for a sign-in. A state this build
    /// does not know offers nothing.
    public static func offersPlugin(_ requirement: ManagementCueSourceForm.Requirement) -> Bool {
        requirement.state == .needsSignIn
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
    /// A token or a secret handed out on this page, shown once.
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
            if let url = source.url, !url.isEmpty {
                LabeledContent(ProductStrings[.cuesSourceURL]) {
                    Text(url)
                        .foregroundStyle(Palette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(url)
                }
            }
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
            handed(slot.field)
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
        handed(.token)
    }

    /// The value handed out on this page for one of its secrets: a new
    /// token, or the secret Fermix made for a GitHub source, shown once.
    @ViewBuilder
    private func handed(_ field: ManagementCueSecretField) -> some View {
        if let token, token.ref == ref, token.field == field {
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

/// A token or a secret handed out, shown once (§4.3, §5.4): in a monospaced
/// field that is not selectable and is never an accessibility value, with
/// its Copy and the line that says it is shown once, then for a token a push
/// example that names the door's port and leaves the token as a placeholder,
/// and for GitHub's secret the notes of the form it was added from. Copy
/// keeps it to this Mac and out of clipboard history, and it is taken back
/// off the pasteboard when this block leaves the sheet.
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
                    .accessibilityLabel(String(format: ProductStrings[accessibilityFormat], token.ref))

                Button(ProductStrings[copyTitle]) { copied.copy(token.value, on: .system) }
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[copyTitle], token.ref))
            }
            .padding(Spacing.xs)
            .background(Palette.chipFill.color, in: RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous))

            CueNote(text: ProductStrings[.cuesSourceTokenOnce], attention: true)

            if token.field == .token, let port {
                Text(String(format: ProductStrings[.cuesSourcePushExampleFormat], port, token.ref, Self.exampleHeader))
                    .fermixType(Typography.style(.monoLog))
                    .foregroundStyle(Palette.secondary.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(token.notes.enumerated()), id: \.offset) { _, note in
                CueNote(text: note)
            }
        }
        .onDisappear { copied.takeBack(on: .system) }
    }

    private var copyTitle: ProductStringKey {
        token.field == .secret ? .cuesSourceCopySecret : .cuesSourceCopyToken
    }

    private var accessibilityFormat: ProductStringKey {
        token.field == .secret ? .cuesSourceSecretAccessibilityFormat : .cuesSourceTokenAccessibilityFormat
    }
}
