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
    /// Whether the window shows its title in the titlebar.
    ///
    /// The host hides the title and makes the titlebar transparent for every
    /// window it builds, which is why the app used to draw a titlebar of its
    /// own. The primary window sets this and takes the system's unified
    /// titlebar instead (M34 §3.1).
    public let showsTitle: Bool
    /// Whether the window carries a minimize button at all.
    ///
    /// Omitted from the style mask rather than disabled, because AppKit draws no
    /// enabled/disabled state for a button the mask never asked for: a settings
    /// window sizes to the pane it is showing and has nothing to minimize to
    /// (M34 §3.1).
    public let minimizable: Bool
    /// Whether the zoom button is live. Dimmed rather than omitted, because the
    /// button sits between close and minimize and removing it would move the
    /// other two.
    public let zoomable: Bool
    /// The name AppKit saves this window's frame under, where it has one.
    ///
    /// M34 §3.1 autosaves the primary window as `main`, so it reopens where the
    /// operator left it. A fixed-size window has no frame worth remembering and
    /// carries none.
    public let frameAutosaveName: String?
    /// Whether macOS may restore this window on the next login.
    ///
    /// Presentation is resolved from current daemon state on launch, so
    /// restoring the primary window never resumes a stale assistant screen.
    public let restorable: Bool

    public init(
        kind: WindowKind,
        title: String,
        size: CGSize,
        minimumSize: CGSize?,
        resizable: Bool,
        borderless: Bool,
        floating: Bool,
        showsTitle: Bool = false,
        minimizable: Bool = true,
        zoomable: Bool = true,
        frameAutosaveName: String? = nil,
        restorable: Bool = true
    ) {
        precondition(size.width > 0 && size.height > 0, "a window needs a size")
        precondition(!(showsTitle && borderless), "a borderless window has no titlebar to show a title in")
        precondition(frameAutosaveName?.isEmpty != true, "a frame autosave name is absent or named")
        precondition(
            frameAutosaveName == nil || resizable,
            "a fixed-size window has no frame to remember"
        )
        precondition(
            !borderless || (!minimizable && !zoomable),
            "a borderless window has no window buttons to dim"
        )

        self.frameAutosaveName = frameAutosaveName
        self.restorable = restorable
        self.kind = kind
        self.title = title
        self.size = size
        self.minimumSize = minimumSize
        self.resizable = resizable
        self.borderless = borderless
        self.floating = floating
        self.showsTitle = showsTitle
        self.minimizable = minimizable
        self.zoomable = zoomable
    }

    /// The name M34 §3.1 publishes for the primary window's frame.
    public static let mainFrameAutosaveName = "main"
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
    /// Grows a window that is smaller than `size` up to it, animated, anchored
    /// at its top-left and clamped to the screen it is on (decision D3).
    ///
    /// A seam because the clamp needs the visible screen frame, which only
    /// AppKit can answer; the geometry itself is `WindowGrowth`, so the rule is
    /// provable without a window server.
    func grow(_ kind: WindowKind, toAtLeast size: CGSize)
}

/// One primary window for Home, Setup and Settings, plus an optional floating
/// pet. Closing every window leaves the menu bar app running.
@MainActor
public final class WindowCoordinator {
    private let host: any WindowHost
    private var occluded: Set<WindowKind> = []

    public init(host: any WindowHost) {
        self.host = host
    }

    public static func descriptor(for kind: WindowKind) -> WindowDescriptor {
        switch kind {
        case .main:
            return WindowDescriptor(
                kind: .main,
                title: ProductStrings[.windowMainTitle],
                size: WindowMetrics.mainDefaultSize,
                // One floor, whatever the sidebar is doing: settings runs in
                // this window and its pane column has to fit (decision D3).
                minimumSize: WindowMetrics.mainMinimumSize,
                resizable: true,
                borderless: false,
                floating: false,
                showsTitle: true,
                frameAutosaveName: WindowDescriptor.mainFrameAutosaveName
            )
        case .pet:
            return WindowDescriptor(
                kind: .pet,
                title: ProductStrings[.windowPetTitle],
                size: PetMetrics.windowSize,
                minimumSize: nil,
                resizable: false,
                borderless: true,
                floating: true,
                minimizable: false,
                zoomable: false
            )
        }
    }

    /// Opens a window, or raises the one that is already open.
    public func show(_ kind: WindowKind) {
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

    /// Entering settings grows the primary window to the size that shows a
    /// pane column beside a readable form (decision D3). A window already that
    /// big is left alone, and leaving settings never shrinks it back: a window
    /// that resizes twice per visit is worse than one that stays put.
    public func growForSettings() {
        host.grow(.main, toAtLeast: WindowMetrics.mainDefaultSize)
    }

    /// The assistant keeps its original content fit when Home was made smaller.
    /// A larger primary window stays at the size the user chose.
    public func growForAssistant() {
        host.grow(.main, toAtLeast: WindowMetrics.onboardingSize)
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

}
