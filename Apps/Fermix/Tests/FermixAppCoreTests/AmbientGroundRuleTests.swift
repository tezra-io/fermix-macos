import Foundation
import Testing

@testable import FermixAppCore

/// Redlines §1.3 and §4.3, as build gates: one ambient ground behind the one
/// window, shown through the system's own translucent containers.
///
/// These scan the shipped tree, the way the container rule does, so a surface
/// added later either joins the rule or fails it.
@Suite("Ambient ground rule")
struct AmbientGroundRuleTests {
    /// The view being built, with the space that tells it from the modifier
    /// whose name ends in the same word.
    static let painting = " AmbientGround("

    /// One window, one ground, one painter. A second ground inside a surface is
    /// a second wash laid over the first, and a surface that paints its own is
    /// the two-window-colours defect §5.8 already closed once.
    ///
    /// The intensity does not change that: two intensities are two settings of
    /// the one ground, chosen by the one painter, so the count is still one.
    @Test("the ground is painted once, by the primary window")
    func onePainter() throws {
        let painters = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains(Self.painting) }

        #expect(painters.count == 1, "painted in: \(painters.map(\.path))")

        let window = try #require(painters.first)
        #expect(window.path.hasSuffix("App/MainWindowView.swift"))
        #expect(occurrences(of: Self.painting, in: window.text) == 1)
        #expect(window.text.contains(".background { AmbientGround(intensity: groundIntensity).ignoresSafeArea() }"))
    }

    /// Every presentation of the window resolves to a ground, and which one is
    /// a pure function of the two facts the window has.
    ///
    /// Walked over `AppRoute.allCases` rather than over the routes that have a
    /// sidebar row, because the update and uninstall routes have no row and are
    /// still surfaces a person lands on. A route added later fails here until it
    /// is placed, which is the whole reason the decision left the view.
    @Test("every route and the settings presentation resolve to one of the two grounds")
    func everyPresentationTakesAGround() throws {
        /// The moments: one screen, one headline, one action, watched rather
        /// than worked in.
        let expressive: Set<AppRoute> = [.setup, .recovery, .pet]

        for route in AppRoute.allCases {
            let resolved = AmbientIntensity.forWindow(showingSettings: false, route: route)

            #expect(resolved == (expressive.contains(route) ? .expressive : .calm), "\(route.rawValue)")
            #expect(
                AmbientIntensity.forWindow(showingSettings: true, route: route) == .calm,
                "settings over \(route.rawValue)"
            )
        }

        // Thirteen panes of rows is the case the calm ground was cut for, so
        // settings answers ahead of the route it is showing over.
        #expect(expressive.contains(.pet))
        #expect(AmbientIntensity.forWindow(showingSettings: true, route: .pet) == .calm)

        // The window asks the same question the gate just did.
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)
        #expect(text.contains("AmbientIntensity.forWindow(showingSettings: presentation.isShowing, route: model.route)"))
    }

    /// The ground costs one draw per resize and nothing per frame, and it gives
    /// way to the system's flat colour for the two settings that ask for one.
    /// A blur, a timeline or an animation here is a cost every surface pays for
    /// as long as the window is open.
    @Test("the ground is static and steps aside for the accessibility settings")
    func groundIsStaticAndAccessible() throws {
        let file = try SourceTree.swiftFiles(matching: "Design/Materials/AmbientGround.swift")
        let text = try #require(file.first?.text)

        #expect(text.contains("accessibilityReduceTransparency"))
        #expect(text.contains("colorSchemeContrast"))

        for moving in [".blur(", "TimelineView", "withAnimation", ".animation(", "Timer", "Canvas"] {
            #expect(!text.contains(moving), "the ground uses \(moving)")
        }
    }

    /// A surface shows the ground by giving up the fill it paints for itself,
    /// and it says so through the one modifier that owns the rule. The raw
    /// modifier survives in exactly two places: that owner, and the assistant's
    /// form chrome, which hid its form's ground before the window had one.
    @Test("a scroll container's own ground is hidden through one owner")
    func oneOwnerForTheHiddenGround() throws {
        let raw = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("scrollContentBackground(") }
            .map { String($0.path.dropFirst(SourceTree.root.path.count + 1)) }
            .sorted()

        #expect(raw == ["Design/Materials/AmbientGround.swift", "Onboarding/OnboardingWindowView.swift"])
    }

    /// Every grouped form in the window shows the ground and draws its rows'
    /// actions in the one row style. The case set is every file that builds a
    /// grouped form, so a surface added later is covered by being one.
    ///
    /// Counted per file rather than contained: a file with two forms that
    /// dresses one satisfies a `contains` and still ships a flat grey sheet.
    @Test("every grouped form shows the ground and states its row actions")
    func everyFormShowsTheGround() throws {
        let form = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])Form\s*\{"#)
        var checked = 0

        for file in try SourceTree.swiftFiles(under: "", excluding: false) {
            // The same word boundary the container rule counts forms with, so a
            // doc comment that names the style is not mistaken for a form.
            let forms = form.numberOfMatches(in: file.text, range: NSRange(file.text.startIndex..., in: file.text))
            guard forms > 0 else { continue }

            let dressed = occurrences(of: ".showsAmbientGround()", in: file.text)
                + occurrences(of: ".assistantFormChrome(", in: file.text)

            checked += forms
            #expect(forms == dressed, "\(file.path) has \(forms) grouped forms and dresses \(dressed)")
            #expect(
                occurrences(of: ".showsAmbientGround()", in: file.text)
                    == occurrences(of: ".rowActions()", in: file.text),
                "\(file.path) shows the ground on a form whose row actions it does not state"
            )
        }

        #expect(checked >= 6, "only \(checked) grouped forms were scanned")

        // The assistant's three forms take both through their one chrome.
        let chrome = try SourceTree.swiftFiles(matching: "Onboarding/OnboardingWindowView.swift")
        let text = try #require(chrome.first?.text)
        #expect(text.contains(".rowActions()"))
    }

    /// The control shape is set once, where the tint is, and the two styles the
    /// app draws take the same capsule from one declaration.
    @Test("every button is the one capsule")
    func oneControlShape() throws {
        let host = try SourceTree.swiftFiles(matching: "App/AppKitWindowHost.swift")
        #expect(try #require(host.first?.text).contains(".buttonBorderShape(.capsule)"))

        let shaping = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains(".buttonBorderShape(") }
        #expect(shaping.count == 1, "shaped in: \(shaping.map(\.path))")

        let buttons = try SourceTree.swiftFiles(matching: "Design/Components/FermixButtons.swift")
        let text = try #require(buttons.first?.text)
        #expect(occurrences(of: "let shape = ButtonRecipe.shape", in: text) == 2)
        #expect(!text.contains("RoundedRectangle("), "a drawn button has a shape of its own again")
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}

/// Redlines §5.7, as build gates: the app sidebar is the rail, and the rail is
/// still the system's list.
@Suite("Rail rule")
struct RailRuleTests {
    /// The rail is drawn by restyling the system's sidebar column, never by
    /// replacing it. A hand-built column of buttons looks the same in a capture
    /// and loses arrow-key selection, full keyboard access and the list's own
    /// VoiceOver semantics, which is why the artboards' drawn rail was refused
    /// twice before this one was taken.
    @Test("the rail is the split view's own list, with symbols that keep their names")
    func railIsTheSystemList() throws {
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)

        #expect(text.contains("List(selection: selection)"), "the rail is no longer a selectable list")
        #expect(text.contains(".labelStyle(.iconOnly)"), "a rail row draws more than its symbol")
        // The name stays on the row for VoiceOver, and is the pointer's help tag.
        #expect(text.contains("Label(title, systemImage: systemImage)"))
        #expect(text.contains(".help(title)"))
        #expect(text.contains(".navigationSplitViewColumnWidth(WindowMetrics.railWidth)"))

        // One rail, in and out of settings, and settings' pane list is the
        // second pane inside the frame rather than a second sidebar.
        #expect(occurrences(of: ".railColumn()", in: text) == 1)
        #expect(occurrences(of: ".paneColumn()", in: text) == 1)
    }

    /// On dark the rail is the application icon's black with its white; on
    /// light it is the standard window grey Mac sidebars wear (owner,
    /// 2026-09-25). The column takes the window's appearance, so its selection
    /// and its symbols are the ones drawn for the fill under them, and the ink
    /// holds §9's floor on both.
    @Test("the rail is the standard grey on light and black on dark")
    func railColours() throws {
        #expect(WindowFrameRecipe.fill == ThemedColor(lightHex: "#ececec", darkHex: "#000000"))
        #expect(WindowFrameRecipe.ink == ThemedColor(lightHex: "#1d1d1f", darkHex: "#ffffff"))
        for scheme in FermixColorScheme.allCases {
            let ratio = Contrast.ratio(
                WindowFrameRecipe.ink.resolved(for: scheme),
                WindowFrameRecipe.fill.resolved(for: scheme)
            )
            #expect(ratio >= 4.5, "the rail's ink is \(ratio):1 on the \(scheme) rail")
        }

        let ground = try SourceTree.swiftFiles(matching: "Design/Materials/AmbientGround.swift")
        let text = try #require(ground.first?.text)
        #expect(!text.contains(".environment(\\.colorScheme, .dark)"), "the rail is forced dark on a light window")
    }

    /// The border around the content was tried and withdrawn the same day
    /// (owner, 2026-09-20). The frame is the rail and nothing else, so nothing
    /// in the window view insets or clips the content into a panel.
    ///
    /// The two leading corners below are not that border coming back, and this
    /// gate is where the difference is written down: they are paint laid over
    /// the body, so the surface keeps every point of its own width and needs no
    /// ground behind it. An inset, a clip or a stroke is a panel, and each of
    /// the three is still refused by name.
    @Test("the window draws no border around its content")
    func noContentBorder() throws {
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)

        for framing in ["frameInset", "clipShape(", "RoundedRectangle(", ".border(", "strokeBorder("] {
            #expect(!text.contains(framing), "the window view frames its content with \(framing)")
        }
    }

    /// The body's two leading corners are cut to the window's own radius (owner,
    /// 2026-09-20: "should we make the left pane or the body rounded edge like
    /// the macOS window?").
    ///
    /// Three things make it an overlay rather than the withdrawn panel, and all
    /// three are asserted: it is laid on the detail column's leading edge, it is
    /// filled with the rail's own fill rather than a colour of its own, and it
    /// takes no clicks from the live surface under it.
    @Test("the body's two leading corners are the rail's fill at the window's radius")
    func bodyCornersAreOverlaidNotClipped() throws {
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)

        #expect(text.contains(".overlay(alignment: .leading) { bodyCorners }"))
        // Both corners, both from the one shape and the one fill.
        #expect(occurrences(of: "FrameCorner().fill(WindowFrameRecipe.fill.color)", in: text) == 2)
        #expect(occurrences(of: "WindowMetrics.bodyCornerRadius", in: text) == 4)
        #expect(text.contains(".scaleEffect(x: 1, y: -1)"), "the bottom corner is not the top one flipped")
        #expect(text.contains(".allowsHitTesting(false)"), "the corners swallow clicks meant for the surface")

        // It is the window's measured radius, not the artboards' panel radius.
        #expect(WindowMetrics.bodyCornerRadius == 20)
        #expect(WindowMetrics.bodyCornerRadius != Radius.window)
    }

    /// The rail draws the four published rows, in their published order, and
    /// nothing above them (owner, 2026-09-20: "the previous icon was fine. The
    /// fermix mascot on the left pane isnt needed. And it should be below the
    /// logs"). For an afternoon the mascot mark headed the rail and stood in for
    /// the Pet row; both halves of that are withdrawn, so the gate is that the
    /// rows come straight from `SidebarItem.mainWindow`, unfiltered, and that
    /// Pet is the last of them with its own symbol.
    @Test("the rail draws the published rows in order, Pet last, and no mark")
    func railRowsAreThePublishedRows() throws {
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)

        #expect(text.contains("ForEach(SidebarItem.mainWindow) { item in"))
        #expect(!text.contains("SidebarItem.mainWindow.filter"), "the rail leaves a published row out")
        #expect(!text.contains("PetMark("), "the mascot is drawn in the rail again")

        #expect(SidebarItem.mainWindow.map(\.route) == [.home, .doctor, .logs, .pet])
        #expect(SidebarItem.item(for: .pet)?.systemImage == "pawprint")
    }

    /// The Pet surface's still mascot is the generator's fourth image, shipped at
    /// both scales, and the view that draws it names the same resource and the
    /// size the generator drew it at.
    @Test("the Pet surface's mascot ships at both scales under the name the view loads")
    func petMarkShips() throws {
        #expect(PetMark.resourceName == "FermixMarkPet")
        #expect(PetMark.size == 108)

        let templates = SourceTree.root.appendingPathComponent("Resources/MenuBarTemplate")
        for name in ["FermixMarkPet.png", "FermixMarkPet@2x.png"] {
            #expect(
                FileManager.default.fileExists(atPath: templates.appendingPathComponent(name).path),
                "\(name) is missing beside the menu bar templates"
            )
        }

        // The rail's mark was withdrawn with its rasters; a file left behind
        // would ship in the bundle with nothing reading it.
        for stale in ["FermixMarkRail.png", "FermixMarkRail@2x.png"] {
            #expect(!FileManager.default.fileExists(atPath: templates.appendingPathComponent(stale).path))
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
