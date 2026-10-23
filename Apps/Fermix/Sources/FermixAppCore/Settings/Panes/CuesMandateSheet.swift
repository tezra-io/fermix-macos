import SwiftUI

/// The mandate form, as a value (M60 app surface §4.5, stage 3, decision D5).
///
/// One form for an add and an edit, filled from `cues.mandates.choices` and,
/// on an edit, from the mandate's own row. What lives here is what a write
/// sends: every field on an add, and on an edit only the fields changed from
/// the form it opened on, so a duration the form rounds to minutes is never
/// rewritten by an edit that did not touch it.
public struct CueMandateFormState: Equatable, Sendable {
    /// One pinned argument as typed. A value the mandate already held keeps
    /// its own type until its text is changed; a typed value is text.
    public struct Pin: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var key: String
        public var text: String
        let original: ManagementCuePinValue?

        public init(key: String = "", text: String = "", original: ManagementCuePinValue? = nil) {
            id = UUID()
            self.key = key
            self.text = text
            self.original = original
        }

        var value: ManagementCuePinValue {
            if let original, CueMandateFormState.text(of: original) == text { return original }

            return .text(text)
        }
    }

    /// Every key a mandate write carries, which is what a refusal can name.
    public static let fields: Set<String> = [
        "name", "job", "mode", "tools", "read_tools", "approve_within_s", "max_cue_age_s", "validator",
        "interpreter", "validator_env", "idempotency_arg", "unpinned", "pin_args"
    ]

    /// The keys an add sends only where they hold something.
    static let optionKeys: Set<String> = ["validator", "interpreter", "validator_env", "idempotency_arg", "unpinned", "pin_args"]

    /// The mandate an edit changes; nil on an add.
    public let original: ManagementCueMandate?
    public var name = ""
    public var job = ""
    public var mode: ManagementCueMandateMode = .approve
    /// Every tool chosen, whether it reads or changes things.
    public var tools: Set<String> = []
    public var waits = "30"
    public var actsOn = "15"
    public var validator = ""
    public var interpreter = ""
    public var validatorEnv: [String] = []
    public var idempotencyArg = ""
    public var unpinned: [String] = []
    public var pins: [Pin] = []
    public var moreOptions = false
    public var refusal: CueRefusal?

    public init() {
        original = nil
    }

    public init(editing mandate: ManagementCueMandate) {
        original = mandate
        name = mandate.name
        job = mandate.job.id
        mode = mandate.mode
        tools = Set(mandate.tools + mandate.readTools)
        waits = String(mandate.approveWithinS / 60)
        actsOn = String(mandate.maxCueAgeS / 60)
        validator = mandate.validator?.path ?? ""
        interpreter = mandate.validator?.interpreter ?? ""
        validatorEnv = mandate.validator?.env ?? []
        idempotencyArg = mandate.idempotencyArg ?? ""
        unpinned = mandate.unpinned
        pins = mandate.pinArgs.map { Pin(key: $0.key, text: Self.text(of: $0.value), original: $0.value) }
        moreOptions = mandate.validator != nil || mandate.idempotencyArg != nil || !mandate.unpinned.isEmpty
            || !mandate.pinArgs.isEmpty
    }

    static func text(of value: ManagementCuePinValue) -> String {
        switch value {
        case .text(let text): return text
        case .flag(let flag): return flag ? "true" : "false"
        case .number(let number): return number == number.rounded() ? String(Int(number)) : String(number)
        }
    }

    /// Whether the form holds enough to send: a name, a task and two whole
    /// numbers of minutes.
    public var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !job.isEmpty
            && Int(waits.trimmingCharacters(in: .whitespaces)) != nil
            && Int(actsOn.trimmingCharacters(in: .whitespaces)) != nil
    }

    /// What a write sends. A tool goes to `read_tools` where the daemon's
    /// choices mark it read only, or where the mandate already had it there
    /// and the choices no longer list it.
    public func values(choices: ManagementCueMandateChoices?) -> [String: ManagementCueValue] {
        let every = allValues(choices: choices)
        guard let original else { return every.filter { !Self.optionKeys.contains($0.key) || !Self.isEmpty($0.value) } }

        let opened = CueMandateFormState(editing: original).allValues(choices: choices)
        return every.filter { opened[$0.key] != $0.value }
    }

    public func refusal(for key: String) -> String? {
        refusal?.field == key ? refusal?.sentence : nil
    }

    /// A refusal that names none of the form's fields, said under the form.
    public var formRefusal: String? {
        guard let refusal else { return nil }
        guard let field = refusal.field, Self.fields.contains(field) else { return refusal.sentence }

        return nil
    }

    private func allValues(choices: ManagementCueMandateChoices?) -> [String: ManagementCueValue] {
        let readOnly = Set(choices?.tools.filter(\.readOnly).map(\.name) ?? [])
        let listed = Set(choices?.tools.map(\.name) ?? [])
        let reads = tools.filter { readOnly.contains($0) || (!listed.contains($0) && original?.readTools.contains($0) == true) }

        return [
            "job": .setting(.text(job)),
            "mode": .setting(.text(mode.wireValue)),
            "tools": .setting(.list(tools.subtracting(reads).sorted())),
            "read_tools": .setting(.list(reads.sorted())),
            "approve_within_s": .setting(.number(Double(minutes(waits) * 60))),
            "max_cue_age_s": .setting(.number(Double(minutes(actsOn) * 60))),
            "validator": .setting(.text(validator.trimmingCharacters(in: .whitespaces))),
            "interpreter": .setting(.text(interpreter.trimmingCharacters(in: .whitespaces))),
            "validator_env": .setting(.list(validatorEnv)),
            "idempotency_arg": .setting(.text(idempotencyArg.trimmingCharacters(in: .whitespaces))),
            "unpinned": .setting(.list(unpinned)),
            "pin_args": .pins(pins.filter { !$0.key.isEmpty }.map { ManagementCuePin(key: $0.key, value: $0.value) })
        ]
    }

    private func minutes(_ text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static func isEmpty(_ value: ManagementCueValue) -> Bool {
        switch value {
        case .setting(.text(let text)): return text.isEmpty
        case .setting(.list(let items)): return items.isEmpty
        case .pins(let pins): return pins.isEmpty
        case .setting: return false
        }
    }
}

/// The words of a mandate's detail, from its published fields.
public enum CueMandateDetailWords {
    public static func duration(seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]

        return formatter.string(from: TimeInterval(seconds)) ?? String(seconds)
    }

    public static func waits(_ mandate: ManagementCueMandate) -> String {
        String(format: ProductStrings[.cuesMandateWaitsFormat], duration(seconds: mandate.approveWithinS))
    }

    public static func actsOn(_ mandate: ManagementCueMandate) -> String {
        guard mandate.maxCueAgeS > 0 else { return ProductStrings[.cuesMandateActsOnAny] }

        return String(format: ProductStrings[.cuesMandateActsOnFormat], duration(seconds: mandate.maxCueAgeS))
    }

    /// Where Approval would be, in the daemon's words alone: the load check's
    /// sentence for a mandate that did not load, the approval's own detail
    /// where it has one, and the row's status sentence otherwise. Nothing is
    /// composed here from the approval's fields.
    public static func approval(_ mandate: ManagementCueMandate) -> String {
        mandate.load.sentence ?? mandate.approval.detail ?? mandate.statusSentence
    }

    public static func lastDay(_ counts: ManagementCueMandate.Counts) -> String {
        let parts = [
            String(format: ProductStrings[.cuesMandateAllowedFormat], counts.allowed),
            String(format: ProductStrings[.cuesMandateProposedFormat], counts.proposed),
            String(format: ProductStrings[.cuesMandateRefusedFormat], counts.refused)
        ]

        return parts.dropFirst().reduce(parts[0]) { ProductStrings.middot($0, $1) }
    }

    public static func list(_ names: [String]) -> String {
        names.isEmpty ? ProductStrings[.cuesNone] : names.joined(separator: ", ")
    }
}

/// What a mandate's detail asks in place.
enum CueMandateQuestion: Equatable {
    case approve
    case remove
}

/// A mandate's detail (§4.5): its task, mode and tools, how long a proposal
/// waits, its validator, its approval and the day's counts. Approve and
/// remove are asked in place.
struct CuesMandateDetailPage: View {
    let name: String
    let approving: Bool
    @ObservedObject var model: SettingsModel
    let edit: (ManagementCueMandate) -> Void
    let done: () -> Void

    @State private var asking: CueMandateQuestion?
    @State private var busy = false
    @State private var refusal: String?

    private var mandate: ManagementCueMandate? { model.cueMandate(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let mandate {
                heading(mandate)
                CuesPageForm { facts(mandate) }
            } else {
                CueNote(text: ProductStrings[.cuesMandateGone])
            }

            if let refusal {
                CueNote(text: refusal, attention: true)
            }
            footer
        }
        .onAppear {
            guard approving, let mandate, CueMandateProjection.offersApprove(mandate) else { return }

            asking = .approve
        }
    }

    private func heading(_ mandate: ManagementCueMandate) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            VendorMarkView(symbol: "checkmark.shield", size: IntegrationMetrics.tileSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(mandate.name)
                    .fermixType(Typography.sheetTitle)
                    .foregroundStyle(Palette.ink.color)
                CueNote(text: mandate.statusSentence)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Spacer(minLength: Spacing.s)

            if CueMandateProjection.switchShown(mandate) {
                Toggle(mandate.name, isOn: Binding(get: { mandate.enabled }, set: { setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.integrationEnabled], mandate.name))
            }
        }
    }

    @ViewBuilder
    private func facts(_ mandate: ManagementCueMandate) -> some View {
        LabeledContent(ProductStrings[.cuesMandateTask]) { CueValue(text: mandate.job.name ?? mandate.job.id) }
        LabeledContent(ProductStrings[.cuesMandateMode]) {
            VStack(alignment: .trailing, spacing: 2) {
                if let mode = CueMandateProjection.modeTitle(mandate.mode) {
                    CueValue(text: mode)
                }
                // Acting without asking is a consequence the owner must read.
                CueNote(text: mandate.consentSentence, attention: mandate.mode == .auto)
            }
        }
        LabeledContent(ProductStrings[.cuesMandateTools]) { CueValue(text: CueMandateDetailWords.list(mandate.tools)) }
        LabeledContent(ProductStrings[.cuesMandateReadTools]) { CueValue(text: CueMandateDetailWords.list(mandate.readTools)) }
        LabeledContent(ProductStrings[.cuesMandateWaits]) { CueValue(text: CueMandateDetailWords.waits(mandate)) }
        LabeledContent(ProductStrings[.cuesMandateActsOn]) { CueValue(text: CueMandateDetailWords.actsOn(mandate)) }
        LabeledContent(ProductStrings[.cuesMandateValidator]) {
            CueValue(text: mandate.validator?.path ?? ProductStrings[.cuesNone])
        }
        LabeledContent(ProductStrings[.cuesMandateApproval]) { CueValue(text: CueMandateDetailWords.approval(mandate)) }
        LabeledContent(ProductStrings[.cuesMandateLastDay]) { CueValue(text: CueMandateDetailWords.lastDay(mandate.counts)) }
    }

    /// Approve, Edit, `Remove mandate…` and `Done`; or the question asked in
    /// their place.
    @ViewBuilder
    private var footer: some View {
        switch asking {
        case .approve:
            CueQuestion(
                text: String(format: ProductStrings[.cuesMandateApproveConfirm], name),
                action: .cuesMandateApprove,
                busy: busy,
                cancel: { asking = nil },
                confirm: approve
            )
        case .remove:
            CueQuestion(
                text: String(format: ProductStrings[.cuesMandateRemoveConfirm], name),
                action: .cuesRemoveDo,
                busy: busy,
                cancel: { asking = nil },
                confirm: remove
            )
        case nil:
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            if let mandate, CueMandateProjection.offersApprove(mandate) {
                Button(ProductStrings[.cuesMandateApprove]) { asking = .approve }
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesMandateApprove], name))
            }
            if let mandate {
                Button(ProductStrings[.cuesEdit]) { edit(mandate) }
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesEdit], name))
            }
            Button(ProductStrings[.cuesMandateRemove]) { asking = .remove }
                .disabled(mandate == nil || busy)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.cuesMandateRemove], name))

            Spacer(minLength: 0)

            PrimaryAction(ProductStrings[.settingsSheetDone], size: .row, action: done)
        }
        .buttonStyle(SecondaryButtonStyle(.row))
    }

    private func setEnabled(_ isOn: Bool) {
        Task { refusal = await model.setCueMandateEnabled(isOn, name: name)?.sentence }
    }

    private func approve() {
        busy = true
        Task {
            defer { busy = false }
            refusal = await model.approveCueMandate(name)?.sentence
            asking = nil
        }
    }

    private func remove() {
        busy = true
        Task {
            defer { busy = false }
            guard let refused = await model.removeCueMandate(name) else {
                done()
                return
            }

            asking = nil
            refusal = refused.sentence
        }
    }
}

/// The mandate editor (§4.5, stage 3): the task, the mode, the tools tagged
/// by what they do, the two durations in minutes, and under More options the
/// validator, the call id argument, the skill paths and the pinned
/// arguments. Every refusal is the daemon's sentence under the field it
/// names.
struct CuesMandateFormPage: View {
    let page: CuesSheetPage
    @Binding var form: CueMandateFormState
    @ObservedObject var model: SettingsModel
    /// The mandate the daemon took, by name.
    let done: (String) -> Void
    let back: () -> Void

    @State private var sending = false

    private var choices: ManagementCueMandateChoices? { model.cueMandateChoices.value }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            heading
            CuesPageForm { rows }

            if case .unavailable(let sentence) = model.cueMandateChoices {
                CueNote(text: sentence, attention: true)
            }
            if let refused = form.formRefusal {
                CueNote(text: refused, attention: true)
            }
            buttons
        }
        .task { await model.refreshCueMandateChoices() }
    }

    @ViewBuilder
    private var heading: some View {
        if let original = form.original {
            IntegrationPageHeader(title: ProductStrings[.cuesEdit], parent: original.name, back: back)
        } else {
            Text(ProductStrings[.cuesMandateAddTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
        }
    }

    @ViewBuilder
    private var rows: some View {
        nameRow
        taskRow

        Picker(ProductStrings[.cuesMandateMode], selection: $form.mode) {
            Text(ProductStrings[.cuesMandateModeApprove]).tag(ManagementCueMandateMode.approve)
            Text(ProductStrings[.cuesMandateModeAuto]).tag(ManagementCueMandateMode.auto)
        }
        .pickerStyle(.segmented)
        error("mode")

        CuesMandateToolRows(tools: $form.tools, choices: choices)
        error("tools")
        error("read_tools")

        minutesRow(.cuesMandateWaits, text: $form.waits, key: "approve_within_s")
        minutesRow(.cuesMandateActsOn, text: $form.actsOn, key: "max_cue_age_s")
        CueNote(text: ProductStrings[.cuesMandateActsOnFooter])

        AdvancedRowsToggle(shown: $form.moreOptions, title: .cuesMoreOptions)
        if form.moreOptions {
            CuesMandateOptionRows(form: $form)
        }
    }

    @ViewBuilder
    private var nameRow: some View {
        if let original = form.original {
            LabeledContent(ProductStrings[.cuesMandateName]) { CueValue(text: original.name) }
        } else {
            LabeledContent(ProductStrings[.cuesMandateName]) {
                TextField(ProductStrings[.cuesMandateName], text: $form.name)
                    .settingsTextField()
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings[.cuesMandateName])
            }
            CueNote(text: ProductStrings[.cuesMandateNameFooter])
            error("name")
        }
    }

    @ViewBuilder
    private var taskRow: some View {
        Picker(ProductStrings[.cuesMandateTask], selection: $form.job) {
            if !(choices?.jobs.contains { $0.id == form.job } ?? false) {
                Text(form.job.isEmpty ? ProductStrings[.cuesMandateChooseTask] : form.job).tag(form.job)
            }
            ForEach(choices?.jobs ?? [], id: \.id) { job in
                Text(job.name).tag(job.id)
            }
        }
        error("job")
    }

    private func minutesRow(_ label: ProductStringKey, text: Binding<String>, key: String) -> some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            LabeledContent(ProductStrings[label]) {
                HStack(spacing: Spacing.xs) {
                    TextField(ProductStrings[label], text: text)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: SettingsRowMetrics.numberFieldWidth)
                        .accessibilityLabel(ProductStrings[label])
                    Text(ProductStrings[.cuesMinutes]).foregroundStyle(Palette.secondary.color)
                }
            }
            error(key)
        }
    }

    @ViewBuilder
    private func error(_ key: String) -> some View {
        if let refused = form.refusal(for: key) {
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
                ProductStrings[form.original == nil ? .cuesMandatesAdd : .settingsSheetDone],
                size: .row,
                action: send
            )
            .disabled(sending || !form.isComplete)
        }
    }

    private func send() {
        guard !sending, form.isComplete else { return }

        sending = true
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let values = form.values(choices: choices)
        let editing = form.original != nil
        Task {
            defer { sending = false }
            let refused = editing
                ? await model.updateCueMandate(name, values: values)
                : await model.addCueMandate(name, values: values)
            guard let refused else {
                done(name)
                return
            }

            form.refusal = refused
        }
    }
}

/// The tools a mandate may name, each a switch, tagged with what it does.
/// A tool the mandate names that the choices no longer list is kept, so an
/// edit never drops it unasked.
struct CuesMandateToolRows: View {
    @Binding var tools: Set<String>
    let choices: ManagementCueMandateChoices?

    var body: some View {
        LabeledContent(ProductStrings[.cuesMandateTools]) {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.entryGap) {
                if offered.isEmpty, unlisted.isEmpty {
                    CueNote(text: ProductStrings[.cuesMandateNoTools])
                }
                ForEach(offered, id: \.name) { tool in
                    Toggle(isOn: chosen(tool.name)) {
                        HStack(spacing: Spacing.xs) {
                            Text(tool.title ?? tool.name)
                            CueNote(text: ProductStrings[tool.readOnly ? .mcpToolReadOnly : .mcpToolChanges])
                        }
                    }
                }
                ForEach(unlisted, id: \.self) { name in
                    Toggle(name, isOn: chosen(name))
                }
            }
        }
    }

    private var offered: [ManagementCueMandateChoices.Tool] { choices?.tools ?? [] }

    private var unlisted: [String] {
        let listed = Set(offered.map(\.name))
        return tools.filter { !listed.contains($0) }.sorted()
    }

    private func chosen(_ name: String) -> Binding<Bool> {
        Binding(
            get: { tools.contains(name) },
            set: { isOn in
                if isOn { tools.insert(name) } else { tools.remove(name) }
            }
        )
    }
}

/// More options: the validator, its interpreter and environment names, the
/// argument Fermix sets as the call's id, the skill paths the job writes,
/// and the pinned arguments as key and value rows.
struct CuesMandateOptionRows: View {
    @Binding var form: CueMandateFormState

    var body: some View {
        textRow(.cuesMandateValidator, text: $form.validator, key: "validator")
        textRow(.cuesMandateInterpreter, text: $form.interpreter, key: "interpreter")
        DescriptorListRow(label: ProductStrings[.cuesMandateValidatorEnv], items: form.validatorEnv) { form.validatorEnv = $0 }
        error("validator_env")
        CueNote(text: ProductStrings[.cuesMandateValidatorNote])

        textRow(.cuesMandateIdempotency, text: $form.idempotencyArg, key: "idempotency_arg")
        CueNote(text: ProductStrings[.cuesMandateIdempotencyFooter])

        DescriptorListRow(label: ProductStrings[.cuesMandateUnpinned], items: form.unpinned) { form.unpinned = $0 }
        error("unpinned")

        pinRows
        error("pin_args")
    }

    private func textRow(_ label: ProductStringKey, text: Binding<String>, key: String) -> some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            LabeledContent(ProductStrings[label]) {
                TextField(ProductStrings[label], text: text)
                    .settingsTextField()
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings[label])
            }
            error(key)
        }
    }

    private var pinRows: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.entryGap) {
            Text(ProductStrings[.cuesMandatePins])

            ForEach($form.pins) { $pin in
                HStack(spacing: Spacing.xs) {
                    TextField(ProductStrings[.cuesMandatePinKey], text: $pin.key)
                        .settingsTextField()
                        .accessibilityLabel(ProductStrings[.cuesMandatePinKey])
                    TextField(ProductStrings[.cuesMandatePinValue], text: $pin.text)
                        .settingsTextField()
                        .accessibilityLabel(ProductStrings[.cuesMandatePinValue])
                    Button(ProductStrings[.settingsListRemove]) { form.pins.removeAll { $0.id == pin.id } }
                        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsListRemove], pin.key))
                }
            }

            Button(ProductStrings[.cuesMandateAddPin]) { form.pins.append(CueMandateFormState.Pin()) }
        }
    }

    @ViewBuilder
    private func error(_ key: String) -> some View {
        if let refused = form.refusal(for: key) {
            CueNote(text: refused, attention: true)
        }
    }
}
