import FermixAppCore
import Foundation

/// The page as a sign-in fills it and the capture guard checks it (M84 §8,
/// §9), on `WebKitPageActions` and `WebKitPageCapture`.
///
/// One `page.login_for` answers for one `page.sign_in`: the origin it found
/// is held here and consumed by the sign-in that follows, which refuses
/// `sign_in_page_moved` when the page is no longer on it, or when no lookup
/// came first.
extension WebKitBrowserPage: BrowserPageSigningIn {
    func loginFor(site: String, store: any LoginStore) async throws -> SavedLogin {
        signInOrigin = nil
        let found = try await pageActions().loginFor(site: site, store: store)
        signInOrigin = found.origin
        return found.login
    }

    func signIn(
        _ request: BrowserSignInRequest,
        store: any LoginStore,
        ledger: LoginLedger,
        observing observation: BrowserSnapshotRequest
    ) async throws -> BrowserSignInOutcome {
        let origin = signInOrigin
        signInOrigin = nil
        return try await pageActions()
            .signIn(request, expectedOrigin: origin, store: store, ledger: ledger, observing: observation)
    }

    func refuseShownSecrets(_ fingerprints: [BrowserSecretFingerprint]) async throws {
        try await WebKitPageCapture(webView: webView, script: pageScriptResult.get()).refuseShownSecrets(fingerprints)
    }
}
