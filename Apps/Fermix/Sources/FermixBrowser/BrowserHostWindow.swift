import AppKit
import FermixAppCore

/// The window a task's pages run in while the pane cannot show them
/// (plan §4.0, §4.8, §4.10): on screen, so WebKit treats each page as visible
/// and runs its animation frames, timers and rendering, and invisible, so
/// nothing is drawn.
///
/// The configuration is the one the spike proved on public API: a 2 by 2
/// point borderless non-activating panel at a screen corner, at the status bar
/// level, at 1 percent opacity, ignoring the mouse, never key, kept out of
/// screen sharing, the Windows menu and window cycling, on every Space and
/// beside a full-screen app, holding each page at a full 1280 by 800. A window
/// that was never shown, or one placed off screen, leaves the page hidden and
/// suspended; this one does not.
///
/// It can never become key: in the spike an off-screen window took the
/// person's own keystrokes into a page's field. A task's clicks and key presses
/// are delivered to the web view directly, which needs no key window.
///
/// Built and ordered in on the first page it holds, which is after the app
/// finished launching, and ordered out when the engine lets its pages go.
@MainActor
final class BrowserHostWindow: BrowserPageStage {
    /// The size a page lays out at while it runs here: a desktop page, not the
    /// window's two points.
    static let pageSize = NSSize(width: 1280, height: 800)
    static let windowSize = NSSize(width: 2, height: 2)

    private var panel: NSPanel?

    func hold(_ page: NSView) {
        let content = orderedIn()
        guard page.superview !== content else { return }

        page.translatesAutoresizingMaskIntoConstraints = true
        page.frame = NSRect(origin: .zero, size: Self.pageSize)
        content.addSubview(page)
    }

    func release(_ page: NSView) {
        guard let content = panel?.contentView, page.superview === content else { return }

        page.removeFromSuperview()
    }

    /// Orders the window out once it holds no page.
    func close() {
        guard let panel, panel.contentView?.subviews.isEmpty == true else { return }

        panel.orderOut(nil)
        self.panel = nil
    }

    private func orderedIn() -> NSView {
        if let content = panel?.contentView { return content }

        let panel = HostPanel.make()
        panel.orderFrontRegardless()
        self.panel = panel
        guard let content = panel.contentView else {
            preconditionFailure("a panel is built with a content view")
        }

        return content
    }
}

/// The panel itself, which refuses to be key or main whatever is asked of it.
private final class HostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make() -> HostPanel {
        // The primary display's bottom-left corner is the origin of the global
        // space whichever display is primary, so the point is always on screen.
        let panel = HostPanel(
            contentRect: NSRect(origin: .zero, size: BrowserHostWindow.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        // An app brought up with `open -j` starts hidden, and an accessory app
        // is rarely active: a panel that hid with the app, or on deactivation
        // as a panel does by default, would leave its pages suspended.
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear

        return panel
    }
}
