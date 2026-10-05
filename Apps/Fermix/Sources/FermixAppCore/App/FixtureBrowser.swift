#if DEBUG
import AppKit
import Darwin
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
    let hostWindow: any BrowserPageStage = FixtureHostWindow()

    func makeTab(profile: BrowserProfile) -> BrowserTab {
        BrowserTab(profile: profile, page: FixtureBrowserPage())
    }

    /// No file dialog: a fake page has no upload field, and a fixture run
    /// raises nothing over the operator's window.
    func chooseFiles(_ request: BrowserFileRequest, for page: NSView, answer: @escaping @MainActor ([URL]?) -> Void) {
        answer(nil)
    }

    /// No save panel either: a fake page downloads nothing.
    func chooseSaveDestination(_ filename: String, for page: NSView, answer: @escaping @MainActor (URL?) -> Void) {
        answer(nil)
    }

    /// Fake pages hold nothing to let go.
    func releaseIdle() {}
}

/// The fixture attaches to no daemon, so no task ever has a page to hold.
@MainActor
final class FixtureHostWindow: BrowserPageStage {
    func hold(_ page: NSView) {
        preconditionFailure("the fixture runs no task, so no page runs in the host window")
    }

    func release(_ page: NSView) {
        preconditionFailure("the fixture runs no task, so no page runs in the host window")
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

    /// A file is drawn as its name over its path: the fixture reads nothing
    /// from the operator's disk.
    static func content(of url: URL) -> (title: String, heading: String, body: String) {
        guard !url.isFileURL else { return (url.lastPathComponent, url.lastPathComponent, url.path) }
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
///
/// The view is built the first time the pane shows it, so a test that drives
/// the page's navigation never touches AppKit.
@MainActor
final class FixtureBrowserPage: BrowserPage {
    weak var events: (any BrowserPageEvents)?

    private var built: FixturePageView?
    private var history: [URL] = []
    private var position = -1

    var view: NSView {
        let page = built ?? FixturePageView()
        built = page
        draw(page)

        return page
    }

    func load(_ url: URL) {
        history = Array(history.prefix(position + 1)) + [url]
        position = history.count - 1
        show()
    }

    /// A file walks the history as a page does, whatever its kind.
    func loadFile(_ url: URL, as kind: BrowserFileKind) {
        load(url)
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

    private func draw(_ page: FixturePageView) {
        guard history.indices.contains(position) else { return }

        let content = FixtureWebPage.content(of: history[position])
        page.show(heading: content.heading, body: content.body)
    }

    private func show() {
        let url = history[position]
        let content = FixtureWebPage.content(of: url)
        if let built { draw(built) }
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
    /// No app is named, so a fixture page never asks to leave for one.
    func appName(toOpen url: URL) -> String? { nil }
    /// Finder is another app too.
    func reveal(_ url: URL) {}
}

/// The browser host socket, never dialed: the fixture drives its two tabs
/// locally (`FixtureWebPage.openTabs`), so there is nothing for a daemon to
/// attach to and no socket to fail interestingly. Every connect answers as an
/// engine that predates the wire would.
final class FixtureBrowserHostTransport: LineSocketTransport, @unchecked Sendable {
    var onMessage: ((BrowserHostInbound) -> Void)?
    var onFailure: ((LineSocketFailure<BrowserHostDecodeFailure>) -> Void)?

    func connect(path: String, completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void) {
        completion(.failure(.system(errno: ENOENT)))
    }

    func send(_ line: Data) {}
    func sendDroppable(_ line: Data) {}
    func sendDroppable(producing line: @escaping @Sendable () -> Data) {}
    func close() {}
}
#endif
