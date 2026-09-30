import Testing

@testable import FermixAppCore

/// The body and the pane sharing the detail column (plan §4.3, redlines
/// decision 37), rule by rule. The rule is pure, so each case is proved on
/// widths; the layout that applies it stays untested, as growth's host does.
@Suite("Browser pane split")
struct PaneSplitTests {
    static let body = WindowMetrics.bodyWidthsBesidePane
    static let pane = WindowMetrics.browserPaneWidths

    static func split(_ available: Double) -> PaneSplit.Widths {
        PaneSplit.widths(available: available, body: body, pane: pane)
    }

    @Test("the pane prefers the width the window widens by, and each side has a 480 point floor")
    func tokens() {
        #expect(Self.pane == 480 ... 600)
        #expect(Self.pane.upperBound == WindowMetrics.browserPaneWidth)
        #expect(Self.body.lowerBound == 480)
    }

    /// The body's ceiling is the chat column with its gutters, so the two
    /// tokens cannot drift apart.
    @Test("the body's ceiling is the chat column and its gutters")
    func bodyCeiling() {
        #expect(Self.body.upperBound == ChatMetrics.columnWidth + 2 * Spacing.l)
    }

    /// The window opened from its default size on a wide screen: 1756 points
    /// less the rail. The body has its ceiling and the page has the rest.
    @Test("past the body's ceiling every point goes to the page")
    func wideGoesToThePage() {
        #expect(Self.split(1704) == PaneSplit.Widths(body: 768, pane: 936))
        #expect(Self.split(2000) == PaneSplit.Widths(body: 768, pane: 1232))
    }

    /// A 1470 point laptop screen: the window is held to the screen, the body
    /// still has its ceiling and the page is wider than it asked for.
    @Test("on a laptop screen the body keeps its ceiling and the page grows")
    func laptop() {
        #expect(Self.split(1418) == PaneSplit.Widths(body: 768, pane: 650))
    }

    /// Between the floors and the ceiling the pane has the width it prefers
    /// before the body grows.
    @Test("the pane reaches the width it prefers before the body grows past its floor")
    func paneFirst() {
        #expect(Self.split(1228) == PaneSplit.Widths(body: 628, pane: 600))
        #expect(Self.split(1080) == PaneSplit.Widths(body: 480, pane: 600))
        #expect(Self.split(1000) == PaneSplit.Widths(body: 480, pane: 520))
    }

    /// The smallest screen a Mac shows, 1024 points less the rail: the body
    /// has its floor and the twelve points past the two floors go to the page,
    /// which has given way first.
    @Test("on the smallest screen the page gives way before the chat")
    func smallestScreen() {
        #expect(Self.split(972) == PaneSplit.Widths(body: 480, pane: 492))
        #expect(Self.split(960) == PaneSplit.Widths(body: 480, pane: 480))
    }

    /// Under both floors, which the window's own floor keeps out of reach, the
    /// pane holds its floor and the body takes what is left.
    @Test("under both floors the pane holds and the body takes the rest")
    func underBothFloors() {
        #expect(Self.split(900) == PaneSplit.Widths(body: 420, pane: 480))
        #expect(Self.split(300) == PaneSplit.Widths(body: 0, pane: 300))
    }

    @Test("the two widths always sum to the column", arguments: [300.0, 900, 960, 1000, 1080, 1228, 1418, 1704, 2000])
    func sumsToTheColumn(available: Double) {
        let widths = Self.split(available)

        #expect(widths.body + widths.pane == available)
        #expect(widths.body >= 0 && widths.pane >= 0)
    }
}
