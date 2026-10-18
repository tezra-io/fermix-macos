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

/// The add and edit form, as a value (M74 §4.2, §4.6).
///
/// The rules live here rather than in the view, so they are proven without a
/// window: what an add sends, what an edit changes, which values go to the
/// Keychain and under which id, and where a refusal is drawn. Names travel on
/// the `mcp.servers.*` methods; every value travels alone in `secret.set`.
public struct MCPServerForm: Equatable, Sendable {
    /// The two headers a key is usually sent in, which the `Header` combo box
    /// offers. `Authorization` carries it as `Bearer <key>`.
    public static let keyHeaders = ["Authorization", "X-API-Key"]

    public var place: MCPServerPlace = .remote
    public var url = ""
    public var commandLine = ""
    public var name = ""
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
                oauthClientId: sentClientID
            )
        case .local:
            return .local(
                name: trimmed(name),
                commandLine: target,
                cwd: folder.isEmpty ? nil : folder,
                envNames: Self.names(variables)
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

    /// Puts the daemon's refusal under the input it named, or at the foot of
    /// the form where it named none on it.
    public mutating func refuse(_ refusal: MCPRefusal) {
        errors = [:]
        self.refusal = nil
        guard let field = refusal.field else {
            self.refusal = refusal.sentence
            return
        }

        errors[field] = refusal.sentence
    }

    // MARK: - The inputs as they are sent

    /// The URL or the command, whichever the place shows.
    private var target: String { trimmed(place == .remote ? url : commandLine) }

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
/// field it names. The page owns no scroll: what does not fit is shortened,
/// not scrolled.
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

            if let consent = form.consent {
                MCPFormNote(text: consent)
            }
            if let refusal = form.refusal {
                MCPFormNote(text: refusal, failed: true)
            }

            buttons
        }
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
            TextField(ProductStrings[.mcpFieldURL], text: $form.url, prompt: MCPFormPrompt.none)
                .settingsTextField()
                .labelsHidden()
                .accessibilityLabel(ProductStrings[.mcpFieldURL])
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
            TextField(ProductStrings[.mcpFieldCommand], text: $form.commandLine, prompt: MCPFormPrompt.none)
                .settingsTextField()
                .labelsHidden()
                .accessibilityLabel(ProductStrings[.mcpFieldCommand])
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
                TextField(ProductStrings[.mcpFieldName], text: $form.name, prompt: MCPFormPrompt.none)
                    .settingsTextField()
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings[.mcpFieldName])
            }
        }
        if !form.nameFixed {
            MCPFormFooter(text: ProductStrings[.mcpFieldNameFooter])
        }
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
