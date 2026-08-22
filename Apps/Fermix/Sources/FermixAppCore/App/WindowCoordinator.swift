import CoreGraphics
import Foundation

/// Everything a window is, before AppKit is involved.
public struct WindowDescriptor: Equatable, Sendable {
    public let kind: WindowKind
    public let title: String
    public let size: CGSize
    public let minimumSize: CGSize?
    public let resizable: Bool
    public let borderless: Bool
    public let floating: Bool

    public init(
        kind: WindowKind,
        title: String,
        size: CGSize,
        minimumSize: CGSize?,
        resizable: Bool,
        borderless: Bool,
        floating: Bool
    ) {
        precondition(size.width > 0 && size.height > 0, "a window needs a size")

        self.kind = kind
        self.title = title
        self.size = size
        self.minimumSize = minimumSize
        self.resizable = resizable
        self.borderless = borderless
        self.floating = floating
    }
}

/// The AppKit seam: creating, raising, and closing real windows.
///
/// The coordinator owns the policy — geometry, which windows may coexist, and
/// which are visible — and the host owns the `NSWindow`s, so the policy is
/// provable without a window server.
@MainActor
public protocol WindowHost: AnyObject {
    func present(_ descriptor: WindowDescriptor)
    func focus(_ kind: WindowKind)
    func dismiss(_ kind: WindowKind)
    func isPresented(_ kind: WindowKind) -> Bool
}

/// Exactly one onboarding window, one main window, and an optional floating pet
/// window.
///
/// Onboarding and the main window are the same journey at two stages, so they
/// never coexist. The pet is the one window that does: it is a companion to
/// whatever else is open. Closing every window leaves the app running, because
/// the menu bar is the app.
@MainActor
public final class WindowCoordinator {
    private let host: any WindowHost
    private var occluded: Set<WindowKind> = []

    public init(host: any WindowHost) {
        self.host = host
    }

    public static func descriptor(for kind: WindowKind) -> WindowDescriptor {
        switch kind {
        case .onboarding:
            return WindowDescriptor(
                kind: .onboarding,
                title: ProductStrings[.windowOnboardingTitle],
                size: WindowMetrics.onboardingSize,
                minimumSize: nil,
                resizable: false,
                borderless: false,
                floating: false
            )
        case .main:
            return WindowDescriptor(
                kind: .main,
                title: ProductStrings[.windowMainTitle],
                size: WindowMetrics.mainDefaultSize,
                // The sidebar is fixed, so the floor is that plus a detail pane
                // wide enough for the two-column cards the surfaces draw.
                minimumSize: CGSize(width: WindowMetrics.sidebarWidth + 360, height: 420),
                resizable: true,
                borderless: false,
                floating: false
            )
        case .pet:
            return WindowDescriptor(
                kind: .pet,
                title: ProductStrings[.windowPetTitle],
                size: PetMetrics.windowSize,
                minimumSize: nil,
                resizable: false,
                borderless: true,
                floating: true
            )
        }
    }

    /// Opens a window, or raises the one that is already open.
    public func show(_ kind: WindowKind) {
        for excluded in Self.exclusive(with: kind) where host.isPresented(excluded) {
            close(excluded)
        }

        guard !host.isPresented(kind) else {
            host.focus(kind)
            return
        }

        host.present(Self.descriptor(for: kind))
        occluded.remove(kind)
        host.focus(kind)
    }

    public func close(_ kind: WindowKind) {
        occluded.remove(kind)
        host.dismiss(kind)
    }

    public func toggle(_ kind: WindowKind) {
        host.isPresented(kind) ? close(kind) : show(kind)
    }

    public func isOpen(_ kind: WindowKind) -> Bool {
        host.isPresented(kind)
    }

    /// Whether a window is actually on screen: open, and not covered,
    /// minimized, or on another Space. This is what pauses the pet's animation.
    public func isVisible(_ kind: WindowKind) -> Bool {
        host.isPresented(kind) && !occluded.contains(kind)
    }

    /// The occlusion observer's one entry point: records what the window server
    /// reported and answers whether that window is now actually on screen.
    ///
    /// The composition routes the report through here rather than straight to
    /// the pet, so `isVisible` is the single answer to "is this window on
    /// screen" instead of a seam nothing calls.
    @discardableResult
    public func visibilityChanged(_ visible: Bool, for kind: WindowKind) -> Bool {
        if visible {
            occluded.remove(kind)
        } else {
            occluded.insert(kind)
        }

        return isVisible(kind)
    }

    /// Onboarding and the main window are two stages of one journey, so opening
    /// either closes the other.
    private static func exclusive(with kind: WindowKind) -> [WindowKind] {
        switch kind {
        case .onboarding: return [.main]
        case .main: return [.onboarding]
        case .pet: return []
        }
    }
}
