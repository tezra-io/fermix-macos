import Foundation

/// The one place a content link is opened (plan §4.5): a link in a reply, and
/// every surface that shows the owner's content after it.
///
/// A web page goes where the person's preference says, the pane or their own
/// browser; a file on this Mac goes to the pane's own rule for files
/// (`BrowserCoordinator.openFile`) whatever the preference, which is about web
/// pages; any other scheme belongs to an app on the Mac and goes there
/// whatever the preference, because the pane has nothing to show for it.
///
/// Provider sign-in and the prior installer never come here. They are not
/// content, and `ExternalOpening` stays their only way out of the app: a
/// sign-in's authorize address must reach the person's own browser, never the
/// pane, where the page could not be trusted with it.
@MainActor
public final class ContentLinkOpener {
    private let preference: any LinkPreferenceStoring
    private let browser: BrowserCoordinator
    private let workspace: any WorkspaceLinkOpening

    public init(
        preference: any LinkPreferenceStoring,
        browser: BrowserCoordinator,
        workspace: any WorkspaceLinkOpening
    ) {
        self.preference = preference
        self.browser = browser
        self.workspace = workspace
    }

    /// The schemes the pane opens from a link. A page itself may move to more
    /// (`BrowserNavigationPolicy.webSchemes`), but a link a person clicks in a
    /// reply is a web page or it is another app's.
    public static let paneSchemes: Set<String> = ["http", "https"]

    /// Where a link that is not a file goes, by its scheme and the
    /// preference.
    public static func destination(of url: URL, preferring preference: LinkDestination) -> LinkDestination {
        guard let scheme = url.scheme?.lowercased(), paneSchemes.contains(scheme) else { return .system }

        return preference
    }

    /// A file never goes straight to the Mac: handed to the workspace, a
    /// script opens in Terminal and runs, and an app launches.
    public func open(_ url: URL) {
        guard !url.isFileURL else {
            browser.openFile(url)
            return
        }

        switch Self.destination(of: url, preferring: preference.linkDestination) {
        case .fermix: browser.open(url)
        case .system: _ = workspace.open(url)
        }
    }
}
