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

        #expect(interactive == [.sidebarRow, .primaryButton, .secondaryButton, .linkButton, .menuRow])
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

    @Test("the activation ladder ships the three provable rows in order")
    func ladderRows() {
        let ladder = ProgressLadderModel.activation(activeIndex: 1)

        #expect(ladder.rows.map(\.title) == [
            "Background service registered",
            "Starting the Fermix daemon",
            "Preparing your setup"
        ])
        #expect(ladder.rows.map(\.state) == [.done, .active, .pending])
        #expect(ladder.headline == "Starting the daemon")
    }

    @Test("each activation stage has its own headline")
    func ladderHeadlines() {
        #expect(ProgressLadderModel.activation(activeIndex: 0).headline == "Registering the service")
        #expect(ProgressLadderModel.activation(activeIndex: 2).headline == "Almost ready")
    }

    @Test("progress dots mark one active, the earlier ones done, the rest pending")
    func progressDots() {
        let dots = ProgressDotsModel(total: 5, activeIndex: 2)

        #expect(dots.states == [.done, .done, .active, .pending, .pending])
        #expect(dots.accessibilityLabel == "Step 3 of 5")
    }

    @Test("the menu-bar glyph never conveys its state by animation alone")
    func menuBarGlyphStates() {
        #expect(MenuBarGlyphState.running.pulses == false)
        #expect(MenuBarGlyphState.running.showsBadge == false)
        #expect(MenuBarGlyphState.starting.pulses)
        #expect(MenuBarGlyphState.starting.showsBadge == false)
        #expect(MenuBarGlyphState.attention.pulses == false)
        #expect(MenuBarGlyphState.attention.showsBadge)

        for state in MenuBarGlyphState.allCases {
            #expect(!state.accessibilityLabel.isEmpty, "\(state)")
        }
        #expect(MenuBarGlyphState.attention.accessibilityLabel == "Fermix needs attention")
    }

    @Test("the attention badge is a shape with a ring, at the redline offset")
    func menuBarBadgeGeometry() {
        #expect(MenuBarGlyphMetrics.glyphSize == 16)
        #expect(MenuBarGlyphMetrics.badgeDiameter == 7)
        #expect(MenuBarGlyphMetrics.badgeRingWidth == 1.5)
        #expect(MenuBarGlyphMetrics.badgeOffset == CGSize(width: 3, height: -2))
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

    @Test("a sidebar row announces selection as a trait, not as a colour")
    func sidebarRows() {
        let items = SidebarItem.mainWindow

        #expect(items.map(\.title) == ["Home", "Setup", "Doctor", "Pet", "Logs"])
        for item in items {
            #expect(!item.systemImage.isEmpty, "\(item.title)")
        }
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

        #expect(panel.title == "Fermix couldn't start")
        #expect(panel.body.contains("90 seconds"))
        #expect(panel.body.contains("hasn't been touched"))
        #expect(panel.primaryAction == "Run Doctor")
        #expect(panel.secondaryAction == "View full log")
        #expect(panel.ghostAction == "Try again")
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
    @Test("the bolt and check vectors keep the artboard's extents")
    func glyphVectors() {
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        let bolt = FermixBoltShape().path(in: box).boundingRect

        #expect(bolt.minX == 4.5)
        #expect(bolt.minY == 2)
        #expect(bolt.maxX == 19.5)
        #expect(bolt.maxY == 22)

        let check = FermixCheckShape().path(in: box).boundingRect

        #expect(check.minX == 5)
        #expect(check.minY == 7)
        #expect(check.maxX == 19)
        #expect(check.maxY == 18)
    }

    /// A status item with no image is invisible, which is the failure this
    /// gate exists to make loud. The name is also load-bearing: macOS only
    /// tints an image whose name ends in "Template".
    @Test("the shipped menu-bar master loads as a template image at the redline size")
    func menuBarTemplateShips() {
        let image = MenuBarGlyphImage.template()

        #expect(MenuBarGlyphImage.resourceName.hasSuffix("Template"))
        #expect(image.isTemplate)
        // Converted explicitly: `#expect` does not apply the implicit
        // CGFloat-to-Double conversion, and 16 compared against 16 fails.
        #expect(Double(image.size.width) == MenuBarGlyphMetrics.glyphSize)
        #expect(Double(image.size.height) == MenuBarGlyphMetrics.glyphSize)
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
            from: ProgressLadderModel.activation(activeIndex: 0),
            to: ProgressLadderModel.activation(activeIndex: 1)
        )

        #expect(sentences == [
            "Background service registered, done",
            "Starting the Fermix daemon, in progress"
        ])
    }

    /// The first draw is not a transition: the rows are already readable, and
    /// reading all three aloud would bury the one that is live.
    @Test("the first ladder announces only the row that is running")
    func ladderAnnouncesTheActiveRowFirst() {
        let sentences = LadderAnnouncement.sentences(from: nil, to: .activation(activeIndex: 0))

        #expect(sentences == ["Background service registered, in progress"])
    }

    @Test("an unchanged ladder announces nothing")
    func ladderIsQuietWhenNothingChanged() {
        let ladder = ProgressLadderModel.activation(activeIndex: 1)

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

/// §4.1 and §5.7–§5.9: the window surfaces are glass, and the recipe is a
/// property of the window rather than something each view decides.
@Suite("Window chrome")
struct WindowChromeTests {
    @Test("both real windows draw the window glass and the pet draws none")
    func recipePerWindow() {
        #expect(GlassRecipe.forWindow(.main) == .window)
        #expect(GlassRecipe.forWindow(.onboarding) == .window)
        #expect(GlassRecipe.forWindow(.pet) == nil)
    }

    @Test("the main window applies its glass rather than an opaque ground")
    func mainWindowIsGlass() throws {
        let view = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")

        #expect(view.count == 1)
        #expect(view.first?.text.contains("GlassChrome(") == true, "the main window paints no glass")
    }

    /// Applying glass to the window is only half of it: a surface inside that
    /// window painting the window ground over the top flattens the material for
    /// the whole detail pane, which is how the material went missing in the
    /// first place. `base100` is the window's own ground and belongs to the
    /// glass; the recessed `base200` is still a surface's to use.
    @Test("no surface repaints the window ground over its glass")
    func nothingRepaintsTheWindowGround() throws {
        let painters = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("background(Palette.base100") }

        #expect(painters.isEmpty, "the window ground is repainted in: \(painters.map(\.path))")
    }
}
