import SwiftUI

/// The provider sub-page (M34 §5.1).
///
/// Everything that belongs to one provider rather than to the list: its auth
/// mode, its key, its base URL, its reasoning effort and fast mode. All of them
/// are the daemon's own `providers.<id>` descriptor rows, so this page holds no
/// field inventory — a routing key added in the engine appears here with no
/// Swift. The page also offers account replacement, sign out, and use as primary.
///
/// A sheet rather than a pushed page, for the same reason the channel sub-page
/// is one: the settings presentation carries exactly one back control
/// (redlines §5.8), and a second navigation stack would put a second chevron
/// beside it.
struct ProviderDetailSheet: View {
    let row: ProviderRowModel
    @ObservedObject var model: SettingsModel
    /// Asks the pane to confirm the primary change, which declares its side
    /// effect before it happens. The pane owns that dialog because it owns the
    /// refusal sentence the daemon answers with.
    let confirmPrimary: (ProviderRowModel) -> Void
    let requestAuth: (ProviderRequest) -> Void
    let dismiss: () -> Void

    @State private var refusal: String?
    @State private var signingOut = false
    /// The model row the operator asked to change, where the daemon could not
    /// inline its options. A value rather than a flag, so the sheet writes back
    /// to the row that opened it.
    @State private var choosingModel: ModelPick?

    /// One model listing, addressed by the row that opens it.
    struct ModelPick: Identifiable, Equatable {
        let section: String
        let key: String

        var id: String { "\(section)/\(key)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            heading

            rows

            authentication

            verbs

            if let refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetDone], action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width)
        // Escape cancels, on every sheet (M34 §3.1). This one commits each row
        // as it is edited, so leaving is the whole of cancelling and `Done` is
        // the only button; without this the key did nothing at all.
        .onExitCommand(perform: dismiss)
        .sheet(item: $choosingModel) { pick in
            ModelPickerSheet(provider: row.id, model: model) { chosen in
                Task { await model.apply(section: pick.section, key: pick.key, value: .text(chosen)) }
            } dismiss: {
                choosingModel = nil
            }
        }
        .task { await model.loadSection(section) }
    }

    private var section: String { ProviderRowProjection.sectionId(for: row.id) }

    /// This provider's own rows, where this is the surface that draws them.
    ///
    /// The primary's live on the pane, which leads with them (M34 §5.1), so for
    /// the primary this page is the two verbs and nothing else: one key, one
    /// control, one place. `ProviderRowProjection.draws` is the one rule both
    /// surfaces read.
    @ViewBuilder
    private var rows: some View {
        if ProviderRowProjection.draws(.subPage, primary: row.primary) {
            DescriptorRows(model: model, section: section, specialised: { descriptorRow in
                modelRow(descriptorRow)
            }, excluding: model.providerCredentialExclusions(row.id))
        }
    }

    /// The one specialised row: a model listing the daemon could not inline
    /// opens the paginated sheet rather than an empty picker. The provider is
    /// this page's own, which is the fact the pane cannot supply for a row that
    /// belongs to a provider other than the primary.
    private func modelRow(_ descriptorRow: ManagementSettingRow) -> AnyView? {
        guard descriptorRow.needsModelPicker else { return nil }

        return AnyView(
            ModelChoiceRow(row: descriptorRow, section: section, model: model) {
                choosingModel = ModelPick(section: section, key: descriptorRow.key)
            }
        )
    }

    private var heading: some View {
        HStack(spacing: Spacing.xs) {
            ProviderMarkDisc(provider: row.id, label: row.label, diameter: IntegrationMetrics.tileSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .fermixType(Typography.sheetTitle)
                    .foregroundStyle(Palette.ink.color)

                Text(row.status)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }

    @ViewBuilder
    private var authentication: some View {
        let actions = ProviderRowProjection.detailAuthVerbs(
            for: row.id, detections: model.detections.value, authMode: model.providerAuthMode(row.id)
        )

        if !actions.isEmpty {
            HStack(spacing: Spacing.xs) {
                ForEach(actions, id: \.rawValue) { verb in
                    Button(authTitle(verb)) { authenticate(verb) }
                        .disabled(signingOut || model.writesBlocked || model.startingSignIn)
                        .accessibilityLabel(ProductStrings.commaPair(authTitle(verb), row.label))
                }
            }
        }
    }

    private func authTitle(_ verb: ProviderVerb) -> String {
        if verb == .signIn { return ProductStrings[.providerSignInBrowser] }

        guard let title = verb.title else { preconditionFailure("a credential action has a title") }

        return title
    }

    private func authenticate(_ verb: ProviderVerb) {
        switch verb {
        case .signIn:
            requestAuth(.signIn(row))
        case .importClaudeCode:
            requestAuth(.importSignIn(row, .claudeCode))
        case .importCodexCLI:
            requestAuth(.importSignIn(row, .codexCLI))
        case .addSetupToken:
            guard let secret = ProviderRowProjection.secretID(for: verb, rows: []) else {
                preconditionFailure("the setup-token action names its published slot")
            }
            requestAuth(.sheet(.addKey(ProviderKeyTarget(provider: row.id, label: row.label, secret: secret))))
        case .addKey, .none:
            preconditionFailure("this action is not offered by the account credential row")
        }
    }

    /// Sign out forgets the local session and revokes nothing upstream. Use as
    /// primary goes back to the pane, which declares the side effect first.
    @ViewBuilder
    private var verbs: some View {
        HStack(spacing: Spacing.xs) {
            Button(ProductStrings[.providerSignOut], action: signOut)
                // Both verbs write, and the daemon refuses a write while the
                // settings file has changed outside Fermix (M34 §7.6).
                .disabled(signingOut || model.writesBlocked)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerSignOut], row.label))

            // Only a provider the daemon reports as working: making an
            // unverified one primary is a write it refuses (M34 §5.1).
            if !row.primary, row.configured {
                Button(ProductStrings[.providerUsePrimary]) { confirmPrimary(row) }
                    .disabled(model.writesBlocked)
                    .accessibilityLabel(
                        ProductStrings.commaPair(ProductStrings[.providerUsePrimary], row.label)
                    )
            }
        }
    }

    private func signOut() {
        signingOut = true
        Task {
            refusal = await model.logOut(provider: row.id)
            signingOut = false
        }
    }
}
