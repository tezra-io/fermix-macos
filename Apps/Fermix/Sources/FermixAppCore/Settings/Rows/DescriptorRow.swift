import SwiftUI

/// One descriptor row, as exactly one control (M34 §7.7).
///
/// Every apply is optimistic in the control and confirmed by the daemon; a
/// refusal reverts the control and shows the daemon's sentence under the row.
/// The footer is the daemon's and doubles as the control's accessibility hint.
struct DescriptorRow: View {
    @ObservedObject var model: SettingsModel
    let section: String
    let row: ManagementSettingRow

    @State private var choosingTimeZone = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            control
            footer
            refusal
        }
        // Nothing is written while the settings file has changed outside Fermix
        // (M34 §7.6), and the write path already refuses. Without this the
        // control still moved and the model returned without writing, so a
        // switch flipped and snapped back — the effect the refusal exists to
        // avoid, under a banner already explaining it. Every descriptor control
        // in the app is one of these, so the gate is here and not per pane.
        .disabled(model.writesBlocked)
    }

    private var projection: DescriptorRowModel {
        DescriptorRowModel(row: row, value: model.value(of: row, in: section))
    }

    private var draftKey: SettingsDraftKey {
        SettingsDraftKey(section: section, key: row.key)
    }

    @ViewBuilder
    private var control: some View {
        switch projection.control {
        case .toggle(let isOn):
            Toggle(row.label, isOn: binding(isOn) { .flag($0) })
        case .choice(let selected, let options):
            choice(selected: selected, options: options)
        case .suggestion(let value, let options):
            suggestion(value: value, options: options)
        case .timeZone(let identifier):
            timeZone(identifier)
        case .text(let value, let prompt):
            DescriptorTextRow(
                label: row.label,
                prompt: prompt,
                value: value,
                model: model,
                key: draftKey,
                commit: commit
            )
        case .stepper(let value, let minimum, let maximum, let step, let measure):
            DescriptorNumberRow(
                label: row.label,
                value: value,
                minimum: minimum,
                maximum: maximum,
                step: step,
                measure: measure,
                commit: commit
            )
        case .slider(let value, let minimum, let maximum, let step, let measure):
            DescriptorSliderRow(
                label: row.label,
                value: value,
                minimum: minimum,
                maximum: maximum,
                step: step,
                measure: measure,
                commit: commit
            )
        case .secret(let present):
            SecretRow(label: row.label, identifier: row.key, present: present, model: model)
        case .list(let items):
            DescriptorListRow(label: row.label, items: items, commit: commitList)
        case .readOnly(let value):
            LabeledContent(row.label) {
                Text(value).foregroundStyle(Palette.secondary.color)
            }
        // The opposite condition from the one beside it: an unknown row kind
        // means the daemon published something this build has no control for,
        // so it is Fermix that is behind, not the engine. The newer-engine
        // sentence sent the operator to restart into the bundle they are
        // already running (M34 §7.1, §7.7).
        case .unsupported:
            LabeledContent(row.label) {
                Text(ProductStrings[.settingsRowUnsupported])
                    .foregroundStyle(Palette.secondary.color)
            }
        }
    }

    @ViewBuilder
    private func choice(selected: String?, options: [ManagementSettingOption]) -> some View {
        Picker(row.label, selection: binding(selected ?? "") { .text($0) }) {
            // A value the options do not carry has no tag to select, so the
            // popup draws blank. An empty value is the honest case of that —
            // nothing has been chosen — and it gets a row that says so rather
            // than an empty line the reader has to interpret.
            if !options.contains(where: { $0.value == (selected ?? "") }) {
                Text(ProductStrings[.settingsChoiceNotSet]).tag(selected ?? "")
            }

            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
                    .help(option.hint ?? "")
                    .disabled(option.disabled)
            }
        }
    }

    /// A choice row whose options are suggestions: a field that takes any value
    /// the daemon's own validator takes, with the published list beside it.
    ///
    /// A closed popup here could not express the answers `settings.apply`
    /// accepts, and the daemon prepending the value in force to the options is
    /// what hid that: it made an off-list value look handled while the control
    /// could still only ever send one of the list back.
    @ViewBuilder
    private func suggestion(value: String, options: [ManagementSettingOption]) -> some View {
        DescriptorTextRow(
            label: row.label,
            prompt: row.emptyValuePrompt,
            value: value,
            model: model,
            key: draftKey,
            commit: commit,
            suggestions: options
        )
    }

    /// The time zone, chosen the way macOS chooses one.
    private func timeZone(_ identifier: String) -> some View {
        LabeledContent(row.label) {
            HStack(spacing: Spacing.xs) {
                Text(
                    identifier.isEmpty
                        ? ProductStrings[.settingsChoiceNotSet]
                        : TimeZoneChoice(identifier: identifier).title
                )
                .foregroundStyle(Palette.secondary.color)

                Button(ProductStrings[.aboutYouTimezoneChange]) { choosingTimeZone = true }
            }
        }
        .sheet(isPresented: $choosingTimeZone) {
            TimeZoneSheet(
                selection: Binding(get: { identifier }, set: { commit(.text($0)) })
            ) {
                choosingTimeZone = false
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let footer = row.footer, !footer.isEmpty {
            Text(footer)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var refusal: some View {
        if let message = model.message(for: draftKey) {
            Text(message)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// A control's binding: read what the pane shows, write the daemon.
    private func binding<Value>(
        _ current: Value,
        _ wrap: @escaping (Value) -> ManagementSettingValue
    ) -> Binding<Value> {
        Binding(get: { current }, set: { value in commit(wrap(value)) })
    }

    private func commit(_ value: ManagementSettingValue) {
        Task { await model.apply(section: section, key: row.key, value: value) }
    }

    /// Keep the list type when clearing it, as the browser setup does.
    func commitList(_ items: [String]) {
        commit(.list(items))
    }
}

extension View {
    /// The chrome a text row's field carries, wherever one is drawn.
    ///
    /// Without it a grouped form draws a text row's value as bare right-aligned
    /// text, which on a page of read-only facts reads as one more fact: `Your
    /// name  Sujeeth` said nothing about being editable at all. The bezel is
    /// what says "type here", and it is declared once so the assistant's About
    /// you form and the descriptor form cannot answer the question differently.
    ///
    /// No width of its own: the field fills the value column the form already
    /// laid out, which is what `System Settings > General > About > Name` does.
    /// A fixed measure put an ideal width on the value column and squeezed the
    /// label beside it — `Call the assistant` wrapped to two lines on both the
    /// 460-point assistant form and the 640-point pane — and a ceiling let each
    /// field shrink to its own value, drawing two different boxes in one form.
    func settingsTextField() -> some View {
        textFieldStyle(.roundedBorder)
    }
}

/// A text row. The edit lives in the field until it is committed, so a value is
/// written once rather than on every keystroke.
///
/// While it is focused it owns Escape, which the window asks it for through the
/// shared model: the field puts the daemon's value back and gives up focus, and
/// nothing is written (M34 §3.1).
struct DescriptorTextRow: View {
    let label: String
    let prompt: String
    let value: String
    @ObservedObject var model: SettingsModel
    let key: SettingsDraftKey
    let commit: (ManagementSettingValue) -> Void
    /// What sits beside the field, where the row has something to offer. The
    /// suggestion menu of a choice row whose options are only suggestions is the
    /// one thing that does.
    var accessory: AnyView?
    var suggestions: [ManagementSettingOption] = []

    @State private var draft = DescriptorTextDraft()
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) { entry }
    }

    private var entry: some View {
        HStack(spacing: Spacing.xs) {
            field

            if !suggestions.isEmpty { suggestionMenu }
            if let accessory {
                accessory
            }
        }
    }

    private var field: some View {
        TextField(label, text: $draft.text, prompt: Text(prompt))
            .settingsTextField()
            .labelsHidden()
            .accessibilityLabel(label)
            .focused($focused)
            .onAppear { draft.text = value }
            .onChange(of: value) { _, latest in
                draft.receive(latest, focused: focused)
            }
            .onSubmit { submit(draft.text) }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else {
                    model.beginEditing(key)
                    return
                }

                model.endEditing(key)
                submit(draft.text)
            }
            .onChange(of: model.editReverts) { _, _ in
                guard focused else { return }

                // The daemon's value goes back first, so the focus loss below
                // finds nothing to commit.
                draft.text = value
                focused = false
            }
    }

    /// The shared settings writer normalizes empty text; it rejects JSON null.
    func submit(_ typed: String) {
        guard let change = DescriptorTextDraft(text: typed).submission(comparedTo: value) else { return }

        commit(change)
    }

    private var suggestionMenu: some View {
        Menu(ProductStrings[.settingsChoiceSuggestions]) {
            ForEach(suggestions, id: \.value) { option in
                Button(option.label) { commit(draft.choose(option.value)) }
                    .disabled(option.disabled)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsChoiceSuggestions], label))
    }
}

/// A field keeps unsubmitted typing through background reads; an explicit
/// suggestion is also a local edit, before its settings write returns.
struct DescriptorTextDraft {
    var text = ""

    mutating func receive(_ value: String, focused: Bool) {
        guard !focused else { return }

        text = value
    }

    mutating func choose(_ value: String) -> ManagementSettingValue {
        text = value
        return .text(value)
    }

    func submission(comparedTo saved: String) -> ManagementSettingValue? {
        guard text != saved else { return nil }

        return .text(text)
    }
}

/// A number row: an editable field with the unit beside it, and a stepper.
///
/// The field is what makes a 1-to-240 bound reachable — steppers alone are up to
/// 239 clicks — and the unit is what makes the figure mean something: `End a
/// conversation after 30` says nothing, and `In cents.` under a bare `200` said
/// it in the wrong place (M34 §5).
struct DescriptorNumberRow: View {
    let label: String
    let value: Double
    let minimum: Double?
    let maximum: Double?
    let step: Double
    let measure: NumberMeasure
    let commit: (ManagementSettingValue) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: Spacing.xs) {
                TextField(label, text: $draft)
                    .labelsHidden()
                    .focused($focused)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: SettingsRowMetrics.numberFieldWidth)
                    .onSubmit(submit)
                    .onChange(of: focused) { _, isFocused in
                        guard !isFocused else { return }

                        submit()
                    }
                    .accessibilityLabel(label)
                    .accessibilityValue(measure.text(value, step: step))

                if let suffix = measure.unit, !suffix.isEmpty {
                    Text(suffix).foregroundStyle(Palette.secondary.color)
                }

                // Money reads differently from the figure in the field, so the
                // row says both rather than making the reader do the arithmetic.
                if measure.format == .currencyCents {
                    Text(measure.text(value, step: step)).foregroundStyle(Palette.secondary.color)
                }

                Stepper(label, value: binding, in: range, step: step)
                    .labelsHidden()
                    .accessibilityLabel(label)
                    .accessibilityValue(measure.text(value, step: step))
            }
        }
        .onAppear { draft = NumberRowFormat.text(value, step: step) }
        .onChange(of: value) { _, latest in
            guard !focused else { return }

            draft = NumberRowFormat.text(latest, step: step)
        }
    }

    private var binding: Binding<Double> {
        Binding(get: { value }, set: { commit(.number($0)) })
    }

    /// A field that does not read as a number puts the daemon's value back
    /// rather than writing a zero.
    private func submit() {
        guard let typed = Double(draft.trimmingCharacters(in: .whitespaces)) else {
            draft = NumberRowFormat.text(value, step: step)
            return
        }

        let bounded = min(max(typed, minimum ?? typed), maximum ?? typed)
        draft = NumberRowFormat.text(bounded, step: step)
        guard bounded != value else { return }

        commit(.number(bounded))
    }

    /// The daemon's own bounds where it published them, and an open range
    /// otherwise: the app invents no ceiling of its own. The projection has
    /// already dropped an inverted pair, so the ends are ordered by the time
    /// they reach here and the range needs no unchecked constructor.
    private var range: ClosedRange<Double> {
        (minimum ?? -Double.greatestFiniteMagnitude)...(maximum ?? Double.greatestFiniteMagnitude)
    }
}

/// A number row as a slider, for the one number a person reads off a track: a
/// fraction of its own bounds, labelled as a percentage.
struct DescriptorSliderRow: View {
    let label: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let measure: NumberMeasure
    let commit: (ManagementSettingValue) -> Void

    @State private var live: Double = 0

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: Spacing.xs) {
                Text(measure.text(live, step: step))
                    .foregroundStyle(Palette.secondary.color)
                    .monospacedDigit()

                Slider(value: $live, in: minimum...maximum, step: step) { editing in
                    guard !editing, live != value else { return }

                    commit(.number(live))
                }
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(measure.text(live, step: step))
            }
        }
        .onAppear { live = value }
        .onChange(of: value) { _, latest in live = latest }
    }
}

/// A list row: the values, with one way to remove each and one to add.
///
/// Three peer blocks rather than one run of lines. A list editor is a whole
/// editor inside a single grouped-form row, so the form's row insets stop at
/// its edge: without the rhythm below, its label, its entries and its add field
/// sat on the caption gap and two `Remove` buttons ended up a point apart,
/// which is what the Sandbox pane was showing.
struct DescriptorListRow: View {
    let label: String
    let items: [String]
    let commit: ([String]) -> Void

    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.stackGap) {
            Text(label)

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: SettingsRowMetrics.entryGap) {
                    ForEach(items, id: \.self) { item in
                        LabeledContent(item) {
                            Button(ProductStrings[.settingsListRemove]) {
                                commit(items.filter { $0 != item })
                            }
                            .accessibilityLabel(
                                ProductStrings.commaPair(ProductStrings[.settingsListRemove], item)
                            )
                        }
                    }
                }
            }

            HStack(spacing: Spacing.xs) {
                TextField(label, text: $entry, prompt: Text(ProductStrings[.settingsListAddPrompt]))
                    .labelsHidden()
                    .onSubmit(add)

                Button(ProductStrings[.settingsListAdd], action: add)
                    .disabled(entry.isEmpty)
            }
        }
        // The editor is taller than the single-control rows around it, so it
        // takes a little of the row rhythm itself: without this its label sits
        // hard against the separator above it.
        .padding(.vertical, SettingsRowMetrics.captionGap)
    }

    private func add() {
        let value = entry.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !items.contains(value) else { return }

        commit(items + [value])
        entry = ""
    }
}

/// How a number row prints its value: whole where the step is whole, and at the
/// step's own precision otherwise, so a 0.01 step never renders as 0.
public enum NumberRowFormat {
    public static func text(_ value: Double, step: Double) -> String {
        guard step != step.rounded() else { return String(Int(value.rounded())) }

        let digits = max(0, min(6, Int(ceil(-log10(step)))))

        return String(format: "%.\(digits)f", value)
    }
}
