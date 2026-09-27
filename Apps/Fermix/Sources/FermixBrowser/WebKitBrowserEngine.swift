import FermixAppCore
import Foundation
import WebKit

/// The browser pane's engine, on WebKit (plan §4.2).
///
/// The only module in the repository that imports WebKit. `FermixAppCore`
/// declares `BrowserEngine` and imports nothing, because both executables link
/// that library and `FermixAgent` must never load a web engine; only the
/// `Fermix` executable links this target, and `main.swift` hands the engine's
/// factory in, as it hands in the updater and the mascot renderer.
///
/// Every tab of the shared profile keeps its cookies and storage in one
/// persistent website data store, named by the identifier the core keeps in
/// the app's support folder, so a website sign-in survives closing the tab and
/// quitting the app, and is separate from every other browser on the Mac. A
/// private tab gets a store that is never written to disk.
@MainActor
public final class WebKitBrowserEngine: BrowserEngine {
    private let websiteProfile: UUID
    /// Opened on the first shared tab, so a person who only ever opens private
    /// tabs never has the persistent store created for them.
    private lazy var sharedStore = WKWebsiteDataStore(forIdentifier: websiteProfile)

    public init(websiteProfile: UUID) {
        self.websiteProfile = websiteProfile
    }

    public func makeTab(profile: BrowserProfile) -> BrowserTab {
        BrowserTab(profile: profile, page: WebKitBrowserPage(configuration: configuration(for: profile)))
    }

    /// The privacy defaults that need no vendored list (plan §4.6).
    ///
    /// Known hosts go to https before the request leaves, and every other http
    /// navigation is tried over https first, with WebKit's own warning page
    /// standing between the person and a page that only answers in the clear.
    /// The fraudulent website warning is WebKit's default and is stated rather
    /// than left implicit, because turning it off would be a decision.
    private func configuration(for profile: BrowserProfile) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile == .shared ? sharedStore : .nonPersistent()
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .userMediatedFallbackToHTTP
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        return configuration
    }
}
