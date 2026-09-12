import SwiftUI

/// Add an API key (M34 §5.1).
///
/// One sheet, both doors. The Providers pane opens it over the single provider
/// its row named; Connect your AI opens it over every provider the daemon
/// published an `api_key` mode and a slot for, and the picker chooses between
/// them. The key is typed into the one secure input the product has, verified
/// by the daemon, and stored. A blank is never sent, and a refusal keeps the
/// sheet open with the daemon's own sentence so nothing has to be retyped.
struct AddKeySheet: View {
    /// Where a key may be written. Never empty: a sheet with nowhere to write
    /// cannot be opened at all, which is what keeps the slot the daemon's.
    let targets: [ProviderKeyTarget]
    @ObservedObject var model: SettingsModel
    let dismiss: () -> Void

    @State private var chosen: String
    @State private var value = ""
    @State private var refusal: String?
    @State private var storing = false

    init(targets: [ProviderKeyTarget], selected: String, model: SettingsModel, dismiss: @escaping () -> Void) {
        precondition(!targets.isEmpty, "a key sheet opens over at least one slot")

        self.targets = targets
        self.model = model
        self.dismiss = dismiss
        _chosen = State(initialValue: targets.contains { $0.id == selected } ? selected : targets[0].id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[target.secret == ProviderRowProjection.anthropicSetupTokenID
                ? .providerVerbAddSetupToken : .providerAddKeyTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            picker

            Text(target.secret == ProviderRowProjection.anthropicSetupTokenID
                ? ProductStrings[.providerSetupTokenBody]
                : String(format: ProductStrings[.providerAddKeySubcopyFormat], target.label))
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            SecretInput(label: target.label, value: $value, onSubmit: store)

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

                Button(ProductStrings[.providerVerifyAndSave], action: store)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty || storing)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
    }

    /// Offered only where there is a choice to make. One target draws no
    /// control: a picker over a single row is a label that looks clickable.
    @ViewBuilder
    private var picker: some View {
        if targets.count > 1 {
            Picker(ProductStrings[.providerAddKeyProvider], selection: $chosen) {
                ForEach(targets) { entry in
                    Text(entry.label).tag(entry.id)
                }
            }
            .accessibilityLabel(ProductStrings[.providerAddKeyProvider])
        }
    }

    /// The chosen target. The initialiser refuses an empty list and pins the
    /// selection to a published id, so this always resolves.
    private var target: ProviderKeyTarget {
        guard let found = targets.first(where: { $0.id == chosen }) else {
            preconditionFailure("the key sheet's selection is one of its own targets")
        }

        return found
    }

    /// The daemon owns the id a provider's key sits under: it is the key of the
    /// secret row it published for that provider, or the setup-token id the
    /// contract names. Never the provider id, which `secret.set` does not take.
    private func store() {
        guard !value.isEmpty, !storing else { return }

        storing = true
        Task {
            let sentence = await model.setSecret(id: target.secret, value: value)
            storing = false
            refusal = sentence

            guard sentence == nil else { return }

            value = ""
            dismiss()
        }
    }
}

/// Sign in (M34 §5.1).
///
/// One sheet for both doors. The browser opens on the row's click, so by the
/// time this is on screen the tab is already there: what the sheet adds is the
/// step the daemon reports, one way to open the tab again where it was lost,
/// and one way to stop.
struct SignInSheet: View {
    /// What the product calls the provider being signed in to.
    let label: String
    let importing: Bool
    let starting: Bool
    @ObservedObject var runner: JobRunner
    /// Opens the browser again for the same provider.
    let reopen: () -> Void
    let retry: () -> Void
    let browserFallback: (() -> Void)?
    let dismiss: () -> Void
    @State private var cancelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[importing ? .providerImportTitle : .providerSignInTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            Text(ProductStrings[importing ? .providerImportBody : .providerSignInBody])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            progress

            if let sentence = runner.failure ?? runner.browserFailure {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            actions
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
        .task(id: runner.job?.status) {
            guard runner.job?.status == .completed || runner.job?.status == .cancelled else { return }

            dismiss()
        }
    }

    private var progress: some View {
        HStack(spacing: Spacing.s) {
            if starting || runner.isRunning {
                ProgressView(value: runner.progress?.fraction)
                    .controlSize(.small)
            }
            if let phase = runner.phase {
                Text(phase)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)

            if runner.isRunning {
                runningActions
            } else {
                terminalActions
            }
        }
        .disabled(starting)
    }

    @ViewBuilder
    private var runningActions: some View {
        Button(ProductStrings[.settingsSheetCancel], action: cancel)
            .keyboardShortcut(.cancelAction)
            .disabled(cancelling)

        if !importing {
            Button(ProductStrings[.providerSignInReopen], action: reopen)
                .keyboardShortcut(.defaultAction)
                .disabled(runner.authorizationURL == nil)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerSignInReopen], label))
        }
    }

    @ViewBuilder
    private var terminalActions: some View {
        Button(ProductStrings[.providerSignInRetry], action: retry)
        if let browserFallback {
            Button(ProductStrings[.providerSignInBrowser], action: browserFallback)
        }
        Button(ProductStrings[.settingsSheetDone], action: dismiss)
            .keyboardShortcut(.cancelAction)
    }

    private func cancel() {
        guard runner.isRunning else {
            dismiss()
            return
        }

        cancelling = true
        Task {
            await runner.cancelJob()
            cancelling = false
        }
    }
}

/// Choose a model (M34 §5.1).
///
/// Paginated over `providers.models.list`, because a provider with thousands of
/// models is exactly why that method has a cursor. A live listing that fails
/// says so; it never falls back to the catalog under a live label.
struct ModelPickerSheet: View {
    /// Which provider's models to list. It is the primary provider's id, read
    /// from `setup.state.get`, because a descriptor row names a model and never
    /// the provider that serves it.
    let provider: String
    @ObservedObject var model: SettingsModel
    /// Writes the chosen model to the row that opened this sheet.
    let commit: (String) -> Void
    let dismiss: () -> Void

    @State private var models: [ManagementProviderModel] = []
    @State private var cursor: String?
    @State private var query = ""
    @State private var refusal: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ProductStrings[.providerModelsTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            TextField(
                ProductStrings[.providerModelsTitle],
                text: $query,
                prompt: Text(ProductStrings[.providerModelsSearchPrompt])
            )
            .labelsHidden()
            .onSubmit { Task { await reload() } }

            list

            if let refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
        .task { await reload() }
    }

    private var list: some View {
        List(models, id: \.id) { entry in
            Button(entry.label) {
                commit(entry.id)
                dismiss()
            }
            .accessibilityLabel(entry.label)
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { more }
    }

    @ViewBuilder
    private var more: some View {
        if cursor != nil {
            Button(ProductStrings[.providerModelsMore]) { Task { await page() } }
                .disabled(loading)
        }
    }

    private func reload() async {
        models = []
        cursor = nil
        await page()
    }

    /// One page. The cursor is the daemon's, so paging never re-reads what it
    /// already returned.
    private func page() async {
        guard !loading else { return }

        loading = true
        defer { loading = false }

        switch await model.models(
            provider: provider,
            live: true,
            query: query.isEmpty ? nil : query,
            cursor: cursor
        ) {
        case .page(let page):
            models += page.models
            cursor = page.cursor
            refusal = nil
        case .refused(let sentence):
            refusal = sentence
            cursor = nil
        }
    }
}
