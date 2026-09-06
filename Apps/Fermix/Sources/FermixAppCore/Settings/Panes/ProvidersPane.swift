import SwiftUI

/// Providers: hand-built rows over the daemon's own provider facts, plus every
/// descriptor section the daemon assigned to this pane (M34 §5.1).
///
/// The rows and their verbs are hand-built because a provider row is a flow —
/// sign in, add a key, reconnect — rather than a value. Everything scalar
/// underneath is the descriptor, so a routing key added in the engine appears
/// here with no Swift.
struct ProvidersPane: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var auth: JobRunner
    @State private var sheet: ProviderSheet?
    @State private var refusal: String?
    @State private var confirming: ProviderRowModel?
    @State private var startingAuth = false

    init(model: SettingsModel) {
        self.model = model
        _auth = StateObject(wrappedValue: model.makeJobRunner())
    }

    var body: some View {
        SettingsPaneForm(title: SettingsPane.providers.title) {
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            } else {
                primarySection
                descriptorSections
                providers
            }
        }
        .sheet(item: $sheet) { sheetView($0) }
        .confirmationDialog(
            ProductStrings[.providerPrimaryConfirmTitle],
            isPresented: confirmationShown,
            titleVisibility: .visible
        ) {
            Button(ProductStrings[.providerUsePrimary]) { makePrimary() }
            Button(ProductStrings[.settingsSheetCancel], role: .cancel) { confirming = nil }
        } message: {
            Text(ProductStrings[.providerPrimaryConfirmBody])
        }
        // Detections change the verbs, so they are read when the pane opens and
        // never on a render. Each provider's own section is read with them,
        // because that is where the sub-page's rows and the key slot live.
        .task {
            await model.refreshDetections([.claudeCode, .codexCLI, .existingPrimary])
            await model.loadProviderSections(for: published)
        }
        .onChange(of: auth.isRunning) { _, running in
            guard !running else { return }

            Task { await model.signInFinished() }
        }
    }

    private var published: [ManagementSetupProvider] {
        model.setupState.value?.providers ?? []
    }

    /// The pane's first section: the primary provider's own rows (M34 §5.1).
    ///
    /// The model in use, its reasoning effort and its fast mode are the pane's
    /// headline, and reaching them only through a row's `Details…` hid the one
    /// fact most visits come for. The rows are the daemon's `providers.<id>`
    /// section drawn whole, and that provider's sub-page draws none of them, so
    /// no key carries a control in two places.
    ///
    /// A home with no primary has no such section: there is no model in use to
    /// lead with yet.
    @ViewBuilder
    private var primarySection: some View {
        if let provider = ProviderRowProjection.paneProvider(in: published) {
            let section = ProviderRowProjection.sectionId(for: provider.id)

            Section {
                DescriptorRows(model: model, section: section, specialised: { row in
                    modelRow(row, in: section)
                }, excluding: model.providerCredentialExclusions(provider.id))
            } header: {
                Text(ProductStrings[.settingsPrimarySection])
            } footer: {
                Text(provider.configured
                    ? String(format: ProductStrings[.settingsPrimaryFooterFormat], provider.label)
                    : ProductStrings[.settingsPrimaryUnconfiguredBody])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: [ProviderRowModel] {
        ProviderRowProjection.rows(
            providers: published,
            detections: model.detections.value,
            signingIn: model.signingInProvider,
            // Where a provider's key slot is named. The shared model owns the
            // lookup, so this pane and the assistant read one answer.
            descriptorRows: model.providerDescriptorRows(for: published),
            selectedAuthModes: Dictionary(uniqueKeysWithValues: published.compactMap { provider in
                model.providerAuthMode(provider.id).map { (provider.id, $0) }
            })
        )
    }

    @ViewBuilder
    private var providers: some View {
        Section(ProductStrings[.settingsProvidersSection]) {
            ForEach(rows) { row in
                ProviderRow(row: row, runner: auth, model: model, starting: startingAuth, present: present)
            }

            if let sentence = refusal ?? auth.failure {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            ForEach(model.sideEffects, id: \.self) { sentence in
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
        }
    }

    /// The descriptor sections of this pane that belong to no single provider.
    ///
    /// A provider's own rows are drawn by exactly one surface (M34 §5.1): the
    /// primary's by `primarySection` above, every other provider's by its
    /// sub-page, as `ProviderRowProjection.draws` decides. Rendering them here
    /// as well would give one key two controls in two places and make the pane
    /// the longest scroll in the app. `ChannelsPane` filters the same way.
    private var otherSections: [ManagementSettingsSection] {
        model.sections(for: .providers).filter { $0.providerId == nil }
    }

    @ViewBuilder
    private var descriptorSections: some View {
        ForEach(otherSections, id: \.id) { section in
            DescriptorSection(model: model, section: section) { row in
                modelRow(row, in: section.id)
            }
        }
    }

    /// The one specialised row: a model listing too large for the daemon to
    /// inline opens the paginated sheet instead of an empty picker.
    ///
    /// Every section this pane draws belongs to the primary — its own section
    /// and the routing keys that name its model — so the listing is read for
    /// the primary provider. A row belonging to any other provider is drawn on
    /// that provider's sub-page, which reads its own.
    private func modelRow(_ row: ManagementSettingRow, in section: String) -> AnyView? {
        guard row.needsModelPicker, let provider = primaryProvider else { return nil }

        return AnyView(
            ModelChoiceRow(row: row, section: section, model: model) {
                sheet = .models(provider: provider, section: section, key: row.key)
            }
        )
    }

    /// The provider a model row belongs to. Read from the daemon's own state:
    /// a descriptor row names a model and never the provider that serves it.
    private var primaryProvider: String? {
        published.first { $0.primary }?.id
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { shown in
            guard !shown else { return }

            confirming = nil
        })
    }

    private func present(_ request: ProviderRequest) {
        switch request {
        case .sheet(let sheet): self.sheet = sheet
        case .confirmPrimary(let row): confirming = row
        case .signIn(let row): startSignIn(row)
        case .importSignIn(let row, let source): startSignIn(row, source: source)
        }
    }

    /// The browser opens on the click, and the sheet says what is happening
    /// while it is open (M34 §5.1). Both doors into a sign-in behave this way,
    /// so a person clicking `Sign in` is never asked to click a second button
    /// inside a sheet to make anything happen.
    private func startSignIn(_ row: ProviderRowModel, source: ManagementAuthImportSource? = nil) {
        guard !startingAuth else { return }

        startingAuth = true
        refusal = nil
        Task {
            defer {
                startingAuth = false
                sheet = .signIn(row, source: source)
            }
            guard let source else {
                refusal = await model.startSignIn(provider: row.id, on: auth)
                return
            }

            refusal = await model.startAuthImport(source: source, provider: row.id, on: auth)
        }
    }

    /// `Use as primary` declares its side effect before it happens, because the
    /// daemon resets the sub-agent model with it.
    private func makePrimary() {
        guard let row = confirming else { return }

        confirming = nil
        Task { refusal = await model.setPrimary(row.id) }
    }

    @ViewBuilder
    private func sheetView(_ sheet: ProviderSheet) -> some View {
        switch sheet {
        case .addKey(let target):
            AddKeySheet(targets: [target], selected: target.id, model: model) { self.sheet = nil }
        case .signIn(let row, let source):
            SignInSheet(
                label: row.label,
                importing: source != nil,
                starting: model.startingSignIn,
                runner: auth,
                reopen: { model.reopenSignIn(on: auth) },
                retry: { startSignIn(row, source: source) },
                browserFallback: source == .codexCLI ? { startSignIn(row) } : nil
            ) { self.sheet = nil }
        case .models(let provider, let section, let key):
            ModelPickerSheet(provider: provider, model: model) { chosen in
                Task { await self.model.apply(section: section, key: key, value: .text(chosen)) }
            } dismiss: {
                self.sheet = nil
            }
        case .detail(let row):
            ProviderDetailSheet(row: row, model: model, confirmPrimary: { provider in
                // The dialog belongs to the pane, which owns the refusal
                // sentence: two confirmations would be two chances to disagree
                // about what `Use as primary` costs.
                self.sheet = nil
                confirming = provider
            }, requestAuth: present) {
                self.sheet = nil
            }
        }
    }
}

/// What a provider row asks the pane for.
enum ProviderRequest: Equatable {
    case sheet(ProviderSheet)
    case confirmPrimary(ProviderRowModel)
    /// Start the browser hop and show what it is doing. Not a sheet case: the
    /// pane starts the flow and then presents, so the sheet never has to.
    case signIn(ProviderRowModel)
    case importSignIn(ProviderRowModel, ManagementAuthImportSource)
}

/// Which provider sheet is open. One value rather than three booleans, so two
/// cannot be open at once.
enum ProviderSheet: Identifiable, Equatable {
    /// The key sheet carries the daemon's own slot id, so the sheet cannot be
    /// opened at all without one to write to.
    case addKey(ProviderKeyTarget)
    case signIn(ProviderRowModel, source: ManagementAuthImportSource? = nil)
    /// A model listing for one provider, opened by the descriptor row that
    /// names the model and committed back to that row's key.
    case models(provider: String, section: String, key: String)
    /// The provider sub-page (M34 §5.1).
    case detail(ProviderRowModel)

    var id: String {
        switch self {
        case .addKey(let target): return "key:\(target.provider):\(target.secret)"
        case .signIn(let row, let source): return "signin:\(row.id):\(source?.wireValue ?? "browser")"
        case .models(let provider, let section, let key): return "models:\(provider):\(section)/\(key)"
        case .detail(let row): return "detail:\(row.id)"
        }
    }
}

/// One provider row: the vendor, where it stands, and the one verb.
struct ProviderRow: View {
    let row: ProviderRowModel
    @ObservedObject var runner: JobRunner
    @ObservedObject var model: SettingsModel
    let starting: Bool
    let present: (ProviderRequest) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                Text(row.status)
                    .foregroundStyle(Palette.secondary.color)

                if let title = row.verb.title {
                    authenticationControl(title)
                        // Every verb here ends in a write the daemon refuses
                        // while the settings file has changed outside Fermix
                        // (M34 §7.6), so the row does not offer it.
                        .disabled(starting || model.startingSignIn || runner.isRunning || !row.canPerform || model.writesBlocked)
                        .accessibilityLabel(ProductStrings.commaPair(title, row.label))
                }

                // `Use as primary` lives on the sub-page beside the other verb
                // that is not a value (M34 §5.1). On the row it made a third
                // bordered control per line and a wall of them down the pane,
                // against the grouped form's one trailing control.
                //
                // The way to the sub-page, where everything that belongs to
                // this provider alone lives.
                Button(ProductStrings[.providerDetails]) { present(.sheet(.detail(row))) }
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerDetails], row.label))
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                VendorMarkView(
                    mark: VendorMarks.mark(.provider, row.id),
                    kind: .provider,
                    size: SettingsRowMetrics.markSize
                )

                Text(row.label)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
        }
    }

    @ViewBuilder
    private func authenticationControl(_ title: String) -> some View {
        if row.verb == .importCodexCLI {
            Menu(title) {
                Button(title, action: perform)
                Button(ProductStrings[.providerSignInBrowser]) { present(.signIn(row)) }
            }
        } else {
            Button(title, action: perform)
        }
    }

    private func perform() {
        switch row.verb {
        case .signIn:
            present(.signIn(row))
        case .addKey, .addSetupToken:
            // The button is disabled until the daemon has named the slot, so a
            // key sheet never opens without one and no id is ever minted from
            // the provider id.
            guard let secret = row.secretID else {
                preconditionFailure("a key sheet opens only once the daemon named the slot")
            }

            present(.sheet(.addKey(ProviderKeyTarget(provider: row.id, label: row.label, secret: secret))))
        case .importClaudeCode:
            present(.importSignIn(row, .claudeCode))
        case .importCodexCLI:
            present(.importSignIn(row, .codexCLI))
        case .none:
            // A connected primary carries no verb, so no button reaches this.
            preconditionFailure("a provider row with no verb draws no button")
        }
    }

}


/// Whether a descriptor row is a model listing too large for the daemon to
/// inline, which is the one row the paginated picker answers.
///
/// The rule keys on the row's own shape, never on its key, and it is written
/// once so the pane and the provider sub-page cannot decide it differently.
extension ManagementSettingRow {
    var needsModelPicker: Bool {
        guard case .choice = kind, !readOnly else { return false }

        return options.isEmpty
    }
}

/// Model discovery is optional for a row that also accepts a custom ID.
struct ModelChoiceRow: View {
    let row: ManagementSettingRow
    let section: String
    @ObservedObject var model: SettingsModel
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            if let modelField {
                modelField
            } else {
                listedValue
            }
            if let footer = row.footer, !footer.isEmpty {
                Text(footer)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refusal = model.message(for: key) {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.writesBlocked)
    }

    var modelField: DescriptorTextRow? {
        guard row.suggestions, !row.readOnly else { return nil }

        return DescriptorTextRow(
            label: row.label, prompt: row.emptyValuePrompt,
            value: DescriptorValue.text(model.value(of: row, in: section)),
            model: model, key: key,
            commit: { value in Task { await model.apply(section: section, key: row.key, value: value) } },
            accessory: AnyView(chooser)
        )
    }

    private var key: SettingsDraftKey { SettingsDraftKey(section: section, key: row.key) }

    private var listedValue: some View {
        LabeledContent(row.label) {
            HStack(spacing: Spacing.xs) {
                Text(DescriptorValue.text(model.value(of: row, in: section)))
                    .foregroundStyle(Palette.secondary.color)
                chooser
            }
        }
    }

    private var chooser: some View {
        Button(ProductStrings[.providerModelsChoose], action: choose)
            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerModelsChoose], row.label))
    }
}
