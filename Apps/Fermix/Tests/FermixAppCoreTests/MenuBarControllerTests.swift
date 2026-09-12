import AppKit
import Foundation
import Testing

@testable import FermixAppCore

/// The status item itself: the image the system draws, the affordance that
/// takes it off the bar, and the menu under it.
///
/// Every one of these runs against `FakeStatusItem`. A real `NSStatusItem`
/// would put an item on the operator's own menu bar, and the whole point of the
/// change under test is that the app hands the system an image and lets the
/// system own the rest.
@Suite("Menu bar item")
@MainActor
struct MenuBarControllerTests {
    private func harness(
        daemon: DaemonCondition = .running,
        attention: Bool = false
    ) -> (controller: MenuBarController, item: FakeStatusItem, model: AppModel) {
        let model = AppModel()
        model.daemon = daemon
        model.needsAttention = attention
        let item = FakeStatusItem()

        return (MenuBarController(model: model, item: item), item, model)
    }

    // MARK: - The glyph

    /// The one mapping that matters: what the daemon is doing decides which
    /// raster the system draws, and the label VoiceOver reads names the same
    /// state. A mismatch here is a menu bar that says one thing and reads
    /// another.
    @Test("each daemon condition puts its own template on the button")
    func stateMapsToImage() {
        let cases: [(DaemonCondition, Bool, MenuBarGlyphState)] = [
            (.running, false, .running),
            (.starting, false, .starting),
            (.stopped, false, .attention),
            (.running, true, .attention)
        ]

        for (daemon, attention, expected) in cases {
            let (controller, item, _) = harness(daemon: daemon, attention: attention)
            controller.install(menu: NSMenu())

            #expect(item.image === MenuBarGlyphImage.template(for: expected), "\(daemon) \(attention)")
            #expect(item.label == expected.accessibilityLabel, "\(daemon) \(attention)")
        }
    }

    /// The status button is what VoiceOver lands on, so the identifier the
    /// design system publishes for this component has to reach it.
    @Test("the button carries the component identifier and a label per state")
    func buttonIsIdentified() {
        let (controller, item, _) = harness()
        controller.install(menu: NSMenu())

        #expect(item.identifier == DesignComponent.menuBarGlyph.accessibilityIdentifier)
        #expect(item.label == ProductStrings[.menuGlyphRunning])
    }

    /// Nothing is layered over the button, so the glyph only changes when the
    /// model does, and it changes for every state the model can reach.
    @Test("a daemon change redraws the glyph")
    func modelChangeRedraws() async {
        let (controller, item, model) = harness()
        controller.install(menu: NSMenu())

        model.needsAttention = true
        // The published change lands after `objectWillChange`, so the redraw is
        // scheduled for the next turn of the run loop.
        await settle()

        #expect(item.image === MenuBarGlyphImage.template(for: .attention))
        #expect(item.label == ProductStrings[.menuGlyphAttention])
    }

    // MARK: - The shipped rasters

    /// The clipping the owner saw: a status button clips its contents, so an
    /// image taller than the bar's own template size loses its top. 18 points
    /// is the canonical size and the ceiling this asserts.
    @Test("every shipped template fits the menu bar with nothing cut off")
    func templatesFitTheMenuBar() throws {
        for state in MenuBarGlyphState.allCases {
            let image = MenuBarGlyphImage.template(for: state)

            #expect(image.isTemplate, "\(state)")
            // Converted explicitly: `#expect` does not apply the implicit
            // CGFloat-to-Double conversion.
            #expect(Double(image.size.width) == MenuBarGlyphMetrics.imageSize, "\(state)")
            #expect(Double(image.size.height) == MenuBarGlyphMetrics.imageSize, "\(state)")
            #expect(Double(image.size.width) <= 18, "\(state)")
            #expect(Double(image.size.height) <= 18, "\(state)")

            let pixels = representations(of: image)
            #expect(pixels == [18, 36], "\(state) ships \(pixels)")
        }
    }

    /// A template image is tinted from its alpha, so any opaque pixel is a
    /// filled square in the menu bar. The corners are where a stray background
    /// would show first.
    @Test("every shipped template is alpha only, with clear corners")
    func templatesAreAlphaOnly() throws {
        for state in MenuBarGlyphState.allCases {
            let rep = try smallestRepresentation(of: MenuBarGlyphImage.template(for: state))
            let last = rep.pixelsWide - 1

            for (x, y) in [(0, 0), (last, 0), (0, last), (last, last)] {
                let alpha = try #require(rep.colorAt(x: x, y: y)).alphaComponent
                #expect(alpha == 0, "\(state) at \(x),\(y)")
            }
        }
    }

    /// The starting state is a lighter mark rather than an animation, which is
    /// what makes it readable under Reduce Motion with nothing moving. Its ink
    /// is the redline's own opacity floor.
    @Test("the starting template is the running one at the redline's lighter ink")
    func startingTemplateIsLighter() throws {
        let running = try peakAlpha(of: MenuBarGlyphImage.template(for: .running))
        let starting = try peakAlpha(of: MenuBarGlyphImage.template(for: .starting))

        #expect(running == 255)
        #expect(starting == Int((255 * MenuBarGlyphInk.startingOpacity).rounded()))
    }

    /// Attention is a shape cut into the same alpha, so it tints with the mark
    /// and is never carried by a colour a monochrome bar cannot show. The badge
    /// is ink the running state does not have, in the corner it is drawn in.
    @Test("the attention template adds a badge shape in the trailing corner")
    func attentionTemplateCarriesABadge() throws {
        let running = try smallestRepresentation(of: MenuBarGlyphImage.template(for: .running))
        let attention = try smallestRepresentation(of: MenuBarGlyphImage.template(for: .attention))

        // The badge's centre, in the image's own pixels: one point of inset
        // plus half the badge, in from the trailing edge and down from the top.
        let inset = MenuBarGlyphMetrics.markInset + MenuBarGlyphMetrics.badgeDiameter / 2
        let x = Int((MenuBarGlyphMetrics.imageSize - inset).rounded())
        let y = Int(inset.rounded())

        let before = try #require(running.colorAt(x: x, y: y)).alphaComponent
        let after = try #require(attention.colorAt(x: x, y: y)).alphaComponent

        #expect(after == 1)
        #expect(after > before)
    }

    // MARK: - Hiding it

    /// Command-drag is the system's own way off the bar, and the autosave name
    /// is what makes macOS remember it. The name is written into the account's
    /// defaults, so changing it later reads as a new item and puts a removed
    /// one back.
    @Test("the name macOS remembers the item by is stable")
    func autosaveNameIsStable() {
        #expect(MenuBarController.autosaveName == "fermix.statusItem")
    }

    /// The one ordering no double can prove: the shipped item is created and
    /// named in the same initializer.
    ///
    /// An `NSStatusItem` is on the bar from the moment it exists, and macOS
    /// applies the visibility it remembers at the instant `autosaveName` is
    /// assigned. Naming it any later — at install, after the rest of the app is
    /// assembled — is an item the user removed being drawn and then taken away
    /// again on every single launch. A real item cannot be built here, so the
    /// gate reads the source.
    @Test("the shipped item is named in the same initializer that creates it")
    func shippedItemIsNamedAtCreation() throws {
        let file = try #require(try SourceTree.swiftFiles(matching: "App/MenuBarController.swift").first)
        #expect(file.text.contains("init(autosaveName: String) {"))

        let afterInit = try #require(file.text.components(separatedBy: "init(autosaveName: String) {").last)
        let initializer = try #require(afterInit.components(separatedBy: "\n    }").first)

        #expect(initializer.contains("NSStatusBar.system.statusItem"))
        #expect(initializer.contains(".removalAllowed"))
        #expect(initializer.contains("item.autosaveName = autosaveName"))
        // One item, named once, with no seam member that could name it again:
        // a second of either is a second ordering to reason about.
        #expect(occurrences(of: "NSStatusBar.system.statusItem", in: file.text) == 1)
        #expect(occurrences(of: "item.autosaveName", in: file.text) == 1)
        #expect(!file.text.contains("func allowRemoval"))
    }

    /// A Command-drag off the bar is a removal nothing in the app made, and the
    /// switch Home draws reads through to the item rather than holding a copy.
    /// One notice for both origins is what keeps the two from drifting.
    @Test("every change to whether the item is on the bar is reported once")
    func visibilityChangesAreReported() {
        let (controller, item, _) = harness()
        var reports = 0
        controller.onMenuBarItemShownChanged = { reports += 1 }
        controller.install(menu: NSMenu())

        item.isVisible = false
        #expect(reports == 1)

        controller.setMenuBarItemShown(true)
        #expect(reports == 2)

        // Writing the value it already holds is not a change.
        controller.setMenuBarItemShown(true)
        #expect(reports == 2)
    }

    /// Installing must not write the visibility. macOS restores it from the
    /// autosave name, so an item the user removed stays removed; writing it
    /// here would put it back on every launch.
    @Test("installing leaves the remembered visibility alone")
    func installDoesNotOverrideRememberedVisibility() {
        let (controller, item, _) = harness()
        item.isVisible = false

        controller.install(menu: NSMenu())

        #expect(item.isVisible == false)
        #expect(controller.menuBarItemShown == false)
    }

    /// One owner: the toggle in Home and the row in the status menu both write
    /// the item, and both read it back, so the two can never disagree.
    @Test("hiding and showing the item is read back from the item itself")
    func visibilityRoundTrips() {
        let (controller, item, _) = harness()
        controller.install(menu: NSMenu())

        #expect(controller.menuBarItemShown)

        controller.setMenuBarItemShown(false)
        #expect(item.isVisible == false)
        #expect(controller.menuBarItemShown == false)

        controller.setMenuBarItemShown(true)
        #expect(item.isVisible)
        #expect(controller.menuBarItemShown)
    }

    // MARK: - The menu

    /// A plain `NSMenu`, so macOS draws it, sizes it, and gives it the current
    /// system material. Nothing is drawn behind it and nothing is anchored to
    /// the button.
    @Test("the item opens the menu it was given and draws nothing itself")
    func menuIsAttached() {
        let (controller, item, _) = harness()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Fermix", action: nil, keyEquivalent: ""))

        controller.install(menu: menu)

        #expect(item.menu === menu)
        #expect(item.menu?.items.count == 1)
    }

    // MARK: - Helpers

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func representations(of image: NSImage) -> [Int] {
        image.representations.map(\.pixelsWide).sorted()
    }

    private func smallestRepresentation(of image: NSImage) throws -> NSBitmapImageRep {
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let smallest = bitmaps.min { $0.pixelsWide < $1.pixelsWide }

        return try #require(smallest)
    }

    private func peakAlpha(of image: NSImage) throws -> Int {
        let rep = try smallestRepresentation(of: image)
        var peak = 0.0

        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }

                peak = max(peak, colour.alphaComponent)
            }
        }

        return Int((peak * 255).rounded())
    }
}
