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
    /// The network rule a file page waits on before it loads anything; nil
    /// for every other page, which is what makes a page a file page.
    private let fileRules: WebKitFileRules?
    /// The file a file page was last asked to show: the one file it loads,
    /// and what reload shows again.
    private var shownFile: (url: URL, kind: BrowserFileKind, readAccess: URL)?
    /// The page's own content controller, from the configuration it was built
    /// on, which holds the network rule.
    private let contentController: WKUserContentController
    /// Whether the network rule is in the content controller yet: it goes in
    /// once, on the first load, and stays.
    private var rulesInstalled = false

    init(configuration: WKWebViewConfiguration, fileRules: WebKitFileRules?) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        contentController = configuration.userContentController
        self.fileRules = fileRules
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
    private var showsFile: Bool { fileRules != nil }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func stop() { webView.stopLoading() }
    func find(_ text: String) { webView.find(text, configuration: WKFindConfiguration()) { _ in } }
    func zoom(_ zoom: BrowserZoom) { webView.pageZoom = zoom.factor(from: webView.pageZoom) }

    /// Text a file page was given as data is read again, since WebKit would
    /// show it as first read; every other page, a file page's image, PDF or
    /// HTML among them, is WebKit's own reload.
    func reload() {
        guard let shownFile, shownFile.kind == .text else {
            webView.reload()
            return
        }

        loadFile(shownFile.url, as: .text, readAccess: shownFile.readAccess)
    }

    /// A file, once the network rule is in place and never before it.
    func loadFile(_ url: URL, as kind: BrowserFileKind, readAccess: URL) {
        guard let fileRules else { preconditionFailure("only a file page loads a file") }

        shownFile = (url, kind, readAccess)
        fileRules.whenCompiled { [weak self] compiled in
            self?.load(url, as: kind, readAccess: readAccess, under: compiled)
        }
    }

    /// A rule list that failed to compile loads nothing and says why.
    private func load(
        _ file: URL,
        as kind: BrowserFileKind,
        readAccess: URL,
        under compiled: Result<WKContentRuleList, any Error>
    ) {
        switch compiled {
        case .failure(let error):
            events?.pageFailed(error.localizedDescription)
        case .success(let rules):
            install(rules)
            show(file, as: kind, readAccess: readAccess)
        }
    }

    private func install(_ rules: WKContentRuleList) {
        guard !rulesInstalled else { return }

        contentController.add(rules)
        rulesInstalled = true
    }

    /// Text is read here and given to WebKit as plain text, because WebKit
    /// would save a markdown or YAML file rather than show it. Anything else
    /// loads from disk, with read access to what the tab was given.
    private func show(_ file: URL, as kind: BrowserFileKind, readAccess: URL) {
        guard kind == .text else {
            webView.loadFileURL(file, allowingReadAccessTo: readAccess)
            return
        }

        showText(file)
    }

    /// The size is asked again first: the file may have grown since the pane
    /// decided to show it, and past the cap nothing is read.
    private func showText(_ file: URL) {
        do {
            guard try Self.size(of: file) <= BrowserFileKind.textSizeCap else {
                events?.pageFailed(ProductStrings[.browserNoticeFileTooLarge])
                return
            }

            webView.load(try Data(contentsOf: file), mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: file)
        } catch {
            events?.pageFailed(error.localizedDescription)
        }
    }

    private static func size(of file: URL) throws -> Int {
        guard let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int else {
            throw CocoaError(.fileReadUnknown)
        }

        return size
    }

    /// Whether a navigation goes to the file the page shows, its own load or
    /// a move within it, rather than to another file.
    private func isShownFile(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, let shownFile else { return false }

        return url.path == shownFile.url.path
    }

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
    private func navigation(_ action: WKNavigationAction, targetsNewWindow: Bool) -> BrowserNavigation {
        BrowserNavigation(
            // A window a script opened with no address is a blank page.
            scheme: action.request.url?.scheme ?? "about",
            targetsNewWindow: targetsNewWindow,
            isDownload: action.shouldPerformDownload,
            isMainFrame: action.targetFrame?.isMainFrame ?? true,
            isUserInitiated: action.navigationType == .linkActivated || action.navigationType == .formSubmitted,
            inFileTab: showsFile,
            isTabsOwnFile: isShownFile(action.request.url)
        )
    }

    /// What a refused navigation leaves behind: a link to another app, handed
    /// to the tab, whose owner rules on it. A task's tab never opens the app,
    /// and the person's asks them first. A link the page does not load, a web
    /// page from a file page or a file from any page, goes to the tab too, to
    /// be opened as the same link from a reply would be.
    private func carryOut(_ decision: BrowserNavigationDecision, for url: URL?) {
        guard let url else { return }

        switch decision {
        case .external: events?.pageMetExternalScheme(url)
        case .handOff: events?.pageHandedOff(url)
        case .allow, .newTab, .download, .cancel: return
        }
    }

    /// The policy's decision as WebKit takes it for a navigation. A new tab
    /// is allowed here and made in `createWebViewWith`.
    private static func actionPolicy(_ decision: BrowserNavigationDecision) -> WKNavigationActionPolicy {
        switch decision {
        case .allow, .newTab: return .allow
        case .download: return .download
        case .external, .handOff, .cancel: return .cancel
        }
    }

    /// The policy's decision as WebKit takes it for a response.
    private static func responsePolicy(_ decision: BrowserNavigationDecision) -> WKNavigationResponsePolicy {
        switch decision {
        case .allow: return .allow
        case .download: return .download
        case .newTab, .external, .handOff, .cancel: return .cancel
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
    /// that keeps the new page's link to its opener. A navigation to this
    /// Mac's own loopback address keeps the scheme it was asked with, and
    /// every other keeps the configuration's HTTPS-first. A file page's
    /// scripts stay off for every navigation, whatever WebKit proposes.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let decision = BrowserNavigationPolicy.decide(navigation(action, targetsNewWindow: action.targetFrame == nil))
        carryOut(decision, for: action.request.url)
        Self.keepLoopbackScheme(of: action.request.url, in: preferences)
        if showsFile { preferences.allowsContentJavaScript = false }
        decisionHandler(Self.actionPolicy(decision), preferences)
    }

    /// HTTPS-first off for a loopback host (`BrowserNavigationPolicy
    /// .isLoopback`). The policy is macOS 15.2's, as the configuration's is,
    /// and below that there is no HTTPS-first to turn off.
    private static func keepLoopbackScheme(of url: URL?, in preferences: WKWebpagePreferences) {
        guard #available(macOS 15.2, *), let host = url?.host, BrowserNavigationPolicy.isLoopback(host: host) else { return }

        preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
    }

    /// A response that is a file rather than a page becomes a download where
    /// the policy allows one: a frame's is refused without a sentence, and so
    /// is any in a file page, which never saves anything.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let isDownload = !response.canShowMIMEType || Self.isAttachment(response.response)
        let navigation = BrowserNavigation(
            scheme: response.response.url?.scheme ?? "about",
            isDownload: isDownload,
            isMainFrame: response.isForMainFrame,
            inFileTab: showsFile,
            isTabsOwnFile: isShownFile(response.response.url)
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

    /// A load that never reached a page, a navigation that became a download
    /// among them.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        ended(with: error)
    }

    /// A load that reached the page but failed once committed (a resource the
    /// main frame needed never arrived).
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        ended(with: error)
    }

    /// The one rule for a navigation that ended without a page
    /// (`BrowserNavigationEnding`). A failure says why, in the system's own
    /// words, and fails the reads waiting on it. Anything else leaves the
    /// page as it stands: ready for those reads once nothing else is loading,
    /// and where a fresh navigation replaced it, that one settles them.
    private func ended(with error: any Error) {
        guard BrowserNavigationEnding(error) == .failed else {
            if !webView.isLoading { resolveReadyWaiters(.success(())) }
            return
        }

        events?.pageFailed(error.localizedDescription)
        resolveReadyWaiters(.failure(BrowserPageDriveError.navigationFailed(error.localizedDescription)))
    }

    private static func isAttachment(_ response: URLResponse) -> Bool {
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")

        return disposition?.lowercased().hasPrefix("attachment") == true
    }
}

// MARK: - What a page asks for

extension WebKitBrowserPage: WKUIDelegate {
    /// A page's own window, as a tab. The web view is built on the
    /// configuration WebKit hands over, which carries the opener's website data
    /// and its link back to the opener: a sign-in window reports to the page
    /// that opened it through exactly that link. A file page never opens one
    /// (the policy answers it no new tab), so the new page is a web page.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let decision = BrowserNavigationPolicy.decide(navigation(action, targetsNewWindow: true))
        guard decision == .newTab else {
            carryOut(decision, for: action.request.url)
            return nil
        }

        let page = WebKitBrowserPage(configuration: configuration, fileRules: nil)
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
