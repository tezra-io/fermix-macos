import CoreGraphics
import Testing

@testable import FermixAppCore

/// The browser pane's room in the window (plan §4.3), rule by rule. The rules
/// are pure, so each is proved on rectangles; the host that applies them stays
/// untested, as growth's does.
@Suite("Browser pane window growth")
struct BrowserPaneGrowthTests {
    /// A 1440 by 875 point screen under a 25 point menu bar, the shape of a
    /// laptop display.
    static let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    static let minimum = WindowMetrics.mainMinimumSize
    static let pane = WindowMetrics.browserPaneWidth

    static func placement(_ frame: CGRect, fillsScreen: Bool = false) -> WindowGrowth.Placement {
        WindowGrowth.Placement(frame: frame, visible: visible, fillsScreen: fillsScreen)
    }

    @Test("the pane is 600 points wide")
    func paneWidth() {
        #expect(WindowMetrics.browserPaneWidth == 600)
    }

    /// The content keeps its width: the window grows by exactly the pane, to the
    /// right, and nothing else about it moves.
    @Test("opening widens the window to the right by the pane")
    func openingWidensToTheRight() {
        let frame = CGRect(x: 100, y: 120, width: 700, height: 600)

        let layout = WindowGrowth.opening(pane: Self.pane, at: Self.placement(frame), minimum: Self.minimum)

        #expect(layout.frame == CGRect(x: 100, y: 120, width: 1300, height: 600))
        #expect(layout.widening == WindowGrowth.PaneWidening(before: frame, widened: CGRect(x: 100, y: 120, width: 1300, height: 600)))
    }

    @Test("a right edge that would pass the screen's shifts the window left")
    func openingShiftsLeft() {
        let frame = CGRect(x: 500, y: 120, width: 700, height: 600)

        let layout = WindowGrowth.opening(pane: Self.pane, at: Self.placement(frame), minimum: Self.minimum)

        #expect(layout.frame == CGRect(x: 140, y: 120, width: 1300, height: 600))
        #expect(layout.frame.map(Self.visible.contains) == true)
    }

    /// Wider than the screen, the window stops at the screen's width and the
    /// pane takes the difference from the content.
    @Test("a window that would be wider than the screen is held to its width")
    func openingClampsToTheScreen() {
        let frame = CGRect(x: 60, y: 120, width: 1040, height: 640)

        let layout = WindowGrowth.opening(pane: Self.pane, at: Self.placement(frame), minimum: Self.minimum)

        #expect(layout.frame == CGRect(x: 0, y: 120, width: 1440, height: 640))
        #expect(layout.minimumSize.width == 1360, "760 and 600 fit on this screen")
    }

    @Test("opening raises the floor by the pane, and never past the screen")
    func openingRaisesTheFloor() {
        let frame = CGRect(x: 100, y: 120, width: 700, height: 600)

        let layout = WindowGrowth.opening(pane: Self.pane, at: Self.placement(frame), minimum: Self.minimum)
        #expect(layout.minimumSize == CGSize(width: Self.minimum.width + Self.pane, height: Self.minimum.height))

        let narrow = CGRect(x: 0, y: 0, width: 1280, height: 800)
        #expect(
            WindowGrowth.paneMinimum(pane: Self.pane, base: Self.minimum, within: narrow)
                == CGSize(width: 1280, height: Self.minimum.height)
        )
    }

    /// Full screen or zoomed, the window is the screen's size: nothing moves and
    /// nothing is remembered, and the pane takes its width from the content.
    @Test("a window that fills its screen is not moved")
    func fullScreenIsSkipped() {
        let layout = WindowGrowth.opening(
            pane: Self.pane,
            at: Self.placement(Self.visible, fillsScreen: true),
            minimum: Self.minimum
        )

        #expect(layout.frame == nil)
        #expect(layout.widening == nil)
    }

    @Test("a window already as wide as the screen has nothing to give")
    func fullWidthIsLeftAlone() {
        let frame = CGRect(x: 0, y: 100, width: 1440, height: 700)

        let layout = WindowGrowth.opening(pane: Self.pane, at: Self.placement(frame), minimum: Self.minimum)

        #expect(layout.frame == nil)
        #expect(layout.widening == nil)
    }

    @Test("closing gives back the frame from before, while the window is the one the app widened")
    func closingRestores() {
        let before = CGRect(x: 100, y: 120, width: 700, height: 600)
        let widened = CGRect(x: 100, y: 120, width: 1300, height: 600)
        let widening = WindowGrowth.PaneWidening(before: before, widened: widened)

        let layout = WindowGrowth.closing(at: Self.placement(widened), widening: widening, minimum: Self.minimum)

        #expect(layout.frame == before)
        #expect(layout.minimumSize == Self.minimum)
        #expect(layout.widening == nil)
    }

    /// AppKit settles an animated frame on its own grid, so a fraction of a
    /// point is still the frame the app set.
    @Test("a frame a fraction of a point away is still the app's")
    func closingToleratesTheBackingGrid() {
        let before = CGRect(x: 100, y: 120, width: 700, height: 600)
        let widened = CGRect(x: 100, y: 120, width: 1300, height: 600)
        let settled = CGRect(x: 100.5, y: 119.5, width: 1300, height: 600.5)

        let layout = WindowGrowth.closing(
            at: Self.placement(settled),
            widening: WindowGrowth.PaneWidening(before: before, widened: widened),
            minimum: Self.minimum
        )

        #expect(layout.frame == before)
    }

    /// A window the person moved or resized while the pane was open is theirs.
    @Test("closing keeps the person's own frame and lowers the floor", arguments: [
        CGRect(x: 100, y: 120, width: 1200, height: 600),
        CGRect(x: 40, y: 120, width: 1300, height: 600),
        CGRect(x: 100, y: 120, width: 1300, height: 700)
    ])
    func closingKeepsThePersonsFrame(_ theirs: CGRect) {
        let widening = WindowGrowth.PaneWidening(
            before: CGRect(x: 100, y: 120, width: 700, height: 600),
            widened: CGRect(x: 100, y: 120, width: 1300, height: 600)
        )

        let layout = WindowGrowth.closing(at: Self.placement(theirs), widening: widening, minimum: Self.minimum)

        #expect(layout.frame == nil)
        #expect(layout.minimumSize == Self.minimum)
    }

    @Test("closing a pane that moved nothing moves nothing")
    func closingWithoutWidening() {
        let layout = WindowGrowth.closing(
            at: Self.placement(CGRect(x: 0, y: 0, width: 1440, height: 875)),
            widening: nil,
            minimum: Self.minimum
        )

        #expect(layout.frame == nil)
        #expect(layout.minimumSize == Self.minimum)
    }

    @Test("closing in full screen moves nothing, even over a widening")
    func closingInFullScreen() {
        let widened = CGRect(x: 100, y: 120, width: 1300, height: 600)
        let layout = WindowGrowth.closing(
            at: Self.placement(widened, fillsScreen: true),
            widening: WindowGrowth.PaneWidening(before: CGRect(x: 100, y: 120, width: 700, height: 600), widened: widened),
            minimum: Self.minimum
        )

        #expect(layout.frame == nil)
        #expect(layout.minimumSize == Self.minimum)
    }
}

/// The coordinator's half: the memory between opening and closing.
@Suite("Browser pane window coordination")
@MainActor
struct BrowserPaneCoordinationTests {
    static let frame = CGRect(x: 100, y: 120, width: 1040, height: 640)
    static let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
    static let raisedMinimum = CGSize(
        width: WindowMetrics.mainMinimumSize.width + WindowMetrics.browserPaneWidth,
        height: WindowMetrics.mainMinimumSize.height
    )

    private func openHost() -> (FakeWindowHost, WindowCoordinator) {
        let host = FakeWindowHost()
        host.placements[.main] = WindowGrowth.Placement(frame: Self.frame, visible: Self.visible, fillsScreen: false)
        let windows = WindowCoordinator(host: host)
        windows.show(.main)

        return (host, windows)
    }

    @Test("opening and closing the pane widens the window and gives the width back")
    func roundTrip() {
        let (host, windows) = openHost()

        windows.setBrowserPane(open: true)
        #expect(windows.isBrowserPaneOpen)
        #expect(host.placed.last?.frame == CGRect(x: 100, y: 120, width: 1640, height: 640))
        #expect(host.placed.last?.minimumSize == Self.raisedMinimum)

        windows.setBrowserPane(open: false)
        #expect(!windows.isBrowserPaneOpen)
        #expect(host.placed.last?.frame == Self.frame)
        #expect(host.placed.last?.minimumSize == WindowMetrics.mainMinimumSize)
    }

    @Test("asking for the state the pane is already in changes nothing")
    func repeatedRequestsAreNoOps() {
        let (host, windows) = openHost()

        windows.setBrowserPane(open: true)
        windows.setBrowserPane(open: true)
        windows.setBrowserPane(open: false)
        windows.setBrowserPane(open: false)

        #expect(host.placed.count == 2)
    }

    @Test("a window resized while the pane was open keeps its size when the pane closes")
    func personsResizeWins() {
        let (host, windows) = openHost()
        windows.setBrowserPane(open: true)
        let theirs = CGRect(x: 100, y: 120, width: 1500, height: 700)
        host.placements[.main] = WindowGrowth.Placement(frame: theirs, visible: Self.visible, fillsScreen: false)

        windows.setBrowserPane(open: false)

        #expect(host.placed.last?.frame == nil)
        #expect(host.placed.last?.minimumSize == WindowMetrics.mainMinimumSize)
    }

    /// A window that is not open has no frame to move, and what the pane did
    /// to a window that has gone is forgotten.
    @Test("a closed window is not placed")
    func closedWindowIsNotPlaced() {
        let host = FakeWindowHost()
        let windows = WindowCoordinator(host: host)

        windows.setBrowserPane(open: true)

        #expect(windows.isBrowserPaneOpen)
        #expect(host.placed.isEmpty)
    }

    @Test("the primary window opened again with the pane open keeps the raised floor")
    func reopenedWindowKeepsTheFloor() {
        let (host, windows) = openHost()
        windows.setBrowserPane(open: true)
        windows.close(.main)

        windows.show(.main)

        #expect(host.placed.last?.frame == nil)
        #expect(host.placed.last?.minimumSize == Self.raisedMinimum)
    }
}
