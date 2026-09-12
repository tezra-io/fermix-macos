import SwiftUI

/// Install consent (M34 §5.6).
///
/// The runtime sentence is the daemon's, so a hosted plugin can never render
/// the local-process line and tell the operator it runs on their machine. For a
/// plugin that runs somewhere else, what leaves this Mac is stated before the
/// install, not after it.
/// The gesture is one switch, so the sheet finishes it: once the install job
/// ends the plugin the operator switched on is enabled, the catalogue is
/// re-read, and the sheet closes. Stopping at the install would install
/// something and leave the switch snapping back off.
struct IntegrationConsentSheet: View {
    let row: IntegrationRowModel
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    let dismiss: () -> Void

    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(row.title)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            Text(row.consent)
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            if let disclosure = row.disclosure {
                DisclosureGroup(ProductStrings[.integrationDisclosureTitle]) {
                    Text(disclosure)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let sentence = refusal ?? runner.failure {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: dismiss)
                    .keyboardShortcut(.cancelAction)

                Button(ProductStrings[.integrationInstall]) {
                    Task { await model.startPluginInstall(name: row.name, on: runner) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(runner.isRunning)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
        // The same shape `ProvidersPane` watches its sign-in with: the job is
        // started and forgotten, and its end is a change on the runner.
        .onChange(of: runner.isRunning) { _, running in
            guard !running else { return }

            Task { await installFinished() }
        }
    }

    /// The install ended. What follows it is the model's; the sheet decides
    /// only that a refusal keeps it up carrying the daemon's own sentence,
    /// because closing on one would report success.
    private func installFinished() async {
        refusal = await model.pluginInstallCompleted(name: row.name, on: runner)

        guard refusal == nil else { return }

        dismiss()
    }
}

/// One plugin's detail (decision D6): where it stands, the verbs the daemon
/// published, the settings rows the manifest publishes, its workspace, and
/// disconnect.
///
/// This is where `plugins.list.verbs` renders, which closes the standing gap in
/// which the contract published a field no surface read. The words on those
/// buttons are the daemon's; the app decides only which method each state
/// admits.
/// The plugin is addressed by name and re-read from the catalogue on every
/// render. Enable, disable, disconnect and check all re-read that catalogue, so
/// a captured row would leave the sheet describing what was true when it opened
/// while the list behind it moved on.
struct IntegrationDetailSheet: View {
    let name: String
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    let dismiss: () -> Void

    @State private var refusal: String?
    @State private var choosingWorkspace = false
    /// The sign-in client this plugin's `set_up_client` verb opens, addressed by
    /// provider so the sheet reads it live rather than holding the snapshot the
    /// detail opened on.
    @State private var editingClient: OAuthClientTarget?
    @State private var showingSignIn = false
    @State private var startingSignIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let row = IntegrationRowProjection.row(named: name, in: model.plugins.value) {
                content(row)
            } else {
                Text(ProductStrings[.integrationGone])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }

            jobNotice
            footer
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width)
        // Escape cancels, on every sheet (M34 §3.1). Every row here commits as
        // it is edited, so leaving is the whole of cancelling.
        .onExitCommand(perform: dismiss)
        .sheet(isPresented: $choosingWorkspace) {
            WorkspaceSheet(name: name, model: model, runner: runner) { choosingWorkspace = false }
        }
        .sheet(item: $editingClient) { target in
            OAuthClientSheet(provider: target.provider, model: model) { editingClient = nil }
        }
        .sheet(isPresented: $showingSignIn) { signInSheet }
        .onChange(of: runner.job, initial: true) { _, job in
            guard let job, job.status.isTerminal else { return }

            Task { await model.pluginJobFinished(job) }
        }
    }

    @ViewBuilder
    private var jobNotice: some View {
        if runner.isRunning, let phase = runner.phase {
            HStack(spacing: Spacing.s) {
                ProgressView(value: runner.progress?.fraction).controlSize(.small)
                Text(phase).fermixType(Typography.style(.calloutSmall))
            }
        }
        if let sentence = refusal ?? runner.failure ?? runner.browserFailure {
            Text(sentence)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)
            Button(ProductStrings[.settingsSheetDone], action: dismiss)
                .keyboardShortcut(.defaultAction)
                .disabled(startingSignIn)
        }
    }

    private var signInSheet: some View {
        SignInSheet(
            label: IntegrationRowProjection.row(named: name, in: model.plugins.value)?.title ?? name,
            importing: false,
            starting: startingSignIn || model.startingSignIn,
            runner: runner,
            reopen: { model.reopenSignIn(on: runner) },
            retry: beginSignIn,
            browserFallback: nil
        ) { showingSignIn = false }
    }

    @ViewBuilder
    private func content(_ row: IntegrationRowModel) -> some View {
        heading(row)
        status(row)
        nextStep(row)
        verbs(row)
        settings(row)
        signInClient(row)
        workspace(row)
    }

    private func heading(_ row: IntegrationRowModel) -> some View {
        HStack(spacing: Spacing.xs) {
            PluginMarkTile(name: row.name, size: IntegrationMetrics.tileSize)

            Text(row.title)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
        }
    }

    private func status(_ row: IntegrationRowModel) -> some View {
        Text(row.status)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The buttons the daemon published for this row.
    ///
    /// One button per entry in `actions`, minus the two credential verbs the
    /// slot below already owns and any id this build has no word for. An empty
    /// `actions` draws nothing: a row with no verbs is a state the daemon
    /// publishes, not a row whose verbs went missing.
    @ViewBuilder
    private func verbs(_ row: IntegrationRowModel) -> some View {
        let buttons = row.buttons

        if !buttons.isEmpty {
            LabeledContent(ProductStrings[.integrationVerbsSection]) {
                HStack(spacing: Spacing.xs) {
                    ForEach(buttons, id: \.self) { action in
                        Button(title(of: action)) { perform(action, on: row) }
                            .disabled(startingSignIn || model.startingSignIn || runner.isRunning || model.writesBlocked)
                            .accessibilityLabel(ProductStrings.commaPair(title(of: action), row.title))
                    }
                }
            }
        }
    }

    /// What the daemon says the next step is, in its own words. Text, never a
    /// button title: the word describes the state and the action id is what
    /// says which method a button runs.
    @ViewBuilder
    private func nextStep(_ row: IntegrationRowModel) -> some View {
        if let verb = row.verb, !verb.isEmpty {
            LabeledContent(ProductStrings[.integrationNextStep]) {
                Text(verb)
                    .foregroundStyle(Palette.secondary.color)
            }
        }
    }

    /// The manifest's own settings, plus the credential slot behind them. The
    /// slot is the one door to a token, which is why `addToken` draws no button
    /// of its own above.
    @ViewBuilder
    private func settings(_ row: IntegrationRowModel) -> some View {
        if row.authKind == .apiKey || !manifestSettings.isEmpty {
            Text(ProductStrings[.integrationSettingsSection])
                .fermixType(Typography.style(.calloutSmall).weight(.medium))
                .foregroundStyle(Palette.secondary.color)

            if row.authKind == .apiKey {
                SecretRow(
                    label: ProductStrings[.integrationTokenLabel],
                    identifier: SettingsModel.pluginSecretId(row.name),
                    present: row.credentialPresent,
                    model: model
                )
            }
            ForEach(manifestSettings, id: \.key) { setting in
                IntegrationSettingRow(name: row.name, setting: setting, model: model) { refusal = $0 }
            }
        }
    }

    /// The sign-in client this plugin signs in through, where it belongs to a
    /// sign-in family.
    ///
    /// The tie is the daemon's `auth_provider`, not the plugin's name. Without
    /// it the client's state was readable only at the foot of the page, so a
    /// plugin whose sign-in is waiting on an unregistered client said so in its
    /// status sentence and nowhere the operator could check.
    @ViewBuilder
    private func signInClient(_ row: IntegrationRowModel) -> some View {
        if let client = IntegrationRowProjection.client(for: row, in: model.plugins.value) {
            LabeledContent(ProductStrings[.integrationClientRow]) {
                Text(ProductStrings[client.configured ? .integrationClientSet : .integrationClientUnset])
                    .foregroundStyle(Palette.secondary.color)
            }
        }
    }

    @ViewBuilder
    private func workspace(_ row: IntegrationRowModel) -> some View {
        if row.bindsWorkspace {
            LabeledContent(ProductStrings[.integrationWorkspaceRow]) {
                HStack(spacing: Spacing.xs) {
                    Text(row.workspaceLabel ?? ProductStrings[.integrationWorkspaceUnset])
                        .foregroundStyle(Palette.secondary.color)

                    Button(ProductStrings[.integrationWorkspaceChoose]) { choosingWorkspace = true }
                        .accessibilityLabel(
                            ProductStrings.commaPair(ProductStrings[.integrationWorkspaceChoose], row.title)
                        )
                }
            }
        }
    }

    private var manifestSettings: [ManagementPluginSetting] {
        model.plugins.value?.plugins.first { $0.name == name }?.settings ?? []
    }

    /// The app's own word for an action, by id. `row.buttons` has already
    /// dropped every id this build has no word for, so a button reaching this
    /// with none is a defect rather than an unlabelled control.
    private func title(of action: ManagementPluginAction) -> String {
        guard let title = action.title else {
            preconditionFailure("\(action.wireValue) has no title and draws no button")
        }

        return title
    }

    /// Runs the id the daemon published for this button. The three ids answered
    /// by a sheet open it; everything else goes to the model.
    private func perform(_ action: ManagementPluginAction, on row: IntegrationRowModel) {
        switch action {
        case .chooseWorkspace:
            choosingWorkspace = true
        case .setUpClient:
            editingClient = row.authProvider.map(OAuthClientTarget.init(provider:))
        case .signIn:
            beginSignIn()
        case .addToken, .replaceToken:
            preconditionFailure("a credential verb draws no button; the secret row is its slot")
        default:
            Task { refusal = await model.perform(action, on: row.name, runner: runner) }
        }
    }

    private func beginSignIn() {
        guard !startingSignIn, !runner.isRunning else { return }

        startingSignIn = true
        refusal = nil
        Task {
            defer {
                startingSignIn = false
                showingSignIn = true
            }
            refusal = await model.perform(.signIn, on: name, runner: runner)
        }
    }
}

/// One plugin setting: the manifest's label, and its value.
struct IntegrationSettingRow: View {
    let name: String
    let setting: ManagementPluginSetting
    @ObservedObject var model: SettingsModel
    let refused: (String?) -> Void

    @State private var draft = ""

    var body: some View {
        LabeledContent(setting.label) {
            TextField(setting.label, text: $draft, prompt: Text(setting.label))
                .labelsHidden()
                .onSubmit(commit)
        }
        .onAppear { draft = setting.value ?? "" }
    }

    private func commit() {
        guard draft != (setting.value ?? "") else { return }

        Task {
            refused(
                await model.setPluginSetting(
                    name: name,
                    key: setting.key,
                    value: draft.isEmpty ? .absent : .text(draft)
                )
            )
        }
    }
}

/// One sign-in client row at the foot of the page, and the way into its sheet.
///
/// It keeps a mark of its own: the section is a list of the same vendors the
/// rows above it name, and a plugin the shipped catalog does not carry simply
/// has no logo to draw, which is the neutral symbol rather than an invented one.
struct OAuthClientRow: View {
    let client: ManagementPluginOAuthClient
    let edit: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                Text(ProductStrings[client.configured ? .integrationClientSet : .integrationClientUnset])
                    .foregroundStyle(Palette.secondary.color)

                Button(ProductStrings[client.configured ? .integrationClientEdit : .integrationClientConnect]) {
                    edit()
                }
                .accessibilityLabel(
                    ProductStrings.commaPair(
                        ProductStrings[.integrationClientRow],
                        WireIdentifier.word(client.provider)
                    )
                )
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                VendorMarkView(
                    mark: VendorMarks.oauthClient(client.provider),
                    kind: .oauthClient,
                    size: SettingsRowMetrics.markSize
                )

                Text(WireIdentifier.word(client.provider))
            }
        }
    }
}

/// One sign-in client, as a sheet item.
///
/// The sheet is addressed by provider rather than by the client record, which is
/// what lets it read the record live: storing the client secret re-reads the
/// catalogue, and a captured record would go on saying `Not configured` over the
/// secret the operator just stored.
struct OAuthClientTarget: Identifiable, Equatable, Sendable {
    let provider: String

    var id: String { provider }
}

/// Public client settings stay local until Done. Secrets use their own row.
struct OAuthClientDraft {
    enum ValidationError: Error, Equatable { case invalidPort }

    var identifier: String
    var port: String

    init(client: ManagementPluginOAuthClient?) {
        identifier = client?.clientId ?? ""
        port = client?.redirectPort.map(String.init) ?? ""
    }

    func validatedPort() throws -> Int? {
        let value = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Int(value), (1...65535).contains(number) else {
            throw ValidationError.invalidPort
        }

        return number
    }
}

/// The OAuth client sheet (M34 §5.6).
///
/// The client id and the redirect port go through `plugins.oauth_client.set`;
/// the client secret goes through `secret.set` under the contract's own
/// `oauth_client:<provider>` id and never through a settings write, so the one
/// secure input in the product stays the one place a credential is typed.
struct OAuthClientSheet: View {
    let provider: String
    @ObservedObject var model: SettingsModel
    let dismiss: () -> Void

    @State private var draft: OAuthClientDraft
    @State private var refusal: String?
    @State private var saving = false

    init(provider: String, model: SettingsModel, dismiss: @escaping () -> Void) {
        precondition(!provider.isEmpty, "an OAuth client names its provider")
        self.provider = provider
        self.model = model
        self.dismiss = dismiss
        _draft = State(initialValue: OAuthClientDraft(
            client: model.plugins.value?.oauthClients.first { $0.provider == provider }
        ))
    }

    /// The client as the daemon last published it, re-read on every render.
    private var client: ManagementPluginOAuthClient? {
        model.plugins.value?.oauthClients.first { $0.provider == provider }
    }

    /// The `secret.set` id for a provider's client secret. M34 §7.3 names the
    /// family; it is written once, here, beside the only sheet that uses it.
    static func secretId(for provider: String) -> String {
        precondition(!provider.isEmpty, "an OAuth client secret is addressed by provider")

        return SettingsModel.oauthClientSecretPrefix + provider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings.commaPair(
                ProductStrings[.integrationClientRow],
                WireIdentifier.word(provider)
            ))
            .fermixType(Typography.sheetTitle)
            .foregroundStyle(Palette.ink.color)

            LabeledContent(ProductStrings[.integrationClientIdentifier]) {
                TextField(
                    ProductStrings[.integrationClientIdentifier],
                    text: $draft.identifier,
                    prompt: Text(ProductStrings[.integrationClientIdentifier])
                )
                .labelsHidden()
            }

            secret

            LabeledContent(ProductStrings[.integrationClientPort]) {
                TextField(
                    ProductStrings[.integrationClientPort],
                    text: $draft.port,
                    prompt: Text(ProductStrings[.integrationClientPortPrompt])
                )
                .labelsHidden()
            }

            if let refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: dismiss)
                    .keyboardShortcut(.cancelAction)

                Button(ProductStrings[.settingsSheetDone], action: store)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
    }

    @ViewBuilder
    private var secret: some View {
        if let present = client?.secretPresent {
            SecretRow(
                label: ProductStrings[.integrationClientSecret],
                identifier: Self.secretId(for: provider),
                present: present,
                model: model
            )
        } else {
            LabeledContent(ProductStrings[.integrationClientSecret]) {
                Text(ProductStrings[.permissionsProfileUnknown]).foregroundStyle(Palette.secondary.color)
            }
        }
    }

    /// A blank port is absent rather than zero: the daemon owns the default,
    /// and sending one the operator did not type would pin it.
    private func store() {
        let identifier = draft.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !saving else { return }
        let redirectPort: Int?
        do {
            redirectPort = try draft.validatedPort()
        } catch {
            refusal = ProductStrings[.integrationClientPortInvalid]
            return
        }

        saving = true
        Task {
            let sentence = await model.setOAuthClient(
                provider: provider,
                clientId: identifier,
                redirectPort: redirectPort
            )
            saving = false
            refusal = sentence

            guard sentence == nil else { return }

            dismiss()
        }
    }
}

/// Choose a workspace (M34 §5.6).
///
/// Two steps in one sheet: the access profile the manifest publishes, with the
/// daemon's own write flag driving the warning, then the workspace the last
/// discovery found. Both halves are the daemon's; the sheet only picks.
///
/// The plugin is addressed by name and re-read on every render, and the
/// discovery job re-reads the catalogue when it ends. A captured row would make
/// `Find workspaces` a button that can never change what it is looking at: the
/// daemon republishes the discovery on the plugin row, not on the job.
struct WorkspaceSheet: View {
    let name: String
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    let dismiss: () -> Void

    @State private var profile = ""
    @State private var chosen = ""
    @State private var refusal: String?

    /// The plugin as the daemon last published it. Absent means the catalogue
    /// no longer carries it, and the sheet says so rather than drawing a list
    /// of nothing.
    private var row: IntegrationRowModel? {
        IntegrationRowProjection.row(named: name, in: model.plugins.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ProductStrings[.integrationWorkspaceTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            if let row {
                access(row)
                list(row)
            } else {
                Text(ProductStrings[.integrationGone])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if let phase = runner.phase {
                Text(phase)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let sentence = refusal ?? runner.failure {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: Spacing.s) {
                Button(ProductStrings[.integrationWorkspaceFind]) {
                    Task { await model.startWorkspaceDiscovery(name: name, on: runner) }
                }
                .disabled(runner.isRunning)

                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: dismiss)
                    .keyboardShortcut(.cancelAction)

                Button(ProductStrings[.integrationWorkspaceUse], action: select)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.isEmpty || chosen.isEmpty || runner.isRunning)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
        .onAppear { profile = row?.accessProfiles.first?.id ?? "" }
        // The discovery ended, so the row it republished is read back. Without
        // this the list is whatever the catalogue held when the sheet opened.
        .onChange(of: runner.isRunning) { _, running in
            guard !running else { return }

            Task { await model.refreshPlugins() }
        }
    }

    /// The access profile, and the warning the daemon's own write flag raises.
    @ViewBuilder
    private func access(_ row: IntegrationRowModel) -> some View {
        Picker(ProductStrings[.integrationWorkspaceAccessSection], selection: $profile) {
            ForEach(row.accessProfiles, id: \.id) { entry in
                Text(entry.label).tag(entry.id)
            }
        }

        if row.accessProfiles.first(where: { $0.id == profile })?.write == true {
            Text(ProductStrings[.integrationWorkspaceWriteWarning])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func list(_ row: IntegrationRowModel) -> some View {
        if row.workspaces.isEmpty {
            Text(ProductStrings[.integrationWorkspaceEmpty])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            List(row.workspaces, id: \.id, selection: $chosen) { workspace in
                Text(workspace.label).tag(workspace.id)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func select() {
        guard let workspace = row?.workspaces.first(where: { $0.id == chosen }) else { return }

        Task {
            refusal = await model.startWorkspaceSelection(
                name: name,
                profile: profile,
                workspace: workspace,
                on: runner
            )
        }
    }
}
