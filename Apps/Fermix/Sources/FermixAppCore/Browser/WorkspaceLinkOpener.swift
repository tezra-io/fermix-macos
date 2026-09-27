import AppKit
import Foundation

/// Handing a link to the Mac: the default browser for a web page, and the app
/// that owns any other scheme, such as Mail for `mailto:`.
///
/// Content only: a link in a reply, the page the pane is showing, a scheme a
/// page reached for. Provider sign-in and the prior installer are not content
/// and never come here; they keep `ExternalOpening`, their own two hops.
@MainActor
public protocol WorkspaceLinkOpening {
    /// Whether an app on this Mac took the link.
    func open(_ url: URL) -> Bool
}

/// The production opener, through the workspace.
public struct WorkspaceLinkOpener: WorkspaceLinkOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
