import SwiftUI

/// Connect your AI: the one required decision (M34 §4).
///
/// Three rows at 460 wide. Detections change the verb a row leads with and never
/// add a row or a screen, and a home that already answers renders the
/// already-connected form instead. Every fact here is the daemon's, read through
/// the one settings model; Swift parses no provider, secret, or config value.
struct ConnectAISurface: View {
    @ObservedObject var model: OnboardingModel

    /// The key sheet, carrying the slots it may write to. A value rather than a
    /// flag, so it cannot be presented with nothing to write to.
    @State private var keySheet: AssistantKeySheet?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            content

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
        .padding(.top, Spacing.xs)
        .task {
            await model.refreshReadiness()
            await model.settings.refreshDetections(ActivationPolicy.detectTargets)
            // The key verb writes to the slot each provider's own section
            // names, so the rows are only performable once those are read.
            await model.loadProviderSections()
        }
        .sheet(item: $keySheet) { sheet in
            AddKeySheet(
                targets: sheet.targets,
                selected: sheet.selected,
                model: model.settings,
                // A key stored here answers the one required decision, and the
                // gate that reads it only moves on a read: without this the
                // bar's Continue would go on refusing for a provider that is
                // now connected.
                dismiss: {
                    keySheet = nil
                    Task { await model.refreshReadiness() }
                }
            )
        }
        .sheet(isPresented: waitingForSignIn) { signInSheet }
    }

    @ViewBuilder
    private var content: some View {
        if model.settings.requiresNewerEngine {
            AssistantNotice(sentence: model.settings.newerEngineSentence)
        } else if let connected = model.alreadyConnected {
            alreadyConnected(connected)
        } else {
            rows
        }
    }

    /// The design's three rows (M34 §4): the two vendors the assistant names,
    /// and the one door to every provider that takes a typed key.
    ///
    /// Three and no more, whatever the daemon publishes. The provider list is
    /// the Providers pane's to render in full; this screen is the one required
    /// decision, and a screen that grows a row per descriptor cannot fit the
    /// window it is drawn in.
    private var rows: some View {
        VStack(spacing: 0) {
            SurfaceHeading(
                title: ProductStrings[.connectAITitle],
                subcopy: ProductStrings[.connectAISubcopy]
            )
            .padding(.bottom, Spacing.l)

            Form {
                Section {
                    ForEach(model.providerRows) { row in
                        ProviderSignInRow(
                            row: row,
                            perform: { perform(row) },
                            enabled: !model.settings.startingSignIn && !model.signIn.isRunning,
                            browserFallback: browserFallback(for: row)
                        )
                    }

                    AssistantKeyRow(targets: model.keyTargets) { targets in
                        guard let first = targets.first else { return }

                        keySheet = AssistantKeySheet(targets: targets, selected: first.id)
                    }
                } footer: {
                    signInRefusal
                }
            }
            .formStyle(.grouped)
            .assistantFormChrome()

            if let blocked = model.blocked {
                AssistantNotice(sentence: model.message(for: blocked)).padding(.top, Spacing.s)
            }

            if let refusal = model.preparationRefusal {
                AssistantNotice(sentence: refusal).padding(.top, Spacing.s)
            }
        }
    }

    /// A sign-in the daemon refused before it began, stated under the rows
    /// that offered it.
    ///
    /// The waiting sheet draws the same runner, but it opens only for a flow
    /// that actually started, so a refused `auth.start` left the row exactly as
    /// it was and the button read as dead (owner report of 2026-09-04). The
    /// sentence is the daemon's own, and the next attempt clears it.
    @ViewBuilder
    private var signInRefusal: some View {
        if let sentence = model.signIn.failure {
            Text(sentence)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// The already-connected form (M34 §4): what was found, and the two ways
    /// forward. Continue is the bottom bar's default action, so this screen adds
    /// only the change-provider link.
    private func alreadyConnected(_ provider: ManagementSetupProvider) -> some View {
        VStack(spacing: 0) {
            SurfaceHeading(
                title: ProductStrings[.connectAIConnectedTitle],
                subcopy: ProductStrings[.connectAIConnectedBody]
            )
            .padding(.bottom, Spacing.l)

            Text(providerSummary(provider))
                .fermixType(Typography.style(.bodyCompact).weight(.semibold))
                .foregroundStyle(Palette.ink.color)

            LinkButton(title: ProductStrings[.connectAIChangeProvider]) {
                model.changeProvider()
            }
            .padding(.top, Spacing.m)
        }
    }

    private func providerSummary(_ provider: ManagementSetupProvider) -> String {
        guard let named = provider.defaultModel, !named.isEmpty else { return provider.label }

        return ProductStrings.middot(provider.label, named)
    }

    /// The one sign-in sheet, the same one the Providers pane draws. The
    /// browser was already opened by the row's click, so the sheet only reports
    /// the step and offers the tab again.
    @ViewBuilder
    private var signInSheet: some View {
        if let provider = model.settings.signingInProvider {
            SignInSheet(
                label: model.providers.first { $0.id == provider }?.label ?? provider,
                importing: model.signIn.job?.kind == .authImport,
                starting: model.settings.startingSignIn,
                runner: model.signIn,
                reopen: { model.settings.reopenSignIn(on: model.signIn) },
                retry: { retrySignIn(provider: provider) },
                browserFallback: provider == "openai_codex" && model.signIn.job?.kind == .authImport
                    ? { Task { await model.startSignIn(provider: provider) } } : nil
            ) {
                Task { await model.signInFinished() }
            }
        }
    }

    private func retrySignIn(provider: String) {
        guard model.signIn.job?.kind == .authImport else {
            Task { await model.startSignIn(provider: provider) }
            return
        }

        let source: ManagementAuthImportSource = provider == "anthropic" ? .claudeCode : .codexCLI
        Task { await model.importSignIn(source: source, provider: provider) }
    }

    private func browserFallback(for row: ProviderRowModel) -> (() -> Void)? {
        guard row.verb == .importCodexCLI else { return nil }

        return { Task { await model.startSignIn(provider: row.id) } }
    }

    /// The waiting sheet is open exactly while a sign-in is in flight, which is
    /// the one status word no daemon field can report: the browser hop happens
    /// outside the daemon.
    private var waitingForSignIn: Binding<Bool> {
        Binding(
            get: { model.settings.signingInProvider != nil },
            set: { open in
                guard !open else { return }

                Task { await model.signInFinished() }
            }
        )
    }

    /// One row, one verb. A verb that writes a secret waits for the slot the
    /// daemon published rather than guessing one: with no slot the row is not
    /// performable at all, so the sheet cannot be opened without one.
    private func perform(_ row: ProviderRowModel) {
        switch row.verb {
        case .signIn:
            Task { await model.startSignIn(provider: row.id) }
        case .importClaudeCode:
            Task { await model.importSignIn(source: .claudeCode, provider: row.id) }
        case .importCodexCLI:
            Task { await model.importSignIn(source: .codexCLI, provider: row.id) }
        case .addKey, .addSetupToken:
            guard let secret = row.secretID else { return }

            let target = ProviderKeyTarget(provider: row.id, label: row.label, secret: secret)
            keySheet = AssistantKeySheet(targets: [target], selected: target.id)
        case .none:
            return
        }
    }
}

/// The key sheet the assistant opens, carrying the daemon's own slots.
///
/// The slots are part of the value, so the sheet cannot be presented without
/// somewhere to write to.
struct AssistantKeySheet: Identifiable, Equatable {
    let targets: [ProviderKeyTarget]
    let selected: String

    var id: String { selected + ":" + targets.map(\.secret).joined(separator: ",") }
}

/// One line the assistant states rather than an error it reports: the N-1 engine
/// window, or the daemon's own refusal of a read (M34 §7.1).
struct AssistantNotice: View {
    let sentence: String

    var body: some View {
        Text(sentence)
            .fermixType(Typography.style(.bodyCompact))
            .foregroundStyle(Palette.secondary.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: OnboardingMetrics.contentWidth)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The title and the one line of subcopy every decision screen opens with.
///
/// Two tiers and no more: a title, one sentence, and nothing under it. It is
/// the shape the whole assistant now keeps (owner directive of 2026-09-03:
/// "Too many subtexts/headings throws off. doesnt look elegant"), so a screen
/// that wants a third thing to say has to make it the sentence.
struct SurfaceHeading: View {
    let title: String
    let subcopy: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Text(title)
                .fermixType(Typography.style(.title))
                .foregroundStyle(Palette.ink.color)

            Text(subcopy)
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: OnboardingMetrics.contentWidth)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One row on Connect your AI: a leading mark, the name over where it stands,
/// and the one verb.
///
/// A grouped-form row. The 64-point card this used to paint, with its own fill,
/// hairline and radius, was the third container grammar across three
/// consecutive screens; the section around these rows draws the box now, and
/// the row draws nothing.
struct AssistantChoiceRow<Leading: View>: View {
    let title: String
    let status: String
    let verb: String?
    let enabled: Bool
    let perform: () -> Void
    var browserFallback: (() -> Void)? = nil
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        LabeledContent {
            if let verb {
                choiceControl(verb)
                    .disabled(!enabled)
                    .accessibilityLabel(ProductStrings.commaPair(verb, title))
            }
        } label: {
            HStack(spacing: Spacing.s) {
                leading()

                VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                    Text(title)
                        .fermixType(Typography.style(.bodyCompact).weight(.semibold))
                        .foregroundStyle(Palette.ink.color)

                    Text(status)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                }
            }
        }
    }

    @ViewBuilder
    private func choiceControl(_ title: String) -> some View {
        if let browserFallback {
            Menu(title) {
                Button(title, action: perform)
                Button(ProductStrings[.providerSignInBrowser], action: browserFallback)
            }
        } else {
            Button(title, action: perform)
        }
    }
}

/// One vendor row: the mark, the name and where it stands, and the one verb the
/// daemon's own facts earned.
struct ProviderSignInRow: View {
    let row: ProviderRowModel
    let perform: () -> Void
    var enabled = true
    var browserFallback: (() -> Void)? = nil

    var body: some View {
        AssistantChoiceRow(
            title: row.label,
            status: row.status,
            verb: row.verb.title,
            enabled: row.canPerform && enabled,
            perform: perform,
            browserFallback: browserFallback
        ) {
            ProviderMarkDisc(provider: row.id, label: row.label, diameter: OnboardingMetrics.rowMarkSize)
        }
    }
}

/// The third row: one door to every provider that takes a typed key.
///
/// It is performable once the daemon has named at least one slot to write to,
/// which is the same rule a vendor row's key verb follows. The picker inside the
/// sheet is where the provider is chosen, so this row names no vendor and cannot
/// go stale when the engine publishes another one.
struct AssistantKeyRow: View {
    let targets: [ProviderKeyTarget]
    let open: ([ProviderKeyTarget]) -> Void

    var body: some View {
        AssistantChoiceRow(
            title: ProductStrings[.connectAIKeyRowTitle],
            status: ProductStrings[.connectAIKeyRowHint],
            verb: ProductStrings[.providerVerbAddKey],
            enabled: !targets.isEmpty,
            perform: { open(targets) }
        ) {
            Image(systemName: "key")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.secondary.color)
                .frame(width: OnboardingMetrics.rowMarkSize, height: OnboardingMetrics.rowMarkSize)
                .background(Circle().fill(Palette.base200.color))
                .accessibilityHidden(true)
        }
    }
}
