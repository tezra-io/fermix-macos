import FermixAppCore
import Foundation

/// The page as the engine captures it and reads its cookies (plan §4.9), on
/// `WebKitPageCapture` and `WebKitPageCookies`.
extension WebKitBrowserPage: BrowserPageCapturing, BrowserPageCookies {
    func screenshot(fullPage: Bool) async throws -> BrowserPageCapture {
        try await WebKitPageCapture(webView: webView, script: pageScriptResult.get()).screenshot(fullPage: fullPage)
    }

    func pdf() async throws -> Data {
        try await WebKitPageCapture(webView: webView, script: pageScriptResult.get()).pdf()
    }

    func cookies() async throws -> [BrowserCookie] {
        try await WebKitPageCookies(webView: webView).cookies()
    }

    func clearCookies() async throws -> Int {
        try await WebKitPageCookies(webView: webView).clearCookies()
    }
}
