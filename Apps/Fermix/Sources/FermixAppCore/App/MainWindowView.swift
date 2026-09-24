import SwiftUI

/// The primary window: a `NavigationSplitView` with the system's sidebar and
/// the surface it selects (M34 §3.1, §6).
///
/// One window for app surfaces, the Setup Assistant, and Settings. Entering
/// settings replaces the app sidebar
/// with the settings pane column and the surface with the pane's form; the
/// sidebar's own visibility is untouched, so leaving restores exactly what the
/// user had.
///
/// Fermix draws no container inside a surface: the toolbar, the inline title and
/// every box a surface shows are the system's, and the window paints no glass
/// and no titlebar of its own. What it does paint is three things, and all three
/// are the window's own rather than any surface's: the one ambient ground behind
/// everything (redlines §1.3), the black rail down its leading edge (§5.7), and
/// the two leading corners that round the body into the window's shape.
///
/// The ground's intensity is decided here too, because this is the one view that
/// holds both halves of the question: which presentation is up, and which route
/// is showing inside it. The rule itself is `AmbientIntensity.forWindow`, so it
/// can be walked over every route instead of read off a capture.
///
/// The rail is still the system's sidebar column, a `List` with a selection, so
/// arrow keys, full keyboard access and VoiceOver reach it exactly as they did
/// when it carried words. What changed is what a row draws.
///
/// The sidebar is the chat-ready shell: a future Chat row is one more entry in
/// `SidebarItem.mainWindow`, and the pinned Settings row below them is the slot
/// the owner named for the dropdown the tab list may become (decision D7).
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sidebar: SidebarModel
    let surfaces: MainWindowSurfaces
    let router: any CommandPerforming
    @ObservedObject var presentation: SettingsPresentation
    /// The sidebar column's height, and where its last row would sit with no
    /// spacer under the four above it. Together they place the pinned Settings
    /// row on the bottom edge; see `footerGap`.
    @State private var sidebarHeight: Double = 0
    @State private var settingsRowBottom: Double = 0
    /// The one settings model, held here so the pane column's search field can
    /// bind to it. It is the same instance `surfaces.settings` carries.
    @ObservedObject var settings: SettingsModel
    /// Leaving settings, which the coordinator owns: the back control, Escape
    /// and a command all take the one path out.
    let leaveSettings: () -> Void
    let openRecovery: () -> Void
    /// Takes the journaled restart, once the sheet's chosen moment arrives. The
    /// coordinator's own transaction, not the command: the command asks, and
    /// this is what the sheet's action runs (M34 §5.10).
    let restart: () -> Void

    var body: some View {
        presented
            // One ground for the one window, behind the split view rather than
            // inside its detail column, so every presentation sits over the same
            // wash. It reaches under the titlebar because every window here is
            // full size content. The rail paints its own black over it.
            .background { AmbientGround(intensity: groundIntensity).ignoresSafeArea() }
            .onGeometryChange(for: Double.self) { proxy in
                proxy.size.width
            } action: { width in
                sidebar.widthChanged(width)
            }
            // The one Restart sheet in the app (M34 §5.10). It hangs off the
            // window rather than off Home, because the Settings banner, the
            // Daemon menu and the status item all ask for it too and only this
            // window can host one.
            .sheet(isPresented: $model.restartSheetShown) {
                RestartSheet(
                    model: settings,
                    restart: restart,
                    isFinishingUpdate: settings.engineReconcile.isFinishingUpdate,
                    refusal: model.restartRefusal
                ) { model.restartSheetShown = false }
            }
            // The one sheet of commands (M34 §15.2). Home's Attention row, a
            // Doctor remediation and the Help menu all open this one.
            .sheet(item: $model.instructionsShown) { instructions in
                CoexistenceInstructionsSheet(instructions: instructions) { model.instructionsShown = nil }
            }
            .lifecycleStatus(of: model)
    }

    /// Setup uses the existing assistant screens inside this same window.
    ///
    /// The search field and the removed sidebar toggle belong to settings and
    /// to nothing else, so they are applied on that branch rather than bound to
    /// a flag the app presentation would have to ignore.
    @ViewBuilder
    private var presented: some View {
        if presentation.isShowing {
            splitView
                .toolbar {
                    SettingsRestartControl(model: settings, router: router, transaction: model.transactionInFlight)
                }
                .searchable(
                    text: $settings.searchText,
                    placement: .sidebar,
                    prompt: Text(ProductStrings[.settingsSearchPrompt])
                )
                // Escape returns, exactly as the back control does. It sits on
                // the whole split view rather than on the detail column, so it
                // answers with focus in the pane list or the search field too:
                // AppKit walks the responder chain up from the first responder,
                // and those two are siblings of the detail, not descendants. A
                // sheet never reaches this — a presented sheet is the key
                // window, so its own cancel action consumes the key first
                // (§5.8).
                //
                // A field being edited owns Escape first, which is what Escape
                // means on the Mac: it puts the daemon's value back and gives up
                // focus, and only Escape with nothing being edited leaves. Every
                // descriptor field commits on focus loss, so without this the
                // gesture read as "save this and leave" (§3.1).
                .onExitCommand(perform: exitCommand)
                .task { await settings.windowAppeared() }
        } else if model.route == .setup || model.route == .recovery {
            OnboardingWindowView(model: surfaces.onboarding)
                .navigationTitle(ProductStrings[.windowOnboardingTitle])
        } else {
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            leadingColumn
        } detail: {
            // The detail column may always compress to the window it is in,
            // which is decision D4's other half: a pane scrolls only when it
            // must, so a pane longer than the window has to be able to give up
            // the height rather than demand it.
            //
            // SwiftUI propagates a minimum height out of content that cannot
            // compress, and the split view republishes it as the window's. The
            // measured one is the settings banner: a wrapping `Text` in a top
            // safe-area bar reports the height it would need wrapped at its
            // narrowest, which made the whole window incompressible. On a 3840
            // by 1080 point display that opened the Integrations pane at 980 by
            // 2115, with half the window below the bottom of the screen.
            //
            // The floor is zero here, at the one seam every pane passes
            // through, rather than in the banner: any pane can hold a view that
            // reports a minimum, and this is where the window's size wins.
            detailColumn.frame(minWidth: 0, minHeight: 0)
                .overlay(alignment: .leading) { bodyCorners }
        }
    }

    /// Escape, resolved once. A focused descriptor field reverts and keeps the
    /// window; anything else leaves settings.
    private func exitCommand() {
        guard settings.editingRow == nil else {
            settings.revertEdit()
            return
        }

        leaveSettings()
    }

    @ViewBuilder
    private var leadingColumn: some View {
        if presentation.isShowing {
            // The pane column is fixed and never collapses, so the system's
            // sidebar toggle is removed from it (redlines §5.8). The modifier
            // has to sit on the column's own content: applied to the split view
            // it is not honoured, and the toggle is still drawn above the pane
            // list on every pane.
            SettingsPaneColumn(model: settings)
                .railColumn()
                .toolbar(removing: .sidebarToggle)
        } else {
            appSidebar
        }
    }

    /// Home, Doctor, Logs, Pet, and the one pinned row anchored beneath them.
    ///
    /// Decision D2 puts the Settings row at the *bottom* of the sidebar, which
    /// is the slot the owner named for the dropdown the tab list may become
    /// (decision D7), and redlines §5.7 requires it "keyboard reachable in the
    /// same order as the rows above it". Both, so it is the last row of the
    /// same `List`, pushed down by one measured spacer row. Drawn as a second
    /// `List` in a bottom safe-area inset it was pinned but unreachable: two
    /// lists are two selection contexts, and arrow-key navigation from Pet
    /// stopped at Pet.
    ///
    /// The rows are the published four in their published order and nothing
    /// else. For an afternoon the mascot mark stood at the head of the rail and
    /// was the way to Pet; the owner withdrew both the same day ("the previous
    /// icon was fine. The fermix mascot on the left pane isnt needed. And it
    /// should be below the logs"), so Pet is its own symbol again, under Logs.
    private var appSidebar: some View {
        List(selection: selection) {
            ForEach(SidebarItem.mainWindow) { item in
                railIcon(item.title, systemImage: item.systemImage)
                    .tag(item.id)
            }

            footerSpacer

            Button { router.perform(.openSettings) } label: {
                railIcon(ProductStrings[.sidebarSettings], systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onGeometryChange(for: Double.self) { proxy in
                proxy.frame(in: .named(Self.sidebarSpace)).maxY
            } action: { bottom in
                settingsRowBottom = bottom - footerGap
            }
            .tag(SidebarItem.settingsIdentifier)
            .selectionDisabled(false)
        }
        .coordinateSpace(.named(Self.sidebarSpace))
        // The column's full height, which is not the height the list is handed.
        // The list's size excludes the titlebar's safe area while its rows are
        // laid out in the column's full-height coordinates, so measuring
        // `size.height` alone left the gear 59 points short of the bottom edge:
        // exactly the inset the proxy had already taken off. Adding the top
        // inset back puts the two measurements in one coordinate space again.
        //
        // `railBottomInset` is what the gear then keeps clear of the edge, so it
        // sits as far off the bottom as the traffic lights sit off the top.
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.top - WindowMetrics.railBottomInset
        } action: { height in
            sidebarHeight = height
        }
        .railColumn()
        // With the spacer measured against the full height the list is exactly
        // as tall as the window, so the system drew a scroll bar down the rail
        // for the last point of it (owner, 2026-09-20: "I saw a scroll bar on
        // the left pane"). The rail is five fixed rows and never scrolls in any
        // way a person can use, and the settings pane column beside it already
        // hides its indicators under §5.8's scroll rule.
        .scrollIndicators(.never)
        // The rail is one fixed width and never has to make room, so the
        // system's toggle is not drawn over its head, where the traffic lights
        // are. View > Hide Sidebar and its shortcut still hide it.
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(WindowMetrics.railWidth)
    }

    /// Which ground this presentation sits on (redlines §1.3).
    ///
    /// The window asks; the recipe answers. Both facts the answer needs are
    /// here and nowhere else, and the rule is a function rather than a branch
    /// inside the body so that a route added later has to answer it.
    private var groundIntensity: AmbientIntensity {
        AmbientIntensity.forWindow(showingSettings: presentation.isShowing, route: model.route)
    }

    /// The body's two leading corners, cut to the window's own radius (owner,
    /// 2026-09-20: "should we make the left pane or the body rounded edge like
    /// the macOS window?").
    ///
    /// The rail already ends in the window's rounded corners, because the window
    /// clips it. Where the body meets the rail it did not: the detail column's
    /// leading corners were square against a column whose outer ones were round,
    /// so the two read as one sheet with a black stripe painted down it rather
    /// than as a body sitting inside a frame.
    ///
    /// What draws them is more of the rail's black, laid over the two corners at
    /// `bodyCornerRadius`, which is this window's own measured radius.
    /// Overlaid rather than clipped, because a clip is the inset panel
    /// the owner removed earlier the same day ("Lets remove the border, it
    /// doesnt fit well with the color of ours"): clipping costs the surface a
    /// point of content on every edge and needs a ground of its own behind what
    /// it cuts away, while an overlay takes nothing and paints only the corners.
    ///
    /// It is paint over live content, so it takes no clicks and says nothing.
    private var bodyCorners: some View {
        VStack(spacing: 0) {
            FrameCorner().fill(WindowFrameRecipe.fill.color)
                .frame(width: WindowMetrics.bodyCornerRadius, height: WindowMetrics.bodyCornerRadius)
            Spacer(minLength: 0)
            FrameCorner().fill(WindowFrameRecipe.fill.color)
                .frame(width: WindowMetrics.bodyCornerRadius, height: WindowMetrics.bodyCornerRadius)
                .scaleEffect(x: 1, y: -1)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One rail destination: the symbol alone (owner directive of 2026-09-20:
    /// "the premium icons instead of the icon + name").
    ///
    /// It is still a `Label`, so the row keeps its name for VoiceOver and for
    /// full keyboard access, and the same name is the help tag a pointer gets.
    private func railIcon(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: WindowMetrics.railSymbolSize))
            .frame(maxWidth: .infinity, minHeight: WindowMetrics.railRowHeight)
            .help(title)
    }

    /// The empty row that holds the Settings row down.
    ///
    /// It carries no selection and no accessibility, so the keyboard walks Home
    /// → Doctor → Logs → Pet → Settings straight through it.
    @ViewBuilder
    private var footerSpacer: some View {
        if footerGap > 0 {
            Color.clear
                .frame(height: footerGap)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .selectionDisabled()
                .accessibilityHidden(true)
        }
    }

    /// How far the Settings row has to fall to sit on the column's bottom edge.
    ///
    /// Derived from two measurements rather than from a row height and a row
    /// count the app would have to keep in step with the system: the column's
    /// own height, and where the row lands with this gap already taken back
    /// out. It settles in one pass — with the row on the bottom edge the sum is
    /// the gap it already has — and it re-settles on its own when the column
    /// resizes or the operator changes the system text size.
    private var footerGap: Double { max(0, sidebarHeight - settingsRowBottom) }

    private static let sidebarSpace = "fermix.sidebar"

    @ViewBuilder
    private var detailColumn: some View {
        if presentation.isShowing {
            SettingsDetailView(model: settings, router: router, openRecovery: openRecovery)
                .toolbar { SettingsBackControl(back: leaveSettings) }
        } else {
            detail.toolbar { toolbarKeeper }
        }
    }

    /// One empty item every app surface carries, so the window always has a
    /// toolbar to size its titlebar by.
    ///
    /// The system's sidebar toggle used to be that item. The rail removed it,
    /// and a surface with no toolbar of its own, which is Pet, then dropped the
    /// window to the short titlebar: the traffic lights and the title jumped
    /// eleven points every time the selection crossed it. Zero sized, because a
    /// one point item drew as a sliver of toolbar glass.
    @ToolbarContentBuilder
    private var toolbarKeeper: some ToolbarContent {
        ToolbarItem(placement: .status) {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// SwiftUI writes this binding for the system toggle, for a drag, and when
    /// the split view collapses the sidebar itself in a window too narrow to
    /// hold both columns. The model decides which of those a write was, from the
    /// width it was last told; the view never guesses.
    ///
    /// While settings is showing the column is the pane list, which is fixed and
    /// never collapses, so the binding reports it shown and swallows writes: the
    /// user's own visibility is a preference the presentation must not overwrite.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                if presentation.isShowing { return .all }

                return sidebar.visibility == .all ? .all : .detailOnly
            },
            set: { proposed in
                guard !presentation.isShowing else { return }

                sidebar.visibilityWritten(proposed == .detailOnly ? .detailOnly : .all)
            }
        )
    }

    /// The sidebar selects a route, or the pinned Settings row. A route with no
    /// row (the update and uninstall surfaces) leaves the selection empty rather
    /// than lighting a row that does not describe what is showing.
    var selection: Binding<String?> {
        Binding(
            get: { selectedSidebarIdentifier },
            set: { identifier in
                guard let identifier else { return }

                // Routing publishes several models. Leave List's update stack
                // first, and ignore callbacks from the List Settings replaced.
                DispatchQueue.main.async {
                    guard !presentation.isShowing,
                          selectedSidebarIdentifier != SidebarItem.settingsIdentifier,
                          identifier != selectedSidebarIdentifier else { return }
                    guard identifier != SidebarItem.settingsIdentifier else {
                        router.perform(.openSettings)
                        return
                    }
                    guard let item = SidebarItem.mainWindow.first(where: { $0.id == identifier }) else { return }

                    switch item.route {
                    case .home: router.perform(.showHome)
                    case .doctor: router.perform(.showDoctor)
                    case .logs: router.perform(.showLogs)
                    case .pet: router.perform(.showPet)
                    case .setup, .update, .uninstall, .recovery:
                        preconditionFailure("\(item.route.rawValue) has no sidebar row")
                    }
                }
            }
        )
    }

    private var selectedSidebarIdentifier: String? {
        switch model.pendingNavigation {
        case .settings?: return SidebarItem.settingsIdentifier
        case .surface(let route)?: return SidebarItem.selection(route: route)
        case nil:
            return presentation.isShowing ? SidebarItem.settingsIdentifier : SidebarItem.selection(route: model.route)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .home:
            HomeView(model: surfaces.home, settings: settings, router: router)
        case .doctor:
            DoctorView(model: surfaces.doctor, router: router)
        case .logs:
            LogsView(model: surfaces.logs, router: router)
        case .pet:
            PetSurfaceView(model: surfaces.pet)
        case .update:
            UpdateSurfaceView(model: surfaces.home.updateSurface, router: router)
        case .setup, .uninstall, .recovery:
            // Setup and Recovery use the assistant presentation above;
            // Uninstall resolves to Doctor before this view is reached.
            preconditionFailure("\(model.route.rawValue) has no sidebar detail")
        }
    }
}

/// The update surface (M34 §3.4, decision 12; M34 §6, R2).
///
/// Three facts and one action: which engine is answering, which one this copy
/// of Fermix ships, what the last check found, and the check itself. Install,
/// Remind Later and Skip are the updater's own alert, so nothing here draws a
/// second one.
struct UpdateSurfaceView: View {
    let model: UpdateSurfaceModel
    let router: any CommandPerforming

    var body: some View {
        Form {
            Section(ProductStrings[.sectionHeaderVersions]) {
                LabeledContent(ProductStrings[.homeRuntimeEngine]) {
                    Text(model.running ?? ProductStrings[.homeRuntimeNone])
                        .foregroundStyle(Palette.secondary.color)
                }

                LabeledContent(ProductStrings[.updateBundled]) {
                    Text(model.bundled ?? ProductStrings[.homeRuntimeNone])
                        .foregroundStyle(Palette.secondary.color)
                }

                Text(model.summary)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)

                Button(ProductStrings[.updateCheck]) { router.perform(.checkForUpdates) }
                    .buttonStyle(SecondaryButtonStyle(.inWindow))
                    .disabled(!router.canPerform(.checkForUpdates))
            }

            Section {
                Text(ProductStrings[.updateHow])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .showsAmbientGround()
        .rowActions()
        .scrollIndicators(.never)
        .paneScrollEdges()
        .navigationTitle(ProductStrings[.updateTitle])
    }
}

/// What the Update surface states: the two engine versions, and whatever the
/// update seam last answered.
public struct UpdateSurfaceModel: Equatable, Sendable {
    public let running: String?
    public let bundled: String?
    public let summary: String

    public init(running: String?, bundled: String?, summary: String) {
        self.running = running
        self.bundled = bundled
        self.summary = summary
    }
}
