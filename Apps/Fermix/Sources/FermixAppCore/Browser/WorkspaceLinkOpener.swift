import AppKit
import Foundation

/// Handing a link to the Mac: the default browser for a web page, and the app
/// that owns any other scheme, such as Mail for `mailto:`. A file goes to the
/// app that opens it, or is shown in Finder where opening it would run it.
///
/// Content only: a link in a reply, the page the pane is showing, a scheme a
/// page reached for. Provider sign-in and the prior installer are not content
/// and never come here; they keep `ExternalOpening`, their own two hops.
@MainActor
public protocol WorkspaceLinkOpening {
    /// Whether an app on this Mac took the link.
    func open(_ url: URL) -> Bool
    /// The name of the app on this Mac that would take the link, as Finder
    /// shows it, or nil where none would.
    func appName(toOpen url: URL) -> String?
    /// A file, selected in a Finder window, and nothing opened: what an app,
    /// an executable or a script gets instead of running.
    func reveal(_ url: URL)
}

/// The production opener, through the workspace.
public struct WorkspaceLinkOpener: WorkspaceLinkOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    public func appName(toOpen url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path) }
    }

    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
