import AppKit
import FermixAppCore
import WebKit

/// One tab's page, on a `WKWebView`.
///
/// It decides nothing. Where a navigation goes is `BrowserNavigationPolicy`'s,
/// which it asks for every navigation and every window a page opens; what the
/// tab shows is what the web view reports through key-value observation; and
/// everything a page asks of the person goes to the tab as an event.
@MainActor
final class WebKitBrowserPage: NSObject, BrowserPage {
    weak var events: (any BrowserPageEvents)?

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    /// The page script, lazily resolved once and reused: `WebKitBrowserPage
    /// +Driving.swift` is the one reader.
    lazy var pageScriptResult = Result { WebKitPageScript(webView: webView, source: try BrowserPageScript.source()) }
    /// The path an in-flight `upload` action expects the next open panel to
    /// answer with; `runOpenPanelWith` below is the one reader.
    var pendingUploadPath: String?
    /// Every call parked in `waitUntilReady()` for the navigation in flight
    /// when it was made; `didFinish` and `didFail` are what resolve them
    /// (`WebKitBrowserPage+Driving.swift` is the one caller).
    var readyWaiters: [ReadyWaiter] = []

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // Link previews are off (plan §4.4): a force click would load the
        // destination in a preview the navigation policy never saw.
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
    }

    var view: NSView { webView }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }
    func find(_ text: String) { webView.find(text, configuration: WKFindConfiguration()) { _ in } }
    func zoom(_ zoom: BrowserZoom) { webView.pageZoom = zoom.factor(from: webView.pageZoom) }

    /// Every published property the tab shows, each reporting the whole state.
    private func observe() {
        let report: (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        observations = [
            webView.observe(\.url) { view, _ in report(view) },
            webView.observe(\.title) { view, _ in report(view) },
            webView.observe(\.isLoading) { view, _ in report(view) },
            webView.observe(\.estimatedProgress) { view, _ in report(view) },
            webView.observe(\.canGoBack) { view, _ in report(view) },
            webView.observe(\.canGoForward) { view, _ in report(view) },
            webView.observe(\.hasOnlySecureContent) { view, _ in report(view) }
        ]
    }

    private func report() {
        events?.pageChanged(
            BrowserPageState(
                url: webView.url,
                title: webView.title ?? "",
                isLoading: webView.isLoading,
                estimatedProgress: webView.estimatedProgress,
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                hasOnlySecureContent: webView.hasOnlySecureContent
            )
        )
    }

    /// A navigation as the policy reads it.
    private static func navigation(_ action: WKNavigationAction, targetsNewWindow: Bool) -> BrowserNavigation {
        BrowserNavigation(
            // A window a script opened with no address is a blank page.
            scheme: action.request.url?.scheme ?? "about",
            targetsNewWindow: targetsNewWindow,
            isDownload: action.shouldPerformDownload,
            isMainFrame: action.targetFrame?.isMainFrame ?? true,
            isUserInitiated: action.navigationType == .linkActivated || action.navigationType == .formSubmitted
        )
    }

    /// What a refused navigation leaves behind: a link to another app, handed
    /// to the tab, whose owner rules on it. A task's tab never opens the app,
    /// and the person's asks them first.
    private func carryOut(_ decision: BrowserNavigationDecision, for url: URL?) {
        guard let url else { return }

        switch decision {
        case .external: events?.pageMetExternalScheme(url)
        case .allow, .newTab, .download, .cancel: return
        }
    }

    /// The policy's decision as WebKit takes it for a navigation. A new tab
    /// is allowed here and made in `createWebViewWith`.
    private static func actionPolicy(_ decision: BrowserNavigationDecision) -> WKNavigationActionPolicy {
        switch decision {
        case .allow, .newTab: return .allow
        case .download: return .download
        case .external, .cancel: return .cancel
        }
    }

    /// The policy's decision as WebKit takes it for a response.
    private static func responsePolicy(_ decision: BrowserNavigationDecision) -> WKNavigationResponsePolicy {
        switch decision {
        case .allow: return .allow
        case .download: return .download
        case .newTab, .external, .cancel: return .cancel
        }
    }

    /// Every waiter parked for the navigation that just finished or failed,
    /// released at once and in the order they asked.
    func resolveReadyWaiters(_ result: Result<Void, any Error>) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters { waiter.finish(result) }
    }
}

/// A `waitUntilReady()` call parked on the navigation in flight: finishes
/// once, with the delegate's own answer or the timeout, whichever comes
/// first, the same shape as `WebKitPageScript`'s own pending call.
@MainActor
final class ReadyWaiter {
    var continuation: CheckedContinuation<Void, any Error>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }

        self.continuation = nil
        timer?.cancel()
        continuation.resume(with: result)
    }
}

// MARK: - Navigation

extension WebKitBrowserPage: WKNavigationDelegate {
    /// A link that asks for a new window is allowed here and becomes a tab in
    /// `createWebViewWith`, which is where WebKit hands over the configuration
    /// that keeps the new page's link to its opener.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let decision = BrowserNavigationPolicy.decide(Self.navigation(action, targetsNewWindow: action.targetFrame == nil))
        carryOut(decision, for: action.request.url)
        decisionHandler(Self.actionPolicy(decision))
    }

    /// A response that is a file rather than a page becomes a download where
    /// the policy allows one: a frame's is refused without a sentence.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let isDownload = !response.canShowMIMEType || Self.isAttachment(response.response)
        let navigation = BrowserNavigation(
            scheme: response.response.url?.scheme ?? "about",
            isDownload: isDownload,
            isMainFrame: response.isForMainFrame
        )
        decisionHandler(Self.responsePolicy(BrowserNavigationPolicy.decide(navigation)))
    }

    /// A navigation the policy answered `.download` is now a download, a
    /// link's `download` attribute or a response that is a file. The tab is
    /// handed it, and its owner rules on where the file goes, if anywhere.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        events?.pageStartedDownload(WebKitBrowserDownload(download))
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        events?.pageStartedDownload(WebKitBrowserDownload(download))
    }

    /// The navigation every `waitUntilReady()` call was parked on.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resolveReadyWaiters(.success(()))
    }

    /// A load that never reached a page says why, in the system's own words.
    /// A navigation the person or the policy cancelled is not a failure: a
    /// fresh one superseded it, and that one's own `didFinish` is still ahead.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard !Self.wasCancelled(error) else { return }

        events?.pageFailed(error.localizedDescription)
        resolveReadyWaiters(.failure(BrowserPageDriveError.navigationFailed(error.localizedDescription)))
    }

    /// A load that reached the page but failed once committed (a resource the
    /// main frame needed never arrived).
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard !Self.wasCancelled(error) else { return }

        events?.pageFailed(error.localizedDescription)
        resolveReadyWaiters(.failure(BrowserPageDriveError.navigationFailed(error.localizedDescription)))
    }

    private static func isAttachment(_ response: URLResponse) -> Bool {
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")

        return disposition?.lowercased().hasPrefix("attachment") == true
    }

    /// `NSURLErrorCancelled` is a navigation replaced by another, and WebKit's
    /// frame-load-interrupted error is one the policy cancelled.
    private static func wasCancelled(_ error: any Error) -> Bool {
        let error = error as NSError
        let frameLoadInterruptedByPolicyChange = 102

        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == WKError.errorDomain && error.code == frameLoadInterruptedByPolicyChange)
    }
}

// MARK: - What a page asks for

extension WebKitBrowserPage: WKUIDelegate {
    /// A page's own window, as a tab. The web view is built on the
    /// configuration WebKit hands over, which carries the opener's website data
    /// and its link back to the opener: a sign-in window reports to the page
    /// that opened it through exactly that link.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let decision = BrowserNavigationPolicy.decide(Self.navigation(action, targetsNewWindow: true))
        guard decision == .newTab else {
            carryOut(decision, for: action.request.url)
            return nil
        }

        let page = WebKitBrowserPage(configuration: configuration)
        guard events?.pageOpened(page) == true else { return nil }

        return page.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        events?.pageAskedToClose()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        present(.alert, message, frame) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        present(.confirm, message, frame) { completionHandler($0 == .confirmed) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        present(.prompt(defaultText: defaultText ?? ""), prompt, frame) { answer in
            guard case .text(let text) = answer else {
                completionHandler(nil)
                return
            }

            completionHandler(text)
        }
    }

    /// Camera and microphone stay off in the pane until the pane asks the
    /// person per website: the app's own microphone grant is for voice calls,
    /// and this bundle declares no camera use at all.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    /// A file chooser the page's own input raised. A driven `upload` primes
    /// `pendingUploadPath` immediately before the click that opens it, and is
    /// answered with exactly that file. Any other goes to the tab, whose owner
    /// decides whether the person is shown the system's chooser (plan §8.1).
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        defer { pendingUploadPath = nil }
        if let path = pendingUploadPath {
            completionHandler([URL(fileURLWithPath: path)])
            return
        }
        guard let events else {
            completionHandler(nil)
            return
        }

        let request = BrowserFileRequest(
            allowsMultipleSelection: parameters.allowsMultipleSelection,
            allowsDirectories: parameters.allowsDirectories
        )
        events.pageRequestedFiles(request) { completionHandler($0) }
    }

    private func present(
        _ kind: BrowserDialog.Kind,
        _ message: String,
        _ frame: WKFrameInfo,
        answer: @escaping @MainActor (BrowserDialogAnswer) -> Void
    ) {
        guard let events else {
            answer(.dismissed)
            return
        }

        events.pagePresented(BrowserDialog(kind: kind, message: message, origin: frame.securityOrigin.host), answer: answer)
    }
}
