import SwiftUI

/// The provider sub-page (M34 §5.1).
///
/// Everything that belongs to one provider rather than to the list: how it
/// connects, its base URL, its model, its reasoning effort and fast mode. All
/// of them are the daemon's own `providers.<id>` descriptor rows, so this page
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
    @State private var keyShown: Bool

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
        // A key that is already stored is one somebody is using, so the door
        // to it opens with the sheet rather than hiding `Stored` behind a
        // click. With no key it stays shut and the sign-in leads alone.
        _keyShown = State(initialValue: row.presentKey)
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

    /// The primary connection block.
    ///
    /// A provider that signs in leads with its doors, and its key is never
    /// drawn beside them: it waits behind one disclosure. A provider whose only
    /// way in is a key has nothing to put in front of it, so the key is drawn
    /// directly.
    @ViewBuilder
    private var connection: some View {
        if !doors.isEmpty {
            Section {
                signIn
                setupToken
                keyDoor
            }
        } else if drawsRows, blocks.hasCredential {
            Section { credential }
        }
    }

    /// The doors that are a click: the browser, and a sign-in this Mac has.
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

    /// The secondary door of a provider that signs in: its API key, and the
    /// auth mode beside it where the daemon publishes one, since choosing the
    /// key is what that row means.
    ///
    /// The system's own disclosure group over a plain title, which is the one
    /// form of it VoiceOver reads and opens correctly. Its children share its
    /// one grouped-form row, so the form's row insets stop at its edge and they
    /// take the peer gap from `SettingsRowMetrics`, as the list editor does.
    @ViewBuilder
    private var keyDoor: some View {
        if drawsRows, blocks.hasCredential {
            DisclosureGroup(isExpanded: $keyShown) {
                VStack(alignment: .leading, spacing: SettingsRowMetrics.stackGap) {
                    credential
                }
                .padding(.top, SettingsRowMetrics.entryGap)
            } label: {
                Text(ProductStrings[.providerUseKeyInstead])
                    // The group answers a press through accessibility by
                    // reporting success and staying shut, so VoiceOver could
                    // read this door and never open it. The press is given the
                    // one thing it means, on the title alone: on the group it
                    // reaches the rows inside as well, and the key field then
                    // reads as a button that shuts the door it is behind.
                    .accessibilityAction { keyShown.toggle() }
            }
        }
    }

    /// The credential rows and nothing else. The descriptor form is told what
    /// to leave out, so the rows stay the daemon's own and keep their footers,
    /// their refusals and the write gate every descriptor row carries.
    private var credential: some View {
        DescriptorRows(model: model, section: section, excluding: blocks.credentialExcluding)
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
        guard descriptorRow.needsModelPicker else { return nil }

        return AnyView(
            ModelChoiceRow(row: descriptorRow, section: section, model: model) {
                page = .models(section: section, key: descriptorRow.key)
            }
        )
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
        case .signIn:
            requestAuth(.signIn(row))
        case .importClaudeCode:
            requestAuth(.importSignIn(row, .claudeCode))
        case .importCodexCLI:
            requestAuth(.importSignIn(row, .codexCLI))
        case .addSetupToken, .addKey, .none:
            preconditionFailure("this action is not a button on the account row")
        }
    }

    /// Sign out forgets the local session and revokes nothing upstream. Use as
    /// primary goes back to the pane, which declares the side effect first.
    /// They share the sheet's one button row with `Done`, leading where it
    /// trails, so the sheet is a row shorter.
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
