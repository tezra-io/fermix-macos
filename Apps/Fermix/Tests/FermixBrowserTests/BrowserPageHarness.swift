import FermixAppCore
import Foundation
import WebKit

@testable import FermixBrowser

/// One real `WebKitBrowserPage`, in no window, loaded from a string under an
/// `https` base address, for the page script and its WebKit half.
///
/// Nothing leaves the Mac: the harness is the web view's navigation delegate,
/// lets through only the loads it starts itself, and cancels and records
/// every other navigation, a form's submission among them. Subresources are
/// never asked for: the pages are inline.
///
/// Every load it starts is one the page asked for (`follow`), as the tab's
/// own are. It hands the start, the commit, the finish and the failure of
/// every load to the page's own delegate methods, which count navigations
/// and release or fail the page's waiters, and can hold a load of its own at
/// WebKit's policy decision for it, or for its response, so a case sees a
/// navigation in flight for as long as it likes.
@MainActor
final class BrowserPageHarness: NSObject, WKNavigationDelegate {
    let page: WebKitBrowserPage
    /// Every navigation the page tried on its own, cancelled before it left.
    private(set) var refusedNavigations: [URL] = []
    private var loading: CheckedContinuation<Void, any Error>?
    /// `hold` waiting for WebKit to ask about its load.
    private var holding: CheckedContinuation<Void, Never>?
    /// The decision `hold` keeps WebKit waiting on, until `release`.
    private var heldDecision: (@MainActor (WKNavigationActionPolicy) -> Void)?
    /// Whether the next navigation is let through, one the page starts on
    /// its own included, with its response held for `releaseResponse`.
    private var holdsNextResponse = false
    /// `holdResponse` waiting for WebKit to ask about that response.
    private var awaitingResponse: CheckedContinuation<Void, Never>?
    /// The response decision `holdResponse` keeps WebKit waiting on, until
    /// `releaseResponse`.
    private var heldResponse: (@MainActor (WKNavigationResponsePolicy) -> Void)?
    /// What `releaseResponse` answered before the response it holds arrived,
    /// given to that response as soon as it does.
    private var earlyResponseAnswer: WKNavigationResponsePolicy?
    /// Whether the next navigation is let through with nothing held: one
    /// `move(within:readAccess:)` starts.
    private var allowsNext = false
    /// Whether WebKit still reported a load in flight as it told of each
    /// finish, failure and interruption, in order.
    private(set) var loadingAtEnd: [Bool] = []
    /// Every navigation WebKit told of finishing, in order.
    private(set) var finished: [WKNavigation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        page = WebKitBrowserPage(configuration: configuration, fileRules: nil, inspectable: false)
        super.init()
        page.webView.navigationDelegate = self
    }

    var webView: WKWebView { page.webView }

    /// Loads `html` as the document at `address`, and returns once it has
    /// finished, bounded by WebKit's own load failure.
    func load(_ html: String, at address: String) async throws {
        let url = try requireURL(address)
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            page.follow(webView.loadHTMLString(html, baseURL: url))
        }
    }

    /// Loads the file at `file` and returns once it has finished, as `load`
    /// does: a load from disk, which takes an entry in the page's history.
    func load(file: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            page.follow(webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()))
        }
    }

    /// Starts a load of `url`, a place within the file the page shows, with
    /// read access to `folder`, and returns at once: WebKit moves within the
    /// document and tells of no commit and no finish for it.
    func move(within url: URL, readAccess folder: URL) {
        allowsNext = true
        page.follow(webView.loadFileURL(url, allowingReadAccessTo: folder))
    }

    /// Starts loading `html` as the document at `address` and returns once
    /// WebKit asks whether it may, leaving it unanswered: from here until
    /// `release`, the web view reports the load in flight and `webView.url`
    /// names it, while the page before it is still the one shown. Every case
    /// that holds a load releases it, since WebKit faults a decision it never
    /// gets.
    func hold(_ html: String, at address: String) async throws {
        let url = try requireURL(address)
        await withCheckedContinuation { continuation in
            holding = continuation
            page.follow(webView.loadHTMLString(html, baseURL: url))
        }
    }

    /// Starts loading the file at `file` and holds it as `hold` does.
    func hold(file: URL) async {
        await withCheckedContinuation { continuation in
            holding = continuation
            page.follow(webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()))
        }
    }

    /// Answers the load `hold` left waiting: `.allow` lets it go on, and
    /// `.cancel` drops it. With nothing held it does nothing.
    func release(_ policy: WKNavigationActionPolicy) {
        let decision = heldDecision
        heldDecision = nil
        decision?(policy)
    }

    /// Starts loading the file at `file` and returns once WebKit asks whether
    /// its response may be shown, leaving that unanswered: the navigation has
    /// started and stays in flight until `releaseResponse`. Every case that
    /// holds a response releases it.
    func holdResponse(file: URL) async {
        holdNextResponse()
        await withCheckedContinuation { continuation in
            awaitingResponse = continuation
            page.follow(webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()))
        }
    }

    /// Lets the next navigation through, one the page starts on its own
    /// included, and holds its response until `releaseResponse`: from its
    /// start the web view reports it in flight.
    func holdNextResponse() {
        holdsNextResponse = true
    }

    /// Whether a response is held, or will be once it arrives.
    var holdsResponse: Bool { heldResponse != nil || holdsNextResponse }

    /// Answers the response held for `releaseResponse`: `.allow` shows it,
    /// and `.cancel` interrupts the load, as a download does. A response
    /// still on its way is answered as soon as it arrives; with nothing held
    /// or awaited it does nothing.
    func releaseResponse(_ policy: WKNavigationResponsePolicy) {
        guard let decision = heldResponse else {
            if holdsNextResponse { earlyResponseAnswer = policy }
            return
        }

        heldResponse = nil
        decision(policy)
    }

    /// The page script's own answer to one of its functions, decoded.
    func call<Answer: Decodable>(_ function: String, _ arguments: [Any], as: Answer.Type = Answer.self) async throws -> Answer {
        try await page.pageScriptResult.get().call(function, arguments, as: Answer.self)
    }

    /// Runs `body` as the page's own script would, in the page's world: the
    /// site's code, not Fermix's.
    @discardableResult
    func pageWorld(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if let holding {
            self.holding = nil
            heldDecision = decisionHandler
            holding.resume()
            return
        }
        if allowsNext {
            allowsNext = false
            decisionHandler(.allow)
            return
        }
        guard loading != nil || holdsNextResponse else {
            if let url = action.request.url { refusedNavigations.append(url) }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        guard holdsNextResponse else {
            decisionHandler(.allow)
            return
        }

        holdsNextResponse = false
        let awaiting = awaitingResponse
        awaitingResponse = nil
        if let answer = earlyResponseAnswer {
            earlyResponseAnswer = nil
            decisionHandler(answer)
        } else {
            heldResponse = decisionHandler
        }
        awaiting?.resume()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        page.webView(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        page.webView(webView, didCommit: navigation)
    }

    /// A finished load goes to the page first, which releases its waiters,
    /// and then to the case waiting in `load`, if any.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingAtEnd.append(webView.isLoading)
        if let navigation { finished.append(navigation) }
        page.webView(webView, didFinish: navigation)
        finishLoading(.success(()))
    }

    /// A failed load goes to the page first, which fails its waiters or,
    /// for an interruption, releases them, and then to the case waiting in
    /// `load`, if any.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadingAtEnd.append(webView.isLoading)
        page.webView(webView, didFail: navigation, withError: error)
        finishLoading(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadingAtEnd.append(webView.isLoading)
        page.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        finishLoading(.failure(error))
    }

    private func finishLoading(_ result: Result<Void, any Error>) {
        let continuation = loading
        loading = nil
        continuation?.resume(with: result)
    }
}

/// A test page's address, which every case writes as a literal.
func requireURL(_ address: String) throws -> URL {
    guard let url = URL(string: address) else { throw HarnessDefect.notAnAddress(address) }

    return url
}

enum HarnessDefect: Error {
    case notAnAddress(String)
}
