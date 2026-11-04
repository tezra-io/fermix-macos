import SwiftUI

/// The browser pane as the window's trailing column (plan §4.3): beside the
/// split view's rail and body, the full height of the window, with its own
/// part of the window's toolbar, where its tabs stand over it while the
/// surface's own controls and search stay over the body (owner, 2026-11-01:
/// one bar across the window that reads as one app).
///
/// It is the system's inspector column, because only a column the window
/// knows gets a part of the toolbar of its own. It opens at the width the
/// window grows by for it (`WindowGrowth`), so the body keeps the width it
/// had; the person can drag its edge, down to the pane's floor and never so
/// far that the body falls under its own (`bodyWidthsBesidePane`). The
/// column's width is never computed from a view that holds the column: the
/// window's width comes from where the window bounds it, and a column held to
/// one exact width at a time grows without end, so it is given a range.
///
/// It shows by whether the pane is open, which the window reads alone so a
/// page loading never redraws it, and the pane hides through the
/// coordinator, which owns that fact.
struct BrowserColumn: ViewModifier {
    let browser: BrowserCoordinator
    /// Whether the pane is open, as the window read it.
    let open: Bool
    /// The window's width, measured where the window bounds it.
    let windowWidth: Double
    /// Whether the rail is showing, whose width the body does not have.
    let railShown: Bool

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: presented) {
                BrowserPaneView(browser: browser)
                    .inspectorColumnWidth(
                        min: WindowMetrics.browserPaneFloor,
                        ideal: WindowMetrics.browserPaneWidth,
                        max: BrowserColumnWidth.widest(window: windowWidth, railShown: railShown)
                    )
            }
    }

    /// Open while the coordinator says so; a close the system asks for goes
    /// through the coordinator.
    private var presented: Binding<Bool> {
        Binding(
            get: { open },
            set: { shown in
                guard !shown, open else { return }

                browser.closePane()
            }
        )
    }
}

/// How wide the browser's column may be dragged (`BrowserColumn`), as one pure
/// rule.
enum BrowserColumnWidth {
    /// What the window leaves once the rail, where it shows, and the body's
    /// floor have theirs, and never under the pane's own floor. A window not
    /// measured yet gives the width the pane opens at.
    static func widest(window: Double, railShown: Bool) -> Double {
        guard window > 0 else { return WindowMetrics.browserPaneWidth }

        let beside = window - (railShown ? WindowMetrics.railWidth : 0)
        return max(WindowMetrics.browserPaneFloor, beside - WindowMetrics.bodyFloorBesidePane)
    }
}
