import AppKit
import SwiftUI

/// Builds the content of each window.
///
/// The window host owns geometry and lifetime; what goes inside is a surface,
/// and the surfaces are what the next slices fill in.
@MainActor
struct AppSurfaces {
    let model: AppModel
    let surfaces: MainWindowSurfaces
    let sidebar: SidebarModel
    let router: any CommandPerforming
    /// The settings presentation switch (decision D1). It lives beside the
    /// model rather than inside it because entering settings is a window
    /// state, not a surface's.
    let settingsPresentation: SettingsPresentation
    /// The back control and Escape, both routed to the coordinator's own
    /// `leaveSettings` so the gesture and a command leave by one path.
    let leaveSettings: () -> Void
    /// The one way out of an unreadable settings file, which is a coordinator
    /// decision rather than a command a menu carries (M34 §7.5).
    let openRecovery: () -> Void
    /// The journaled restart the one Restart sheet takes once it has asked.
    let restart: () -> Void

    func view(for kind: WindowKind) -> NSView {
        switch kind {
        case .main:
            let view = hosting(
                MainWindowView(
                    model: model,
                    sidebar: sidebar,
                    surfaces: surfaces,
                    router: router,
                    presentation: settingsPresentation,
                    settings: surfaces.settings,
                    leaveSettings: leaveSettings,
                    openRecovery: openRecovery,
                    restart: restart
                )
            )
            // The primary window's toolbar and title are SwiftUI's, hosted in
            // an AppKit window: this is what carries `.toolbar` and
            // `.navigationTitle` out to the window (M34 §3.1).
            view.sceneBridgingOptions = [.toolbars, .title]
            return view
        case .pet:
            return hosting(PetView(model: surfaces.pet))
        }
    }

    /// The one place a window's content view is built, and the whole of the
    /// rule that a window's size is the app's and never its content's.
    ///
    /// A hosting view's default `sizingOptions` write the SwiftUI content's
    /// size extrema onto the `NSWindow`. Measured live on a 3840 by 1080 point
    /// display: the Integrations pane drove the primary window to 980 by 2115,
    /// twice the screen's height and half of it below the bottom edge, through
    /// `NSHostingView.updateWindowContentSizeExtremaIfNecessary`. Cleared, the
    /// window keeps the size the descriptor, `WindowGrowth` and the operator's
    /// drag give it. What lets the content take that size is the split view's
    /// own floor, in `MainWindowView`.
    private func hosting<Content: View>(_ root: Content) -> NSHostingView<ProductTinted<Content>> {
        let view = NSHostingView(rootView: ProductTinted(content: root))
        view.sizingOptions = []

        return view
    }
}

/// Every window's root, carrying the product's accent.
///
/// The tint is applied once, here, rather than on the one control that showed
/// the defect. The owner's report of 2026-09-03 was that Home's `Continue
/// setup` reads wrong in dark appearance; measured off the shipped captures,
/// its label was white in both appearances and its fill was the *macOS* accent,
/// `rgb(5,124,254)` on dark and `rgb(0,112,237)` on light, against the
/// product's `#2b5cff` that every other primary action draws. The system blue
/// is markedly lighter on a near-black ground, which is why the mismatch showed
/// in dark and hid on white.
///
/// Tinting only that button would have swapped one mismatch for another: every
/// switch, every list selection and every sheet's default button on the same
/// page would have kept the user's macOS accent while the toolbar action turned
/// product blue, and §1.1 calls one surface showing two blues a defect
/// regardless of which two they are. One tint at the root is the whole of the
/// answer.
///
/// The accent stays uniform across appearances: lightening it is what would
/// break the label. White on `#2b5cff` is 5.13:1, while white on `accentHover`
/// (`#4a73ff`), the only lighter accent the ramp has, is 4.04:1 and under the
/// 4.5:1 floor §9 gates.
struct ProductTinted<Content: View>: View {
    let content: Content

    var body: some View {
        content.tint(Palette.accent.color)
    }
}

/// The `NSWindow` half of window coordination.
///
/// It creates a window per kind, applies the descriptor, and reports occlusion
/// back. Every decision about *which* window may be open belongs to
/// `WindowCoordinator`; this type only does what it is told.
@MainActor
final class AppKitWindowHost: NSObject, WindowHost, NSWindowDelegate {
    var surfaces: AppSurfaces?
    var onVisibilityChanged: ((WindowKind, Bool) -> Void)?

    /// Applies the app-wide activation policy; a seam so tests never touch the
    /// real `NSApp`.
    var applyActivationPolicy: (NSApplication.ActivationPolicy) -> Void = { policy in
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private var windows: [WindowKind: NSWindow] = [:]

    func present(_ descriptor: WindowDescriptor) {
        guard let surfaces else {
            preconditionFailure("the window host has no surfaces to present")
        }

        let window = makeWindow(descriptor)
        window.delegate = self
        windows[descriptor.kind] = window
        reconcileActivationPolicy()
        // Geometry first, content second. The window reaches its final frame
        // before anything is hosted in it, so the SwiftUI content is laid out
        // once, at the size it will be shown at. Resizing a window that already
        // holds a hosting view leaves the content laid out for the old frame,
        // which draws the pane shifted out of the top of the window (observed
        // live on the settings panes).
        position(window, descriptor)
        fit(window)
        window.contentView = surfaces.view(for: descriptor.kind)
        // An accessory app that orders a window front without activating
        // leaves it behind whatever the user was in — the window "opens" and
        // nobody sees it (observed live). Presenting IS the activation intent.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(descriptor.kind, true)
    }

    func focus(_ kind: WindowKind) {
        guard let window = windows[kind] else { return }

        // The app is an accessory, so it has to ask for activation explicitly:
        // ordering a window front without it leaves the window behind whatever
        // the user was in.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss(_ kind: WindowKind) {
        guard let window = windows.removeValue(forKey: kind) else { return }

        window.delegate = nil
        window.orderOut(nil)
        window.close()
        reconcileActivationPolicy()
        onVisibilityChanged?(kind, false)
    }

    /// The app is a Dock app exactly while a real window is open, and a
    /// menu-bar accessory otherwise. The pet's floating window is ambient and
    /// never forces Dock presence.
    private func reconcileActivationPolicy() {
        let wantsDock = windows.keys.contains { $0 != .pet }

        applyActivationPolicy(wantsDock ? .regular : .accessory)
    }

    func isPresented(_ kind: WindowKind) -> Bool {
        windows[kind] != nil
    }

    /// Grows a window so it holds at least `content`, animated and clamped to
    /// the screen it is on (decision D3).
    ///
    /// The geometry is `WindowGrowth`'s; what belongs here are the three facts
    /// only AppKit has — which screen the window is on, its visible frame, and
    /// how much chrome sits on top of a content rect. A window that is not open
    /// has no frame to grow.
    func grow(_ kind: WindowKind, toAtLeast content: CGSize) {
        guard let window = windows[kind],
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }

        // `content` is a content size, the same unit the descriptor builds the
        // window with, while `WindowGrowth` works in frame units. The window is
        // asked how much chrome sits on top rather than the two being assumed
        // equal: they are equal today only because every descriptor here
        // carries `.fullSizeContentView`, which puts the content rect and the
        // frame rect on one rectangle.
        let wanted = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size

        guard let frame = WindowGrowth.frame(growing: window.frame, toAtLeast: wanted, within: visible)
        else { return }

        window.setFrame(frame, display: true, animate: true)
    }

    /// Fed by the app delegate's occlusion observer, which sees every window in
    /// the process and not just ours.
    func occlusionChanged(window: NSWindow, visible: Bool) {
        guard let kind = windows.first(where: { $0.value === window })?.key else { return }

        onVisibilityChanged?(kind, visible)
    }

    // MARK: - NSWindowDelegate

    /// A window the user closed is gone: the app stays alive, and reopening it
    /// builds a fresh one rather than resurrecting a closed handle.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key
        else { return }

        windows.removeValue(forKey: kind)
        reconcileActivationPolicy()
        onVisibilityChanged?(kind, false)
    }

    // MARK: - Construction

    private func makeWindow(_ descriptor: WindowDescriptor) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: descriptor.size),
            styleMask: styleMask(descriptor),
            backing: .buffered,
            defer: false
        )

        window.title = descriptor.title
        // A window that shows its title takes the system's unified titlebar,
        // which is what draws the sidebar toggle and the inline title. One that
        // does not still draws a titlebar zone of its own.
        window.titleVisibility = descriptor.showsTitle ? .visible : .hidden
        window.titlebarAppearsTransparent = !descriptor.showsTitle
        window.toolbarStyle = descriptor.showsTitle ? .unified : .automatic
        window.isReleasedWhenClosed = false
        window.isRestorable = descriptor.restorable
        window.isMovableByWindowBackground = !descriptor.showsTitle

        if descriptor.borderless {
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        if descriptor.floating {
            window.level = .floating
        }

        if let minimumSize = descriptor.minimumSize {
            window.minSize = minimumSize
        }

        if !descriptor.resizable {
            window.maxSize = descriptor.size
            window.minSize = descriptor.size
        }

        // Minimize is absent from the style mask above where the descriptor
        // says so; zoom is a live button that has to be dimmed by hand.
        if !descriptor.zoomable {
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }

        return window
    }

    /// Puts a window inside the screen it is opening on, before it is shown.
    ///
    /// The geometry is `WindowGrowth`'s; what belongs here is the one fact only
    /// AppKit has, which screen the window is on.
    ///
    /// AppKit constrains a *titled* window itself, and it is worth being exact
    /// about which paths that covers. Measured on a 3840 by 1080 point display
    /// with this step removed: a poisoned 980 by 2115 autosave still opened at
    /// 980 by 960, and a 980 by 1200 descriptor with no autosave still centred
    /// at 980 by 960. A **borderless** window is the path AppKit leaves alone —
    /// the floating pet, given a 400 by 1400 descriptor, opened at 400 by 1400
    /// with 440 points hanging below the screen, and at 400 by 960 with this
    /// step back. So this is the one ceiling every window gets, and the only
    /// one the pet has.
    private func fit(_ window: NSWindow) {
        guard let visible = screen(showing: window.frame)?.visibleFrame,
              let frame = WindowGrowth.frame(fitting: window.frame, within: visible)
        else { return }

        window.setFrame(frame, display: false)
    }

    /// The screen a frame belongs to, before the window is on screen and
    /// `NSWindow.screen` can answer.
    ///
    /// The display the frame overlaps most, and the main one where it overlaps
    /// none. A frame that overlaps nothing is the case the fit exists for: it
    /// was saved on a display that is not attached now.
    private func screen(showing frame: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0

        for candidate in NSScreen.screens {
            let overlap: CGRect = candidate.frame.intersection(frame)
            let area: CGFloat = overlap.isNull ? 0 : overlap.width * overlap.height
            guard area > bestArea else { continue }

            bestArea = area
            best = candidate
        }

        return best ?? NSScreen.main
    }

    /// A window that remembers its frame opens where the operator left it; one
    /// that does not opens centred. Two configurations, one placement step.
    private func position(_ window: NSWindow, _ descriptor: WindowDescriptor) {
        guard let name = descriptor.frameAutosaveName else {
            window.center()
            return
        }

        let autosave = NSWindow.FrameAutosaveName(name)
        window.setFrameAutosaveName(autosave)
        if !window.setFrameUsingName(autosave) {
            window.center()
        }
    }

    private func styleMask(_ descriptor: WindowDescriptor) -> NSWindow.StyleMask {
        guard !descriptor.borderless else { return [.borderless, .fullSizeContentView] }

        var mask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if descriptor.minimizable {
            mask.insert(.miniaturizable)
        }
        if descriptor.resizable {
            mask.insert(.resizable)
        }

        return mask
    }
}
