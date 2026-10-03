import SwiftUI

/// The provider sub-page (M34 §5.1).
///
/// Everything that belongs to one provider rather than to the list: how it
/// connects and as whom, its base URL, its model and its reasoning effort. The
/// settings are the daemon's own `providers.<id>` descriptor rows, so this page
/// holds no field inventory — a routing key added in the engine appears here
/// with no Swift. The page also offers sign out and use as primary.
///
/// A sheet rather than a pushed page, for the same reason the channel sub-page
/// is one: the settings presentation carries exactly one back control
/// (redlines §5.8), and a second navigation stack would put a second chevron
/// beside it.
///
/// One popup, and it never raises another (owner directive of 2026-09-20). It
/// used to: the key opened a sheet over it and so did the model listing, which
/// put a person three windows deep to paste a key. The key is typed in its own
/// row now, and the model listing is a page of this same sheet.
///
/// It leads with how the provider really connects. Sign-in is the primary
/// method wherever a provider has one, so its doors come first and its key
/// waits behind one disclosure; a provider whose only way in is a key leads
/// with the key.
struct ProviderDetailSheet: View {
    let row: ProviderRowModel
    @ObservedObject var model: SettingsModel
    /// Asks the pane to confirm the primary change, which declares its side
    /// effect before it happens. The pane owns that dialog because it owns the
    /// refusal sentence the daemon answers with.
    let confirmPrimary: (ProviderRowModel) -> Void
    /// A sign-in is the pane's to start and follow: it replaces this sheet with
    /// the one that waits on the browser, so the two are never both open.
    let requestAuth: (ProviderRequest) -> Void
    let dismiss: () -> Void

    @State private var refusal: String?
    @State private var signingOut = false
    @State private var page = Page.detail

    /// What this one sheet is showing.
    enum Page: Equatable {
        case detail
        /// A model listing, addressed by the row that asked for it so the
        /// choice is written back to that row.
        case models(section: String, key: String)
    }

    init(
        row: ProviderRowModel,
        model: SettingsModel,
        confirmPrimary: @escaping (ProviderRowModel) -> Void,
        requestAuth: @escaping (ProviderRequest) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.row = row
        self.model = model
        self.confirmPrimary = confirmPrimary
        self.requestAuth = requestAuth
        self.dismiss = dismiss

    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            switch page {
            case .detail:
                detail
            case .models(let section, let key):
                models(section: section, key: key)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: page == .detail ? nil : SheetMetrics.pickerSize.height)
        // Escape cancels, on every sheet (M34 §3.1). This one commits each row
        // as it is edited, so leaving is the whole of cancelling and `Done` is
        // the only button; without this the key did nothing at all.
        .onExitCommand(perform: escape)
        .task { await model.loadSection(section) }
    }

    private var section: String { ProviderRowProjection.sectionId(for: row.id) }

    /// Escape, resolved once for this window, by the rule the settings window
    /// follows (M34 §3.1). A field being edited owns it first: it puts its
    /// value back and gives up focus, and a key half typed is dropped without
    /// the sheet closing under it. Then the model page goes back to the detail,
    /// and only the detail closes.
    private func escape() {
        guard model.editingRow == nil else {
            model.revertEdit()
            return
        }

        guard page == .detail else {
            page = .detail
            return
        }

        dismiss()
    }

    // MARK: - The detail

    @ViewBuilder
    private var detail: some View {
        heading

        // The same grouped form the pane draws, so a row does not change shape
        // between the pane and the sheet and every value sits in one column.
        Form {
            connection
            settings
        }
        .formStyle(.grouped)
        // The sheet's own material is the ground here, and the rows' actions
        // are the one row style, as on every form in the window.
        .showsAmbientGround()
        .rowActions()
        .fixedSize(horizontal: false, vertical: true)

        if let refusal {
            Text(refusal)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }

        verbs
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

    /// Whether this is the surface that draws the provider's own rows.
    ///
    /// The primary's live on the pane, which leads with them (M34 §5.1), so for
    /// the primary this page is its sign-in doors and the two verbs: one key,
    /// one control, one place. `ProviderRowProjection.draws` is the one rule
    /// both surfaces read.
    private var drawsRows: Bool { ProviderRowProjection.draws(.subPage, primary: row.primary) }

    /// The provider's own rows, where the daemon has answered with them.
    private var published: [ManagementSettingRow]? { model.section(section).value?.rows }

    private var blocks: ProviderDetailBlocks {
        ProviderRowProjection.detailBlocks(
            rows: published ?? [],
            hidden: model.providerCredentialExclusions(row.id)
        )
    }

    /// The ways to connect or replace this provider's account by signing in,
    /// each with whether it can be used right now.
    private var doors: [ProviderDoor] {
        ProviderRowProjection.detailDoors(for: row.id, detections: model.detections.value)
    }

    // MARK: - How it connects

    /// The primary connection block, led by the daemon's own "Sign in with"
    /// row where the provider publishes one (owner, 2026-09-28): a
    /// subscription puts the sign-in doors under it and an API key puts the
    /// key field there, and neither waits behind a disclosure. A provider with
    /// no such row draws what it has, its doors or its key. The primary's rows
    /// live on the pane, mode and key included, so its detail draws the doors
    /// alone and only while its mode is not the key.
    ///
    /// The account the daemon names comes before the doors, for any provider
    /// that publishes one, so a person sees who is connected before the way to
    /// connect again. OpenAI Codex has no mode row and only `oauth`, so its
    /// block is the account, the plan and the ChatGPT door whether or not it is
    /// the primary.
    @ViewBuilder
    private var connection: some View {
        if row.account != nil || showsMode || showsDoors || showsSecrets {
            Section {
                if showsMode { mode }
                account
                if showsDoors {
                    chatGPTPlan
                    signIn
                    setupToken
                }
                if showsSecrets { secrets }
            }
        }
    }

    /// Who is connected, where the daemon names an account: plain text beside
    /// its label, never a control.
    @ViewBuilder
    private var account: some View {
        if let account = row.account {
            LabeledContent(ProductStrings[.providerAccount]) {
                Text(account)
                    .foregroundStyle(Palette.secondary.color)
            }
        }
    }

    /// Whether this is OpenAI Codex, which signs in with ChatGPT.
    private var isChatGPT: Bool { row.id == ProviderRowProjection.chatGPTProvider }

    /// That Fermix is using the person's ChatGPT plan, with the way to OpenAI's
    /// own usage settings beside it (M57). The daemon reports the provider
    /// configured only once the sign-in granted plan usage, so this is drawn on
    /// that and nothing else; until then the door below offers the plan.
    @ViewBuilder
    private var chatGPTPlan: some View {
        if isChatGPT, row.configured {
            LabeledContent(ProductStrings[.providerChatGPTUsingPlan]) {
                Button(ProductStrings[.providerChatGPTManageUsage]) { refusal = model.openChatGPTUsage() }
                    .accessibilityHint(ProductStrings[.providerChatGPTManageUsageHint])
            }
        }
    }

    private var authMode: String? { model.providerAuthMode(row.id) }
    private var showsMode: Bool { drawsRows && blocks.hasMode }
    private var showsDoors: Bool { !doors.isEmpty && authMode != ProviderRowProjection.apiKeyMode }
    private var showsSecrets: Bool { drawsRows && blocks.hasSecret && authMode != ProviderRowProjection.oauthMode }

    /// The doors that are a click: the browser, ChatGPT's included, and a
    /// sign-in this Mac has.
    ///
    /// A door that is not ready stays where it is and cannot be pressed, with
    /// one line under the row saying what makes it ready. Taken away, a Mac
    /// with no Claude Code sign-in showed Claude no way to sign in at all.
    @ViewBuilder
    private var signIn: some View {
        // A typed secret is a row below, never a button that opens one.
        let buttons = doors.filter { !$0.verb.writesSecret }

        if !buttons.isEmpty {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                HStack(spacing: Spacing.xs) {
                    ForEach(buttons, id: \.verb.rawValue) { door in
                        Button(authTitle(door.verb)) { authenticate(door.verb) }
                            .disabled(!door.available)
                            .accessibilityLabel(ProductStrings.commaPair(authTitle(door.verb), row.label))
                    }
                }
                .disabled(signingOut || model.writesBlocked || model.startingSignIn)

                ForEach(buttons.filter { !$0.available }, id: \.verb.rawValue) { door in
                    Text(unavailableCaption(door.verb))
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The ChatGPT door is kept once connected, because it is how a
                // person reconnects or switches account; the offer is the one
                // line it carries until the plan is in use.
                if isChatGPT, !row.configured {
                    Text(ProductStrings[.providerChatGPTOffer])
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What makes a door ready. Only the sign-in a Mac may not have yet is ever
    /// drawn unready, so it is the only one with something to say.
    private func unavailableCaption(_ verb: ProviderVerb) -> String {
        guard verb == .importClaudeCode else {
            preconditionFailure("only the Claude Code sign-in is drawn before it is ready")
        }

        return ProductStrings[.providerImportClaudeCodeUnavailable]
    }

    /// Anthropic's setup token, typed here like every other secret.
    ///
    /// It is the one id no descriptor row carries (M34 §7.3), so no descriptor
    /// row can draw it and this does. It is a sign-in door rather than a stored
    /// value the daemon reports on, so it is always the field: storing another
    /// token replaces the account, which is what the door is for.
    @ViewBuilder
    private var setupToken: some View {
        if doors.contains(where: { $0.verb == .addSetupToken }) {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                SecretRow(
                    label: ProductStrings[.providerSetupTokenLabel],
                    identifier: ProviderRowProjection.anthropicSetupTokenID,
                    present: false,
                    model: model
                )

                Text(ProductStrings[.providerSetupTokenBody])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Every write is refused while the settings file has changed
            // outside Fermix (M34 §7.6). A descriptor row gates itself; this
            // one is drawn by hand, so it says so here.
            .disabled(model.writesBlocked)
        }
    }

    /// The daemon's "Sign in with" row and nothing else, drawn by the
    /// descriptor form so it keeps its footer, its refusals and the write gate
    /// every descriptor row carries.
    private var mode: some View {
        DescriptorRows(model: model, section: section, excluding: blocks.modeExcluding)
    }

    /// The secret rows and nothing else, the same way.
    private var secrets: some View {
        DescriptorRows(model: model, section: section, excluding: blocks.secretExcluding)
    }

    // MARK: - Its own settings

    /// Everything the provider publishes that is not its credential. Before the
    /// daemon has answered, this is where the one state that explains the wait
    /// is drawn: reading, refused, or an engine too old to say.
    @ViewBuilder
    private var settings: some View {
        if drawsRows, published == nil || blocks.hasSettings {
            Section {
                DescriptorRows(model: model, section: section, specialised: { descriptorRow in
                    modelRow(descriptorRow)
                }, excluding: blocks.settingsExcluding)
            }
        }
    }

    /// The one specialised row: a model listing the daemon could not inline
    /// turns this sheet to its listing page rather than drawing an empty
    /// picker. The provider is this page's own, which is the fact the pane
    /// cannot supply for a row that belongs to a provider other than the
    /// primary.
    private func modelRow(_ descriptorRow: ManagementSettingRow) -> AnyView? {
        guard let form = descriptorRow.modelRowForm else { return nil }
        switch form {
        case .listing:
            return AnyView(
                ModelChoiceRow(row: descriptorRow, section: section, model: model) {
                    page = .models(section: section, key: descriptorRow.key)
                }
            )
        case .typeahead:
            return AnyView(ModelTypeaheadRow(row: descriptorRow, section: section, provider: row.id, model: model))
        }
    }

    // MARK: - The model page

    /// The model listing, as a page of this sheet. It is the same listing the
    /// pane presents for the primary, with the way back where a page has one.
    @ViewBuilder
    private func models(section: String, key: String) -> some View {
        HStack(spacing: Spacing.s) {
            Button(action: { page = .detail }) {
                Label(ProductStrings[.assistantBack], systemImage: "chevron.backward")
            }
            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.assistantBack], row.label))

            Text(ProductStrings[.providerModelsTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
        }

        ModelListing(provider: row.id, model: model) { chosen in
            Task { await model.apply(section: section, key: key, value: .text(chosen)) }
            page = .detail
        }
    }

    // MARK: - The two verbs

    private func authTitle(_ verb: ProviderVerb) -> String {
        if verb == .signIn { return ProductStrings[.providerSignInBrowser] }

        guard let title = verb.title else { preconditionFailure("a credential action has a title") }

        return title
    }

    private func authenticate(_ verb: ProviderVerb) {
        switch verb {
        case .signIn, .continueWithChatGPT:
            requestAuth(.signIn(row))
        case .importClaudeCode:
            requestAuth(.importSignIn(row, .claudeCode))
        case .addSetupToken, .addKey, .none:
            preconditionFailure("this action is not a button on the account row")
        }
    }

    /// Sign out forgets the local session. For OpenAI Codex the daemon also
    /// revokes the ChatGPT session upstream; nothing else is revoked. It asks
    /// nothing first: this sheet never raises another (owner directive of
    /// 2026-09-20), and signing in again is one click. Use as primary goes
    /// back to the pane, which declares the side effect first. They share the
    /// sheet's one button row with `Done`, leading where it trails, so the
    /// sheet is a row shorter.
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

            Spacer(minLength: 0)

            Button(ProductStrings[.settingsSheetDone], action: dismiss)
                .keyboardShortcut(.defaultAction)
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
