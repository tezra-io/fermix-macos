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

/// The pages of a plugin's detail.
///
/// The detail is the one sheet a plugin raises, and it never raises another.
/// What used to be a second sheet over it, and a secret's third over that, is a
/// page the same sheet turns to: one window deep however far a plugin's setup
/// goes, and each page short enough that nothing on it has to scroll to be
/// reached.
enum IntegrationDetailPage: Equatable, Sendable {
    case detail
    case workspace
    /// Addressed by provider rather than by the client record, which is what
    /// lets the page read the record live.
    case client(provider: String)
    /// The token, where it is the plugin's second way in
    /// (`IntegrationTokenSlot.secondary`).
    case token

    /// The page that answers one published action, where a page does.
    ///
    /// Read from the id and never from the daemon's word for it. A client verb
    /// on a row that names no sign-in family has no client to open, so it
    /// answers with no page rather than with a page about nothing.
    static func answering(
        _ action: ManagementPluginAction,
        on row: IntegrationRowModel
    ) -> IntegrationDetailPage? {
        switch action {
        case .chooseWorkspace:
            return .workspace
        case .setUpClient:
            return row.authProvider.map { .client(provider: $0) }
        case .install, .enable, .disable, .signIn, .addToken, .replaceToken, .check, .disconnect,
             .unrecognized:
            return nil
        }
    }
}

/// Where a plugin's sign-in stands on its detail page.
///
/// The wait was a sheet over the detail. It is a block on the page now, under
/// the verb that started it, and it keeps the sheet's own rules: up from the
/// moment the sign-in is asked for, gone by itself once the run completes or is
/// cancelled, and left standing with the daemon's sentence where it ended
/// badly.
enum IntegrationSignInBlock: Equatable, Sendable {
    /// Nothing to draw: no sign-in was asked for here, it ended well, or the
    /// runner has moved on to other work.
    case hidden
    /// Starting or running: the step, the progress, `Cancel` and the way to
    /// open the browser again.
    case waiting
    /// Ended badly, or refused before a job was minted: the sentence and the
    /// way to try again.
    case ended

    /// `asked` is the detail's own fact, that the last thing asked of it was a
    /// sign-in. Without it a check that was refused, which leaves the runner
    /// holding a sentence and no job exactly as a refused sign-in does, would
    /// be drawn as a sign-in that failed.
    static func resolve(asked: Bool, starting: Bool, job: ManagementJob?) -> IntegrationSignInBlock {
        guard asked else { return .hidden }
        guard !starting else { return .waiting }
        guard let job else { return .ended }
        guard job.kind == .auth else { return .hidden }

        switch job.status {
        case .running: return .waiting
        case .completed, .cancelled: return .hidden
        case .failed, .timedOut, .unrecognized: return .ended
        }
    }
}

/// What Escape does on a plugin's detail, which is always the innermost thing
/// (M34 §3.1).
///
/// A page goes back to the detail and the detail closes. A sign-in being waited
/// for is the exception the old sheet had: there Escape was its `Cancel`, and
/// the detail under it could not be closed at all until the wait was over.
enum IntegrationDetailEscape: Equatable, Sendable {
    case nothing
    case back
    case cancelSignIn
    case close

    /// `busy` is a sign-in being started or a cancel already on its way, which
    /// is when the wait's own buttons are disabled too.
    static func resolve(
        page: IntegrationDetailPage,
        signIn: IntegrationSignInBlock,
        busy: Bool
    ) -> IntegrationDetailEscape {
        guard page == .detail else { return .back }
        guard signIn == .waiting else { return .close }

        return busy ? .nothing : .cancelSignIn
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
///
/// It presents nothing. The workspace, the sign-in client and a second-door
/// token are pages of this sheet (`IntegrationDetailPage`), and the sign-in
/// wait is a block on the detail page. One size for every page, so turning one
/// does not move the sheet.
struct IntegrationDetailSheet: View {
    let name: String
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    let dismiss: () -> Void

    @State private var page = IntegrationDetailPage.detail
    @State private var refusal: String?
    /// Whether the last thing asked of this detail was its sign-in
    /// (`IntegrationSignInBlock.resolve`).
    @State private var signInAsked = false
    @State private var startingSignIn = false
    @State private var cancellingSignIn = false

    var body: some View {
        pageView
            .padding(WindowMetrics.contentPadding)
            .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
            // On the sheet rather than on a page, so a job that ends while
            // another page is up is still read back.
            .onChange(of: runner.job, initial: true) { _, job in
                guard let job, job.status.isTerminal else { return }

                Task { await model.pluginJobFinished(job) }
            }
    }

    /// The plugin as the daemon last published it.
    private var row: IntegrationRowModel? {
        IntegrationRowProjection.row(named: name, in: model.plugins.value)
    }

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .detail:
            detailPage
        case .workspace:
            WorkspacePage(name: name, model: model, runner: runner, back: showDetail)
        case .client(let provider):
            clientPage(provider)
        case .token:
            tokenPage
        }
    }

    private var detailPage: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let row {
                heading(row)
                rows(row)
            } else {
                Text(ProductStrings[.integrationGone])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            jobNotice
            footer(done: dismiss)
        }
    }

    private func clientPage(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            IntegrationPageHeader(
                title: OAuthClientEditor.title(for: provider),
                parent: row?.title ?? name,
                back: showDetail
            )

            OAuthClientEditor(provider: provider, model: model, close: showDetail)
        }
    }

    /// The token as a page of its own, which is where it sits while a sign-in
    /// leads. The row commits by itself, so `Done` only goes back.
    private var tokenPage: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            IntegrationPageHeader(
                title: ProductStrings[.integrationTokenLabel],
                parent: row?.title ?? name,
                back: showDetail
            )

            if let row { tokenRow(row) }

            Spacer(minLength: 0)

            footer(done: showDetail)
        }
    }

    /// The rows of the detail page, in a scroll of their own.
    ///
    /// The pages are what keep this short, so for the plugins the catalogue
    /// ships it does not scroll at all. It is here for the manifest nobody has
    /// written yet: a plugin that publishes a dozen settings would otherwise
    /// run under the buttons of a sheet whose size is fixed. The scroll runs to
    /// the sheet's own edges and pads its rows back in, because a scroll view
    /// clips at its bounds and a field flush against them loses its focus ring.
    private func rows(_ row: IntegrationRowModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                status(row)
                nextStep(row)
                verbs(row)
                signIn(row)
                settings(row)
                signInClient(row)
                workspace(row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WindowMetrics.contentPadding)
            .padding(.vertical, Spacing.xxs)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .padding(.horizontal, -WindowMetrics.contentPadding)
    }

    /// Where the sign-in stands, which is what the block, the notice under the
    /// rows, `Done` and Escape all read.
    private var signInBlock: IntegrationSignInBlock {
        IntegrationSignInBlock.resolve(
            asked: signInAsked,
            starting: startingSignIn || model.startingSignIn,
            job: runner.job
        )
    }

    private var signInBusy: Bool { startingSignIn || model.startingSignIn || cancellingSignIn }

    /// The one sentence this sheet has to say, whoever draws it.
    private var warning: String? { refusal ?? runner.failure ?? runner.browserFailure }

    /// What a run looks like and what went wrong, for everything but a sign-in:
    /// that draws both itself, under the verb that started it.
    @ViewBuilder
    private var jobNotice: some View {
        if signInBlock == .hidden {
            if runner.isRunning, let phase = runner.phase {
                HStack(spacing: Spacing.s) {
                    ProgressView(value: runner.progress?.fraction).controlSize(.small)
                    Text(phase).fermixType(Typography.style(.calloutSmall))
                }
            }
            if let warning {
                Text(warning)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    /// `Done`, on a page where leaving is the whole of finishing: every row on
    /// it commits as it is edited, so there is no `Cancel` to offer.
    ///
    /// It waits for a sign-in the way the detail did under the sign-in sheet:
    /// the wait ends by finishing or by `Cancel`, and until then the default
    /// action is the wait's own.
    private func footer(done: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)
            Button(ProductStrings[.settingsSheetDone], action: done)
                .keyboardShortcut(signInBlock == .waiting ? nil : .defaultAction)
                .disabled(signInBlock == .waiting)
                .background { escapeKey }
        }
    }

    /// Escape, as a key the page answers whatever holds focus (M34 §3.1).
    ///
    /// A key equivalent rather than an exit command. An exit command is only
    /// delivered to a view that holds focus, and a page made of buttons holds
    /// none: on the detail the key did nothing at all, under a source gate that
    /// passed because the modifier was written down. A button takes one
    /// shortcut and `Done` already has Return, so the second key rides on a
    /// twin that draws nothing and is read by nothing. The pages that do offer
    /// a `Cancel` carry the key on it.
    private var escapeKey: some View {
        Button(ProductStrings[.settingsSheetCancel], action: escape)
            .keyboardShortcut(.cancelAction)
            .hidden()
    }

    @ViewBuilder
    private func signIn(_ row: IntegrationRowModel) -> some View {
        if signInBlock != .hidden {
            IntegrationSignInWait(
                label: row.title,
                block: signInBlock,
                busy: signInBusy,
                warning: warning,
                runner: runner,
                cancel: cancelSignIn,
                reopen: { model.reopenSignIn(on: runner) },
                retry: beginSignIn
            )
        }
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
            // On the first line's baseline rather than a labelled row's centre:
            // once the verbs take two lines, the centre is the gap between them.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(ProductStrings[.integrationVerbsSection])

                IntegrationVerbFlow(spacing: Spacing.xs) {
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
    ///
    /// Where the daemon leads with a sign-in instead, the token is the second
    /// way in and is not drawn beside it: the row here is only the way to its
    /// page (`IntegrationTokenSlot`).
    @ViewBuilder
    private func settings(_ row: IntegrationRowModel) -> some View {
        if row.tokenSlot != .none || !manifestSettings.isEmpty {
            Text(ProductStrings[.integrationSettingsSection])
                .fermixType(Typography.style(.calloutSmall).weight(.medium))
                .foregroundStyle(Palette.secondary.color)

            switch row.tokenSlot {
            case .none:
                EmptyView()
            case .leading:
                tokenRow(row)
            case .secondary:
                tokenDoor(row)
            }
            ForEach(manifestSettings, id: \.key) { setting in
                IntegrationSettingRow(name: row.name, setting: setting, model: model) { refusal = $0 }
            }
        }
    }

    /// The token slot itself, wherever it is drawn: on the detail where it
    /// leads, and on its own page where it does not.
    private func tokenRow(_ row: IntegrationRowModel) -> some View {
        SecretRow(
            label: ProductStrings[.integrationTokenLabel],
            identifier: SettingsModel.pluginSecretId(row.name),
            present: row.credentialPresent,
            model: model
        )
    }

    /// The way to the token's page, titled from the deck by the id it stands
    /// for: replacing what is stored, or adding what is not.
    private func tokenDoor(_ row: IntegrationRowModel) -> some View {
        LabeledContent(ProductStrings[.integrationTokenLabel]) {
            Button(title(of: row.tokenAction)) { page = .token }
                .disabled(signInBlock == .waiting)
                .accessibilityLabel(ProductStrings.commaPair(title(of: row.tokenAction), row.title))
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
                Text(OAuthClientState.sentence(for: client))
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

                    Button(ProductStrings[.integrationWorkspaceChoose]) { page = .workspace }
                        .disabled(signInBlock == .waiting)
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

    /// Runs the id the daemon published for this button. The two ids answered
    /// by a page turn to it, the sign-in is waited for on this page, and
    /// everything else goes to the model.
    private func perform(_ action: ManagementPluginAction, on row: IntegrationRowModel) {
        switch action {
        case .chooseWorkspace, .setUpClient:
            page = IntegrationDetailPage.answering(action, on: row) ?? .detail
        case .signIn:
            beginSignIn()
        case .addToken, .replaceToken:
            preconditionFailure("a credential verb draws no button; the secret row is its slot")
        default:
            signInAsked = false
            Task { refusal = await model.perform(action, on: row.name, runner: runner) }
        }
    }

    /// The wait is drawn from the moment it is asked for, so the step between
    /// the press and the browser opening is a spinner rather than nothing.
    private func beginSignIn() {
        guard !startingSignIn, !runner.isRunning else { return }

        startingSignIn = true
        signInAsked = true
        refusal = nil
        Task {
            defer { startingSignIn = false }
            refusal = await model.perform(.signIn, on: name, runner: runner)
        }
    }

    /// Asks the daemon to stop the sign-in. The block then follows the job to
    /// whatever it reports, and goes once that is `cancelled`.
    private func cancelSignIn() {
        guard runner.isRunning, !cancellingSignIn else { return }

        cancellingSignIn = true
        Task {
            await runner.cancelJob()
            cancellingSignIn = false
        }
    }

    private func showDetail() { page = .detail }

    private func escape() {
        switch IntegrationDetailEscape.resolve(page: page, signIn: signInBlock, busy: signInBusy) {
        case .nothing: return
        case .back: showDetail()
        case .cancelSignIn: cancelSignIn()
        case .close: dismiss()
        }
    }
}

/// The detail's verb buttons, on as many lines as they need.
///
/// One line was the defect. The widest row the daemon publishes is a sign-in
/// whose client was refused: `Set up the sign-in client`, `Sign in again`,
/// `Check again`, `Disconnect` and `Turn off`, which is wider than the sheet. On
/// one line every button was squeezed to fit, and the one the row leads with
/// read `Set up th…`. The daemon's order is kept: the verb it leads with is
/// first on the first line.
struct IntegrationVerbFlow: Layout {
    let spacing: Double

    /// Which line each of a run of widths lands on, by index.
    ///
    /// A width starts a new line when it would run past the one it is on. One
    /// wider than a whole line still gets a line to itself rather than being
    /// dropped, and is squeezed there, which is the only place left for it.
    static func lines(widths: [Double], spacing: Double, fitting available: Double) -> [[Int]] {
        var lines: [[Int]] = []
        var used = 0.0

        for (index, width) in widths.enumerated() {
            let extended = used + spacing + width

            if let last = lines.indices.last, extended <= available {
                lines[last].append(index)
                used = extended
            } else {
                lines.append([index])
                used = width
            }
        }

        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let placed = frames(of: subviews, fitting: proposal.width ?? .infinity)

        return CGSize(
            width: placed.map(\.maxX).max() ?? 0,
            height: placed.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, frames(of: subviews, fitting: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// The first line's text baseline, which is the first button's: it is
    /// placed at the layout's own top. What stands beside the flow lines up on
    /// its first line however many it takes.
    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }

        return bounds.minY + first.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
    }

    /// Where every button sits, from the layout's own origin.
    private func frames(of subviews: Subviews, fitting available: Double) -> [CGRect] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = sizes.map { Double($0.width) }
        let heights = sizes.map { Double($0.height) }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var top = 0.0

        for line in Self.lines(widths: widths, spacing: spacing, fitting: available) {
            var leading = 0.0

            for index in line {
                let width = min(widths[index], available)
                frames[index] = CGRect(x: leading, y: top, width: width, height: heights[index])
                leading += width + spacing
            }
            top += (line.map { heights[$0] }.max() ?? 0) + spacing
        }

        return frames
    }
}

/// The line at the top of a page of the detail: the way back, and what the page
/// is.
///
/// `chevron.backward` is the direction-relative symbol the settings back control
/// draws, and the only one that mirrors under a right-to-left layout. It carries
/// no word, so VoiceOver is told where it goes.
struct IntegrationPageHeader: View {
    let title: String
    /// What the page came from, which is what the back control is named for.
    let parent: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Button(action: back) {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel(String(format: ProductStrings[.integrationPageBackFormat], parent))

            Text(title)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
        }
        // The detail's own heading is as tall as its tile, so a page's heading
        // is too, and the rows under it do not move as the sheet turns.
        .frame(minHeight: IntegrationMetrics.tileSize)
    }
}

/// A plugin's sign-in, waited for under the verb that started it (M34 §5.1).
///
/// The browser opens on the press, so by the time this is drawn the tab is
/// already there: what it adds is the step the daemon reports, one way to open
/// the tab again where it was lost, and one way to stop. It is the providers'
/// sign-in sheet without the sheet, and it says what that one says.
struct IntegrationSignInWait: View {
    /// What the product calls the plugin being signed in to.
    let label: String
    let block: IntegrationSignInBlock
    /// A sign-in being started or a cancel on its way: nothing here is pressed
    /// twice.
    let busy: Bool
    let warning: String?
    @ObservedObject var runner: JobRunner
    let cancel: () -> Void
    /// Opens the browser again for the same sign-in.
    let reopen: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.entryGap) {
            waiting

            if let warning {
                Text(warning)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: Spacing.xs) { actions }
                .disabled(busy)
        }
    }

    /// Where to look and what the daemon is doing, while there is a wait. The
    /// sheet said both in every state because a sheet needs a body; once the run
    /// has ended, `Finish signing in in your browser` is an instruction for a
    /// tab that is no longer waiting for anybody.
    @ViewBuilder
    private var waiting: some View {
        if block == .waiting {
            Text(ProductStrings[.providerSignInBody])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.s) {
                ProgressView(value: runner.progress?.fraction)
                    .controlSize(.small)

                if let phase = runner.phase {
                    Text(phase)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if block == .waiting {
            // No Escape of its own: the page answers that key once, and while
            // this is waiting its answer is this button's.
            Button(ProductStrings[.settingsSheetCancel], action: cancel)

            Button(ProductStrings[.providerSignInReopen], action: reopen)
                .keyboardShortcut(.defaultAction)
                .disabled(runner.authorizationURL == nil)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerSignInReopen], label))
        } else {
            Button(ProductStrings[.providerSignInRetry], action: retry)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerSignInRetry], label))
        }
    }
}

/// The two words a boolean plugin setting is written in.
///
/// The daemon takes `true` or `false` and refuses everything else, and a
/// setting nobody has written is absent from the row, which is what off is.
/// Both rules live here so the switch cannot disagree with the wire about what
/// off looks like.
enum PluginSettingSwitch {
    static func isOn(value: String?) -> Bool { value == "true" }

    static func wireValue(isOn: Bool) -> ManagementSettingValue { .text(isOn ? "true" : "false") }
}

/// One plugin setting: the manifest's label, and the control its kind names.
struct IntegrationSettingRow: View {
    let name: String
    let setting: ManagementPluginSetting
    @ObservedObject var model: SettingsModel
    let refused: (String?) -> Void

    @State private var draft = ""
    @State private var writing = false

    @ViewBuilder
    var body: some View {
        switch setting.kind {
        case .text:
            field
        case .boolean:
            toggle
        // A kind this build has no control for means the daemon is ahead of the
        // app, so the row says so rather than writing a shape it guessed. The
        // same answer `DescriptorRow` gives an unknown row kind.
        case .unrecognized:
            LabeledContent(setting.label) {
                Text(ProductStrings[.settingsRowUnsupported])
                    .foregroundStyle(Palette.secondary.color)
            }
        }
    }

    /// The label over the field rather than beside it. A manifest names its
    /// setting in a phrase, not a word, and beside a phrase the field was left
    /// with whatever width the label did not take; stacked, the field has the
    /// sheet's width and the label may wrap.
    private var field: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Text(setting.label)
                .fixedSize(horizontal: false, vertical: true)

            TextField(setting.label, text: $draft, prompt: Text(setting.label))
                .settingsTextField()
                .labelsHidden()
                .accessibilityLabel(setting.label)
                .frame(maxWidth: .infinity)
                .onSubmit(commit)
        }
        .onAppear { draft = setting.value ?? "" }
    }

    /// A switch, written on every flip. There is no save button behind any
    /// other switch in the app, and the daemon's two words are the whole of the
    /// value, so there is nothing to hold back.
    private var toggle: some View {
        LabeledContent {
            Toggle(setting.label, isOn: Binding(
                get: { PluginSettingSwitch.isOn(value: setting.value) },
                set: { write(PluginSettingSwitch.wireValue(isOn: $0)) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(writing)
            .accessibilityLabel(setting.label)
        } label: {
            Text(setting.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commit() {
        guard draft != (setting.value ?? "") else { return }

        write(draft.isEmpty ? .absent : .text(draft))
    }

    private func write(_ value: ManagementSettingValue) {
        writing = true
        Task {
            let sentence = await model.setPluginSetting(name: name, key: setting.key, value: value)
            writing = false
            refused(sentence)
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
                Text(OAuthClientState.sentence(for: client))
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

/// What a sign-in client's state reads as, wherever it is drawn.
///
/// The plugin's detail and the row at the foot of the page both say it, so one
/// rule composes it: the configured word, and the region the account belongs to
/// where the daemon named one. The label is the daemon's own.
enum OAuthClientState {
    static func sentence(for client: ManagementPluginOAuthClient) -> String {
        let state = ProductStrings[client.configured ? .integrationClientSet : .integrationClientUnset]
        guard let label = client.regionLabel else { return state }

        return ProductStrings.commaPair(state, label)
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
    enum ValidationError: Error, Equatable { case invalidPort, missingRegion }

    var identifier: String
    var port: String
    var region: String

    init(client: ManagementPluginOAuthClient?) {
        identifier = client?.clientId ?? ""
        port = client?.redirectPort.map(String.init) ?? ""
        region = client?.region ?? ""
    }

    /// The account region, against the regions the daemon offers for this
    /// provider.
    ///
    /// A provider that serves one region publishes none and the daemon refuses
    /// a region for it, so nothing is sent. Where it publishes some the daemon
    /// requires one of them, and anything else is not a region this provider
    /// offers.
    func validatedRegion(offered: [ManagementPluginOAuthRegion]) throws -> String? {
        guard !offered.isEmpty else { return nil }
        guard offered.contains(where: { $0.id == region }) else {
            throw ValidationError.missingRegion
        }

        return region
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

/// The OAuth client sheet (M34 §5.6), which the page's sign-in clients section
/// raises.
///
/// One level: a title over the one editor. The same editor is a page of a
/// plugin's detail, where `set_up_client` leads to it, so the two doors to a
/// client cannot come to ask for different things.
struct OAuthClientSheet: View {
    let provider: String
    @ObservedObject var model: SettingsModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(OAuthClientEditor.title(for: provider))
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            OAuthClientEditor(provider: provider, model: model, close: dismiss)
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
        // Escape cancels, on every sheet (M34 §3.1). The key itself rides on
        // the editor's `Cancel`, which answers it whatever holds focus; this
        // states the same answer on the sheet, where the rule is read.
        .onExitCommand(perform: dismiss)
    }
}

/// One sign-in client's fields, wherever they are edited (M34 §5.6).
///
/// The client id and the redirect port go through `plugins.oauth_client.set`;
/// the client secret goes through `secret.set` under the contract's own
/// `oauth_client:<provider>` id and never through a settings write, so the one
/// secure input in the product stays the one place a credential is typed.
///
/// It draws no title and no frame of its own: a sheet gives it one of each and
/// a page of the detail gives it another. Its buttons sit at the foot of
/// whatever it is given, which is the content's own height in the sheet and the
/// page's in the detail.
struct OAuthClientEditor: View {
    let provider: String
    @ObservedObject var model: SettingsModel
    /// Leaves the editor: `Cancel`, and a client the daemon accepted.
    let close: () -> Void

    @State private var draft: OAuthClientDraft
    @State private var refusal: String?
    @State private var saving = false

    init(provider: String, model: SettingsModel, close: @escaping () -> Void) {
        precondition(!provider.isEmpty, "an OAuth client names its provider")
        self.provider = provider
        self.model = model
        self.close = close
        _draft = State(initialValue: OAuthClientDraft(
            client: model.plugins.value?.oauthClients.first { $0.provider == provider }
        ))
    }

    /// The client as the daemon last published it, re-read on every render.
    private var client: ManagementPluginOAuthClient? {
        model.plugins.value?.oauthClients.first { $0.provider == provider }
    }

    /// The `secret.set` id for a provider's client secret. M34 §7.3 names the
    /// family; it is written once, here, beside the only editor that uses it.
    static func secretId(for provider: String) -> String {
        precondition(!provider.isEmpty, "an OAuth client secret is addressed by provider")

        return SettingsModel.oauthClientSecretPrefix + provider
    }

    /// What either surface titles itself with: the row's own name, and whose
    /// client it is.
    static func title(for provider: String) -> String {
        ProductStrings.commaPair(ProductStrings[.integrationClientRow], WireIdentifier.word(provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fields

            Spacer(minLength: Spacing.m)

            buttons
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            region

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
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)

            Button(ProductStrings[.settingsSheetCancel], action: close)
                .keyboardShortcut(.cancelAction)

            Button(ProductStrings[.settingsSheetDone], action: store)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    draft.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || regionMissing
                        || saving
                )
        }
    }

    /// The regions this provider offers, which is the daemon's own list and
    /// empty for a provider that serves one.
    private var offeredRegions: [ManagementPluginOAuthRegion] { client?.regions ?? [] }

    /// Done waits for a region the way it waits for an identifier, because the
    /// daemon requires one exactly where the client offers some. It reads the
    /// same validation the save runs, so what the sheet refuses to send is what
    /// it refuses to enable.
    private var regionMissing: Bool {
        do {
            _ = try draft.validatedRegion(offered: offeredRegions)
            return false
        } catch {
            return true
        }
    }

    /// The account region, first because it is a fact about the account rather
    /// than about the client, and because it is chosen before connecting: it
    /// selects the token audience, so a grant minted under the wrong one is
    /// refused rather than used.
    @ViewBuilder
    private var region: some View {
        if !offeredRegions.isEmpty {
            LabeledContent(ProductStrings[.integrationClientRegion]) {
                Picker(ProductStrings[.integrationClientRegion], selection: $draft.region) {
                    // Nothing chosen has no tag among the offered ids, so the
                    // popup would draw blank. It says so instead, and the row
                    // goes once a region is chosen.
                    if !offeredRegions.contains(where: { $0.id == draft.region }) {
                        Text(ProductStrings[.integrationClientRegionPrompt]).tag(draft.region)
                    }

                    ForEach(offeredRegions, id: \.id) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Text(ProductStrings[.integrationClientRegionFooter])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    /// and sending one the operator did not type would pin it. A region is sent
    /// only where the provider offers some, which is where the daemon wants one.
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

        let chosenRegion: String?
        do {
            chosenRegion = try draft.validatedRegion(offered: offeredRegions)
        } catch {
            refusal = ProductStrings[.integrationClientRegionMissing]
            return
        }

        saving = true
        Task {
            let sentence = await model.setOAuthClient(
                provider: provider,
                clientId: identifier,
                redirectPort: redirectPort,
                region: chosenRegion
            )
            saving = false
            refusal = sentence

            guard sentence == nil else { return }

            close()
        }
    }
}

/// Choose a workspace (M34 §5.6), as a page of the plugin's detail.
///
/// Two steps on one page: the access profile the manifest publishes, with the
/// daemon's own write flag driving the warning, then the workspace the last
/// discovery found. Both halves are the daemon's; the page only picks.
///
/// The plugin is addressed by name and re-read on every render, and the
/// discovery job re-reads the catalogue when it ends. A captured row would make
/// `Find workspaces` a button that can never change what it is looking at: the
/// daemon republishes the discovery on the plugin row, not on the job. That
/// re-read is the model's (`jobsRepublishingPlugins`), asked for by the sheet
/// this is a page of: a binding sends the person back to the detail while its
/// job is still running, so a re-read hung on this page would be gone before
/// the job it was waiting for ended.
struct WorkspacePage: View {
    let name: String
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    /// Returns to the detail: the back control, `Cancel`, and a binding the
    /// daemon accepted.
    let back: () -> Void

    @State private var profile = ""
    @State private var chosen = ""
    @State private var refusal: String?

    /// The plugin as the daemon last published it. Absent means the catalogue
    /// no longer carries it, and the page says so rather than drawing a list
    /// of nothing.
    private var row: IntegrationRowModel? {
        IntegrationRowProjection.row(named: name, in: model.plugins.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            IntegrationPageHeader(
                title: ProductStrings[.integrationWorkspaceTitle],
                parent: row?.title ?? name,
                back: back
            )

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

                Button(ProductStrings[.settingsSheetCancel], action: back)
                    .keyboardShortcut(.cancelAction)

                Button(ProductStrings[.integrationWorkspaceUse], action: select)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.isEmpty || chosen.isEmpty || runner.isRunning)
            }
        }
        .onAppear { profile = row?.accessProfiles.first?.id ?? "" }
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

    /// A binding the daemon accepted goes back to the detail, which is where
    /// its progress is drawn and where the workspace row reads the label the
    /// daemon republishes. A refusal stays here with its sentence, because
    /// leaving on one would report a choice that was never made.
    private func select() {
        guard let workspace = row?.workspaces.first(where: { $0.id == chosen }) else { return }

        Task {
            refusal = await model.startWorkspaceSelection(
                name: name,
                profile: profile,
                workspace: workspace,
                on: runner
            )

            guard refusal == nil else { return }

            back()
        }
    }
}
