import FermixAppCore
import Foundation
import WebKit

/// `cookies.get` and `cookies.clear` (plan §4.9), on the tab's own
/// `WKHTTPCookieStore`.
///
/// The store comes from the tab's own web view configuration
/// (`WebKitBrowserEngine.configuration(for:)`), which is the shared profile's
/// persistent store for a shared tab and a data store made fresh for a
/// private one: reading or clearing always goes through that one store, so a
/// shared request never reaches a private tab's cookies and a private
/// request never reaches the shared profile's.
@MainActor
final class WebKitPageCookies {
    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
    }

    func cookies() async throws -> [BrowserCookie] {
        guard let host = webView.url?.host else { return [] }

        return await matchingCookies(host: host).map(Self.cookie)
    }

    func clearCookies() async throws -> Int {
        guard let host = webView.url?.host else { return 0 }

        let matching = await matchingCookies(host: host)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in matching {
            await store.deleteCookie(cookie)
        }

        return matching.count
    }

    private func matchingCookies(host: String) async -> [HTTPCookie] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all = await store.allCookies()

        return all.filter { Self.domainMatches($0.domain, host: host) }
    }

    /// Standard cookie domain matching: the cookie's own host, or a parent
    /// domain it named with or without the leading dot browsers write.
    private static func domainMatches(_ cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain

        return host == domain || host.hasSuffix("." + domain)
    }

    private static func cookie(_ cookie: HTTPCookie) -> BrowserCookie {
        BrowserCookie(
            name: cookie.name,
            domain: cookie.domain,
            path: cookie.path,
            secure: cookie.isSecure,
            httpOnly: cookie.isHTTPOnly,
            sameSite: cookie.sameSitePolicy?.rawValue,
            expires: cookie.expiresDate?.timeIntervalSince1970,
            session: cookie.isSessionOnly
        )
    }
}
