import Testing

@testable import FermixAppCore

/// The browser's column (plan §4.3): it opens at the width the window grows by
/// for it, is dragged down to its own floor at most, and never so wide that the
/// body beside it falls under its floor.
@Suite("Browser column")
struct BrowserColumnTests {
    private static let rail = WindowMetrics.railWidth

    @Test("the widest the pane is dragged leaves the rail and the body's floor theirs")
    func widest() {
        let window = 1640.0

        #expect(BrowserColumnWidth.widest(window: window, railShown: true) == window - Self.rail - WindowMetrics.bodyFloorBesidePane)
        #expect(BrowserColumnWidth.widest(window: window, railShown: false) == window - WindowMetrics.bodyFloorBesidePane)
    }

    @Test("a window too narrow for both floors still lets the pane keep its own")
    func narrow() {
        #expect(BrowserColumnWidth.widest(window: 900, railShown: true) == WindowMetrics.browserPaneFloor)
    }

    @Test("a window not measured yet gives the width the pane opens at")
    func unmeasured() {
        #expect(BrowserColumnWidth.widest(window: 0, railShown: true) == WindowMetrics.browserPaneWidth)
    }

    @Test("the pane opens at the width the window grows by, above its floor")
    func opening() {
        #expect(WindowMetrics.browserPaneWidth > WindowMetrics.browserPaneFloor)
    }
}

/// The toolbar's pills: every tab and the search field the toolbar's own
/// control height, and every tab one width, so a title arriving as its page
/// loads never moves the row.
@Suite("Toolbar pills")
struct ToolbarPillTests {
    @Test("a pill is the toolbar's control height, and every tab is one width")
    func heights() {
        #expect(ToolbarPillMetrics.height == HitTarget.button)
        #expect(BrowserPaneMetrics.tabWidth > 0)
        #expect(ToolbarPillMetrics.searchWidth > BrowserPaneMetrics.tabWidth)
    }
}
