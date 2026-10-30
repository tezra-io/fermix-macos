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
@MainActor
final class BrowserPageHarness: NSObject, WKNavigationDelegate {
    let page: WebKitBrowserPage
    /// Every navigation the page tried on its own, cancelled before it left.
    private(set) var refusedNavigations: [URL] = []
    private var loading: CheckedContinuation<Void, any Error>?

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
            webView.loadHTMLString(html, baseURL: url)
        }
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
        guard loading != nil else {
            if let url = action.request.url { refusedNavigations.append(url) }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        page.resolveReadyWaiters(.success(()))
        finishLoading(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishLoading(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
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
