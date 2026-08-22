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
    let coordinator: AppCoordinator

    func view(for kind: WindowKind) -> NSView {
        switch kind {
        case .onboarding:
            return NSHostingView(rootView: OnboardingWindowView(model: surfaces.onboarding))
        case .main:
            return NSHostingView(
                rootView: MainWindowView(model: model, surfaces: surfaces, coordinator: coordinator)
            )
        case .pet:
            return NSHostingView(rootView: PetView(model: surfaces.pet))
        }
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
        window.contentView = surfaces.view(for: descriptor.kind)
        window.delegate = self
        windows[descriptor.kind] = window
        reconcileActivationPolicy()
        window.center()
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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true

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

        return window
    }

    private func styleMask(_ descriptor: WindowDescriptor) -> NSWindow.StyleMask {
        guard !descriptor.borderless else { return [.borderless, .fullSizeContentView] }

        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if descriptor.resizable {
            mask.insert(.resizable)
        }

        return mask
    }
}
