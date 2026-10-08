import AppKit
import Foundation
import UniformTypeIdentifiers

/// An app on this Mac: where it is, and its name as Finder shows it.
public struct WorkspaceApplication: Equatable, Sendable {
    public let url: URL
    public let name: String

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

/// Handing a link to the Mac: the default browser for a web page, and the app
/// that owns any other scheme, such as Mail for `mailto:`. A file is never
/// handed over by its path alone: it goes to an app named before the open, or
/// is shown in Finder.
///
/// Content only: a link in a reply, the page the pane is showing, a scheme a
/// page reached for. Provider sign-in and the prior installer are not content
/// and never come here; they keep `ExternalOpening`, their own two hops.
@MainActor
public protocol WorkspaceLinkOpening {
    /// Whether an app on this Mac took the link. Never a file: Launch
    /// Services would choose by whatever is at the path when it opens, and a
    /// file swapped in since would be launched or run.
    func open(_ url: URL) -> Bool
    /// The app on this Mac that would take the link, or nil where none would.
    func application(toOpen url: URL) -> WorkspaceApplication?
    /// The app on this Mac that opens a document of `type`, or nil where none
    /// does. Asked of the type the pane decided on, never of the file, so a
    /// file swapped in afterwards cannot change the answer.
    func application(toOpen type: UTType) -> WorkspaceApplication?
    /// Whether the app opens web pages: a browser given a file runs its
    /// scripts and reaches the network, which a file tab exists to prevent.
    func opensWebPages(_ app: WorkspaceApplication) -> Bool
    /// A file, handed to exactly this app as a document: whatever is at the
    /// path by then is a document to that app, never launched or run.
    /// `failed` hears the system's sentence where the app could not take it.
    func open(_ file: URL, withApplicationAt app: URL, failed: @escaping @MainActor (String) -> Void)
    /// A file, selected in a Finder window, and nothing opened.
    func reveal(_ url: URL)
}

/// The production opener, through the workspace.
public struct WorkspaceLinkOpener: WorkspaceLinkOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    public func application(toOpen url: URL) -> WorkspaceApplication? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map(Self.application(at:))
    }

    public func application(toOpen type: UTType) -> WorkspaceApplication? {
        NSWorkspace.shared.urlForApplication(toOpen: type).map(Self.application(at:))
    }

    /// Every app that takes an https link, the default browser and any other.
    public func opensWebPages(_ app: WorkspaceApplication) -> Bool {
        NSWorkspace.shared.urlsForApplications(toOpen: Self.webPage)
            .contains { $0.standardizedFileURL == app.url.standardizedFileURL }
    }

    private static func application(at url: URL) -> WorkspaceApplication {
        WorkspaceApplication(url: url, name: FileManager.default.displayName(atPath: url.path))
    }

    private static let webPage: URL = {
        guard let url = URL(string: "https://example.com/") else { preconditionFailure("a web address parses") }

        return url
    }()

    public func open(_ file: URL, withApplicationAt app: URL, failed: @escaping @MainActor (String) -> Void) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let reason = error?.localizedDescription else { return }

            Task { @MainActor in failed(reason) }
        }
    }

    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
