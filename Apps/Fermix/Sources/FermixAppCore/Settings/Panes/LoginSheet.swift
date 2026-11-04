import SwiftUI

/// Which login a sheet is about: a new one, or one already saved.
enum LoginSheetMode: Identifiable, Equatable {
    case add
    case edit(SavedLogin)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let login): return login.id.uuidString
        }
    }

    /// The field the sheet opens on: the site for a new login, the username
    /// for a saved one, whose site is fixed.
    var firstField: LoginField {
        switch self {
        case .add: return .site
        case .edit: return .username
        }
    }
}

/// The sheet's fields, in the order they are drawn and refused.
enum LoginField: Hashable, CaseIterable {
    case site, username, password
}

/// What a save asks the store to do, built from what was typed.
enum LoginSaveRequest: Equatable, Sendable {
    case add(site: String, username: String, password: LoginSecret)
    /// A nil password keeps the saved one.
    case edit(SavedLogin, username: String, password: LoginSecret?)
}

enum LoginSaveOutcome: Equatable, Sendable {
    case saved(SavedLogin)
    case refused(LoginRefusals)
}

/// Why a save was refused, as the sentences the sheet draws under each field,
/// plus the one that belongs to no field (the keychain, the cap, a login that
/// is gone). The first refusal for a field wins.
struct LoginRefusals: Equatable, Sendable {
    private(set) var site: String?
    private(set) var username: String?
    private(set) var password: String?
    private(set) var general: String?

    init() {}

    init(_ errors: [LoginStoreError]) {
        for error in errors {
            record(error)
        }
    }

    var isEmpty: Bool { site == nil && username == nil && password == nil && general == nil }

    /// The first refused field, in drawing order, which takes the focus.
    var firstField: LoginField? {
        LoginField.allCases.first { self[$0] != nil }
    }

    subscript(field: LoginField) -> String? {
        switch field {
        case .site: return site
        case .username: return username
        case .password: return password
        }
    }

    /// Typing in a field answers its refusal; the others stand.
    mutating func clear(_ field: LoginField) {
        switch field {
        case .site: site = nil
        case .username: username = nil
        case .password: password = nil
        }
    }

    /// The sentence for any store refusal, wherever it is drawn.
    static func sentence(for error: LoginStoreError) -> String {
        switch error {
        case .site: return ProductStrings[.settingsBrowserLoginSiteRefused]
        case .siteTaken: return ProductStrings[.settingsBrowserLoginSiteTaken]
        case .usernameRequired: return ProductStrings[.settingsBrowserLoginUsernameRequired]
        case .passwordTooShort: return ProductStrings[.settingsBrowserLoginTooShort]
        case .full: return String(format: ProductStrings[.settingsBrowserLoginsFullFormat], LoginStoreRules.maximumLogins)
        case .notFound: return ProductStrings[.settingsBrowserLoginGone]
        case .unavailable, .timedOut:
            guard let reason = LoginsUnavailable(error) else {
                preconditionFailure("\(error) is an availability refusal")
            }

            return reason.sentence
        }
    }

    private static func field(for error: LoginStoreError) -> LoginField? {
        switch error {
        case .site, .siteTaken: return .site
        case .usernameRequired: return .username
        case .passwordTooShort: return .password
        case .full, .notFound, .unavailable, .timedOut: return nil
        }
    }

    private mutating func record(_ error: LoginStoreError) {
        let sentence = Self.sentence(for: error)

        switch Self.field(for: error) {
        case .site: site = site ?? sentence
        case .username: username = username ?? sentence
        case .password: password = password ?? sentence
        case nil: general = general ?? sentence
        }
    }
}

/// What one login sheet holds, and where it is in its one job.
///
/// A value rather than loose view state, so the rules are written once and
/// proven without a window: one save or delete in flight at a time, a refusal
/// keeps every value, a saved login drops the password, and cancel and close
/// drop it too. The password lives here only while it is being typed; the
/// store gets it as a `LoginSecret` and nothing else keeps it.
struct LoginDraft: Equatable {
    enum Phase: Equatable {
        case editing
        case saving
        /// The sheet asks whether to delete, in place of the form: one popup
        /// that changes what it says, never a second one over it.
        case confirmingDelete
        case deleting
        /// Saved or deleted; the sheet closes.
        case finished
    }

    let mode: LoginSheetMode
    var site: String
    var username: String
    var password = ""
    private(set) var refusals = LoginRefusals()
    /// Why a delete was refused, drawn under the question.
    private(set) var deleteRefusal: String?
    private(set) var phase = Phase.editing

    init(mode: LoginSheetMode) {
        self.mode = mode

        switch mode {
        case .add:
            site = ""
            username = ""
        case .edit(let login):
            site = login.site
            username = login.username
        }
    }

    /// Whether the store is answering, or the sheet is done: every control
    /// waits, and a second press sends nothing.
    var isBusy: Bool {
        switch phase {
        case .saving, .deleting, .finished: return true
        case .editing, .confirmingDelete: return false
        }
    }

    /// The login being edited; nil while adding.
    var editing: SavedLogin? {
        guard case .edit(let login) = mode else { return nil }

        return login
    }

    /// The question the delete asks, naming the site.
    static func deleteQuestion(for login: SavedLogin) -> String {
        String(format: ProductStrings[.settingsBrowserLoginDeleteTitle], login.site)
    }

    /// The request to send, or nil while one is already in flight.
    mutating func beginSave() -> LoginSaveRequest? {
        guard phase == .editing else { return nil }

        phase = .saving
        switch mode {
        case .add:
            return .add(site: site, username: username, password: LoginSecret(password))
        case .edit(let login):
            return .edit(login, username: username, password: password.isEmpty ? nil : LoginSecret(password))
        }
    }

    mutating func finishSave(_ outcome: LoginSaveOutcome) {
        precondition(phase == .saving, "a save finishes only after it began")

        switch outcome {
        case .saved:
            refusals = LoginRefusals()
            clearPassword()
            phase = .finished
        case .refused(let refused):
            refusals = refused
            phase = .editing
        }
    }

    mutating func edited(_ field: LoginField) {
        refusals.clear(field)
    }

    mutating func askDelete() {
        precondition(editing != nil, "only a saved login can be deleted")
        guard phase == .editing else { return }

        deleteRefusal = nil
        phase = .confirmingDelete
    }

    /// The question's Cancel: back to the form, with everything as it was.
    mutating func keepLogin() {
        guard phase == .confirmingDelete else { return }

        deleteRefusal = nil
        phase = .editing
    }

    /// The login to delete, or nil unless the question is up and idle.
    mutating func beginDelete() -> SavedLogin? {
        guard let login = editing, phase == .confirmingDelete else { return nil }

        phase = .deleting
        deleteRefusal = nil
        return login
    }

    mutating func finishDelete(refusal: String?) {
        precondition(phase == .deleting, "a delete finishes only after it began")

        guard let refusal else {
            clearPassword()
            phase = .finished
            return
        }

        deleteRefusal = refusal
        phase = .confirmingDelete
    }

    /// Cancel and the sheet going away both drop what was typed into the
    /// password field.
    mutating func clearPassword() {
        password = ""
    }
}

/// Add or edit one website login (M84 §11).
///
/// One sheet for both: adding types the site, editing fixes it, fills the
/// username and leaves the password empty to keep the saved one. Save checks
/// every rule at once and says why under each refused field, keeping all of
/// it; the first refused field takes the focus. The password goes through the
/// one secure input the product has and is dropped on save, cancel and close.
/// Return saves and Escape cancels; while the store answers every control
/// waits, so nothing is sent twice.
struct LoginSheet: View {
    let model: WebsiteLoginsModel
    let dismiss: () -> Void

    @State private var draft: LoginDraft
    @FocusState private var focus: LoginField?

    init(mode: LoginSheetMode, model: WebsiteLoginsModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        _draft = State(initialValue: LoginDraft(mode: mode))
    }

    var body: some View {
        content
            .padding(WindowMetrics.contentPadding)
            .frame(width: SheetMetrics.credentialWidth)
            .onAppear(perform: focusFirstField)
            // Closed some other way than Cancel: the window went, or the pane.
            .onDisappear { draft.clearPassword() }
            .onChange(of: draft.site) { _, _ in draft.edited(.site) }
            .onChange(of: draft.username) { _, _ in draft.edited(.username) }
            .onChange(of: draft.password) { _, _ in draft.edited(.password) }
    }

    @ViewBuilder
    private var content: some View {
        if let login = draft.editing, draft.phase == .confirmingDelete || draft.phase == .deleting {
            deleteQuestion(login)
        } else {
            form
        }
    }

    // MARK: The form

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[draft.editing == nil ? .settingsBrowserLoginAddTitle : .settingsBrowserLoginEditTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)

            // The labels in a trailing column beside their fields, which is
            // how a Mac sheet of labelled fields reads. A grid, not a `Form`:
            // every `Form` in the app is a grouped pane form. No field has a
            // prompt: the label beside it already names it, and a field's
            // own title as its prompt would say it twice.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                siteRow
                usernameRow
                passwordRow
            }
            .disabled(draft.isBusy)

            if let general = draft.refusals.general {
                LoginNote(refusal: general)
            }

            formButtons
        }
    }

    private var siteRow: some View {
        GridRow {
            LoginFieldLabel(title: ProductStrings[.settingsBrowserLoginSite])

            if let login = draft.editing {
                Text(login.site)
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsBrowserLoginSite], login.site))
            } else {
                VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                    TextField(ProductStrings[.settingsBrowserLoginSite], text: $draft.site, prompt: Text(verbatim: ""))
                        .settingsTextField()
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .focused($focus, equals: .site)
                        .onSubmit(save)

                    LoginNote(refusal: draft.refusals.site, hint: ProductStrings[.settingsBrowserLoginSiteHint])
                }
            }
        }
    }

    private var usernameRow: some View {
        GridRow {
            LoginFieldLabel(title: ProductStrings[.settingsBrowserLoginUsername])

            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                TextField(ProductStrings[.settingsBrowserLoginUsername], text: $draft.username, prompt: Text(verbatim: ""))
                    .settingsTextField()
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .onSubmit(save)

                LoginNote(refusal: draft.refusals.username)
            }
        }
    }

    private var passwordRow: some View {
        GridRow {
            LoginFieldLabel(title: ProductStrings[.settingsBrowserLoginPassword])

            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                // No prompt: the label beside it already says Password.
                SecretInput(label: ProductStrings[.settingsBrowserLoginPassword], value: $draft.password, onSubmit: save, prompt: "")
                    .focused($focus, equals: .password)

                LoginNote(
                    refusal: draft.refusals.password,
                    hint: draft.editing == nil ? nil : ProductStrings[.settingsBrowserLoginKeepPassword]
                )
            }
        }
    }

    /// `Delete…` on the leading edge of an edit, then Cancel and the verb.
    /// Only a request in flight disables them.
    private var formButtons: some View {
        HStack(spacing: Spacing.s) {
            if draft.editing != nil {
                DestructiveSheetButton(
                    title: ProductStrings[.settingsBrowserLoginDelete],
                    accessibilityName: ProductStrings.commaPair(ProductStrings[.settingsBrowserLoginDelete], draft.site)
                ) { draft.askDelete() }
            }

            Spacer(minLength: 0)

            if draft.phase == .saving {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }

            Button(ProductStrings[.settingsSheetCancel], action: cancel)
                .buttonStyle(SecondaryButtonStyle(.row))
                .keyboardShortcut(.cancelAction)

            PrimaryAction(
                ProductStrings[draft.editing == nil ? .settingsBrowserLoginAddAction : .settingsSheetDone],
                size: .row,
                action: save
            )
        }
        .disabled(draft.isBusy)
    }

    // MARK: The delete question

    /// The question in place of the form. Escape is its Cancel, which goes
    /// back to the form; Return answers nothing, so only a press deletes.
    private func deleteQuestion(_ login: SavedLogin) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                Text(LoginDraft.deleteQuestion(for: login))
                    .fermixType(Typography.sheetTitle)
                    .foregroundStyle(Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(ProductStrings[.settingsBrowserLoginDeleteBody])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let refusal = draft.deleteRefusal {
                LoginNote(refusal: refusal)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                if draft.phase == .deleting {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }

                Button(ProductStrings[.settingsSheetCancel]) { draft.keepLogin() }
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)

                DestructiveSheetButton(
                    title: ProductStrings[.settingsBrowserLoginDeleteAction],
                    accessibilityName: ProductStrings.commaPair(ProductStrings[.settingsBrowserLoginDeleteAction], login.site),
                    action: delete
                )
            }
            .disabled(draft.isBusy)
        }
    }

    // MARK: Actions

    /// A turn later, as `SecretEntry` does: focus asked for while the sheet is
    /// still coming up is lost to it.
    private func focusFirstField() {
        let field = draft.mode.firstField
        DispatchQueue.main.async { focus = field }
    }

    /// Return in any field and the verb both land here; the draft sends one
    /// request at a time. The store runs off the main actor, so the sheet
    /// keeps drawing while it answers.
    private func save() {
        let returning = focus
        guard let request = draft.beginSave() else { return }

        Task {
            draft.finishSave(await model.save(request))
            guard draft.phase == .finished else {
                focus = draft.refusals.firstField ?? returning
                return
            }

            dismiss()
        }
    }

    private func delete() {
        guard let login = draft.beginDelete() else { return }

        Task {
            draft.finishDelete(refusal: await model.delete(login))
            guard draft.phase == .finished else { return }

            dismiss()
        }
    }

    private func cancel() {
        guard !draft.isBusy else { return }

        draft.clearPassword()
        dismiss()
    }
}

/// The line under a field: why it was refused, or else its hint.
struct LoginNote: View {
    let refusal: String?
    var hint: String?

    var body: some View {
        if let refusal {
            Text(refusal)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.error.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        } else if let hint {
            Text(hint)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A field's label in the sheet's label column. Hidden from VoiceOver, which
/// reads the same name from the field itself.
struct LoginFieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundStyle(Palette.ink.color)
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(true)
    }
}

/// A sheet button that deletes: the secondary capsule with its label in the
/// error colour, the destructive role, and a name that says what it deletes.
struct DestructiveSheetButton: View {
    let title: String
    let accessibilityName: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title).foregroundStyle(Palette.error.color)
        }
        .buttonStyle(SecondaryButtonStyle(.row))
        .accessibilityLabel(accessibilityName)
    }
}
