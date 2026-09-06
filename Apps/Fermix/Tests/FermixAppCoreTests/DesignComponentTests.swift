import Foundation
import Testing

@testable import FermixAppCore

/// The component library's presentation logic: the parts that decide what a
/// row says, what VoiceOver reads, and which shape carries a state. The
/// drawing itself is redline geometry; these are the decisions.
@Suite("Design components")
struct DesignComponentTests {
    @Test("every component in the inventory declares a unique identifier")
    func inventoryIdentifiersAreUnique() {
        let identifiers = DesignComponent.allCases.map(\.accessibilityIdentifier)

        #expect(Set(identifiers).count == identifiers.count)
        for identifier in identifiers {
            #expect(identifier.hasPrefix("fermix."))
        }
    }

    /// Written as one invariant over the whole inventory rather than per
    /// component: a component added later lands outside this set and fails
    /// here until someone decides whether it belongs in the focus order.
    @Test("exactly these components are interactive, so a new one forces the decision")
    func interactiveComponentsAreClassified() {
        let interactive = Set(DesignComponent.allCases.filter(\.isInteractive))

        #expect(interactive == [.primaryButton, .secondaryButton, .linkButton])
    }

    /// M34 §6 deleted the containers the app drew for itself, so the inventory
    /// no longer carries them.
    @Test("the deleted containers are out of the inventory")
    func deletedComponentsAreGone() {
        let names = Set(DesignComponent.allCases.map(\.rawValue))

        // `chip` and `statusRow` join the list here: the container rule left the
        // primary window's rows to the system, which removed the last call site
        // of both views.
        for deleted in ["card", "sidebarRow", "menuRow", "chip", "statusRow"] {
            #expect(!names.contains(deleted), "\(deleted) is still in the inventory")
        }
    }

    @Test("a ladder row reads its state in words, not by its spinner")
    func ladderRowAccessibility() {
        #expect(LadderRowState.done.accessibilityValue == "done")
        #expect(LadderRowState.active.accessibilityValue == "in progress")
        #expect(LadderRowState.pending.accessibilityValue == "waiting")

        let row = LadderRowModel(id: "service", title: "Background service registered", state: .done)

        #expect(row.accessibilityLabel == "Background service registered")
        #expect(row.accessibilityValue == "done")
    }

    @Test("the Starting ladder ships the four provable rows in order")
    func ladderRows() {
        let ladder = ProgressLadderModel.starting(activeIndex: 1, includesRegistration: true)

        #expect(ladder.rows.map(\.title) == [
            "Registering the background service",
            "Starting the daemon",
            "Checking it answers",
            "Reading what is already set up"
        ])
        #expect(ladder.rows.map(\.state) == [.done, .active, .pending, .pending])
        #expect(ladder.headline == "Starting Fermix")
    }

    /// The headline is the screen's, not the row's: a mechanical stage says what
    /// it is doing once, and the rows carry the detail.
    @Test("each ladder carries the headline of the screen it runs inside")
    func ladderHeadlines() {
        #expect(ProgressLadderModel.starting(activeIndex: 0, includesRegistration: true).headline == "Starting Fermix")
        #expect(ProgressLadderModel.applying(activeIndex: 0, includesRestart: true).headline == "Applying your setup")
        #expect(
            ProgressLadderModel.applying(activeIndex: 1, includesRestart: true).rows.map(\.state) == [.done, .active]
        )
    }

    @Test("progress dots mark one active, the earlier ones done, the rest pending")
    func progressDots() {
        let dots = ProgressDotsModel(total: 5, activeIndex: 2)

        #expect(dots.states == [.done, .done, .active, .pending, .pending])
        #expect(dots.accessibilityLabel == "Step 3 of 5")
    }

    /// The state has to be in the raster, because the status item draws an
    /// image: two states sharing one would leave the difference carried by
    /// nothing but the words in the menu it opens.
    @Test("every menu-bar state draws its own template and says which it is")
    func menuBarGlyphStates() {
        let names = MenuBarGlyphState.allCases.map(MenuBarGlyphImage.resourceName(for:))

        #expect(Set(names).count == names.count)
        for name in names {
            // Load-bearing: macOS only tints an image whose name ends in
            // "Template", and an untinted raster is a black shape on a dark bar.
            #expect(name.hasSuffix("Template"), "\(name)")
        }

        for state in MenuBarGlyphState.allCases {
            #expect(!state.accessibilityLabel.isEmpty, "\(state)")
        }
        #expect(MenuBarGlyphState.attention.accessibilityLabel == "Fermix needs attention")
    }

    /// The geometry the build script draws with. The badge is cut INTO the
    /// image box rather than overhanging it, because a status button clips its
    /// own contents and an overhanging badge is what lost its top edge.
    @Test("the template box holds the mark and its badge with nothing outside it")
    func menuBarBadgeGeometry() {
        #expect(MenuBarGlyphMetrics.imageSize == 18)
        #expect(MenuBarGlyphMetrics.markInset == 1)
        #expect(MenuBarGlyphMetrics.badgeDiameter == 5)
        #expect(MenuBarGlyphMetrics.badgeRingWidth == 1)

        let badgeReach = MenuBarGlyphMetrics.badgeDiameter + 2 * MenuBarGlyphMetrics.badgeRingWidth
        #expect(badgeReach <= MenuBarGlyphMetrics.imageSize)
    }

    /// Doctor pills are text, so a status this app version has never seen is
    /// still readable: the wire value is shown rather than folded into a
    /// neighbouring status.
    @Test("every check status maps to a letter pill, including an unknown one")
    func checkBadges() {
        #expect(CheckBadge.forStatus(.passed) == CheckBadge(letters: "PASS", tone: .pass))
        #expect(CheckBadge.forStatus(.warning) == CheckBadge(letters: "WARN", tone: .warn))
        #expect(CheckBadge.forStatus(.failed) == CheckBadge(letters: "FAIL", tone: .fail))
        #expect(CheckBadge.forStatus(.unavailable) == CheckBadge(letters: "UNAVAILABLE", tone: .neutral))
        #expect(CheckBadge.forStatus(.skipped) == CheckBadge(letters: "SKIPPED", tone: .neutral))
        #expect(CheckBadge.forStatus(.cancelled) == CheckBadge(letters: "CANCELLED", tone: .neutral))
        #expect(CheckBadge.forStatus(.timedOut) == CheckBadge(letters: "TIMED OUT", tone: .neutral))
        #expect(CheckBadge.forStatus(.notApplicable) == CheckBadge(letters: "N/A", tone: .neutral))
        #expect(CheckBadge.forStatus(.unrecognized("quarantined")) == CheckBadge(letters: "QUARANTINED", tone: .neutral))
    }

    /// The pills are low-chroma text on no flood fill, per §5.9.
    @Test("pill tones resolve to the low-chroma text tokens")
    func pillTones() {
        #expect(StatusTone.pass.textColor == Palette.pillPass)
        #expect(StatusTone.warn.textColor == Palette.pillWarn)
        #expect(StatusTone.fail.textColor == Palette.error)
        #expect(StatusTone.neutral.textColor == Palette.faint)
    }

    /// The sidebar rows are system labels now, so what is left to assert here
    /// is that each row names a real route.
    @Test("every sidebar row names the route it selects")
    func sidebarRows() {
        for item in SidebarItem.mainWindow {
            #expect(item.route.sidebarItemIdentifier == item.id, "\(item.title)")
            #expect(SidebarItem.item(for: item.route)?.id == item.id, "\(item.title)")
        }

        #expect(SidebarItem.item(for: .update) == nil, "a route with no row selects none")
    }

    @Test("a status row carries a title, a detail, and an optional trailing fact")
    func statusRows() {
        let row = StatusRowModel(
            id: "engine",
            title: "Engine",
            detail: "Running the pinned app engine",
            meta: "0.9.0",
            systemImage: "cpu",
            tone: .neutral
        )

        #expect(row.accessibilityLabel == "Engine")
        #expect(row.accessibilityValue == "Running the pinned app engine, 0.9.0")
    }

    /// A fact inside a grouped `Form` is a `LabeledContent` with no tile of its
    /// own, so the icon is optional rather than a symbol every caller invents.
    @Test("a labelled fact needs no icon, no meta, and no tone")
    func statusRowWithoutDecoration() {
        let row = StatusRowModel(id: "skills", title: "Skills", detail: "12")

        #expect(row.systemImage == nil)
        #expect(row.meta == nil)
        #expect(row.tone == .neutral)
        #expect(row.accessibilityValue == "12")
    }

    @Test("a status row without a trailing fact reads only its detail")
    func statusRowWithoutMeta() {
        let row = StatusRowModel(
            id: "channels",
            title: "Channels",
            detail: "Telegram",
            meta: nil,
            systemImage: "bubble.left",
            tone: .neutral
        )

        #expect(row.accessibilityValue == "Telegram")
    }

    @Test("the empty state is one caption line and no illustration")
    func emptyState() {
        let empty = EmptyStateModel(message: ProductStrings[.homeAttentionEmpty])

        #expect(empty.message == "Nothing needs your attention")
        #expect(empty.accessibilityLabel == "Nothing needs your attention")
    }

    @Test("an error panel reads what happened, what is untouched, and one action")
    func errorPanel() {
        let panel = ErrorPanelModel.bootFailure(.timedOut, logLines: ["boot: waiting", "boot: gave up"])

        #expect(panel.title == "Fermix could not start")
        #expect(panel.body.contains("90 seconds"))
        #expect(panel.body.contains("hasn’t been touched"))
        #expect(panel.primary == .runDoctor)
        #expect(panel.secondary == .viewLog)
        #expect(panel.ghost == .tryAgain)
        #expect(panel.commands.isEmpty)
        #expect(panel.logHeader == "LAST LOG LINES")
        #expect(panel.logLines.count == 2)
    }

    /// §5.6 caps the card at three lines; a longer tail is trimmed to the most
    /// recent three rather than growing the card.
    @Test("the log card keeps the last three lines")
    func errorPanelLogLines() {
        let panel = ErrorPanelModel.bootFailure(
            .crashLoop,
            logLines: ["one", "two", "three", "four"]
        )

        #expect(panel.logLines == ["two", "three", "four"])
    }

    /// The in-window bolt is a vector, drawn at whatever size and colour the
    /// chrome needs. Its extents are the artboard's own 24-point path.
    @Test("the bolt vector keeps the artboard's extents")
    func glyphVectors() {
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        let bolt = FermixBoltShape().path(in: box).boundingRect

        #expect(bolt.minX == 4.5)
        #expect(bolt.minY == 2)
        #expect(bolt.maxX == 19.5)
        #expect(bolt.maxY == 22)

    }

    @Test("humane times read as words and never as a duration format")
    func humaneTimes() {
        #expect(HumaneTime.uptime(seconds: 273_600) == "3 days 4 hours")
        #expect(HumaneTime.uptime(seconds: 15_120) == "4 hours 12 minutes")
        #expect(HumaneTime.uptime(seconds: 720) == "12 minutes")
        #expect(HumaneTime.uptime(seconds: 30) == "just now")
        #expect(HumaneTime.uptime(seconds: 90_000) == "1 day 1 hour")
        #expect(HumaneTime.coarseUptime(seconds: 273_600) == "3 days")
        #expect(HumaneTime.coarseUptime(seconds: 15_120) == "4 hours")
    }

    @Test("a negative or zero uptime is refused rather than rendered")
    func humaneTimeRejectsNonsense() {
        #expect(HumaneTime.uptime(seconds: 0) == "just now")
        #expect(HumaneTime.uptime(seconds: -5) == "just now")
    }

    /// §5.2 and §9: the ladder is the one screen whose whole purpose is progress
    /// feedback, and focus stays on the window for the whole 90 seconds. A row
    /// that changed must therefore be spoken, not merely readable on landing.
    @Test("a ladder advance announces every row whose state changed")
    func ladderAnnouncesTransitions() {
        let sentences = LadderAnnouncement.sentences(
            from: ProgressLadderModel.starting(activeIndex: 0, includesRegistration: true),
            to: ProgressLadderModel.starting(activeIndex: 1, includesRegistration: true)
        )

        #expect(sentences == [
            "Registering the background service, done",
            "Starting the daemon, in progress"
        ])
    }

    /// The first draw is not a transition: the rows are already readable, and
    /// reading all four aloud would bury the one that is live.
    @Test("the first ladder announces only the row that is running")
    func ladderAnnouncesTheActiveRowFirst() {
        let sentences = LadderAnnouncement.sentences(from: nil, to: .starting(activeIndex: 0, includesRegistration: true))

        #expect(sentences == ["Registering the background service, in progress"])
    }

    @Test("an unchanged ladder announces nothing")
    func ladderIsQuietWhenNothingChanged() {
        let ladder = ProgressLadderModel.starting(activeIndex: 1, includesRegistration: true)

        #expect(LadderAnnouncement.sentences(from: ladder, to: ladder).isEmpty)
    }

    /// The sentences are only worth having if the ladder speaks them. A policy
    /// with no caller is the same defect as a design token no view applies.
    @Test("the ladder is wired to the announcer, not only to its labels")
    func ladderIsWiredToTheAnnouncer() throws {
        let ladder = try SourceTree.swiftFiles(matching: "Design/Components/ProgressLadder.swift")

        #expect(ladder.count == 1)
        #expect(ladder.first?.text.contains("announcer.announce(") == true)
        #expect(ladder.first?.text.contains(".onChange(of: model)") == true)
    }
}

/// §9's keyboard rules, as build gates: one way to draw a primary action, and
/// it is the default button everywhere.
@Suite("Design keyboard path")
struct DesignKeyboardTests {
    /// A `ButtonStyle` cannot carry a keyboard shortcut, so "the primary action
    /// is the default button" can only hold if there is exactly one way to draw
    /// one. The style is that component's private business.
    @Test("the primary button style is applied in exactly one place")
    func onePrimaryButtonImplementation() throws {
        let applied = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("PrimaryButtonStyle(") }

        #expect(applied.count == 1, "primary buttons drawn in: \(applied.map(\.path))")
        #expect(applied.first?.path.hasSuffix("Design/Components/FermixButtons.swift") == true)
    }

    @Test("the one primary action carries the default keyboard shortcut")
    func primaryActionIsTheDefaultButton() throws {
        let buttons = try SourceTree.swiftFiles(matching: "Design/Components/FermixButtons.swift")

        #expect(buttons.count == 1)
        #expect(buttons.first?.text.contains("keyboardShortcut(.defaultAction)") == true)
    }
}

/// §4.1 and M34 §6: the glass a window draws is a property of the window, and
/// the primary window draws none.
@Suite("Window chrome")
@MainActor
struct WindowChromeTests {
    /// The container rule in one value: owner decision 1 took the assistant's
    /// glass card and its backdrop with it, so no window draws a container of
    /// its own and the two primitives that did are gone from the tree.
    @Test("no window draws glass of its own")
    func noWindowDrawsGlass() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        for name in ["struct GlassChrome", "struct BackdropView"] {
            #expect(files.allSatisfy { !$0.text.contains(name) }, "\(name) survives")
        }
    }

    /// The primary window shows the system's unified titlebar, which is what
    /// draws the sidebar toggle and the inline title. Every other window keeps
    /// the hidden-title treatment the app already had.
    @Test("the primary window is the one window that shows its title")
    func titledWindows() {
        #expect(WindowCoordinator.descriptor(for: .main).showsTitle)
        #expect(WindowCoordinator.descriptor(for: .pet).showsTitle == false)
    }

    /// The toolbar and the title only reach the window because the hosting view
    /// bridges them out to the scene.
    @Test("the primary window bridges its toolbar and title to the scene")
    func sceneBridging() throws {
        let host = try SourceTree.swiftFiles(matching: "App/AppKitWindowHost.swift")

        #expect(host.count == 1)
        #expect(host.first?.text.contains("sceneBridgingOptions = [.toolbars, .title]") == true)
    }
}

/// The wordmark: a 1:1 path port of the approved SVG, pinned to the published
/// glyph geometry so a redrawn approximation fails here.
@Suite("Wordmark")
struct FermixWordmarkTests {
    @Test("the wordmark keeps the published aspect ratio and dot centres")
    func geometry() {
        #expect(FermixWordmark.aspectRatio == 3.84)
        #expect(FermixWordmarkLetters.glyphSize == CGSize(width: 384, height: 100))
        // One ulp of slack: 384 / 100 and the literal 3.84 round differently.
        let derived = FermixWordmarkLetters.glyphSize.width / FermixWordmarkLetters.glyphSize.height
        #expect(abs(FermixWordmark.aspectRatio - derived) < 0.000001)

        // translate(294 0) plus cx 2 / cx 15 at cy 21, r 4.7 — the two accent
        // eye-dots of the published asset.
        #expect(FermixWordmark.dotCenters == [CGPoint(x: 296, y: 21), CGPoint(x: 309, y: 21)])
        #expect(FermixWordmark.dotRadius == 4.7)
    }

    /// The letter paths span the full glyph space: x from 0 (the F stem) to
    /// 384 (the X's trailing wedge), y from 0 to 100. A port that dropped or
    /// displaced a letter group moves this box.
    @Test("the letter paths fill the 384 by 100 glyph space")
    func letterExtents() {
        let box = FermixWordmarkLetters()
            .path(in: CGRect(x: 0, y: 0, width: 384, height: 100))
            .boundingRect

        #expect(box.minX == 0)
        #expect(box.minY == 0)
        #expect(box.maxX == 384)
        #expect(box.maxY == 100)
    }

    /// A `Toggle` is a switch only while it is a row of a grouped `Form`. Put
    /// inside another row's trailing content it arrives as a checkbox, which is
    /// how Channels drew a checkbox for `Telegram` and a switch for `Accept
    /// editor connections` in the same pane.
    ///
    /// A hidden label is what says the toggle is not the row, because a form
    /// row's own toggle carries it. So every toggle with a hidden label states
    /// the style it wants, whichever style that is, and the case set comes from
    /// the tree rather than from the ones somebody remembered.
    @Test("a toggle drawn outside a form row states its own style")
    func hiddenLabelTogglesStateTheirStyle() throws {
        var checked = 0

        for file in try SourceTree.swiftFiles(under: "", excluding: false) {
            for chunk in file.text.components(separatedBy: "Toggle(").dropFirst() {
                let declaration = chunk.split(separator: "\n").prefix(8).joined(separator: "\n")
                guard declaration.contains(".labelsHidden()") else { continue }

                checked += 1
                #expect(
                    declaration.contains(".toggleStyle("),
                    "a label-hidden toggle in \(file.path) takes whatever style it is handed"
                )
            }
        }

        // Three today: the two channel-style switches and the Ready checklist's
        // checkbox. A scan that matched nothing would pass every assertion it
        // was written to make.
        #expect(checked >= 3, "the toggle scan found \(checked) label-hidden toggles")
    }

    /// A `ButtonStyle` is handed no disabled treatment: `.disabled(true)` stops
    /// the action and leaves the drawing alone. Both styles read the state, so
    /// Pet's `Mute microphone` stops looking pressable with no call running.
    @Test("both button styles draw an unavailable control as unavailable")
    func buttonStylesDrawTheDisabledState() throws {
        let source = try SourceTree.swiftFiles(matching: "Design/Components/FermixButtons.swift")
        let text = try #require(source.first?.text)

        #expect(text.components(separatedBy: "@Environment(\\.isEnabled)").count == 3)
        #expect(text.components(separatedBy: "ButtonRecipe.disabledOpacity)").count == 3)
        #expect(ButtonRecipe.disabledOpacity > 0)
        #expect(ButtonRecipe.disabledOpacity < 1)
    }

    /// The product accent is applied once, at every window's root, and nowhere
    /// else.
    ///
    /// Untinted, a prominent button takes the macOS accent, which is a
    /// different blue from `#2b5cff` and a markedly lighter one in dark
    /// appearance: measured off the shipped Home captures at rgb(5,124,254) on
    /// dark and rgb(0,112,237) on light, against the accent every other primary
    /// action in the product draws. §1.1 calls one surface showing two blues
    /// that are not selection plus primary action a defect.
    ///
    /// Tinting the one control that showed it would have swapped one mismatch
    /// for another: the switches, the list selection and the sheets' default
    /// buttons on the same page would have kept the user's macOS accent while
    /// the toolbar action turned product blue. So the invariant is "one tint,
    /// at the root", and the toolbar button asserting it carries none of its
    /// own is the half that keeps it true.
    @Test("the product accent is set once, at the window root")
    func productAccentIsSetAtTheRoot() throws {
        let host = try #require(
            try SourceTree.swiftFiles(matching: "App/AppKitWindowHost.swift").first?.text
        )

        #expect(host.contains("struct ProductTinted"))
        #expect(host.contains("content.tint(Palette.accent.color)"))
        #expect(host.contains("NSHostingView(rootView: ProductTinted(content: root))"))

        // Every window's content view is built by that one function, so nothing
        // reaches a window untinted.
        let surfaces = try #require(
            try SourceTree.swiftFiles(matching: "App/AppKitWindowHost.swift").first?.text
        )
        #expect(surfaces.components(separatedBy: "NSHostingView(rootView:").count == 2)

        // No second tint anywhere in the product.
        let tinting = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains(".tint(") }
            .map(\.path)

        #expect(tinting.count == 1, "tinted in: \(tinting)")
        #expect(tinting.first?.hasSuffix("App/AppKitWindowHost.swift") == true, "tinted in: \(tinting)")
    }

    /// The toolbar's prominent action states the style and nothing else.
    @Test("the toolbar's prominent button takes the root tint")
    func toolbarPrimaryTakesTheRootTint() throws {
        let source = try SourceTree.swiftFiles(matching: "Design/Components/SurfaceToolbar.swift")
        let text = try #require(source.first?.text)

        #expect(!text.contains(".tint("), "the button sets a tint of its own")
        #expect(text.contains(".glassProminent"))
        #expect(text.contains(".borderedProminent"))

        // The accent stays scheme independent, because lightening it is what
        // would break the label: white on #2b5cff clears the 4.5:1 floor and
        // white on the only lighter accent in the ramp does not.
        #expect(Palette.accent.light == Palette.accent.dark)
        #expect(Palette.accent.light == SRGBColor(hex: "#2b5cff"))
    }
}
