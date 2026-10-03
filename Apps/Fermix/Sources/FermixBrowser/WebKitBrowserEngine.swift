import AppKit
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

    /// The system's open panel, as a sheet on the pane's window, which is the
    /// window the person's tab in front is in. A page in no window has nowhere
    /// to show it, and gets no file.
    public func chooseFiles(_ request: BrowserFileRequest, for page: NSView, answer: @escaping @MainActor ([URL]?) -> Void) {
        guard let window = page.window else {
            answer(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        panel.canChooseDirectories = request.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            answer(response == .OK ? panel.urls : nil)
        }
    }

    /// The system's save panel, as a sheet on the pane's window, the same way.
    /// A page in no window has nowhere to show it, which cancels the download.
    public func chooseSaveDestination(_ filename: String, for page: NSView, answer: @escaping @MainActor (URL?) -> Void) {
        guard let window = page.window else {
            answer(nil)
            return
        }

        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = filename
        panel.beginSheetModal(for: window) { response in
            answer(response == .OK ? panel.url : nil)
        }
    }

    /// The corner window a task's pages run in while the pane cannot show
    /// them.
    public var hostWindow: any BrowserPageStage { cornerWindow }
    private let cornerWindow = BrowserHostWindow()

    /// With no tab of anyone's left, the corner window goes off screen.
    public func releaseIdle() {
        cornerWindow.close()
    }

    /// The privacy defaults that need no vendored list (plan §4.6).
    ///
    /// Known hosts go to https before the request leaves, and every other http
    /// navigation is tried over https first, except to this Mac's own loopback
    /// addresses, which `WebKitBrowserPage` keeps as asked. Where https fails,
    /// WebKit tells the navigation delegate nothing. For a host name it lays
    /// its own warning view over the page ("This Connection Is Not Secure",
    /// with Continue and Go Back), the web view's URL goes to nil and no
    /// failure or finish arrives; Continue loads the page in the clear as a
    /// new navigation. For an IPv4 address it tries nothing, commits
    /// `about:blank` and reports that finished, with no warning.
    /// The fraudulent website warning is WebKit's default and is stated rather
    /// than left implicit, because turning it off would be a decision.
    private func configuration(for profile: BrowserProfile) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile == .shared ? sharedStore : .nonPersistent()
        // Unconditional: available since macOS 11.3, well under the floor.
        configuration.upgradeKnownHostsToHTTPS = true
        // `preferredHTTPSNavigationPolicy` is macOS 15.2. The floor stays 15.0
        // (the Homebrew cask cannot express a minor release), so on 15.0 and
        // 15.1 the policy is left at WebKit's own default rather than raising
        // the floor for this one property.
        if #available(macOS 15.2, *) {
            configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .userMediatedFallbackToHTTP
        }
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        return configuration
    }
}
