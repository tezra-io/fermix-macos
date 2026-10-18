import SwiftUI

/// Where a server's code runs, which is the form's deciding control.
public enum MCPServerPlace: Hashable, Sendable, CaseIterable {
    case remote
    case local

    public var titleKey: ProductStringKey {
        switch self {
        case .remote: return .mcpAddRemote
        case .local: return .mcpAddLocal
        }
    }

    init(_ transport: ManagementMCPTransport) {
        self = transport == .http ? .remote : .local
    }
}

/// The three sign-in choices of a remote server, as the pop-up words them.
public enum MCPSignInChoice: Hashable, Sendable, CaseIterable {
    case automatic
    case apiKey
    case none

    public var titleKey: ProductStringKey {
        switch self {
        case .automatic: return .mcpSignInAutomatic
        case .apiKey: return .mcpSignInAPIKey
        case .none: return .mcpSignInNone
        }
    }

    var mode: ManagementMCPAuthMode {
        switch self {
        case .automatic: return .auto
        case .apiKey: return .header
        case .none: return .none
        }
    }

    init(_ mode: ManagementMCPAuthMode) {
        switch mode {
        case .header: self = .apiKey
        case .none: self = .none
        case .auto, .unrecognized: self = .automatic
        }
    }
}

/// One named value on the form: a variable or a header. A value already
/// stored is drawn as dots with `Replace` and is never read back.
public struct MCPFormEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var value: String
    /// The daemon holds a value for this name.
    public var stored: Bool
    public var replacing: Bool

    public init(name: String = "", value: String = "", stored: Bool = false) {
        id = UUID()
        self.name = name
        self.value = value
        self.stored = stored
        replacing = false
    }

    /// Whether the value column is the dots rather than a field.
    public var showsStored: Bool { stored && !replacing }
}

/// The daemon's reading of the text the URL or the command field held: the
/// lines the form draws for it while the field still holds that text.
public struct MCPDraftReading: Equatable, Sendable {
    /// The field's text, as it was read.
    public let text: String
    public let consent: String
    /// `Runs <program>`, or the sentence for a program this Mac does not
    /// have. Nil while the daemon does not know the program yet.
    public let commandSentence: String?
    public let resolved: Bool
}

/// The add and edit form, as a value (M74 §4.2, §4.6).
///
/// The rules live here rather than in the view, so they are proven without a
/// window: what a draft fills in, what an add sends, what an edit changes,
/// which values go to the Keychain and under which id, and where a refusal is
/// drawn. Names travel on the `mcp.servers.*` methods; a value travels alone
/// in `secret.set`, or stays with the daemon under the draft id of the paste
/// that carried it.
public struct MCPServerForm: Equatable, Sendable {
    /// The two headers a key is usually sent in, which the `Header` combo box
    /// offers. `Authorization` carries it as `Bearer <key>`.
    public static let keyHeaders = ["Authorization", "X-API-Key"]

    public var place: MCPServerPlace = .remote
    public var url = ""
    public var commandLine = ""
    public var name = ""
    /// The owner typed the name, so a draft no longer fills it.
    public var nameEdited = false
    /// Fixed once the server exists, because the agent knows its tools by it.
    public var nameFixed = false
    public var signIn: MCPSignInChoice = .automatic
    public var keyHeader = MCPServerForm.keyHeaders[0]
    public var key = MCPFormEntry()
    public var variables: [MCPFormEntry] = []
    public var headers: [MCPFormEntry] = []
    public var clientID = ""
    public var clientSecret = MCPFormEntry()
    public var workingFolder = ""
    public var moreOptions = false
    /// Where the code runs and what leaves this Mac, in the daemon's words:
    /// the server's own line on an edit.
    public var consent: String?
    /// The last draft of the URL or the command field.
    public var reading: MCPDraftReading?
    /// The paste whose values the add stores for the names it declares.
    public var draftId: String?
    public var errors: [MCPFormField: String] = [:]
    /// A refusal that named no input on this form.
    public var refusal: String?

    public init() {}

    /// The form for a server that exists, filled from its row, with every
    /// stored value as dots.
    public init(editing server: ManagementMCPServer) {
        place = MCPServerPlace(server.transport)
        url = server.url ?? ""
        commandLine = place == .local ? server.location : ""
        name = server.name
        nameFixed = true
        signIn = MCPSignInChoice(server.auth.mode)
        if signIn == .apiKey, let header = server.auth.keyHeader {
            keyHeader = header
            key = MCPFormEntry(name: header, stored: MCPServerProjection.keyStored(server))
        }
        headers = server.headers.map { MCPFormEntry(name: $0.name, stored: $0.present) }
        variables = server.env.map { MCPFormEntry(name: $0.name, stored: $0.present) }
        clientID = server.oauthClient.clientId ?? ""
        clientSecret = MCPFormEntry(stored: server.oauthClient.secretPresent)
        workingFolder = server.cwd ?? ""
        consent = server.consentSentence
        moreOptions = !headers.isEmpty || !clientID.isEmpty || !workingFolder.isEmpty
    }

    // MARK: - Drafts

    /// What a draft answer did to the form.
    public enum DraftOutcome: Equatable, Sendable {
        case filled
        /// A paste held several servers, which a page of their own lists.
        case several(ManagementMCPDrafts)
    }

    /// The input a paste lands in, which is where its refusal is drawn: the
    /// URL or the command field, whichever the place shows.
    public var pasteField: MCPFormField { place == .remote ? .url : .command }

    /// The line under the command, while the field holds the text it was
    /// read for.
    public var commandSentence: String? {
        guard place == .local, let reading, reading.text == target else { return nil }

        return reading.commandSentence
    }

    /// Whether the line under the command names the program it runs, rather
    /// than one this Mac does not have.
    public var commandResolved: Bool { reading?.resolved ?? false }

    /// The consent line: the daemon's reading of what the field holds now,
    /// or the server's own on an edit.
    public var consentLine: String? {
        guard let reading, reading.text == target else { return consent }

        return reading.consent
    }

    /// Fills the form from the daemon's reading of `sent`, the text the URL
    /// or the command field held.
    ///
    /// Typed text is only read: the line under the command, the consent line
    /// and a name the owner has not typed. A paste on an add fills the form:
    /// where the server runs, the field as the daemon reads it, and where the
    /// paste carried more than an address, its sign-in, the names it declares
    /// and, as stored, the values it carried, held under the draft's own id.
    /// A paste of several servers turns to the page that lists them.
    public mutating func apply(_ answer: ManagementMCPDrafts, sent: String, pasted: Bool) -> DraftOutcome {
        let filling = pasted && !nameFixed
        guard answer.drafts.count == 1, let draft = answer.drafts.first else {
            return filling ? .several(answer) : .filled
        }

        errors[.url] = nil
        errors[.command] = nil
        if filling { fill(from: draft) }
        guard MCPServerPlace(draft.transport) == place, filling || target == sent else { return .filled }

        if !nameEdited, !nameFixed { name = draft.name }
        reading = MCPDraftReading(
            text: target,
            consent: draft.consentSentence,
            commandSentence: draft.commandSentence,
            resolved: draft.resolvedCommand != nil
        )
        return .filled
    }

    /// Puts a refusal of what was pasted or typed under the input it names,
    /// leaving every other mark where it was.
    public mutating func mark(_ refusal: MCPRefusal) {
        guard let field = refusal.field else {
            self.refusal = refusal.sentence
            return
        }

        errors[field == .paste ? pasteField : field] = refusal.sentence
    }

    private mutating func fill(from draft: ManagementMCPDraft) {
        place = MCPServerPlace(draft.transport)
        url = draft.url ?? ""
        commandLine = draft.commandLine ?? ""
        guard Self.carriesMoreThanAnAddress(draft) else { return }

        draftId = draft.draftId
        signIn = MCPSignInChoice(draft.auth)
        let key = draft.headers.first { $0.name == draft.keyHeader }
        if let key {
            keyHeader = key.name
            self.key = MCPFormEntry(name: key.name, stored: key.present)
        }
        headers = draft.headers.filter { $0 != key }.map { MCPFormEntry(name: $0.name, stored: $0.present) }
        variables = draft.env.map { MCPFormEntry(name: $0.name, stored: $0.present) }
        workingFolder = draft.cwd ?? ""
        clientID = draft.oauthClientId ?? ""
        moreOptions = !headers.isEmpty || !clientID.isEmpty || !workingFolder.isEmpty
    }

    /// Whether a paste said more about its server than where it is: a value,
    /// a name it declares, a sign-in, a folder or a client. A pasted address
    /// alone leaves what the owner chose on the form as it was.
    private static func carriesMoreThanAnAddress(_ draft: ManagementMCPDraft) -> Bool {
        draft.draftId != nil || !draft.env.isEmpty || !draft.headers.isEmpty || draft.cwd != nil
            || draft.keyHeader != nil || draft.oauthClientId != nil || draft.auth == .header
    }

    // MARK: - What a click sends

    /// The inputs a click finds empty that no server goes without, each with
    /// the line that asks for it. Add stays enabled: the click marks them.
    public var missingFields: [MCPFormField: String] {
        var missing: [MCPFormField: String] = [:]
        if target.isEmpty {
            switch place {
            case .remote: missing[.url] = ProductStrings[.mcpFieldURLMissing]
            case .local: missing[.command] = ProductStrings[.mcpFieldCommandMissing]
            }
        }
        if trimmed(name).isEmpty { missing[.name] = ProductStrings[.mcpFieldNameMissing] }

        return missing
    }

    /// What `mcp.servers.add` sends: the name, where it runs, and that
    /// place's fields.
    public var spec: ManagementMCPServerSpec {
        switch place {
        case .remote:
            return .remote(
                name: trimmed(name),
                url: target,
                auth: signIn.mode,
                keyHeader: sentKeyHeader,
                headerNames: Self.names(headers),
                oauthClientId: sentClientID,
                draftId: draftId
            )
        case .local:
            return .local(
                name: trimmed(name),
                commandLine: target,
                cwd: folder.isEmpty ? nil : folder,
                envNames: Self.names(variables),
                draftId: draftId
            )
        }
    }

    /// What `mcp.servers.update` sends for the server this form edits: the
    /// fields that differ from its row, and nothing else.
    public func change(from server: ManagementMCPServer) -> ManagementMCPServerChange {
        var change = ManagementMCPServerChange(name: server.name)

        switch place {
        case .local:
            if target != server.location { change.commandLine = target }
            if folder != server.cwd ?? "" { change.cwd = folder.isEmpty ? .clear : .set(folder) }
            if Self.names(variables) != server.env.map(\.name) { change.envNames = Self.names(variables) }
        case .remote:
            if target != server.url ?? "" { change.url = target }
            if signIn.mode != server.auth.mode { change.auth = signIn.mode }
            if let header = sentKeyHeader, header != server.auth.keyHeader { change.keyHeader = header }
            if Self.names(headers) != server.headers.map(\.name) { change.headerNames = Self.names(headers) }
            if sentClientID != server.oauthClient.clientId {
                change.oauthClientId = sentClientID.map(ManagementMCPClearable.set) ?? .clear
            }
        }

        return change
    }

    /// Every value typed on the form, each under the `mcp:` id that names it.
    /// Dots that were not replaced send nothing: the daemon already holds
    /// them.
    public var secrets: [MCPSecretValue] {
        let server = trimmed(name)
        guard !server.isEmpty else { return [] }

        switch place {
        case .remote:
            var values: [MCPSecretValue] = []
            if let header = sentKeyHeader, !key.value.isEmpty {
                values.append(MCPSecretValue(id: MCPSecretId.header(server: server, name: header), value: key.value, field: .key))
            }
            values += Self.typed(headers).map { entry in
                MCPSecretValue(id: MCPSecretId.header(server: server, name: trimmed(entry.name)), value: entry.value, field: .headers)
            }
            if sentClientID != nil, !clientSecret.value.isEmpty {
                values.append(MCPSecretValue(id: MCPSecretId.clientSecret(server: server), value: clientSecret.value, field: .clientSecret))
            }
            return values
        case .local:
            return Self.typed(variables).map { entry in
                MCPSecretValue(id: MCPSecretId.env(server: server, name: trimmed(entry.name)), value: entry.value, field: .variables)
            }
        }
    }

    /// Puts the daemon's refusal of a write under the input it named, or at
    /// the foot of the form where it named none on it, in place of every
    /// earlier mark.
    public mutating func refuse(_ refusal: MCPRefusal) {
        errors = [:]
        self.refusal = nil
        mark(refusal)
    }

    // MARK: - The inputs as they are sent

    /// The URL or the command, whichever the place shows, as it is sent.
    public var target: String { trimmed(place == .remote ? url : commandLine) }

    private var folder: String { trimmed(workingFolder) }

    /// The header an API key is sent in, where the key is how the server is
    /// reached and a header is named.
    private var sentKeyHeader: String? {
        let header = trimmed(keyHeader)
        guard signIn == .apiKey, !header.isEmpty else { return nil }

        return header
    }

    /// A pre-registered client, which only the automatic sign-in uses.
    private var sentClientID: String? {
        let client = trimmed(clientID)
        guard signIn == .automatic, !client.isEmpty else { return nil }

        return client
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The names of the rows that have one, in the form's order.
    private static func names(_ entries: [MCPFormEntry]) -> [String] {
        entries.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The named rows a value was typed into.
    private static func typed(_ entries: [MCPFormEntry]) -> [MCPFormEntry] {
        entries.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.value.isEmpty }
    }
}

/// The add and the edit form, one page of the server sheet (M74 §4.2, §4.6).
///
/// The deciding control comes first and reveals the rest; More options is
/// closed until asked for; every refusal is the daemon's sentence under the
/// field it names. Where the daemon reads pastes, the URL and the command
/// field take a whole configuration, and what is typed there is read as the
/// owner pauses. The page owns no scroll: what does not fit is shortened, not
/// scrolled.
struct MCPServerFormPage: View {
    enum Mode: Equatable {
        case add
        case edit(String)
    }

    let mode: Mode
    @Binding var form: MCPServerForm
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    /// Where the sheet goes once the daemon took what was sent.
    let turn: (MCPServerPage) -> Void
    let cancel: () -> Void

    @State private var saving = false
    @State private var drafting: Task<Void, Never>?

    /// Whether the daemon reads what is typed or pasted (`mcp.servers.draft`).
    private var reads: Bool { model.serves(.mcpServersDraft) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            heading

            // Where a server runs is decided once: an edit keeps it, as it keeps
            // the name, so the switch belongs to an add alone.
            if mode == .add {
                VStack(spacing: Spacing.xxs) {
                    Picker(ProductStrings[.mcpAddWhereItRuns], selection: $form.place) {
                        ForEach(MCPServerPlace.allCases, id: \.self) { place in
                            Text(ProductStrings[place.titleKey]).tag(place)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    if reads {
                        MCPFormNote(text: ProductStrings[.mcpAddPasteHint])
                    }
                    if let error = form.errors[.place] {
                        MCPFormNote(text: error, failed: true)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Every button the rows draw takes the row action style: ink on a
            // neutral capsule rather than the accent (redlines §4.4).
            VStack(alignment: .leading, spacing: Spacing.s) {
                switch form.place {
                case .remote: remoteRows
                case .local: localRows
                }
            }
            .rowActions()

            AdvancedRowsToggle(shown: $form.moreOptions, title: .mcpMoreOptions)

            if form.moreOptions {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    switch form.place {
                    case .remote: remoteOptions
                    case .local: localOptions
                    }
                }
                .rowActions()
            }

            if let consent = form.consentLine {
                MCPFormNote(text: consent)
            }
            if let refusal = form.refusal {
                MCPFormNote(text: refusal, failed: true)
            }

            buttons
        }
        .onChange(of: form.url) { old, new in changed(.remote, from: old, to: new) }
        .onChange(of: form.commandLine) { old, new in changed(.local, from: old, to: new) }
        // An edit reads the command it opens on, so the line under it is the
        // daemon's word on it now.
        .onAppear { if mode != .add { read(pasted: false, pause: .zero) } }
        .onDisappear { drafting?.cancel() }
    }

    @ViewBuilder
    private var heading: some View {
        switch mode {
        case .add:
            Text(ProductStrings[.mcpAddTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
        case .edit(let name):
            IntegrationPageHeader(title: ProductStrings[.mcpActionEdit], parent: name, back: cancel)
        }
    }

    // MARK: - Remote

    @ViewBuilder
    private var remoteRows: some View {
        MCPFormRow(label: .mcpFieldURL, error: form.errors[.url]) {
            MCPPasteField(label: .mcpFieldURL, text: $form.url)
        }

        nameRow

        MCPFormRow(label: .mcpFieldSignIn, error: form.errors[.signIn]) {
            Picker(ProductStrings[.mcpFieldSignIn], selection: $form.signIn) {
                ForEach(MCPSignInChoice.allCases, id: \.self) { choice in
                    Text(ProductStrings[choice.titleKey]).tag(choice)
                }
            }
            .pickerStyle(.menu)
            // Outside a grouped form a menu picker draws as accent text with no
            // bezel; bordered is the pop-up button every other choice in
            // Settings is, ink on the control's own fill.
            .buttonStyle(.bordered)
            .labelsHidden()
            .fixedSize()
        }

        switch form.signIn {
        case .automatic:
            MCPFormFooter(text: ProductStrings[.mcpSignInAutomaticFooter])
        case .apiKey:
            MCPFormRow(label: .mcpFieldHeader, error: form.errors[.keyHeader]) {
                ModelComboBox(
                    label: ProductStrings[.mcpFieldHeader],
                    prompt: MCPServerForm.keyHeaders[0],
                    value: form.keyHeader,
                    items: MCPServerForm.keyHeaders,
                    reverts: model.editReverts,
                    edited: { form.keyHeader = $0 },
                    began: {},
                    chosen: { form.keyHeader = $0 },
                    ended: { form.keyHeader = $0 }
                )
            }
            MCPFormRow(label: .mcpFieldKey, error: form.errors[.key]) {
                MCPSecretValueField(label: ProductStrings[.mcpFieldKey], entry: $form.key)
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var remoteOptions: some View {
        MCPEntryRows(
            label: .mcpFieldHeaders,
            namePrompt: .mcpFieldHeader,
            addTitle: .mcpFieldAddHeader,
            entries: $form.headers,
            error: form.errors[.headers]
        )

        if form.signIn == .automatic {
            MCPFormRow(label: .mcpFieldClientID, error: form.errors[.clientID]) {
                TextField(ProductStrings[.mcpFieldClientID], text: $form.clientID, prompt: MCPFormPrompt.none)
                    .settingsTextField()
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings[.mcpFieldClientID])
            }
            MCPFormRow(label: .mcpFieldClientSecret, error: form.errors[.clientSecret]) {
                MCPSecretValueField(label: ProductStrings[.mcpFieldClientSecret], entry: $form.clientSecret)
            }
            MCPFormFooter(text: ProductStrings[.mcpFieldClientFooter])
        }
    }

    // MARK: - On this Mac

    @ViewBuilder
    private var localRows: some View {
        MCPFormRow(label: .mcpFieldCommand, error: form.errors[.command]) {
            MCPPasteField(label: .mcpFieldCommand, text: $form.commandLine)
        }

        if let sentence = form.commandSentence, form.errors[.command] == nil {
            MCPFormFooter(text: sentence, failed: !form.commandResolved)
        }

        nameRow

        MCPEntryRows(
            label: .mcpFieldVariables,
            namePrompt: .mcpFieldName,
            addTitle: .mcpFieldAddVariable,
            entries: $form.variables,
            error: form.errors[.variables]
        )
    }

    @ViewBuilder
    private var localOptions: some View {
        MCPFormRow(label: .mcpFieldWorkingFolder, error: form.errors[.workingFolder]) {
            HStack(spacing: Spacing.xs) {
                TextField(ProductStrings[.mcpFieldWorkingFolder], text: $form.workingFolder, prompt: MCPFormPrompt.none)
                    .settingsTextField()
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings[.mcpFieldWorkingFolder])

                Button(ProductStrings[.mcpDetailChoose], action: chooseFolder)
                    .accessibilityLabel(
                        ProductStrings.commaPair(ProductStrings[.mcpDetailChoose], ProductStrings[.mcpFieldWorkingFolder])
                    )
            }
        }
    }

    // MARK: - Both

    @ViewBuilder
    private var nameRow: some View {
        MCPFormRow(label: .mcpFieldName, error: form.errors[.name]) {
            if form.nameFixed {
                Text(form.name)
                    .foregroundStyle(Palette.secondary.color)
            } else {
                TextField(ProductStrings[.mcpFieldName], text: typedName, prompt: MCPFormPrompt.none)
                    .settingsTextField()
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings[.mcpFieldName])
            }
        }
        if !form.nameFixed {
            MCPFormFooter(text: ProductStrings[.mcpFieldNameFooter])
        }
    }

    /// The name, marked as the owner's own once they type in it, so a draft
    /// no longer fills it.
    private var typedName: Binding<String> {
        Binding(
            get: { form.name },
            set: { typed in
                form.name = typed
                form.nameEdited = true
            }
        )
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)

            Button(ProductStrings[.settingsSheetCancel], action: cancel)
                .buttonStyle(SecondaryButtonStyle(.row))
                .keyboardShortcut(.cancelAction)

            PrimaryAction(
                ProductStrings[mode == .add ? .integrationsMCPAdd : .settingsSheetDone],
                size: .row,
                action: submit
            )
            .disabled(saving)
        }
    }

    // MARK: - Actions

    /// The URL or the command field changed. A change of more than one
    /// character at once is a paste, read at once and filling the form; typing
    /// is read once the owner pauses. A change a draft itself wrote, or one to
    /// the field the place does not show, is not read.
    private func changed(_ field: MCPServerPlace, from old: String, to new: String) {
        guard reads, field == form.place,
              new.trimmingCharacters(in: .whitespacesAndNewlines) != form.reading?.text
        else { return }

        let pasted = mode == .add && new.count > old.count + 1
        read(pasted: pasted, pause: pasted ? .zero : MCPServerSheetMetrics.draftPause)
    }

    /// Asks the daemon about what the field holds, and drops an answer for a
    /// text that has changed since.
    private func read(pasted: Bool, pause: Duration) {
        drafting?.cancel()
        let sent = form.target
        guard reads, !sent.isEmpty else {
            form.reading = nil
            return
        }

        drafting = Task {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }

            let answer = await model.draftMCPServer(text: sent)
            guard !Task.isCancelled, sent == form.target else { return }

            switch answer {
            case .success(let drafts):
                guard case .several(let all) = form.apply(drafts, sent: sent, pasted: pasted) else { return }

                form.url = ""
                form.commandLine = ""
                turn(.pasted(all))
            case .failure(let refusal):
                form.mark(refusal)
            }
        }
    }

    private func submit() {
        form.refusal = nil
        form.errors = form.missingFields
        guard form.errors.isEmpty else { return }

        saving = true
        Task {
            defer { saving = false }
            switch mode {
            case .add: await add()
            case .edit(let name): await save(name)
            }
        }
    }

    /// The add, its values and its check, in that order. A value the daemon
    /// refused leaves the server added, so the form turns into its edit with
    /// what was typed and the refusal under the input.
    private func add() async {
        let outcome = await model.addMCPServer(form.spec, values: form.secrets, on: runner)
        switch outcome {
        case .refused(let refusal):
            form.refuse(refusal)
        case .added(_, let unstored):
            if let unstored {
                form.nameFixed = true
                form.refuse(unstored)
            }
        }

        if let next = MCPServerPage.after(outcome) { turn(next) }
    }

    private func save(_ name: String) async {
        guard let server = model.mcpServer(named: name) else { return }

        if let refusal = await model.updateMCPServer(form.change(from: server), values: form.secrets, on: runner) {
            form.refuse(refusal)
            return
        }
        turn(.detail(name))
    }

    /// The system folder panel, which is a panel of macOS and not a popup of
    /// this sheet.
    private func chooseFolder() {
        guard let url = OpenPanelDirectoryChooser().chooseDirectory(prompt: ProductStrings[.mcpFieldWorkingFolder]) else {
            return
        }

        form.workingFolder = url.path
    }
}

/// A field's placeholder on this form: none, because its name is the label
/// beside it and repeating it inside the box says nothing new.
enum MCPFormPrompt {
    static var none: Text { Text(verbatim: "") }
}

/// The URL or the command field, which also takes a whole pasted
/// configuration. It grows to the lines a paste holds, so a Codex block or a
/// JSON snippet keeps its line breaks, and returns to one line once the
/// daemon's reading of it fills the form.
struct MCPPasteField: View {
    let label: ProductStringKey
    @Binding var text: String

    var body: some View {
        TextField(ProductStrings[label], text: $text, prompt: MCPFormPrompt.none, axis: .vertical)
            .lineLimit(1...MCPServerSheetMetrics.pasteLines)
            .settingsTextField()
            .labelsHidden()
            .accessibilityLabel(ProductStrings[label])
    }
}

/// One labelled row of the form, with the daemon's refusal for that input
/// drawn under it. The label column is one width on every row, so the fields
/// line up and take the rest of the sheet.
struct MCPFormRow<Content: View>: View {
    let label: ProductStringKey
    let error: String?
    @ViewBuilder let content: Content

    var body: some View {
        MCPLabeledRow(label: label) { content }

        if let error {
            MCPFormFooter(text: error, failed: true)
        }
    }
}

/// A label in the form's label column beside its value, on the first line's
/// baseline. The detail's facts are drawn the same way.
struct MCPLabeledRow<Content: View>: View {
    let label: ProductStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            MCPRowLabel(label: label)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A line under a row, in its value column.
struct MCPFormFooter: View {
    let text: String
    var failed = false

    var body: some View {
        MCPFormNote(text: text, failed: failed)
            .padding(.leading, MCPServerSheetMetrics.labelWidth + Spacing.s)
            .padding(.top, -Spacing.xs)
    }
}

/// A line of the form's small print, in the secondary colour, or in the
/// warning colour where it says something is wrong.
struct MCPFormNote: View {
    let text: String
    var failed = false

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle((failed ? Palette.warning : Palette.secondary).color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(failed ? .updatesFrequently : [])
    }
}

/// A value typed in place: the secure field, or the dots of one the daemon
/// already holds, with `Replace`.
struct MCPSecretValueField: View {
    let label: String
    @Binding var entry: MCPFormEntry

    var body: some View {
        if entry.showsStored {
            HStack(spacing: Spacing.xs) {
                Text(ProductStrings[.mcpStoredValue])
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityLabel(ProductStrings.commaPair(label, ProductStrings[.mcpStored]))

                Spacer(minLength: 0)

                Button(ProductStrings[.mcpReplace]) { entry.replacing = true }
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.mcpReplace], label))
            }
        } else {
            SecretInput(label: label, value: $entry.value, onSubmit: {})
        }
    }
}

/// The variables of a local server, or the extra headers of a remote one: a
/// name and a secure value per row, a way to take one out, and a way to add
/// one.
struct MCPEntryRows: View {
    let label: ProductStringKey
    let namePrompt: ProductStringKey
    let addTitle: ProductStringKey
    @Binding var entries: [MCPFormEntry]
    let error: String?

    var body: some View {
        ForEach($entries) { $entry in
            MCPLabeledRow(label: entry.id == entries.first?.id ? label : nil) {
                HStack(spacing: Spacing.xs) {
                    if entry.stored {
                        Text(entry.name)
                            .frame(width: MCPServerSheetMetrics.entryNameWidth, alignment: .leading)
                    } else {
                        TextField(ProductStrings[namePrompt], text: $entry.name, prompt: Text(ProductStrings[namePrompt]))
                            .settingsTextField()
                            .labelsHidden()
                            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[label], ProductStrings[namePrompt]))
                            .frame(width: MCPServerSheetMetrics.entryNameWidth)
                    }

                    MCPSecretValueField(label: entry.name, entry: $entry)

                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Palette.secondary.color)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsSecretRemove], entry.name))
                }
            }
        }

        MCPLabeledRow(label: entries.isEmpty ? label : nil) {
            Button(ProductStrings[addTitle]) { entries.append(MCPFormEntry()) }
        }

        if let error {
            MCPFormFooter(text: error, failed: true)
        }
    }
}

/// The label column of one row: the row's name where it leads a group, and
/// the same width of nothing under it.
struct MCPRowLabel: View {
    let label: ProductStringKey?

    var body: some View {
        Text(label.map { ProductStrings[$0] } ?? "")
            .frame(width: MCPServerSheetMetrics.labelWidth, alignment: .leading)
            .accessibilityHidden(label == nil)
    }
}
