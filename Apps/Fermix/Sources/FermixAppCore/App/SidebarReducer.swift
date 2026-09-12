import Foundation

/// Which columns the primary window is showing.
///
/// Two values, not `NavigationSplitViewVisibility`'s four: the window has one
/// sidebar and one detail pane, so `automatic` and `doubleColumn` are the same
/// answer as `all` here and are normalized at the SwiftUI boundary.
public enum SidebarVisibility: String, CaseIterable, Sendable {
    case all
    case detailOnly

    public var showsSidebar: Bool { self == .all }
}

/// Everything the sidebar's collapse rule knows.
///
/// `collapsedByWidth` and `hiddenByUser` are separate because the two collapses
/// mean opposite things: one is the window being narrow and is reversible by
/// widening it, the other is a decision and outlives every resize.
public struct SidebarState: Equatable, Sendable {
    public let visibility: SidebarVisibility
    /// True while the width rule owns this collapse, which is the only state
    /// the width rule may restore from.
    public let collapsedByWidth: Bool
    /// True once the user hid the sidebar by hand. Width never overrides it.
    public let hiddenByUser: Bool

    public init(visibility: SidebarVisibility, collapsedByWidth: Bool, hiddenByUser: Bool) {
        precondition(
            !(collapsedByWidth && hiddenByUser),
            "a collapse is the width rule's or the user's, never both"
        )
        precondition(
            visibility == .detailOnly || !(collapsedByWidth || hiddenByUser),
            "a collapsed reason cannot be recorded against a shown sidebar"
        )

        self.visibility = visibility
        self.collapsedByWidth = collapsedByWidth
        self.hiddenByUser = hiddenByUser
    }
}

/// What can change the sidebar.
public enum SidebarEvent: Equatable, Sendable {
    /// The window's content width, reported by the root's geometry.
    case widthChanged(Double)
    /// The toolbar toggle, the View menu item, or a drag: all three land here,
    /// because all three are the user saying what they want.
    case userSet(SidebarVisibility)
    /// The split view collapsed the sidebar itself because the window cannot
    /// hold both columns. It is the width rule's collapse wearing SwiftUI's
    /// clothes, so it is reversible and is never persisted as a decision.
    case systemCollapsed
}

/// The collapse rule, as a pure function (M34 §6).
///
/// It is a reducer rather than logic inside the view because "collapse below
/// `collapseWidth`, restore above `restoreWidth`, never override an explicit
/// hide" is exactly the kind of rule that is invisible in a view body and
/// provable as a value. The two widths are named below and stated nowhere else,
/// so this sentence cannot go stale against them again.
public enum SidebarReducer {
    /// Below this the sidebar collapses.
    ///
    /// The offsets are the design's, carried onto decision D3's 760 pt window
    /// minimum: collapse 80 pt above the floor, restore 140 pt above it. Left
    /// at the old 720 and 780 both would be dead, because a window that can
    /// never be narrower than 760 can never cross 720.
    public static let collapseWidth: Double = 840
    /// Above this it comes back, but only from a width-driven collapse. The
    /// band between the two is what stops a window parked on the threshold
    /// flickering, and it is 60 pt as it was before.
    public static let restoreWidth: Double = 900

    /// First launch shows the sidebar. A persisted hide is the only thing that
    /// starts the window collapsed (M34 §6: never hidden by default).
    public static func initial(persistedVisible: Bool?) -> SidebarState {
        if persistedVisible == false {
            return SidebarState(visibility: .detailOnly, collapsedByWidth: false, hiddenByUser: true)
        }

        return SidebarState(visibility: .all, collapsedByWidth: false, hiddenByUser: false)
    }

    public static func reduce(_ state: SidebarState, _ event: SidebarEvent) -> SidebarState {
        switch event {
        case .userSet(let visibility):
            return SidebarState(
                visibility: visibility,
                collapsedByWidth: false,
                hiddenByUser: visibility == .detailOnly
            )
        case .widthChanged(let width):
            return applyWidth(width, to: state)
        case .systemCollapsed:
            guard state.visibility == .all else { return state }

            return SidebarState(visibility: .detailOnly, collapsedByWidth: true, hiddenByUser: false)
        }
    }

    private static func applyWidth(_ width: Double, to state: SidebarState) -> SidebarState {
        if width < collapseWidth, state.visibility == .all {
            return SidebarState(visibility: .detailOnly, collapsedByWidth: true, hiddenByUser: false)
        }

        if width > restoreWidth, state.collapsedByWidth {
            return SidebarState(visibility: .all, collapsedByWidth: false, hiddenByUser: false)
        }

        return state
    }
}

/// Where the explicit hide is remembered.
///
/// Only the user's own decision is stored; a width-driven collapse is a
/// property of the window's current size and is recomputed on the next launch
/// from the window's restored frame.
@MainActor
public protocol SidebarVisibilityStoring: AnyObject {
    /// The stored choice, or nil where the user has never made one.
    var sidebarVisible: Bool? { get set }
}

/// The shipped store. The key is M34 §6's `main.sidebar.visible`.
@MainActor
public final class UserDefaultsSidebarStore: SidebarVisibilityStoring {
    public static let key = "main.sidebar.visible"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var sidebarVisible: Bool? {
        get {
            guard defaults.object(forKey: Self.key) != nil else { return nil }

            return defaults.bool(forKey: Self.key)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.key)
                return
            }

            defaults.set(newValue, forKey: Self.key)
        }
    }
}

/// The sidebar's live state, owned once so it survives a view rebuild.
///
/// The view binds to `visibility` and reports the root's width; it decides
/// nothing. `visibilityWritten` is where a write from SwiftUI is judged to be a
/// person or the split view's own collapse, and only the first is persisted.
/// That split is what keeps a narrow window from being recorded as a decision
/// the width rule can then never undo.
@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var state: SidebarState

    private let store: any SidebarVisibilityStoring
    /// The last width the root reported. It is the arbiter for a collapse
    /// SwiftUI writes: nothing else distinguishes the user pressing the system
    /// toggle from the split view collapsing itself.
    private var reportedWidth: Double = 0

    public init(store: any SidebarVisibilityStoring) {
        self.store = store
        self.state = SidebarReducer.initial(persistedVisible: store.sidebarVisible)
    }

    public var visibility: SidebarVisibility { state.visibility }

    /// The user asked for a visibility, from whichever of the three system ways.
    public func userSet(_ visibility: SidebarVisibility) {
        apply(.userSet(visibility))
        store.sidebarVisible = visibility.showsSidebar
    }

    public func toggle() {
        userSet(state.visibility == .all ? .detailOnly : .all)
    }

    public func widthChanged(_ width: Double) {
        guard width > 0 else { return }

        reportedWidth = width
        apply(.widthChanged(width))
    }

    /// SwiftUI wrote the visibility through the window's binding.
    ///
    /// Two different things arrive here: the user pressing the system toggle or
    /// dragging the divider closed, and the split view collapsing the sidebar on
    /// its own because the window is too narrow to hold both columns. Only the
    /// first is a decision, and recording the second as one would make it
    /// permanent — `SidebarReducer` never restores an explicit hide.
    ///
    /// The width is the only thing that tells them apart: the split view can
    /// only auto-collapse where the window is too narrow, which is at or below
    /// the width the app's own rule already collapses at. Above that width the
    /// write is a person's; at or below it the width rule owns the answer.
    public func visibilityWritten(_ visibility: SidebarVisibility) {
        guard visibility != state.visibility else { return }

        if visibility.showsSidebar || reportedWidth > SidebarReducer.collapseWidth {
            userSet(visibility)
            return
        }

        apply(.systemCollapsed)
    }

    private func apply(_ event: SidebarEvent) {
        let next = SidebarReducer.reduce(state, event)
        guard next != state else { return }

        state = next
    }
}
