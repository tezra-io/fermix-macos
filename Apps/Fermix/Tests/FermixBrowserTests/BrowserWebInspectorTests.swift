import FermixAppCore
import Foundation
import Testing
import WebKit

@testable import FermixBrowser

/// Whether the pane's pages offer Web Inspector (M84 §7). The inspector reads
/// `input.value` in the page, so the executable decides it once from the
/// signature (`LoginStoreSelection.allowsWebInspector`) and the engine applies
/// that answer to every page it makes, whatever the build: a debug build that
/// can hold website logins gets pages nobody can inspect.
@MainActor
@Suite("Browser Web Inspector")
struct BrowserWebInspectorTests {
    @Test("every tab an engine makes carries the engine's inspector answer", arguments: [true, false])
    func tabsFollowTheEngine(inspectable: Bool) throws {
        let engine = WebKitBrowserEngine(websiteProfile: UUID(), inspectable: inspectable)

        for profile in [BrowserProfile.private, .file] {
            let webView = try #require(engine.makeTab(profile: profile).view as? WKWebView)
            #expect(webView.isInspectable == inspectable, "\(profile) tab")
        }
    }

    @Test("a page built not inspectable stays that way", arguments: [true, false])
    func pageFollowsItsAnswer(inspectable: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let page = WebKitBrowserPage(configuration: configuration, fileRules: nil, inspectable: inspectable)

        #expect(page.webView.isInspectable == inspectable)
    }
}
