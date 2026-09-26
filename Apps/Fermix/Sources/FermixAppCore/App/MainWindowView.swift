import SwiftUI

/// The primary window: a `NavigationSplitView` with the system's sidebar and
/// the surface it selects (M34 §3.1, §6).
///
/// One window for app surfaces, the Setup Assistant, and Settings. Settings is
/// a place inside the frame rather than a mode that replaces it: the rail stays
/// with its gear selected, and the body shows the settings pane list beside the
/// pane's form (owner, 2026-09-25, from the Codex app: "we can keep it for
/// homepage and settings can be inside that").
///
/// Fermix draws no container inside a surface: the toolbar, the inline title and
/// every box a surface shows are the system's, and the window paints no glass
/// and no glass of its own. What it does paint is three things, and all three
/// are the window's own rather than any surface's: the one ambient ground behind
/// everything (redlines §1.3), the frame of rail and top band (§5.7), and the
/// three corners that round the body into it.
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
    /// The toolbar's height over the body, which is the frame's band.
    @State private var bandHeight: Double = 0
    /// The one settings model, handed to the settings columns. It is held and
    /// not observed: the window's own body reads nothing from it, and observing
    /// it redrew the whole window, rail and ground included, on every one of its
    /// twenty published changes. The views that draw it observe it themselves.
    let settings: SettingsModel
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
            // full size content. The frame paints its own fill over it.
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
                RestartSheetHost(
                    settings: settings,
                    restart: restart,
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
    /// The app surfaces and settings share one split view: entering or leaving
    /// settings changes what its two columns hold, never the split view itself.
    /// Built as two branches, crossing between them tore down and rebuilt the
    /// split view, its toolbar, both lists and every task under them on each
    /// Back, gear click and Escape (2026-09-24). What only settings has sits on
    /// its own columns: the search field on the pane column, the Restart
    /// control beside the back control, and the first read on the detail.
    @ViewBuilder
    private var presented: some View {
        if !presentation.isShowing, model.route == .setup || model.route == .recovery {
            OnboardingWindowView(model: surfaces.onboarding)
                .navigationTitle(ProductStrings[.windowOnboardingTitle])
        } else {
            splitView
                // Escape returns, exactly as the back control does. It sits on
                // the whole split view rather than on the detail column, so it
                // answers with focus in the pane list or the search field too:
                // AppKit walks the responder chain up from the first responder,
                // and those two are siblings of the detail, not descendants. A
                // sheet never reaches this — a presented sheet is the key
                // window, so its own cancel action consumes the key first
                // (§5.8). Outside settings there is nothing to leave, so it
                // answers nothing.
                //
                // A field being edited owns Escape first, which is what Escape
                // means on the Mac: it puts the daemon's value back and gives up
                // focus, and only Escape with nothing being edited leaves. Every
                // descriptor field commits on focus loss, so without this the
                // gesture read as "save this and leave" (§3.1).
                .onExitCommand(perform: presentation.isShowing ? exitCommand : nil)
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            appSidebar
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
                .framedByBand(height: bandHeight)
                .overlay { bodyCorners }
                .onGeometryChange(for: Double.self) { proxy in
                    proxy.safeAreaInsets.top
                } action: { top in
                    bandHeight = top
                }
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

    /// Home, Doctor, Logs, Pet, and Settings pinned to the foot of the rail.
    ///
    /// Decision D2 puts Settings at the *bottom* of the sidebar, the slot the
    /// owner named for the dropdown the tab list may become (decision D7), and
    /// redlines §5.7 requires it "keyboard reachable in the same order as the
    /// rows above it": it is the last button of the one column, held down by a
    /// spacer. The four are the published four in their published order and
    /// nothing else; the mascot that stood at the head of the rail for an
    /// afternoon was withdrawn the same day (2026-09-20).
    ///
    /// A column of buttons rather than the split view's `List`, so the squares
    /// can stand apart as the Codex rail's do (`RailMetrics`, 2026-09-25).
    private var appSidebar: some View {
        RailColumn(items: SidebarItem.mainWindow, selected: selectedSidebarIdentifier) { identifier in
            selection.wrappedValue = identifier
        }
        .railColumn()
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

    /// The body's three open corners, cut to the window's own radius (owner,
    /// 2026-09-20: "should we make the left pane or the body rounded edge like
    /// the macOS window?").
    ///
    /// The rail already ends in the window's rounded corners, because the window
    /// clips it. Where the body meets the rail it did not: the detail column's
    /// leading corners were square against a column whose outer ones were round,
    /// so the two read as one sheet with a black stripe painted down it rather
    /// than as a body sitting inside a frame. The top trailing corner, where the
    /// band meets the window's trailing edge, is cut the same way (owner,
    /// 2026-09-25: "add the rounded edge to top right of the body as well to
    /// keep it consistent"); the fourth is the window's own corner.
    ///
    /// What draws them is more of the frame's glass, laid over the corners at
    /// `bodyCornerRadius`, which is this window's own measured radius.
    /// Overlaid rather than clipped, because a clip is the inset panel
    /// the owner removed earlier the same day ("Lets remove the border, it
    /// doesnt fit well with the color of ours"): clipping costs the surface a
    /// point of content on every edge and needs a ground of its own behind what
    /// it cuts away, while an overlay takes nothing and paints only the corners.
    ///
    /// The top corners sit under the band rather than on the window's top edge,
    /// so the body's safe area places them; the bottom one still sits on the
    /// window's bottom edge.
    ///
    /// It is paint over live content, so it takes no clicks and says nothing.
    private var bodyCorners: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                bodyCorner(FrameCorner())
                Spacer(minLength: 0)
                bodyCorner(FrameCorner().scale(x: -1, y: 1))
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                bodyCorner(FrameCorner().scale(x: 1, y: -1))
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One corner: the frame's glass, masked to the wedge `shape` leaves.
    private func bodyCorner(_ shape: some Shape) -> some View {
        FrameGlass().mask(shape)
            .frame(width: WindowMetrics.bodyCornerRadius, height: WindowMetrics.bodyCornerRadius)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if presentation.isShowing {
            // Settings inside the frame: its pane list is the second pane and
            // the form the third, and the rail stays, so the rail is the way
            // back and no back control is drawn.
            HStack(spacing: 0) {
                SettingsPaneColumn(model: settings)
                    .paneColumn()
                SettingsDetailView(model: settings, router: router, openRecovery: openRecovery)
            }
            .toolbar {
                SettingsRestartControl(model: settings, router: router, transaction: model.transactionInFlight)
            }
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
    /// The rail is the column in and out of settings, so the one preference
    /// governs it in both.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebar.visibility == .all ? .all : .detailOnly },
            set: { proposed in
                sidebar.visibilityWritten(proposed == .detailOnly ? .detailOnly : .all)
            }
        )
    }

    /// The rail selects a route, or the pinned Settings button. A route with no
    /// button (the update and uninstall surfaces) leaves the selection empty
    /// rather than lighting one that does not describe what is showing.
    var selection: Binding<String?> {
        Binding(
            get: { selectedSidebarIdentifier },
            set: { identifier in
                guard let identifier else { return }

                // Routing publishes several models, so leave the view update
                // that chose first. The rail is one column in and out of
                // settings, so a surface chosen from settings leaves it: the
                // coordinator's presentation of a surface is what closes it.
                DispatchQueue.main.async {
                    guard identifier != selectedSidebarIdentifier else { return }
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
            HomeView(model: surfaces.home, router: router)
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

/// The Restart sheet as the window hosts it. It observes the settings model the
/// window itself only holds, so the sheet's title follows `isFinishingUpdate`
/// while it is up without the whole window redrawing for it.
private struct RestartSheetHost: View {
    @ObservedObject var settings: SettingsModel
    let restart: () -> Void
    let refusal: String?
    let dismiss: () -> Void

    var body: some View {
        RestartSheet(
            model: settings,
            restart: restart,
            isFinishingUpdate: settings.engineReconcile.isFinishingUpdate,
            refusal: refusal,
            dismiss: dismiss
        )
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
