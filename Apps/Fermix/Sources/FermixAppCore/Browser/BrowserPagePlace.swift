import Foundation

/// How much of the pane the person can see.
public enum BrowserPaneVisibility: Equatable, Sendable {
    /// The pane is closed, or has no page area built yet.
    case hidden
    /// The pane is open in a window that is covered, minimised or on another
    /// Space, which the window's occlusion state says and SwiftUI cannot.
    case covered
    case onScreen
}

/// Where a tab's page is (plan §4.10).
public enum BrowserPagePlace: Equatable, Sendable {
    case pane
    case hostWindow
    /// Out of every window: a person's tab behind another, or in a hidden
    /// pane, as a tab behind another always was.
    case nowhere

    /// A task's page is always in a window, so it keeps running as a visible
    /// page: in the pane while it is in front of a pane on screen, and in the
    /// host window otherwise. The person's page is in the pane while it is in
    /// front of an open pane, and nowhere otherwise.
    public static func of(owner: BrowserTabOwner, inFront: Bool, pane: BrowserPaneVisibility) -> BrowserPagePlace {
        switch (owner, pane) {
        case (.task, .onScreen):
            return inFront ? .pane : .hostWindow
        case (.task, .hidden), (.task, .covered):
            return .hostWindow
        case (.person, .onScreen), (.person, .covered):
            return inFront ? .pane : .nowhere
        case (.person, .hidden):
            return .nowhere
        }
    }
}
