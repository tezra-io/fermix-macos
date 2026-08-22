import SwiftUI
import WebKit

/// The ephemeral web view the daemon's Setup LiveView runs in.
///
/// Ephemeral is the point: a non-persistent data store means no cookie, cache,
/// or local-storage entry outlives the surface, so a one-use token cannot be
/// left behind on disk. Navigation is decided by `SetupNavigationPolicy` and
/// nowhere else.
struct SetupWebView: NSViewRepresentable {
    let session: SetupSession
    let policy: SetupNavigationPolicy
    let opener: any ExternalOpening

    func makeCoordinator() -> SetupWebCoordinator {
        SetupWebCoordinator(policy: policy, opener: opener)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: session.url))
        context.coordinator.loadedURL = session.url

        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.policy = policy
        guard context.coordinator.loadedURL != session.url else { return }

        context.coordinator.loadedURL = session.url
        view.load(URLRequest(url: session.url))
    }
}

/// The navigation delegate. It decides nothing itself: every answer comes from
/// the policy, and the one side effect it owns is handing an external url to
/// the system browser.
final class SetupWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var policy: SetupNavigationPolicy
    var loadedURL: URL?

    private let opener: any ExternalOpening
    private let log = AppLog.logger(.app)

    init(policy: SetupNavigationPolicy, opener: any ExternalOpening) {
        self.policy = policy
        self.opener = opener
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        switch policy.decide(Self.navigation(navigationAction, isMainFrame: nil)) {
        case .allowInline:
            decisionHandler(.allow)
        case .openInSystemBrowser(let url):
            opener.open(url)
            decisionHandler(.cancel)
        case .refuse(let reason):
            log.error("setup navigation refused: \(reason.rawValue, privacy: .public)")
            decisionHandler(.cancel)
        }
    }

    /// A target-blank link asks for a new window. There is no second window in
    /// this surface, so the same policy answers it — and a new window is a
    /// top-level navigation, which is why the frame is reported as the main one.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if case .openInSystemBrowser(let url) = policy.decide(
            Self.navigation(navigationAction, isMainFrame: true)
        ) {
            opener.open(url)
        }

        return nil
    }

    /// The navigation as the policy reads it. `targetFrame` is nil for a
    /// navigation that would open a new window, so the caller says which world
    /// it is in rather than a missing frame being read as the main one.
    private static func navigation(
        _ action: WKNavigationAction,
        isMainFrame: Bool?
    ) -> SetupNavigation {
        SetupNavigation(
            url: action.request.url,
            isMainFrame: isMainFrame ?? (action.targetFrame?.isMainFrame ?? false),
            isLinkActivation: action.navigationType == .linkActivated
        )
    }
}
