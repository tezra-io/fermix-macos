#if DEBUG
import AppKit
import Foundation

/// The browser the fixture configuration stands on: fake pages that never
/// touch the network, so the pane can be looked at in a build with no web
/// engine behind it and on a Mac with no connection.
///
/// A page knows two addresses, draws each as a plain white page with its
/// heading, and walks back and forward over what it was asked to load, which
/// is enough for the tab strip, the address capsule, the lock glyph and the
/// navigation controls to be seen in every state.
@MainActor
final class FixtureBrowserEngine: BrowserEngine {
    func makeTab(profile: BrowserProfile) -> BrowserTab {
        BrowserTab(profile: profile, page: FixtureBrowserPage())
    }
}

/// The two pages the fixture tabs open, by address.
enum FixtureWebPage {
    static let example = address("https://example.com/")
    static let reserved = address("https://www.iana.org/domains/reserved")

    /// The `browser` start's pane: the first page as a link opens it, and the
    /// second typed into a private tab, both through the coordinator's own
    /// verbs, with the first in front.
    @MainActor
    static func openTabs(in browser: BrowserCoordinator) {
        browser.open(example)
        browser.newTab(profile: .private)
        browser.load(address: reserved.absoluteString)
        guard let first = browser.model.tabs.first else { return }

        browser.select(first)
    }

    private static func address(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("a fixture page has an address: \(text)") }

        return url
    }

    static func content(of url: URL) -> (title: String, heading: String, body: String) {
        guard url == reserved else {
            return (
                "Example Domain",
                "Example Domain",
                "This domain is for use in documentation examples without needing permission."
            )
        }

        return (
            "IANA-managed Reserved Domains",
            "IANA-managed Reserved Domains",
            "Certain domains are set aside, and nominally registered to IANA, for specific policy or technical purposes."
        )
    }
}

/// One fake page: a history, and a white view carrying the heading and the
/// text of whatever it was last asked to load.
@MainActor
final class FixtureBrowserPage: BrowserPage {
    weak var events: (any BrowserPageEvents)?

    private let page = FixturePageView()
    private var history: [URL] = []
    private var position = -1

    var view: NSView { page }

    func load(_ url: URL) {
        history = Array(history.prefix(position + 1)) + [url]
        position = history.count - 1
        show()
    }

    func back() {
        guard position > 0 else { return }

        position -= 1
        show()
    }

    func forward() {
        guard position < history.count - 1 else { return }

        position += 1
        show()
    }

    func reload() { show() }
    func stop() {}
    func find(_ text: String) {}
    func zoom(_ zoom: BrowserZoom) {}

    private func show() {
        let url = history[position]
        let content = FixtureWebPage.content(of: url)
        page.show(heading: content.heading, body: content.body)
        events?.pageChanged(
            BrowserPageState(
                url: url,
                title: content.title,
                isLoading: false,
                estimatedProgress: 1,
                canGoBack: position > 0,
                canGoForward: position < history.count - 1,
                hasOnlySecureContent: url.scheme == "https"
            )
        )
    }
}

/// A web page's own ground and type, which are the page's and not the app's:
/// white in both appearances, as a page with no dark style of its own is.
@MainActor
final class FixturePageView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        heading.font = .systemFont(ofSize: 28, weight: .semibold)
        heading.textColor = .black
        body.font = .systemFont(ofSize: 15)
        body.textColor = NSColor(white: 0.25, alpha: 1)

        let column = NSStackView(views: [heading, body])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 64),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("the fixture page is built in code")
    }

    override var isFlipped: Bool { true }

    func show(heading text: String, body paragraph: String) {
        heading.stringValue = text
        body.stringValue = paragraph
    }
}

/// The Mac's opener, not opened: a fixture run must not send the operator to
/// another app.
struct FixtureWorkspaceOpener: WorkspaceLinkOpening {
    func open(_ url: URL) -> Bool { true }
}
#endif
