import CoreGraphics
import Foundation
import Testing

@testable import FermixAppCore

/// Settings as a presentation of the primary window (decision D1, redlines
/// §5.8; owner directive of 2026-09-03: "having it launch as a separate app or
/// window doesnt make sense and adds friction").
///
/// There is no settings window to size, so what is provable here is the switch:
/// what entering records, what leaving restores, and that no second window is
/// ever put on screen.
@Suite("Settings presentation")
@MainActor
struct SettingsPresentationTests {

    // MARK: - The switch

    /// Entering records the surface the user came from, and leaving answers it.
    @Test("entering settings remembers the surface it replaced, and leaving returns to it")
    func entersAndLeaves() {
        let presentation = SettingsPresentation()

        #expect(!presentation.isShowing)

        presentation.enter(from: .logs)

        #expect(presentation.isShowing)
        #expect(presentation.returnRoute == .logs)
        #expect(presentation.leave() == .logs)
        #expect(!presentation.isShowing)
    }

    /// A second entry while settings is already open must not record the
    /// settings presentation as the place to come back to: a url that arrives
    /// while a pane is open would otherwise strand the back control on itself.
    @Test("entering twice keeps the surface the first entry recorded")
    func enteringTwiceKeepsTheFirstReturnRoute() {
        let presentation = SettingsPresentation()

        presentation.enter(from: .doctor)
        presentation.enter(from: .home)

        #expect(presentation.returnRoute == .doctor)
        #expect(presentation.leave() == .doctor)
    }

    /// Every entry grows the window, including one that arrives while settings
    /// is already showing: the window may have been resized since.
    @Test("every entry asks the window to grow")
    func everyEntryGrows() {
        var growths = 0
        let presentation = SettingsPresentation { growths += 1 }

        presentation.enter(from: .home)
        presentation.enter(from: .home)
        presentation.leave()

        #expect(growths == 2)
    }

    // MARK: - Routes

    /// A `fermix://settings/<pane>` url selects the pane and enters the
    /// presentation of the primary window. No second window opens.
    @Test("a settings url enters the presentation of the primary window")
    func routeEntersThePresentation() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)

        try harness.coordinator.open(url: URL(string: "fermix://settings/sandbox")!)
        try await harness.coordinator.drainPendingWork()

        #expect(harness.windows.presented == [.main])
        #expect(harness.settings.selectedPane == .sandbox)
        #expect(harness.presentation.isShowing)
        #expect(harness.presentation.returnRoute == .home)
    }

    /// Command-comma opens the pane the presentation was last left on, from
    /// wherever the user is standing.
    @Test("Command-comma enters at the remembered pane and returns to the surface it left")
    func commandCommaEntersAndReturns() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        harness.model.route = .doctor
        harness.settings.selectedPane = .images

        harness.coordinator.openSettings()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.presentation.isShowing)
        #expect(harness.settings.selectedPane == .images)
        #expect(harness.presentation.returnRoute == .doctor)

        harness.coordinator.leaveSettings()

        #expect(!harness.presentation.isShowing)
        #expect(harness.model.route == .doctor)

        let shortcut = try #require(CommandTable.shortcut(of: .openSettings))
        #expect(shortcut.key == ",")
        #expect(!shortcut.holdsControl)
        #expect(!shortcut.holdsShift)
    }

    /// Every navigation command is a request for a surface of this same window,
    /// and settings is its other presentation. Issued from inside settings, a
    /// route therefore leaves the presentation rather than writing a route
    /// nobody can see — which the next Back would then overwrite with the
    /// surface the entry recorded.
    @Test("a route performed from inside settings leaves the presentation")
    func aRouteLeavesTheSettingsPresentation() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        harness.model.route = .home
        harness.coordinator.openSettings()
        try await harness.coordinator.drainPendingWork()

        #expect(harness.presentation.isShowing)

        harness.coordinator.open(.doctor)
        try await harness.coordinator.drainPendingWork()

        #expect(!harness.presentation.isShowing, "the window is still on the settings pane")
        #expect(harness.model.route == .doctor)

        // And the same for a surface url, which is the other door.
        harness.coordinator.openSettings()
        try await harness.coordinator.drainPendingWork()
        try harness.coordinator.open(url: URL(string: "fermix://logs")!)
        try await harness.coordinator.drainPendingWork()

        #expect(!harness.presentation.isShowing)
        #expect(harness.model.route == .logs)
    }

    @Test("opening the assistant replaces settings inside the primary window")
    func theAssistantReplacesSettings() async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        harness.model.route = .doctor
        harness.coordinator.openSettings()
        try await harness.coordinator.drainPendingWork()

        harness.coordinator.openAssistant(at: .welcome)

        #expect(!harness.presentation.isShowing)
        #expect(harness.model.route == .setup)
        #expect(harness.presentation.returnRoute == .doctor)
    }

    /// Leaving when nothing is showing changes nothing: the back control only
    /// exists while settings does, and a stray command must not move the route.
    @Test("leaving settings that is not showing moves nothing")
    func leavingWhenClosedIsANoOp() throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        harness.model.route = .logs

        harness.coordinator.leaveSettings()

        #expect(harness.model.route == .logs)
        #expect(!harness.presentation.isShowing)
    }

    /// The presentation is a value, so what a url means is decidable without a
    /// window server.
    @Test("a settings destination presents the primary window")
    func presentationValue() {
        #expect(
            AppCoordinator.presentation(for: .route(.settings(.voice)), bootstrap: .present) == .settings(.voice)
        )
        #expect(AppDestination.settings(.voice).window == .main)
    }

    // MARK: - The sidebar footer row

    /// Decision D2: the pinned row is always present and is not a
    /// `SidebarItem` — it selects a presentation rather than a route.
    ///
    /// There is no settings answer in `selection`: entering replaces the whole
    /// app sidebar with the pane column, so no drawn row could carry that
    /// highlight and a branch for it would publish a value nothing can show.
    @Test("the pinned Settings row is its own identifier, outside the route rows")
    func footerRowSelection() {
        #expect(SidebarItem.settingsIdentifier == "settings")
        #expect(!SidebarItem.mainWindow.contains { $0.id == SidebarItem.settingsIdentifier })

        #expect(SidebarItem.selection(route: .home) == "home")
        #expect(SidebarItem.selection(route: .doctor) == "doctor")
        #expect(SidebarItem.selection(route: .update) == nil)
    }

    /// The row draws a title and a gear, sits in the footer position rather
    /// than directly under Pet, and is the last row of the sidebar's own list.
    ///
    /// Both halves, because either one alone is a defect redlines §5.7 names.
    /// A trailing `Section` renders under Pet with the whole column empty
    /// beneath it. A second `List` in a bottom safe-area inset pins the row and
    /// takes it out of the keyboard order: two lists are two selection
    /// contexts, so arrow keys from Pet reached nothing, against the redline's
    /// "keyboard reachable in the same order as the rows above it".
    ///
    /// What holds it down is a measured spacer row, so the gate asserts the
    /// measurement is derived rather than a row height written down here: a
    /// constant would be wrong at every system text size but one.
    @Test("the pinned row is the sidebar list's last row, held on the bottom edge")
    func footerRowIsDescribed() throws {
        #expect(ProductStrings[.sidebarSettings] == "Settings")

        let sidebar = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(sidebar.first?.text)

        #expect(text.contains("SidebarItem.settingsIdentifier"))
        #expect(text.contains("\"gearshape\""))
        #expect(!text.contains(".safeAreaInset(edge: .bottom"), "the row is in a list of its own again")

        // One list in the app sidebar, with the four route rows and the pinned
        // row in it, in that order.
        let rows = try #require(text.range(of: "ForEach(SidebarItem.mainWindow)"))
        let after = text[rows.upperBound...]
        let spacer = try #require(after.range(of: "footerSpacer"), "nothing holds the row down")
        let pinned = try #require(after.range(of: "SidebarItem.settingsIdentifier"))

        #expect(spacer.lowerBound < pinned.lowerBound, "the spacer follows the row it should precede")
        #expect(after[..<spacer.lowerBound].contains("List(") == false, "a second list opens before the spacer")

        // The gap is measured off the column and the row, never written down.
        #expect(text.contains("max(0, sidebarHeight - settingsRowBottom)"))
        #expect(!text.contains("sidebarFooterRowHeight"), "the row height is a constant again")
    }

    @Test("the pinned Settings row is an actionable control in keyboard order")
    func footerRowIsActionable() throws {
        let text = try #require(try SourceTree.swiftFiles(matching: "App/MainWindowView.swift").first?.text)
        let start = try #require(text.range(of: "            footerSpacer"))
        let end = try #require(text.range(of: "        .coordinateSpace", range: start.upperBound..<text.endIndex))
        let row = text[start.upperBound..<end.lowerBound]

        #expect(row.contains("Button"))
        #expect(row.contains("router.perform(.openSettings)"))
        #expect(row.contains(".selectionDisabled(false)"))
        #expect(row.contains(".tag(SidebarItem.settingsIdentifier)"))
    }

    /// Entering settings hides the app sidebar as a *presentation*, not as a
    /// preference: the pane column is fixed and never collapses, so the window
    /// reports it shown and swallows every write while settings is up. Without
    /// that guard the split view's own layout would be recorded as the user
    /// hiding their sidebar, and `SidebarReducer` never restores an explicit
    /// hide — the sidebar would be gone for good after one visit.
    @Test("the settings presentation never writes the user's own sidebar visibility")
    func thePresentationDoesNotTouchTheSidebarPreference() throws {
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)

        #expect(text.contains("guard !presentation.isShowing else { return }"))
        #expect(text.contains("if presentation.isShowing { return .all }"))

        // And the model itself is untouched: leaving restores whatever the
        // reducer was holding, because nothing wrote to it.
        let model = SidebarModel(store: InMemorySidebarStore())
        model.userSet(.detailOnly)

        let presentation = SettingsPresentation()
        presentation.enter(from: .home)
        presentation.leave()

        #expect(model.visibility == .detailOnly)
        #expect(model.state.hiddenByUser)
    }

    // MARK: - Window growth

    /// Entering grows a window smaller than the default up to it, anchored at
    /// its top-left, so the titlebar does not move under the pointer.
    @Test("a small window grows to the default, holding its top-left")
    func growsToTheDefault() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_800, height: 1_100)
        let frame = CGRect(x: 100, y: 300, width: 760, height: 520)

        let grown = try #require(
            WindowGrowth.frame(growing: frame, toAtLeast: WindowMetrics.mainDefaultSize, within: screen)
        )

        #expect(grown.size == WindowMetrics.mainDefaultSize)
        #expect(grown.minX == frame.minX)
        #expect(grown.maxY == frame.maxY, "the top edge does not move")
    }

    /// Growth is one-way: a window already at or past the default is left where
    /// the user put it, and leaving settings never shrinks it.
    @Test("a window already large enough is not moved")
    func neverShrinks() {
        let screen = CGRect(x: 0, y: 0, width: 1_800, height: 1_100)
        let large = CGRect(x: 0, y: 0, width: 1_400, height: 900)

        #expect(WindowGrowth.frame(growing: large, toAtLeast: WindowMetrics.mainDefaultSize, within: screen) == nil)

        // One dimension short: the short one grows, the wide one is kept.
        let wide = CGRect(x: 0, y: 0, width: 1_400, height: 400)
        let grown = WindowGrowth.frame(growing: wide, toAtLeast: WindowMetrics.mainDefaultSize, within: screen)

        #expect(grown?.width == 1_400)
        #expect(grown?.height == WindowMetrics.mainDefaultSize.height)
    }

    /// The growth is clamped to the visible frame, so it can never push the
    /// window off-screen or under the menu bar.
    @Test("growth never leaves the visible screen frame")
    func clampedToTheVisibleFrame() throws {
        // A screen smaller than the target in both directions, with the window
        // parked against its trailing and top edges.
        let screen = CGRect(x: 0, y: 60, width: 900, height: 560)
        let frame = CGRect(x: 500, y: 400, width: 400, height: 220)

        let grown = try #require(
            WindowGrowth.frame(growing: frame, toAtLeast: WindowMetrics.mainDefaultSize, within: screen)
        )

        #expect(grown.width == screen.width, "it cannot be wider than the screen shows")
        #expect(grown.height == screen.height)
        #expect(screen.contains(grown), "the whole window stays on screen")
    }

    /// A screen the window server could not report is not a reason to move a
    /// window to nowhere.
    @Test("an empty visible frame moves nothing")
    func emptyScreenMovesNothing() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(WindowGrowth.frame(growing: frame, toAtLeast: WindowMetrics.mainDefaultSize, within: .zero) == nil)
    }

    // MARK: - Window fit

    /// The measured defect, as arithmetic.
    ///
    /// On the owner's 3840 by 1080 point display, whose visible frame is 3840
    /// by 960 once the menu bar and the Dock are taken off, the Integrations
    /// pane drove the primary window to 980 by 2115: twice the screen's height,
    /// with its lower half below the bottom edge. Whatever produces an ideal
    /// size that large, the frame that reaches the screen is bounded by what
    /// the screen can show.
    @Test("a window taller than the screen is fitted to it, holding its top-left")
    func fitsAnOversizedWindow() throws {
        let visible = CGRect(x: 0, y: 90, width: 3_840, height: 960)
        let ideal = CGRect(x: 1_047, y: -1_065, width: 980, height: 2_115)

        let fitted = try #require(WindowGrowth.frame(fitting: ideal, within: visible))

        #expect(fitted.height == visible.height)
        #expect(fitted.width == ideal.width, "a width the screen can show is kept")
        #expect(fitted.maxY == ideal.maxY, "the top edge does not move")
        #expect(visible.contains(fitted), "the whole window is on screen")
    }

    /// The same rule in the other direction, and both at once: a window can be
    /// too wide as well as too tall, and a frame restored from a larger display
    /// is usually both.
    @Test("a window larger than the screen in both directions is fitted in both")
    func fitsInBothDirections() throws {
        let visible = CGRect(x: 0, y: 90, width: 3_840, height: 960)
        let ideal = CGRect(x: -200, y: -400, width: 4_200, height: 1_400)

        let fitted = try #require(WindowGrowth.frame(fitting: ideal, within: visible))

        #expect(fitted.size == visible.size)
        #expect(fitted.origin == visible.origin)
    }

    /// A window the screen can already show is the operator's own, and nothing
    /// moves it. This is what keeps the fit off the resize the user just made.
    @Test("a window already inside the visible frame is not moved")
    func fitLeavesAnOnScreenWindowAlone() {
        let visible = CGRect(x: 0, y: 90, width: 3_840, height: 960)

        #expect(WindowGrowth.frame(fitting: visible, within: visible) == nil)
        #expect(
            WindowGrowth.frame(
                fitting: CGRect(x: 1_200, y: 250, width: 1_120, height: 700),
                within: visible
            ) == nil
        )
    }

    /// A window that fits but sits off the edge is pushed back in, because the
    /// frame it was restored with was measured against a screen that reached
    /// further than this one does.
    @Test("a window that fits but hangs off the edge is pushed back on")
    func fitPushesAWindowBackOnScreen() throws {
        let visible = CGRect(x: 0, y: 90, width: 1_440, height: 800)
        let ideal = CGRect(x: 1_300, y: 700, width: 980, height: 640)

        let fitted = try #require(WindowGrowth.frame(fitting: ideal, within: visible))

        #expect(fitted.size == ideal.size, "a window that fits keeps its size")
        #expect(visible.contains(fitted))
        #expect(fitted.maxX == visible.maxX)
        #expect(fitted.maxY == visible.maxY)
    }

    /// A screen the window server could not report is not a reason to move a
    /// window to nowhere. The same refusal the growth makes, for the same
    /// reason.
    @Test("an empty visible frame fits nothing")
    func fitOnAnEmptyScreenMovesNothing() {
        let frame = CGRect(x: 0, y: 0, width: 4_000, height: 4_000)

        #expect(WindowGrowth.frame(fitting: frame, within: .zero) == nil)
    }

    /// Growth and fit answer the same ceiling, so entering settings on a window
    /// that is already too big for the screen cannot make it bigger.
    @Test("growth is bounded by the same visible frame the fit is")
    func growthAndFitShareOneCeiling() throws {
        let visible = CGRect(x: 0, y: 90, width: 3_840, height: 960)
        let tall = CGRect(x: 1_047, y: -1_065, width: WindowMetrics.mainDefaultSize.width, height: 2_115)

        let grown = try #require(
            WindowGrowth.frame(growing: tall, toAtLeast: WindowMetrics.mainDefaultSize, within: visible)
        )

        #expect(grown.size == WindowGrowth.frame(fitting: tall, within: visible)?.size)
        #expect(visible.contains(grown))
    }

    /// Decision D3 states a *content* size: it is the unit the window
    /// descriptor builds the window with. `WindowGrowth` works in frame units,
    /// so the seam asks the window how much chrome sits on top before comparing
    /// rather than assuming the two are the same number.
    ///
    /// They are the same number today, because every descriptor here carries
    /// `.fullSizeContentView`, which puts a window's content rect and its frame
    /// rect on one rectangle. The conversion is there so the stated size stays
    /// a content size if that mask ever changes.
    ///
    /// The gate is a source scan rather than a live `NSWindow` measurement:
    /// touching AppKit from this process starts a main run loop that outlives
    /// the run, and a suite that can hang is worth less than the assertion.
    @Test("the growth target is converted from the stated content size")
    func growthTargetIsAFrameSize() throws {
        let host = try SourceTree.swiftFiles(matching: "App/AppKitWindowHost.swift")
        let text = try #require(host.first?.text)
        let conversion = try #require(text.range(of: "window.frameRect(forContentRect:"))
        let handoff = try #require(text.range(of: "WindowGrowth.frame(growing:"))

        #expect(conversion.lowerBound < handoff.lowerBound, "the content size is compared against a frame")
    }
}

/// The structural gates this slice makes true (M34 §8, §7.4, decision D1).
@Suite("Settings source gates")
struct SettingsSourceGateTests {
    /// Exactly one `SettingsModel` is built, in the composition. The
    /// two-`SetupModel` defect this replaces was two constructions in one file,
    /// which no value assertion could see.
    @Test("exactly one SettingsModel is constructed in the shipped tree")
    func oneSettingsModel() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let constructions = files.map { file in
            (file.path, file.text.components(separatedBy: "SettingsModel(").count - 1)
        }
        .filter { $0.1 > 0 }

        // The declaration site carries `public final class SettingsModel:`,
        // which does not match, so every hit here is a construction.
        #expect(constructions.count == 1, "built in \(constructions.map(\.0))")
        #expect(constructions.first?.1 == 1)
        #expect(constructions.first?.0.hasSuffix("App/AppComposition.swift") == true)
    }

    /// The same rule for the presentation: one switch, built in the
    /// composition, so the coordinator's entry and the window's rendering
    /// cannot read two different answers.
    @Test("exactly one SettingsPresentation is constructed in the shipped tree")
    func onePresentation() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let constructions = files.map { file in
            (file.path, file.text.components(separatedBy: "SettingsPresentation(").count - 1)
        }
        .filter { $0.1 > 0 }

        #expect(constructions.count == 1, "built in \(constructions.map(\.0))")
        #expect(constructions.first?.0.hasSuffix("App/AppComposition.swift") == true)
    }

    /// Decision D1 deletes a window, not a surface. Nothing in the tree names a
    /// settings window kind, a settings window descriptor, or the view that
    /// hosted one.
    @Test("no settings window survives in the tree")
    func theSettingsWindowIsGone() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        #expect(!WindowKind.allCases.contains { $0.rawValue == "settings" })
        #expect(WindowKind.allCases.count == 2)

        for name in ["struct SettingsWindowView", "WindowKind.settings", "settingsDefaultSize",
                     "settingsMinimumSize", "windowSettingsTitle"] {
            let offenders = files.filter { $0.text.contains(name) }

            #expect(offenders.isEmpty, "\(name) survives in: \(offenders.map(\.path))")
        }
    }

    /// The one back control, and Escape beside it. Two ways back would be two
    /// places to disagree about where back is.
    @Test("the presentation carries exactly one back control and one Escape")
    func oneWayBack() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let declaring = files.filter { $0.text.contains("struct SettingsBackControl") }
        // A sheet answers Escape for itself, which is its own gate: the one
        // this asks about is the presentation's, and there is one of those.
        let exiting = files
            .filter { $0.text.contains(".onExitCommand(") }
            .filter { !$0.text.contains("Sheet: View") }

        #expect(declaring.count == 1, "declared in: \(declaring.map(\.path))")
        #expect(exiting.count == 1, "Escape handled in: \(exiting.map(\.path))")
        #expect(exiting.first?.path.hasSuffix("App/MainWindowView.swift") == true)

        // Escape sits on the whole split view, not on the detail column: AppKit
        // walks the responder chain up from the first responder, and the pane
        // list and the search field are siblings of the detail rather than
        // descendants. Attached to the detail alone, the key answers only with
        // focus in the form. The one occurrence above plus its position before
        // `detailColumn` is what says which of the two it is.
        let window = try #require(exiting.first?.text)
        let handler = try #require(window.range(of: ".onExitCommand("))
        let detailColumn = try #require(window.range(of: "private var detailColumn: some View {"))

        #expect(handler.lowerBound < detailColumn.lowerBound, "Escape is attached to the detail column")

        // The chevron alone (owner directive of 2026-09-03). The word is gone
        // from the control and from the deck; the name survives only where it
        // is still read, which is VoiceOver. A plain button style would take
        // the standard leading-edge position and hit target away with it, so
        // its absence is part of the invariant.
        let control = try #require(declaring.first?.text)
        // `chevron.backward`, not `chevron.left`: the direction-relative symbol
        // is the one the system's own back button draws, and the only one that
        // mirrors under a right-to-left layout.
        #expect(control.contains("Image(systemName: \"chevron.backward\")"))
        #expect(!control.contains("Image(systemName: \"chevron.left\")"))
        #expect(!control.contains("labelStyle"))
        #expect(!control.contains(".buttonStyle("))
        #expect(control.contains(".settingsBackAccessibility"))
        #expect(ProductStrings[.settingsBackAccessibility] == "Back to Fermix")
        #expect(!ProductStringKey.allCases.contains { $0.rawValue == "settings.back" })
    }

    /// Files under `Settings/Panes/` allowed to hold a scroll view, and why.
    ///
    /// A `List` scrolls exactly as a `ScrollView` does, so the gate has to see
    /// both: scanning for `ScrollView` alone would pass a `List` dropped into a
    /// pane's `Form`, which is the same nested scroll decision D4 forbids and
    /// the shape these panes actually reach for.
    static let scrollingPaneFiles: [String: String] = [
        "Settings/Panes/ProviderSheets.swift": "the model picker's paginated listing, inside a sheet",
        "Settings/Panes/IntegrationSheets.swift": "the workspace listing, inside a sheet",
        "Settings/Panes/ComputerPane.swift": "the installed-app picker, inside a sheet",
        "Settings/Panes/IntegrationsPane.swift": "the plugins page's flat list, which is that pane's only scroll"
    ]

    /// Decision D4: no pane draws a scroll indicator, and a pane form is the
    /// one scroll view a pane has.
    @Test("the pane form hides its scroll indicators and nests no second scroll view")
    func noInlineScrollbars() throws {
        let form = try SourceTree.swiftFiles(matching: "Settings/DescriptorForm.swift")
        let text = try #require(form.first?.text)

        #expect(text.contains(".scrollIndicators(.never)"))
        #expect(text.contains(".paneScrollEdges()"))

        let panes = try SourceTree.swiftFiles(matching: "Settings/Panes/")
        for file in panes {
            let scrolls = file.text.contains("ScrollView")
                || file.text.contains("List(")
                || file.text.contains("List {")
            guard scrolls else { continue }

            let allowed = Self.scrollingPaneFiles.keys.contains { file.path.hasSuffix($0) }
            #expect(allowed, "\(file.path) nests a scroll view inside a pane")
        }

        // And every allowance names a file that still scrolls, so the list
        // cannot outlive what it excuses.
        for allowance in Self.scrollingPaneFiles.keys {
            let file = panes.first { $0.path.hasSuffix(allowance) }
            #expect(file != nil, "\(allowance) is allowed to scroll and no longer exists")
        }
    }

    /// Every pane has a title, a symbol, keywords and a slug, because a pane
    /// missing any of them is a sidebar row that cannot be found or drawn.
    @Test("every pane is fully described")
    func panesAreDescribed() {
        for pane in SettingsPane.allCases {
            #expect(!pane.title.isEmpty, "\(pane.slug)")
            #expect(!pane.systemImage.isEmpty, "\(pane.slug)")
            #expect(!pane.keywords.isEmpty, "\(pane.slug)")
            #expect(pane.matches(pane.title), "\(pane.slug) does not match its own title")
            #expect(pane.matches(""), "an empty search matches every pane")
        }

        #expect(SettingsPane.codingAgents.slug == "coding")
        #expect(SettingsPane.codingAgents.title == "Coding agents")
    }

    /// The secure input exists in one file. M34 §7.4 makes this a source gate
    /// because a second `SecureField` is how a credential reaches a view whose
    /// state nobody audited.
    @Test("SecureField exists only in SecretRow.swift")
    func secureFieldIsConfined() throws {
        let offenders = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("SecureField") }
            .filter { !$0.path.hasSuffix("Settings/Rows/SecretRow.swift") }

        #expect(offenders.isEmpty, "SecureField in: \(offenders.map(\.path))")

        let row = try SourceTree.swiftFiles(matching: "Settings/Rows/SecretRow.swift")
        #expect(row.first?.text.contains("SecureField") == true, "the gate is checking a file that has none")
    }

    /// The banner floats over the pane, so it has to be measured like the pane.
    /// On the window's own width its first word sat 60 points left of every
    /// section header and its button 60 points right of every `Details…`, which
    /// reads as two columns rather than one surface.
    @Test("the settings banner is measured like the pane it sits over")
    func bannerTakesThePaneMeasure() throws {
        let banner = try SourceTree.swiftFiles(matching: "Settings/SettingsBanners.swift")
        let text = try #require(banner.first?.text)

        #expect(text.contains(".frame(maxWidth: WindowMetrics.settingsContentMaxWidth)"))
        #expect(text.contains(".padding(.horizontal, WindowMetrics.settingsFormCardInset)"))
        // The same ceiling the pane form takes, so the two cannot drift apart.
        let form = try SourceTree.swiftFiles(matching: "Settings/DescriptorForm.swift")
        #expect(form.first?.text.contains(".frame(maxWidth: WindowMetrics.settingsContentMaxWidth)") == true)
        #expect(WindowMetrics.settingsFormCardInset > 0)
        #expect(WindowMetrics.settingsFormCardInset < WindowMetrics.settingsContentMaxWidth)
    }

    /// A row that stacks peers spaces them like peers.
    ///
    /// The list editor is a whole editor inside one grouped-form row, so the
    /// form's row insets stop at its edge. On the caption gap its label, its
    /// entries and its add field ran together and two 24-point `Remove` buttons
    /// sat a point apart, which is what the owner reported on the Sandbox pane.
    /// The rhythm lives on `SettingsRowMetrics` rather than at the call site, so
    /// every descriptor pane takes it and a pane that grows a second stacked
    /// editor cannot decide it again.
    @Test("the descriptor rows take their rhythm from one table")
    func descriptorRowRhythm() throws {
        let rows = try SourceTree.swiftFiles(matching: "Settings/Rows/DescriptorRow.swift")
        let text = try #require(rows.first?.text)

        #expect(text.contains("VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap)"))
        #expect(text.contains("VStack(alignment: .leading, spacing: SettingsRowMetrics.stackGap)"))
        #expect(text.contains("VStack(alignment: .leading, spacing: SettingsRowMetrics.entryGap)"))
        // No hand-written gap survives inside a row: a literal here is a pane
        // deciding its own rhythm, which is the defect.
        #expect(!text.contains("spacing: Spacing.xxs"))

        // And the panes go on drawing their rows through that one file rather
        // than restating a control, which is what makes the fix reach all of
        // them. The two hand-built lists are the plugins page and the channels
        // list, which are flows rather than values (M34 §5.2, §5.6).
        let panes = try SourceTree.swiftFiles(matching: "Settings/Panes/")
        let redeclaring = panes.filter { $0.text.contains("struct DescriptorListRow") }

        #expect(redeclaring.isEmpty, "\(redeclaring.map(\.path))")
    }

    /// No rules between plugin rows (owner directive of 2026-09-03: "remove any
    /// extra horizontal separation. keep it clean"). A plain `List` draws a
    /// separator under every row, and the page's rows are already an icon tile
    /// over two lines of text.
    @Test("the plugins page draws no separator between its rows")
    func pluginsPageHasNoRules() throws {
        let pane = try SourceTree.swiftFiles(matching: "Settings/Panes/IntegrationsPane.swift")
        let text = try #require(pane.first?.text)

        // `listRowSeparator` is a row modifier, so it has to sit on each of the
        // list's own children: on the container it is not the row it names.
        // Five children, five statements, and the sign-in clients section is
        // one of them, because a section that kept its rules would draw the
        // ledger back at the foot of the page.
        let rows = text.components(separatedBy: ".listRowSeparator(.hidden)").count - 1
        let children = text.components(separatedBy: "\n        List {").count - 1

        #expect(rows == 5, "\(rows) rows hide their separator")
        #expect(children == 1, "the page owns exactly one list")
        #expect(text.contains(".padding(.vertical, Spacing.xs)"))
    }

    /// Every row that is about one vendor draws that vendor's mark, at one
    /// size, through the one component that reads the provenance record.
    @Test("provider, channel and sign-in rows all draw a recorded mark")
    func rowsDrawMarks() throws {
        let expected = [
            "Settings/Panes/ProvidersPane.swift": "VendorMarks.mark(.provider, row.id)",
            "Settings/Panes/ChannelsPane.swift": "VendorMarks.mark(.channel, row.name)",
            "Settings/Panes/IntegrationSheets.swift": "VendorMarks.oauthClient(client.provider)"
        ]

        for (path, needle) in expected {
            let file = try SourceTree.swiftFiles(matching: path)
            #expect(file.first?.text.contains(needle) == true, "\(path) does not draw \(needle)")
            #expect(file.first?.text.contains("SettingsRowMetrics.markSize") == true, "\(path) size")
        }
    }

    /// Home's Runtime section draws none.
    ///
    /// It is seven labelled facts in one flush column, and a leading tile on the
    /// single row that names a vendor indented that label alone against the
    /// other six. For the provider the owner actually runs there is no mark to
    /// draw either, so what the row carried was a neutral placeholder chip
    /// beside a raw wire key. A mark belongs on a row that is *about* a vendor.
    @Test("a fact row in Home's Runtime section carries no vendor mark")
    func runtimeFactsCarryNoMark() throws {
        let home = try #require(try SourceTree.swiftFiles(matching: "Home/HomeView.swift").first?.text)
        let model = try #require(
            try SourceTree.swiftFiles(matching: "Design/Components/ComponentModels.swift").first?.text
        )

        #expect(!home.contains("VendorMarkView("), "Home draws a mark in a fact list")
        #expect(!model.contains("let mark: VendorMark?"), "a status row still carries a mark to draw")
    }
}
