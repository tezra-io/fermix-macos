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

    /// The frame is the system's sidebar material under its own colours, and
    /// it gives way to the plain fill for the two settings the ground gives
    /// way for. Liquid Glass drew a rim round every piece of the frame, a line
    /// under the band and a shard at each corner (owner, 2026-09-25), so it
    /// stays out of the frame.
    @Test("the frame is the sidebar material, rimless, and plain for the accessibility settings")
    func frameIsSidebarGlass() throws {
        let file = try SourceTree.swiftFiles(matching: "Design/Materials/AmbientGround.swift")
        let text = try #require(file.first?.text)

        #expect(text.contains("view.material = .sidebar"))
        #expect(text.contains("view.blendingMode = .behindWindow"))
        #expect(text.contains("if reduceTransparency || contrast == .increased {\n            WindowFrameRecipe.fill.color"))
        #expect(!text.contains("NSGlassEffectView()"), "the frame draws Liquid Glass and its rim")
        #expect(!text.contains(".glassEffect("), "the frame draws Liquid Glass and its rim")

        // Rail, settings pane list, band and corners are one glass, so nothing
        // paints the flat fill over the frame any more.
        #expect(occurrences(of: "background { FrameGlass().ignoresSafeArea() }", in: text) == 2)
        #expect(!text.contains("WindowFrameRecipe.pane"), "the pane list wears a glass of its own again")
        #expect(text.contains("FrameGlass().frame(height: height)"))
        #expect(occurrences(of: "WindowFrameRecipe.fill.color", in: text) == 1)
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

    /// The two browser sign-in waits, a provider's and a plugin's, draw their
    /// buttons from one view, so the two cannot be drawn apart again. That
    /// every sheet's default is the monochrome capsule is the sheet rule's.
    @Test("both sign-in waits draw their buttons from one view")
    func signInWaitsShareTheirButtons() throws {
        for wait in ["Settings/Panes/IntegrationSheets.swift", "Settings/Panes/ProviderSheets.swift"] {
            let text = try #require(try SourceTree.swiftFiles(matching: wait).first?.text)

            #expect(occurrences(of: "SignInWaitActions(", in: text) == 1, "\(wait) draws its own wait buttons")
            #expect(occurrences(of: "SignInRetryAction(", in: text) == 1, "\(wait) draws its own retry button")
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}

/// Redlines §5.7, as build gates: the app sidebar is the rail.
@Suite("Rail rule")
struct RailRuleTests {
    /// The rail is a column of symbol buttons (2026-09-25): a sidebar list
    /// draws its selection across the whole row and cannot leave space between
    /// rows, so the squares could not stand apart as the owner asked. A drawn
    /// rail was refused twice before because it loses what the list gave, so
    /// the gate is that it keeps all of it: each destination keeps its name for
    /// VoiceOver and as its help tag, says which one is showing, is reachable by
    /// full keyboard access, and the arrow keys walk the five in order.
    @Test("the rail is named symbol buttons that keep the list's keyboard walk")
    func railKeepsWhatTheListGave() throws {
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)
        let rail = try #require(try SourceTree.swiftFiles(matching: "App/Rail.swift").first?.text)

        #expect(text.contains("RailColumn(items: SidebarItem.mainWindow, selected: selectedSidebarIdentifier)"))
        #expect(text.contains("selection.wrappedValue = identifier"), "the rail routes around the one path")
        #expect(text.contains(".navigationSplitViewColumnWidth(WindowMetrics.railWidth)"))

        #expect(rail.contains(".labelStyle(.iconOnly)"), "a rail destination draws more than its symbol")
        #expect(rail.contains("Label(title, systemImage: systemImage)"))
        #expect(rail.contains(".accessibilityLabel(title)"))
        #expect(rail.contains(".help(title)"))
        #expect(rail.contains(".accessibilityAddTraits(selected ? .isSelected : [])"))
        #expect(rail.contains(".focused($focused, equals:"), "a destination cannot take keyboard focus")
        #expect(rail.contains(".onMoveCommand(perform: move)"), "the arrow keys no longer walk the rail")

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
        // The glass wears the same two colours, part transparent, so the frame
        // shows a hint of the desktop without changing colour (owner, 2026-09-25).
        #expect(WindowFrameRecipe.glassTint == ThemedColor(light: .rgba(236, 236, 236, 0.5), dark: .rgba(0, 0, 0, 0.6)))
        for scheme in FermixColorScheme.allCases {
            let tint = WindowFrameRecipe.glassTint.resolved(for: scheme)
            let fill = WindowFrameRecipe.fill.resolved(for: scheme)
            #expect([tint.red, tint.green, tint.blue] == [fill.red, fill.green, fill.blue], "the \(scheme) glass changed colour")
            #expect(tint.alpha >= 0.5, "the \(scheme) frame shows more desktop than frame")
        }
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

    /// The body's three open corners are cut to the window's own radius (owner,
    /// 2026-09-20: "should we make the left pane or the body rounded edge like
    /// the macOS window?"; 2026-09-25, of the top trailing one: "add the rounded
    /// edge to top right of the body as well to keep it consistent").
    ///
    /// Three things make it an overlay rather than the withdrawn panel, and all
    /// three are asserted: it is laid over the detail column, it is the frame's
    /// own glass rather than a colour of its own, and it takes no clicks from the
    /// live surface under it.
    @Test("the body's three open corners are the frame's glass at the window's radius")
    func bodyCornersAreOverlaidNotClipped() throws {
        let window = try SourceTree.swiftFiles(matching: "App/MainWindowView.swift")
        let text = try #require(window.first?.text)

        // Laid over the body: the surface, or in settings the form, since the
        // pane list beside it is part of the frame.
        #expect(occurrences(of: ".overlay { bodyCorners }", in: text) == 2)
        #expect(text.contains("SettingsDetailView(model: settings, router: router, openRecovery: openRecovery)\n                    .overlay { bodyCorners }"), "in settings the corners do not round the form")
        // Three corners, all from the one shape: top leading as drawn, top
        // trailing and bottom leading as it flipped.
        #expect(text.contains("bodyCorner(FrameCorner())"))
        #expect(text.contains("bodyCorner(FrameCorner().scale(x: -1, y: 1))"), "the top trailing corner is not rounded")
        #expect(text.contains("bodyCorner(FrameCorner().scale(x: 1, y: -1))"), "the bottom leading corner is not rounded")
        #expect(occurrences(of: "bodyCorner(FrameCorner()", in: text) == 3)
        #expect(text.contains("FrameGlass().mask(shape)"), "a corner is not the frame's own glass")
        // Sized in one place, so the three cannot drift to different radii.
        #expect(occurrences(of: ".frame(width: WindowMetrics.bodyCornerRadius, height: WindowMetrics.bodyCornerRadius)", in: text) == 1)
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

        let rail = try #require(try SourceTree.swiftFiles(matching: "App/Rail.swift").first?.text)

        #expect(text.contains("RailColumn(items: SidebarItem.mainWindow,"))
        #expect(rail.contains("ForEach(items) { item in"))
        #expect(!text.contains("SidebarItem.mainWindow.filter"), "the rail leaves a published row out")
        #expect(!text.contains("PetMark(") && !rail.contains("PetMark("), "the mascot is drawn in the rail again")

        #expect(SidebarItem.mainWindow.map(\.route) == [.chat, .home, .doctor, .logs, .pet])
        #expect(SidebarItem.item(for: .pet)?.systemImage == "pawprint")
        #expect(SidebarItem.item(for: .chat)?.systemImage == "bubble.left")
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

/// Every popup wears the app's glass (owner, 2026-10-16), as build gates: one
/// modifier owns a sheet's ground, and the content of every sheet the app
/// presents wears it at its root.
@Suite("Sheet ground rule")
struct SheetGroundRuleTests {
    /// The case set is every sheet the tree presents, so a sheet added later
    /// either wears the ground or fails here. Checked at the root: a ground
    /// worn by something inside the content leaves the system's panel round it.
    @Test("every sheet's content wears the sheet ground at its root")
    func everySheetWearsTheGround() throws {
        var presented = 0

        for file in try SourceTree.swiftFiles(under: "", excluding: false) {
            for content in try Self.sheetContents(in: file.text) {
                presented += 1
                guard let content else {
                    Issue.record("\(file.path) presents a sheet with no trailing content closure")
                    continue
                }

                #expect(
                    content.hasSuffix(".sheetGround()"),
                    "\(file.path) presents a sheet whose root does not wear the ground: \(content.suffix(120))"
                )
            }
        }

        // A scan that finds nothing passes every assertion it makes.
        #expect(presented >= 15, "only \(presented) sheets were scanned")
    }

    /// The scan itself, on the cases it has to tell apart: it is the gate, so
    /// a scan that stopped seeing a bare sheet would pass a tree full of them.
    @Test("the scan sees a sheet without the ground, and only sheets")
    func scanTellsTheCasesApart() throws {
        let source = """
            .sheet(item: $row) { row in
                RowSheet(row: row) { dismiss() }
                    .sheetGround()
            }
            .sheet(isPresented: $shown) { BareSheet() }
            .sheet(isPresented: $nested) {
                Outer { Inner().sheetGround() }
            }
            .sheet(isPresented: $labelled, content: { LabelledSheet() })
            // .sheet(isPresented: $commented) { Commented() }
            present(.sheet(.detail(row)))
            """
        let contents = try Self.sheetContents(in: source)

        #expect(contents.count == 4)
        #expect(contents[0]?.hasSuffix(".sheetGround()") == true)
        #expect(contents[1] == "BareSheet()")
        #expect(contents[2]?.hasSuffix(".sheetGround()") == false)
        #expect(contents[3] == nil)
    }

    /// One owner: the presentation background is set in one place, and the
    /// frame recipe is the frame's own glass rather than a copy of it. Liquid
    /// Glass stays out of the frame (owner, 2026-09-25), so the sheet ground is
    /// the one place it is drawn.
    @Test("one modifier owns a sheet's ground, and the frame recipe is the default")
    func oneOwner() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let owner = "Design/Materials/SheetGround.swift"

        #expect(Self.paths(of: files.filter { $0.text.contains(".presentationBackground") }) == [owner])
        #expect(Self.paths(of: files.filter { $0.text.contains("NSGlassEffectView(") }) == [owner])

        let text = try #require(try SourceTree.swiftFiles(matching: owner).first?.text)
        #expect(text.contains("case .frame: FrameGlass()"))
        #expect(
            text.contains("LiquidGlassMaterial()\n        } else {\n            FrameGlass()\n        }"),
            "the liquid recipe has no macOS 15 form"
        )
        #expect(SheetGroundRecipe.standard == .frame)
        #expect(SheetGroundRecipe.allCases == [.frame, .liquid])
    }

    /// No sheet draws the accent-filled default: its default action is the
    /// app's monochrome capsule, `PrimaryAction`, which carries the default
    /// key itself, and nothing a sheet draws is the prominent system style
    /// (owner, 2026-09-20: the accent blue on a primary action "doesnt match
    /// with the theme").
    ///
    /// Over everything a sheet draws: the sheet's content, the presenting
    /// view's own members it names, and every view reached from those, in
    /// whichever file it lives. A view shared with a non-sheet surface is held
    /// to the rule too, because a sheet draws it.
    @Test("no sheet draws the accent-filled default or a prominent button")
    func sheetsDrawNoAccentDefault() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let views = try Self.viewDeclarations(in: files)
        var drawn: [(name: String, text: String)] = []
        var sheets = 0

        for file in files {
            for content in try Self.sheetContents(in: file.text) {
                guard let content else { continue }

                sheets += 1
                drawn += Self.drawn(by: content, presentedIn: file.text, views: views)
            }
        }

        #expect(sheets >= 15, "only \(sheets) sheets were scanned")
        #expect(Set(drawn.map(\.name)).count >= 15, "only \(drawn.count) views were followed from the sheets")
        // Any default key, written plainly or chosen by a condition, except
        // the one the component that owns it carries.
        let defaultKey = try NSRegularExpression(pattern: #"\.keyboardShortcut\([^\n]*\.defaultAction"#)
        for view in drawn where view.name != "PrimaryAction" {
            #expect(
                defaultKey.firstMatch(in: view.text, range: NSRange(view.text.startIndex..., in: view.text)) == nil,
                "\(view.name), drawn in a sheet, makes a system button the accent-filled default"
            )
            #expect(!view.text.contains("borderedProminent"), "\(view.name), drawn in a sheet, is the prominent style")
        }
    }

    /// A list in a sheet is rounded like the grouped form sections beside it
    /// rather than the square panel the system draws a bare list in, since a
    /// shape inside a rounded card follows the card (Liquid Glass). Over the
    /// same views the default-action rule follows.
    @Test("every list a sheet draws is rounded like the sheet's sections")
    func sheetListsAreRounded() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let views = try Self.viewDeclarations(in: files)
        let list = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])List\s*[({]"#)
        var lists = 0

        for file in files {
            for content in try Self.sheetContents(in: file.text) {
                guard let content else { continue }

                for view in Self.drawn(by: content, presentedIn: file.text, views: views) {
                    let built = list.numberOfMatches(in: view.text, range: NSRange(view.text.startIndex..., in: view.text))
                    let rounded = view.text.components(separatedBy: ".sheetList()").count - 1
                    lists += built
                    #expect(built == rounded, "\(view.name), drawn in a sheet, builds \(built) lists and rounds \(rounded)")
                }
            }
        }

        #expect(lists >= 4, "only \(lists) lists were found in sheets")
    }

    /// A button in a sheet that names no style is the secondary capsule, not
    /// the system button the window's tint turns blue: the sheet's one root
    /// modifier states the row actions for everything inside it.
    @Test("the sheet ground states the row actions for the whole sheet")
    func sheetGroundStatesRowActions() throws {
        let owner = try #require(try SourceTree.swiftFiles(matching: "Design/Materials/SheetGround.swift").first?.text)

        #expect(owner.contains("content.rowActions()"))
    }

    /// Every view a sheet draws, by name with its text: the content itself,
    /// the members of the presenting file it names (a builder such as
    /// `sheetView(_:)`), and the closure of the view types they reach.
    private static func drawn(
        by content: String,
        presentedIn file: String,
        views: [String: [String]]
    ) -> [(name: String, text: String)] {
        var texts = [(name: "sheet content", text: content)]
        var members: Set<String> = []
        var index = 0
        while index < texts.count {
            for word in identifiers(in: texts[index].text) where !members.contains(word) {
                guard let member = memberBody(named: word, in: file) else { continue }

                members.insert(word)
                texts.append((name: word, text: member))
            }
            index += 1
        }

        var reached: Set<String> = []
        var queue = texts.flatMap { identifiers(in: $0.text) }.filter { views[$0] != nil }
        while let name = queue.popLast() {
            guard reached.insert(name).inserted, let bodies = views[name] else { continue }

            for body in bodies {
                texts.append((name: name, text: body))
                queue += identifiers(in: body).filter { views[$0] != nil && !reached.contains($0) }
            }
        }

        return texts
    }

    /// Every `View` the tree declares, by name, with each declaration's
    /// braced body. A name declared privately in two files keeps both.
    private static func viewDeclarations(in files: [SourceTree.File]) throws -> [String: [String]] {
        let declaration = try NSRegularExpression(
            pattern: #"struct ([A-Za-z_][A-Za-z0-9_]*)(?:<[^>{]*>)?\s*:[^{\n]*\bView\b[^{\n]*\{"#
        )
        var views: [String: [String]] = [:]

        for file in files {
            let text = file.text
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text),
                    let open = text[whole].lastIndex(of: "{"),
                    let close = closing(from: open, in: text, opens: "{", closes: "}")
                else { continue }

                views[String(text[name]), default: []].append(String(text[open...close]))
            }
        }

        return views
    }

    /// The braced body of a function or computed property the file declares
    /// under this name, opening on the declaration's own line.
    private static func memberBody(named name: String, in file: String) -> String? {
        let pattern = #"(?:func \#(name)\([^\n]*|var \#(name):[^\n=]*)\{"#
        guard let declaration = try? NSRegularExpression(pattern: pattern),
            let match = declaration.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)),
            let found = Range(match.range, in: file),
            let open = file[found].lastIndex(of: "{"),
            let close = closing(from: open, in: file, opens: "{", closes: "}")
        else { return nil }

        return String(file[open...close])
    }

    private static func identifiers(in text: String) -> Set<String> {
        var words: Set<String> = []
        var word = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
            } else if !word.isEmpty {
                words.insert(word)
                word = ""
            }
        }
        if !word.isEmpty { words.insert(word) }

        return words
    }

    /// The content of every sheet a file presents: the trailing closure after
    /// the presentation's arguments, trimmed. A presentation with no trailing
    /// closure answers nil, which fails the gate rather than escaping it.
    ///
    /// A presentation is found by the two labels every SwiftUI sheet opens
    /// with, so an enum case named `sheet` is not one, and whole-line comments
    /// are blanked first, so prose that names a sheet is not one either.
    static func sheetContents(in source: String) throws -> [String?] {
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
        let presentation = try NSRegularExpression(pattern: #"\.sheet\(\s*(?:isPresented|item)\s*:"#)

        return presentation.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { match in
            guard let found = Range(match.range, in: code),
                let open = code[found].lastIndex(of: "("),
                let close = closing(from: open, in: code, opens: "(", closes: ")")
            else { return nil }

            let rest = code[code.index(after: close)...]
            guard let brace = rest.firstIndex(where: { !$0.isWhitespace }), code[brace] == "{",
                let end = closing(from: brace, in: code, opens: "{", closes: "}")
            else { return nil }

            return code[code.index(after: brace)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Where the bracket opened at `start` closes.
    private static func closing(
        from start: String.Index,
        in code: String,
        opens: Character,
        closes: Character
    ) -> String.Index? {
        var depth = 0
        var index = start
        while index < code.endIndex {
            if code[index] == opens { depth += 1 }
            if code[index] == closes {
                depth -= 1
                if depth == 0 { return index }
            }
            index = code.index(after: index)
        }

        return nil
    }

    private static func paths(of files: [SourceTree.File]) -> [String] {
        files.map { String($0.path.dropFirst(SourceTree.root.path.count + 1)) }.sorted()
    }
}
