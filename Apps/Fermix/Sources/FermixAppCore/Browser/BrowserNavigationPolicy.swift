import Foundation

/// A navigation, as far as the policy needs to know it.
public struct BrowserNavigation: Equatable, Sendable {
    /// The destination's scheme, in whatever case the page wrote it.
    public let scheme: String
    /// A `target=_blank` link or `window.open`: the page asked for a window of
    /// its own rather than for this one to move.
    public let targetsNewWindow: Bool
    /// The response is a file to save rather than a page to show, or the link
    /// asked to be downloaded.
    public let isDownload: Bool
    /// The navigation moves the tab itself rather than a frame inside it.
    public let isMainFrame: Bool
    /// A person clicked or submitted something; a script did not do it alone.
    public let isUserInitiated: Bool

    public init(
        scheme: String,
        targetsNewWindow: Bool = false,
        isDownload: Bool = false,
        isMainFrame: Bool = true,
        isUserInitiated: Bool = true
    ) {
        self.scheme = scheme
        self.targetsNewWindow = targetsNewWindow
        self.isDownload = isDownload
        self.isMainFrame = isMainFrame
        self.isUserInitiated = isUserInitiated
    }
}

/// What the pane does with a navigation.
public enum BrowserNavigationDecision: Equatable, Sendable {
    /// The tab goes there.
    case allow
    /// The page gets a tab of its own for it.
    case newTab
    /// The Mac's own app for the scheme opens it, and the tab stays put.
    case external
    /// The response is saved as a file, where the tab's owner says.
    case download
    /// Nothing happens.
    case cancel
}

/// Where a navigation goes (plan §4.2): pure, so every rule is provable
/// without a web view. The WebKit page asks it and does what it answers.
public enum BrowserNavigationPolicy {
    /// The schemes a web page is made of. `about` carries blank tabs and
    /// `srcdoc` frames, `blob` and `data` carry content a page built itself,
    /// and `file` is left to WebKit's own rule, which refuses a file a web page
    /// was not given.
    public static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript", "file"]

    public static func isWeb(_ scheme: String) -> Bool {
        webSchemes.contains(scheme.lowercased())
    }

    /// The decision, in order: a download is saved, unless a frame began it,
    /// since a hidden frame is how a page saves a file nobody asked for; a
    /// web page moves the tab or opens a new one; anything else belongs to
    /// another app, which is opened only for a click on the page itself. A
    /// frame or a script reaching for another app on its own is refused: that
    /// is how a page would launch an app nobody asked for.
    public static func decide(_ navigation: BrowserNavigation) -> BrowserNavigationDecision {
        guard !navigation.isDownload else { return navigation.isMainFrame ? .download : .cancel }
        guard !isWeb(navigation.scheme) else { return navigation.targetsNewWindow ? .newTab : .allow }
        guard navigation.isMainFrame || navigation.targetsNewWindow, navigation.isUserInitiated else { return .cancel }

        return .external
    }
}
