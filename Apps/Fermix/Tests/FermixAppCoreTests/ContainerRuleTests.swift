import Foundation
import Testing

@testable import FermixAppCore

/// M34 §6's container rule, as build gates.
///
/// Fermix draws no container of its own in the primary window: a box exists
/// only where the system draws one. These scan the shipped tree, so the case
/// set comes from the product rather than from a list somebody has to remember
/// to update.
@Suite("Container rule")
struct ContainerRuleTests {
    /// The window views, by the file each lives in. A window added later joins
    /// this list or fails the split-view gate below.
    ///
    /// Two, not three: decision D1 deletes the settings window, and its split
    /// view with it. The settings pane column is the primary window's own
    /// leading column, drawn by that one split view.
    static let windowViews = [
        "App/MainWindowView.swift",
        "Onboarding/OnboardingWindowView.swift"
    ]

    @Test("each window view builds exactly one navigation split view, or none")
    func oneSplitViewPerWindow() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        for file in files {
            let count = occurrences(of: "NavigationSplitView(", in: file.text)
            guard count > 0 else { continue }

            #expect(count == 1, "\(file.path) builds \(count) split views")
            #expect(
                Self.windowViews.contains { file.path.hasSuffix($0) },
                "\(file.path) is not a window view"
            )
        }

        let main = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        #expect(main.first?.text.contains("NavigationSplitView(columnVisibility:") == true)
    }

    /// The detail column may always compress to the window it is in, which is
    /// what makes a long pane scroll rather than push the window past the
    /// screen (decision D4, and the measured defect this gate closes: the
    /// Integrations pane opened the primary window at 980 by 2115 points on a
    /// 3840 by 1080 point display).
    ///
    /// SwiftUI publishes a minimum height out of content that cannot compress,
    /// the split view republishes it as the window's, and one such view is
    /// enough. The floor sits on the detail column, at the one seam every pane
    /// passes through, so a pane added later is covered without being listed.
    @Test("the detail column carries a floor the window's size can win against")
    func detailColumnCompressesToTheWindow() throws {
        let main = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(main.first?.text)

        #expect(
            text.contains("detailColumn.frame(minWidth: 0, minHeight: 0)"),
            "the split view's detail has no floor, so a pane can size the window"
        )
    }

    /// Divider overlays are gone: the system draws every separator inside its
    /// own containers, and a hand-drawn one reintroduces the box.
    @Test("nothing in the tree draws a divider")
    func noDividers() throws {
        let offenders = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("Divider(") }

        #expect(offenders.isEmpty, "dividers drawn in: \(offenders.map(\.path))")
    }

    /// M34 §6 names two accessibility gates, and neither existed: the sheet
    /// with no Cancel and the button with no label both shipped. They are
    /// source scans because the property is structural — every sheet, every
    /// button — and a list of the ones somebody remembered is what rots.
    @Test("every sheet answers Escape")
    func everySheetAnswersEscape() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("Sheet: View") }

        #expect(!files.isEmpty, "the scan found no sheets at all")
        for file in files {
            for declaration in Self.sheetDeclarations(in: file.text) {
                let body = Self.body(of: declaration, in: file.text)

                #expect(
                    body.contains(".cancelAction") || body.contains(".onExitCommand"),
                    "\(declaration) in \(file.path) does not answer Escape"
                )
            }
        }
    }

    /// A sheet titles at the headline rung, and its Cancel sits beside the
    /// default action.
    ///
    /// Both are macOS rules the app was breaking on every sheet at once: at the
    /// step-title rung a credential sheet opened with a headline as large as
    /// the window title behind it, and the Restart sheet ordered
    /// Cancel · Restart when idle · Restart now, which strands Cancel at the
    /// far end of the row from the button it cancels.
    ///
    /// Derived from the sheet declarations rather than a list, so a sheet added
    /// later joins the rule.
    @Test("every sheet titles at the headline rung with Cancel beside the default")
    func sheetsTitleAndOrderTheirButtons() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("Sheet: View") }
        var checked = 0

        #expect(!files.isEmpty, "the scan found no sheets at all")
        for file in files {
            for declaration in Self.sheetDeclarations(in: file.text) {
                let body = Self.body(of: declaration, in: file.text)
                checked += 1

                #expect(
                    !body.contains("Typography.style(.title)"),
                    "\(declaration) in \(file.path) titles at the assistant's step rung"
                )

                guard let cancel = body.range(of: ".keyboardShortcut(.cancelAction)"),
                      let action = body.range(of: ".keyboardShortcut(.defaultAction)"),
                      cancel.lowerBound < action.lowerBound
                else { continue }

                // Exactly one `Button(` between the two shortcuts: the default
                // action's own, since a shortcut is written after the button it
                // is on. A third button in that span is one standing between
                // Cancel and the action it cancels.
                let between = body[cancel.upperBound..<action.lowerBound]
                #expect(
                    between.components(separatedBy: "Button(").count == 2,
                    "\(declaration) puts a button between Cancel and the default action"
                )
            }
        }

        #expect(checked >= 8, "only \(checked) sheets were scanned")
    }

    /// A control the app draws needs a name VoiceOver can read: the catalogue
    /// title it was built from, or an explicit label beside it.
    @Test("every button under Settings and Onboarding carries a readable name")
    func everyButtonIsNamed() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.path.contains("/Settings/") || $0.path.contains("/Onboarding/") }

        #expect(!files.isEmpty)
        for file in files {
            for (index, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let range = line.range(of: "Button(") else { continue }
                let argument = line[range.upperBound...]
                // A button built from a catalogue string, a value's own title,
                // or a label the next lines carry. `Button {` with a `Label`
                // inside is named by that label.
                let named = argument.hasPrefix("ProductStrings[")
                    || argument.hasPrefix("action:")
                    || argument.isEmpty
                    || argument.hasPrefix("verb")
                    || argument.hasPrefix("title")
                    || argument.hasPrefix("command")
                    || argument.hasPrefix("entry.label")
                    || argument.hasPrefix("action.title")
                    || argument.hasPrefix("model.")
                    || argument.hasPrefix("row.")
                    || argument.hasPrefix("String(format:")
                let labelled = Self.followedByAccessibilityLabel(file.text, afterLine: index)

                #expect(named || labelled, "\(file.path):\(index + 1) draws an unnamed button")
            }
        }
    }

    /// The declared name of every `…Sheet: View` in one file.
    private static func sheetDeclarations(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "struct "), line.contains("Sheet: View") else { return nil }

            return String(line[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
        }
    }

    /// The text from a declaration to the next one, which is the body the scan
    /// asks about. The last declaration runs to the end of the file.
    private static func body(of declaration: String, in text: String) -> String {
        guard let start = text.range(of: "struct \(declaration): View") else { return "" }

        let rest = text[start.upperBound...]
        guard let next = rest.range(of: "\nstruct ") else { return String(rest) }

        return String(rest[..<next.lowerBound])
    }

    /// Whether an accessibility label follows within the control's own lines.
    private static func followedByAccessibilityLabel(_ text: String, afterLine index: Int) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let window = lines[index..<min(index + 8, lines.count)]

        return window.contains { $0.contains(".accessibilityLabel(") }
    }

    /// The system focus ring is never suppressed (redlines §9). A ring the app
    /// draws itself is one more thing that has to track every macOS change to
    /// focus, and it overrides a person who has turned the system ring up.
    @Test("nothing in the tree suppresses the system focus effect")
    func noSuppressedFocusRing() throws {
        let offenders = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("focusEffectDisabled") }

        #expect(offenders.isEmpty, "focus suppressed in: \(offenders.map(\.path))")
    }

    /// The status item is an `NSMenu`. A popover would put the app back in the
    /// business of drawing a panel the system already draws.
    @Test("nothing in the tree builds an NSPopover")
    func noPopover() throws {
        let offenders = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("NSPopover") }

        #expect(offenders.isEmpty, "popovers built in: \(offenders.map(\.path))")
    }

    /// The same rule one level down: the status item hands the system a
    /// template image and lets it draw. A view added to the status button is
    /// clipped to the button, which is how the glyph's badge lost its top edge,
    /// and it takes the item's sizing, hover and material away from macOS.
    @Test("nothing is drawn into or layered over the status button")
    func statusButtonCarriesAnImageAndNothingElse() throws {
        let controllers = try SourceTree.swiftFiles(matching: "App/MenuBarController.swift")

        #expect(controllers.count == 1)
        for file in controllers {
            for drawn in ["NSHostingView", "addSubview", "NSLayoutConstraint", "NSView("] {
                #expect(!file.text.contains(drawn), "\(drawn) in \(file.path)")
            }

            #expect(file.text.contains("button.image = image"))
            #expect(file.text.contains("item.menu = menu"))
        }
    }

    /// M34 §9: no WKWebView, no HTML strings, no web content anywhere in the
    /// app. The hosted Setup pane was the only importer, and the browser setup
    /// the daemon serves for every formula install is not this app's surface.
    @Test("nothing in the tree imports WebKit")
    func noWebKit() throws {
        let offenders = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("import WebKit") || $0.text.contains("WKWebView") }

        #expect(offenders.isEmpty, "web content in: \(offenders.map(\.path))")
    }

    /// The primitives M34 §6 deletes. Written as one invariant over the whole
    /// list so a resurrection of any of them fails here.
    @Test("the deleted primitives are gone from the tree")
    func deletedPrimitivesAreGone() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        for name in ["struct Card<", "struct SectionCard<", "struct SidebarRow", "struct SidebarFooter",
                     "struct SurfaceTitlebar", "struct MenuBarPanel", "struct MenuRow",
                     // Owner decision 1 took the assistant's chrome with it.
                     "struct GlassChrome", "struct BackdropView", "struct SetupWebView",
                     "struct SetupSurfaceView", "struct SetupNavigationPolicy", "enum LoopbackHost",
                     // One restart sheet, one owner. The second one drifted
                     // inside a single slice: it had already lost the
                     // `Restart when idle` button (M34 §5.10).
                     "struct AssistantRestartSheet"] {
            let offenders = files.filter { $0.text.contains(name) }

            #expect(offenders.isEmpty, "\(name) survives in: \(offenders.map(\.path))")
        }
    }

    /// Every `Form` in the tree is a grouped one. A `Form` with the automatic
    /// style renders as a column of bare rows on macOS, which is the shape the
    /// container rule replaced, not the one it asks for.
    @Test("every Form carries the grouped form style")
    func everyFormIsGrouped() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        var checked = 0

        for file in files {
            // A word boundary rather than a fixed indentation: `DescriptorForm`
            // and a `Form` nested one level deeper both have to be seen.
            let forms = try matches(of: #"(?<![A-Za-z0-9_])Form\s*\{"#, in: file.text)
            guard forms > 0 else { continue }

            checked += forms
            #expect(
                forms == occurrences(of: ".formStyle(.grouped)", in: file.text),
                "\(file.path) has a Form without .formStyle(.grouped)"
            )
        }

        #expect(checked >= 3, "no forms were found to check")
    }

    private func matches(of pattern: String, in text: String) throws -> Int {
        let expression = try NSRegularExpression(pattern: pattern)

        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Decision D4: a pane scrolls only when it must, and when it does the
    /// indicators are never drawn and its edges take the system's fade.
    ///
    /// This is the rule the window's own bounds depend on. The window is
    /// bounded by the screen it is on, so a pane longer than the window has to
    /// scroll inside itself; a pane whose content had nowhere to go is what
    /// drove the primary window to twice the screen's height.
    ///
    /// The case set is derived from the tree rather than listed: a type whose
    /// name ends in `Pane`, plus the settings presentation's own two — the
    /// shared form every pane is drawn inside, and the pane column beside it. A
    /// pane added later joins the gate by being named like one. A sheet is not
    /// a pane and carries neither rule, which is why the split is by type
    /// rather than by file.
    ///
    /// Counted rather than contained: a type that owns two scroll containers
    /// and hides the indicators of one satisfies a `contains` and still draws a
    /// scrollbar.
    @Test("every scroll container a pane owns hides its indicators and fades its edges")
    func paneScrollContainersFollowTheEdgeRule() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.path.contains("/Settings/") }
        var checked: [String] = []

        for file in files {
            for (name, body) in Self.types(in: file.text) where Self.isPaneBody(name) {
                let containers = Self.scrollContainers.reduce(0) { $0 + occurrences(of: $1, in: body) }
                guard containers > 0 else { continue }

                checked.append(name)
                #expect(
                    occurrences(of: ".scrollIndicators(.never)", in: body) == containers,
                    "\(name) owns \(containers) scroll containers and hides fewer sets of indicators"
                )
                #expect(
                    occurrences(of: ".paneScrollEdges()", in: body) == containers,
                    "\(name) owns \(containers) scroll containers and fades fewer sets of edges"
                )
            }
        }

        #expect(checked.count >= 3, "no pane scroll containers were found to check")
        // The three the settings presentation owns today. The column is here
        // because it is the one that was outside the gate while it drew the
        // only scrollbar left in the window.
        for owner in ["SettingsPaneForm", "SettingsPaneColumn", "IntegrationsPane"] {
            #expect(checked.contains(owner), "\(owner) was not scanned")
        }
    }

    /// What makes a view a scroll container on macOS: a list, a form, or a
    /// scroll view. All three scroll their own content, which is the property
    /// the rule is about.
    static let scrollContainers = ["List {", "List(", "Form {", "ScrollView"]

    /// The pane bodies: every `…Pane`, plus the settings presentation's own
    /// `SettingsPane…` types, which are the form the panes are drawn inside and
    /// the column that lists them.
    private static func isPaneBody(_ name: String) -> Bool {
        name.hasSuffix("Pane") || name.hasPrefix("SettingsPane")
    }

    /// A file split into its top-level types, by name.
    ///
    /// A declaration at column zero opens a type and closes the one before it,
    /// which is enough for this tree: every type in it is declared at the top
    /// level of its file.
    private static func types(in text: String) -> [(String, String)] {
        var types: [(String, String)] = []
        var current: String?
        var body = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = declaredType(String(line)) {
                if let current { types.append((current, body)) }
                current = name
                body = ""
            }
            body += line + "\n"
        }
        if let current { types.append((current, body)) }

        return types
    }

    /// The name a line declares, where it opens a top-level type.
    private static func declaredType(_ line: String) -> String? {
        for keyword in ["struct ", "final class ", "class ", "enum ", "extension "] {
            guard line.hasPrefix(keyword) else { continue }

            let name = line.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }

            return name.isEmpty ? nil : String(name)
        }

        return nil
    }

    /// M34 §5: setup is a task rather than a destination, so the sidebar is
    /// four rows and the Setup row is gone. The pinned Settings row below them
    /// is not one of these: it selects a presentation of this window rather
    /// than a route, so it carries no `AppRoute` and is not a `SidebarItem`.
    @Test("the sidebar is Home, Doctor, Logs and Pet, with Settings pinned under them")
    func sidebarRows() {
        #expect(SidebarItem.mainWindow.map(\.title) == ["Home", "Doctor", "Logs", "Pet"])
        #expect(SidebarItem.mainWindow.map(\.id) == ["home", "doctor", "logs", "pet"])

        for item in SidebarItem.mainWindow {
            #expect(!item.systemImage.isEmpty, "\(item.title)")
        }

        #expect(!SidebarItem.mainWindow.map(\.id).contains(SidebarItem.settingsIdentifier))
        #expect(SidebarItem.selection(route: .home) == "home")
    }

    /// M34 §6's macOS 26 inventory is a closed list, and the gate asserts
    /// membership rather than a count the design itself breaks.
    ///
    /// Owner decision 1 took the assistant's glass card, and `GlassSurface`'s
    /// two sites went with it: the inventory is the redline's five, which is
    /// what §4.3 says it is once the artboards lose the chrome decision.
    ///
    /// Decision D1 took `.windowResizeAnchor` with the settings window: the
    /// primary window's growth is an AppKit frame animation (`WindowGrowth`),
    /// because the app hosts SwiftUI inside an `NSHostingView` and has no
    /// `Scene` for that modifier to reach. Decision D4 adds the pane form's
    /// scroll edge effect in its place, so the inventory stays at five.
    static let macOS26Sites: [String: [String]] = [
        "Design/Components/SurfaceToolbar.swift": [
            "ToolbarSpacer(",
            ".sharedBackgroundVisibility(",
            ".glassProminent"
        ],
        "Settings/DescriptorForm.swift": [".scrollEdgeEffectStyle("],
        "Settings/SettingsBanners.swift": [".safeAreaBar("]
    ]

    @Test("every macOS 26 site in the tree is on the published list")
    func macOS26Inventory() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        for file in files where file.text.contains("#available(macOS 26") {
            let entry = Self.macOS26Sites.first { file.path.hasSuffix($0.key) }

            #expect(entry != nil, "\(file.path) guards macOS 26 and is not on the list")
        }

        // A stale entry is the other half of the invariant: a file that no
        // longer uses what it declared leaves the list lying about the tree.
        for (path, expressions) in Self.macOS26Sites {
            let file = files.first { $0.path.hasSuffix(path) }
            let text = try #require(file?.text, "\(path) is on the list and not in the tree")

            for expression in expressions {
                #expect(text.contains(expression), "\(path) no longer uses \(expression)")
            }
        }
    }

    /// Each macOS 26 modifier has a declared macOS 15 form, so the same tree
    /// renders on the floor rather than losing a control.
    @Test("the macOS 26 toolbar sites declare their macOS 15 forms")
    func macOS15Forms() throws {
        let toolbar = try SourceTree.swiftFiles(matching: "Design/Components/SurfaceToolbar.swift")
        let text = try #require(toolbar.first?.text)

        #expect(text.contains(".borderedProminent"), "the prominent action has no macOS 15 form")
        #expect(occurrences(of: "ToolbarItem(placement: .status)", in: text) == 2, "the status item has one form")
    }

    /// The settings banner is a bar, so it draws a bar's material on both
    /// systems. `safeAreaBar` places its content and paints nothing behind it,
    /// which left the daemon's restart reasons as an orphan line of text under
    /// the toolbar with nothing dividing them from the form.
    ///
    /// Counted against the two placement branches rather than merely present,
    /// because a material applied on one branch is the defect this replaces.
    @Test("the settings banner carries a material on both placement branches")
    func bannerIsABarOnBothSystems() throws {
        let banners = try SourceTree.swiftFiles(matching: "Settings/SettingsBanners.swift")
        let text = try #require(banners.first?.text)

        #expect(occurrences(of: ".safeAreaBar(edge: .top) { material }", in: text) == 1)
        #expect(occurrences(of: ".safeAreaInset(edge: .top, spacing: 0) { material }", in: text) == 1)
        #expect(text.contains("bar.background(.bar)"))
        #expect(text.contains("bar.background(Palette.base200.color)"), "Reduce Transparency has no ground")
    }

    /// A surface with nothing on it draws the system's own empty state; the
    /// app's one-line caption stays what an empty *section* inside a `Form`
    /// draws. The split is by container, so the gate is too.
    @Test("a surface-level empty state is the system's and a section's is one line")
    func emptyStatesSplitByContainer() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let component = try #require(
            files.first { $0.path.hasSuffix("Design/Components/EmptyState.swift") }?.text
        )

        #expect(component.contains("ContentUnavailableView("), "the surface form draws no system empty state")

        // Nothing else in the tree builds one of its own.
        let builders = files.filter { $0.text.contains("ContentUnavailableView(") }.map(\.path)
        #expect(builders.count == 1, "\(builders)")

        // The surface that has one uses it; the sections keep the caption.
        let logs = try #require(files.first { $0.path.hasSuffix("Logs/LogsView.swift") }?.text)
        #expect(logs.contains("SurfaceEmptyState("))
        #expect(!logs.contains("EmptyState(model:"), "Logs draws a section caption over a whole surface")

        for path in ["Home/HomeView.swift", "Doctor/DoctorView.swift"] {
            let text = try #require(files.first { $0.path.hasSuffix(path) }?.text)

            #expect(text.contains("EmptyState("), "\(path)")
            #expect(!text.contains("SurfaceEmptyState("), "\(path) draws a surface state inside a form")
        }
    }

    /// A text row's field carries a bezel and a measure, wherever one is drawn.
    /// A grouped form strips a field's chrome, and the value then reads as one
    /// more fact in a page of facts.
    @Test("every text row's field takes the one declared chrome")
    func textRowsCarryFieldChrome() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let declarations = files.filter { $0.text.contains("func settingsTextField()") }

        #expect(declarations.count == 1, "the chrome has \(declarations.count) owners")
        #expect(
            try #require(declarations.first?.text).contains("textFieldStyle(.roundedBorder)")
        )

        // Every `TextField` inside a grouped form takes it: the two the
        // assistant draws, and the one every descriptor text row is.
        for path in ["Settings/Rows/DescriptorRow.swift", "Onboarding/AboutYouSurface.swift"] {
            let text = try #require(files.first { $0.path.hasSuffix(path) }?.text)

            #expect(text.contains(".settingsTextField()"), "\(path)")
        }
    }

    /// Integrations is the one pane that draws a page header of its own, so it
    /// is the one pane that removes the toolbar's inline title: the window
    /// title said `Integrations` two lines above the header that says it. Every
    /// other pane still takes its title from the window.
    ///
    /// Both halves, because dropping the `navigationTitle` instead would leave
    /// the window named by whichever pane was open before it.
    @Test("only the pane with its own header removes the toolbar title")
    func onlyTheCodexPageRemovesItsTitle() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let removers = files.filter { $0.text.contains(".toolbar(removing: .title)") }.map(\.path)

        #expect(removers.count == 1, "\(removers)")
        #expect(try #require(removers.first).hasSuffix("Settings/Panes/IntegrationsPane.swift"))

        let pane = try #require(files.first { $0.path.hasSuffix("Settings/Panes/IntegrationsPane.swift") }?.text)
        #expect(pane.contains(".navigationTitle(SettingsPane.integrations.title)"), "the window loses its name")
    }

    /// A row that opens something says so before it is clicked. The plugin rows
    /// opened a detail sheet with no chevron, no hover fill and no pointer
    /// change, so the one control the row advertised was its switch.
    @Test("a plugin row advertises the detail it opens")
    func pluginRowsAdvertiseTheirDetail() throws {
        let pane = try SourceTree.swiftFiles(matching: "Settings/Panes/IntegrationsPane.swift")
        let text = try #require(pane.first?.text)

        #expect(text.contains("chevron.forward"), "the row draws no chevron")
        #expect(text.contains(".onHover"), "the row has no hover treatment")
        // The direction-relative symbol, the only one that mirrors under a
        // right-to-left layout, which is the rule the back control follows.
        #expect(!text.contains("chevron.right"), "the row draws a direction the layout cannot mirror")
    }

    /// The ladder takes the width the surface offers and stops at the
    /// assistant's own column. Fixed at 380 it wrapped Applying's longest row
    /// onto two lines inside the 800-point window the ladder is drawn in.
    @Test("the ladder is capped rather than fixed")
    func ladderFollowsItsSurface() throws {
        let ladder = try SourceTree.swiftFiles(matching: "Design/Components/ProgressLadder.swift")
        let text = try #require(ladder.first?.text)

        #expect(text.contains(".frame(maxWidth: WindowMetrics.ladderMaxWidth)"))
        #expect(!text.contains(".frame(width: WindowMetrics"), "the ladder pins a width again")
        #expect(WindowMetrics.ladderMaxWidth == OnboardingMetrics.contentWidth)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
