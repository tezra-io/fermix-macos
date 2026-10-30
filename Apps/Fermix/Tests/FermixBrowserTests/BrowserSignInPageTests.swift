import FermixAppCore
import Foundation
import Testing

@testable import FermixBrowser

/// `page.login_for` and `page.sign_in` on a real web view (M84 §8): the
/// checks before anything is typed, the one fill, and what it answers.
@MainActor
@Suite("Browser sign-in on a page", .serialized)
struct BrowserSignInPageTests {
    private static let observation = BrowserSnapshotRequest(mode: .interactive, maxChars: 1, depth: 1)

    // MARK: - The fill

    @Test("a matching sign-in types both fields and answers which ones, never a value")
    func matchingSignInFills() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        let ledger = LoginLedger()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()

        let login = try await harness.page.loginFor(site: SignInFixture.site, store: store)
        let outcome = try await harness.page.signIn(
            Self.request(username: refs["Email"], password: refs["Password"]),
            store: store, ledger: ledger, observing: Self.observation
        )

        #expect(login.site == SignInFixture.site)
        #expect(login.username == SignInFixture.username)
        #expect(outcome.filled == [.username, .password])
        #expect(try await harness.pageString("document.getElementById('username').value") == SignInFixture.username)
        #expect(try await harness.pageString("document.getElementById('password').value") == SignInFixture.password)
        #expect(ledger.holds(LoginSecret(SignInFixture.password)))
        #expect(await store.passwordReads == 1)
    }

    @Test("fillLogin's answer has exactly one key")
    func fillAnswerHasOneKey() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        let fill = BrowserLoginFill(
            topURL: try requireURL(SignInFixture.loginPage),
            usernameRef: refs["Email"], username: SignInFixture.username,
            passwordRef: refs["Password"], password: LoginSecret(SignInFixture.password)
        )

        let answer = try await harness.page.pageScriptResult.get().text("fillLogin", [fill.scriptArgument()])

        let object = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(Array(object.keys) == ["ok"])
        #expect(object["ok"] as? Bool == true)
    }

    @Test("a username-only sign-in never reads the secret")
    func usernameOnlyReadsNoSecret() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        let ledger = LoginLedger()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()

        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)
        let outcome = try await harness.page.signIn(
            Self.request(username: refs["Email"], password: nil),
            store: store, ledger: ledger, observing: Self.observation
        )

        #expect(outcome.filled == [.username])
        #expect(await store.passwordReads == 0)
        #expect(ledger.isEmpty)
        #expect(try await harness.pageString("document.getElementById('password').value") == "")
    }

    @Test("www. is folded: github.com on www.github.com finds the login")
    func wwwIsFolded() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: "https://www.github.com/login")

        let login = try await harness.page.loginFor(site: SignInFixture.site, store: store)

        #expect(login.site == SignInFixture.site)
    }

    /// A site that signs in on a host of its own (`identity.walmart.com` for
    /// `walmart.com`) uses the login saved for the domain it is under, and the
    /// fill types that login: the engine's approval names both sites.
    @Test("a sign-in page on a subdomain uses the login saved for its parent domain, and fills it")
    func parentDomainLoginFills() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        let ledger = LoginLedger()
        try await harness.load(SignInFixture.plainForm, at: "https://gist.github.com/login")
        let refs = try await harness.fieldRefs()

        let login = try await harness.page.loginFor(site: "gist.github.com", store: store)
        let outcome = try await harness.page.signIn(
            BrowserSignInRequest(
                site: "gist.github.com", loginSite: login.site,
                usernameRef: refs["Email"], passwordRef: refs["Password"]
            ),
            store: store, ledger: ledger, observing: Self.observation
        )

        #expect(login.site == SignInFixture.site)
        #expect(outcome.filled == [.username, .password])
        #expect(try await harness.pageString("document.getElementById('password').value") == SignInFixture.password)
    }

    // MARK: - Refusals before anything is typed

    @Test("a page that is not https is refused")
    func insecurePageRefused() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(SignInFixture.plainForm, at: "http://github.com/login")

        await #expect(throws: BrowserLoginRefusal.insecurePage) {
            _ = try await harness.page.loginFor(site: SignInFixture.site, store: try await SignInFixture.store())
        }
    }

    @Test("a site other than the page's is sign_in_wrong_site")
    func wrongSiteRefused() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)

        await #expect(throws: BrowserLoginRefusal.wrongSite(site: "gitlab.com")) {
            _ = try await harness.page.loginFor(site: "gitlab.com", store: try await SignInFixture.store())
        }
    }

    @Test("evilgithub.com and github.com.evil.example find no login saved for github.com")
    func lookalikesFindNoLogin() async throws {
        for host in ["evilgithub.com", "github.com.evil.example"] {
            let harness = BrowserPageHarness()
            try await harness.load(SignInFixture.plainForm, at: "https://\(host)/login")

            await #expect(throws: BrowserLoginRefusal.noLogin(host: host)) {
                _ = try await harness.page.loginFor(site: host, store: try await SignInFixture.store())
            }
        }
    }

    @Test("a navigation to another origin between the two requests is sign_in_page_moved")
    func navigationBetweenRequestsMoved() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: "https://www.github.com/login")
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)

        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()

        await #expect(throws: BrowserLoginRefusal.pageMoved(.origin)) {
            _ = try await harness.page.signIn(
                Self.request(username: refs["Email"], password: refs["Password"]),
                store: store, ledger: LoginLedger(), observing: Self.observation
            )
        }
        #expect(await store.passwordReads == 0)
        #expect(try await harness.pageString("document.getElementById('password').value") == "")
    }

    @Test("a navigation to another site between the two requests is sign_in_wrong_site, as the first check again")
    func navigationToAnotherSiteIsWrongSite() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)

        try await harness.load(SignInFixture.plainForm, at: "https://evil.example/login")
        let refs = try await harness.fieldRefs()

        await #expect(throws: BrowserLoginRefusal.wrongSite(site: SignInFixture.site)) {
            _ = try await harness.page.signIn(
                Self.request(username: refs["Email"], password: refs["Password"]),
                store: store, ledger: LoginLedger(), observing: Self.observation
            )
        }
    }

    @Test("a sign-in with no lookup before it is sign_in_page_moved, and one lookup answers one sign-in")
    func signInNeedsItsOwnLookup() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        let request = Self.request(username: refs["Email"], password: nil)

        await #expect(throws: BrowserLoginRefusal.pageMoved(.origin)) {
            _ = try await harness.page.signIn(request, store: store, ledger: LoginLedger(), observing: Self.observation)
        }
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)
        _ = try await harness.page.signIn(request, store: store, ledger: LoginLedger(), observing: Self.observation)
        await #expect(throws: BrowserLoginRefusal.pageMoved(.origin)) {
            _ = try await harness.page.signIn(request, store: store, ledger: LoginLedger(), observing: Self.observation)
        }
    }

    @Test("a login that is no longer login_site's is sign_in_page_moved")
    func changedLoginMoved() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)

        await #expect(throws: BrowserLoginRefusal.pageMoved(.login)) {
            _ = try await harness.page.signIn(
                BrowserSignInRequest(site: SignInFixture.site, loginSite: "gitlab.com", usernameRef: refs["Email"], passwordRef: nil),
                store: store, ledger: LoginLedger(), observing: Self.observation
            )
        }
    }

    /// The page takes the field out of reach after the snapshot (a modal
    /// opened over the form makes it inert), so the field will not take the
    /// focus. A page in no key window fires no focus event for a script's
    /// `focus()`, so a focus handler that moves the focus on cannot run here.
    @Test("a password field the page made unfocusable is sign_in_field, and nothing is typed")
    func unfocusableFieldRefused() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        let passwordRef = try #require(refs["Password"])
        try await harness.pageWorld("""
            const field = document.getElementById("password");
            const cover = document.createElement("div");
            cover.inert = true;
            field.before(cover);
            cover.append(field);
            """)
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)

        await #expect(throws: BrowserLoginRefusal.field(ref: passwordRef, .focus)) {
            _ = try await harness.page.signIn(
                Self.request(username: refs["Email"], password: passwordRef),
                store: store, ledger: LoginLedger(), observing: Self.observation
            )
        }
        #expect(try await harness.pageString("document.getElementById('username').value") == "")
        #expect(try await harness.pageString("document.getElementById('password').value") == "")
    }

    @Test("a ref of the wrong kind is sign_in_field, naming it, and nothing is typed")
    func wrongFieldKindsRefused() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        let email = try #require(refs["Email"])
        let password = try #require(refs["Password"])

        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)
        await #expect(throws: BrowserLoginRefusal.field(ref: email, .notPassword)) {
            _ = try await harness.page.signIn(
                Self.request(username: nil, password: email), store: store, ledger: LoginLedger(), observing: Self.observation
            )
        }
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)
        await #expect(throws: BrowserLoginRefusal.field(ref: password, .notUsername)) {
            _ = try await harness.page.signIn(
                Self.request(username: password, password: nil), store: store, ledger: LoginLedger(), observing: Self.observation
            )
        }
        #expect(try await harness.pageString("document.getElementById('username').value") == "")
        #expect(try await harness.pageString("document.getElementById('password').value") == "")
    }

    @Test("fields in two documents are sign_in_field")
    func twoDocumentsRefused() async throws {
        let harness = BrowserPageHarness()
        try await harness.load("""
            <!doctype html><html><body>
            <input id="username" type="email" aria-label="Email">
            <iframe srcdoc='<input id="password" type="password" aria-label="Password">'></iframe>
            </body></html>
            """, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        let email = try #require(refs["Email"])
        let password = try #require(refs["Password"])
        let fill = BrowserLoginFill(
            topURL: try requireURL(SignInFixture.loginPage),
            usernameRef: email, username: SignInFixture.username,
            passwordRef: password, password: LoginSecret(SignInFixture.password)
        )

        let answer = try await harness.page.pageScriptResult.get().text("fillLogin", [fill.scriptArgument()])

        #expect(answer == #"{"error":"field","detail":"documents"}"#)
    }

    @Test("a top origin other than the one checked is refused inside the script, and nothing is typed")
    func scriptChecksTheOrigin() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        let fill = BrowserLoginFill(
            topURL: try requireURL("https://github.com.evil.example/login"),
            usernameRef: refs["Email"], username: SignInFixture.username,
            passwordRef: refs["Password"], password: LoginSecret(SignInFixture.password)
        )

        let answer = try await harness.page.pageScriptResult.get().text("fillLogin", [fill.scriptArgument()])

        #expect(answer == #"{"error":"moved","detail":"top"}"#)
        #expect(try await harness.pageString("document.getElementById('password').value") == "")
    }

    @Test("a ref whose node is gone is stale_ref")
    func goneRefIsStale() async throws {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let refs = try await harness.fieldRefs()
        let passwordRef = try #require(refs["Password"])
        try await harness.pageWorld("document.getElementById('password').remove();")
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)

        await #expect(throws: BrowserPageDriveError.staleRef(passwordRef)) {
            _ = try await harness.page.signIn(
                Self.request(username: nil, password: passwordRef), store: store, ledger: LoginLedger(), observing: Self.observation
            )
        }
    }

    // MARK: - Mechanics

    static func request(username: Int?, password: Int?) -> BrowserSignInRequest {
        BrowserSignInRequest(site: SignInFixture.site, loginSite: SignInFixture.site, usernameRef: username, passwordRef: password)
    }
}
