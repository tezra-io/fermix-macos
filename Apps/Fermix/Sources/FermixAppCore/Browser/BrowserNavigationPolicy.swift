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
    /// Another app's link: the tab stays put, and the tab's owner rules on
    /// the app, which a person is asked about and a task never opens.
    case external
    /// A file to save, handed to the tab, whose owner rules on it: the
    /// person's is saved where they choose, and a task's never is.
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

    /// The schemes a file is saved from: the web's own, and `blob` and `data`
    /// for a file a page built itself. A download of any other scheme (another
    /// app's, `file`, `about`, `javascript`) is nothing a website offers.
    public static let downloadSchemes: Set<String> = ["http", "https", "blob", "data"]

    /// The decision, in order: a download is saved where its scheme is one a
    /// file is saved from, and never where a frame began it, since a hidden
    /// frame is how a page saves a file nobody asked for; a web page moves the
    /// tab or opens a new one; anything else belongs to another app, which is
    /// opened only for a click on the page itself. A frame or a script
    /// reaching for another app on its own is refused: that is how a page
    /// would launch an app nobody asked for.
    public static func decide(_ navigation: BrowserNavigation) -> BrowserNavigationDecision {
        guard !navigation.isDownload else { return isSavable(navigation) ? .download : .cancel }
        guard !isWeb(navigation.scheme) else { return navigation.targetsNewWindow ? .newTab : .allow }
        guard navigation.isMainFrame || navigation.targetsNewWindow, navigation.isUserInitiated else { return .cancel }

        return .external
    }

    private static func isSavable(_ download: BrowserNavigation) -> Bool {
        download.isMainFrame && downloadSchemes.contains(download.scheme.lowercased())
    }

    /// Whether a host is this Mac's own loopback address, in a spelling that
    /// cannot mean another machine to WebKit's URL parser: `localhost` in any
    /// case, with or without one trailing dot; an address in `127.0.0.0/8` as
    /// its canonical dotted quad; and `::1`, with or without its brackets.
    ///
    /// HTTPS-first never applies to one, as in every browser: a local server
    /// answers in the clear, nothing on the network stands between it and the
    /// page, and WebKit's https attempt on one ends in a blank page with no
    /// failure reported. A navigation there keeps the scheme it was asked with.
    ///
    /// Every other spelling is refused and keeps HTTPS-first. An IPv4 host
    /// counts only where `inet_ntop` gives back exactly what was written,
    /// because `inet_pton` reads `0127.0.0.1` as decimal where a URL parser
    /// reads the leading zero as octal and reaches another machine. A name
    /// under `.localhost` reaches this Mac only if the system resolver says
    /// so, which WebKit does not force. An IPv6 literal needs no round trip:
    /// its spelling has no octal or shorthand a URL parser reads another way.
    /// A zone id is refused outright: `inet_pton` accepts anything after a `%`
    /// and drops it, while a URL parser refuses a zone id, so no navigation
    /// carries one.
    public static func isLoopback(host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "localhost." { return true }
        if let address = canonicalIPv4(name) { return UInt32(bigEndian: address.s_addr) >> 24 == 127 }

        let literal = name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name
        var address = in6_addr()
        guard !literal.contains("%"), inet_pton(AF_INET6, literal, &address) == 1 else { return false }

        return withUnsafeBytes(of: address) { parsed in
            withUnsafeBytes(of: in6addr_loopback) { loopback in parsed.elementsEqual(loopback) }
        }
    }

    /// The IPv4 address `name` spells, where it spells it canonically: the
    /// dotted quad `inet_ntop` writes back for it, and nothing else.
    private static func canonicalIPv4(_ name: String) -> in_addr? {
        var address = in_addr()
        guard inet_pton(AF_INET, name, &address) == 1 else { return nil }

        let written = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(INET_ADDRSTRLEN)) { buffer in
            inet_ntop(AF_INET, &address, buffer.baseAddress, socklen_t(buffer.count)).map { String(cString: $0) }
        }
        return written == name ? address : nil
    }
}
