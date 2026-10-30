import Foundation

/// A field a sign-in typed into, spelled as `page.sign_in`'s `filled` lists
/// it. Username first: that is the order a sign-in types them in.
public enum BrowserLoginField: String, Equatable, Sendable {
    case username
    case password
}

/// `page.sign_in` as the page carries it out. No secret is in it: the
/// password is read from the store by the page's own handler, and only when
/// `passwordRef` is given.
public struct BrowserSignInRequest: Equatable, Sendable {
    /// The host the model read off the page, as the engine canonicalised it.
    public let site: String
    /// The key the owner was shown at `page.login_for`.
    public let loginSite: String
    public let usernameRef: Int?
    public let passwordRef: Int?

    public init(site: String, loginSite: String, usernameRef: Int?, passwordRef: Int?) {
        self.site = site
        self.loginSite = loginSite
        self.usernameRef = usernameRef
        self.passwordRef = passwordRef
    }
}

/// What a sign-in typed, and what it did to the page, in the shape a
/// `page.act` reports its own effect.
public struct BrowserSignInOutcome: Equatable, Sendable {
    public var filled: [BrowserLoginField]
    public var effect: BrowserPageEffect
    /// The page's address once it settled.
    public var url: String

    public init(filled: [BrowserLoginField], effect: BrowserPageEffect, url: String) {
        self.filled = filled
        self.effect = effect
        self.url = url
    }
}

/// The one script call that types a login into the page (`fillLogin` in the
/// page script), as the page's handler hands it over: the refs, the saved
/// username, the password and the address the checks were made against.
///
/// It is the one value in the app that carries a password to the page, so it
/// prints, debug-prints and mirrors as withheld, the username with it.
public struct BrowserLoginFill: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let topURL: URL
    public let usernameRef: Int?
    public let username: String?
    public let passwordRef: Int?
    public let password: LoginSecret?

    public init(topURL: URL, usernameRef: Int?, username: String?, passwordRef: Int?, password: LoginSecret?) {
        precondition((usernameRef == nil) == (username == nil), "a username ref travels with a username")
        precondition((passwordRef == nil) == (password == nil), "a password ref travels with a password")
        self.topURL = topURL
        self.usernameRef = usernameRef
        self.username = username
        self.passwordRef = passwordRef
        self.password = password
    }

    /// The fields this fill types, in the order it types them.
    public var fields: [BrowserLoginField] {
        (usernameRef == nil ? [] : [.username]) + (passwordRef == nil ? [] : [.password])
    }

    /// `fillLogin`'s one argument. Built at the call, never kept.
    public func scriptArgument() -> [String: Any] {
        [
            "topURL": topURL.absoluteString,
            "usernameRef": usernameRef.map { $0 as Any } ?? NSNull(),
            "username": username.map { $0 as Any } ?? NSNull(),
            "passwordRef": passwordRef.map { $0 as Any } ?? NSNull(),
            "password": password.map { $0.withValue { $0 } as Any } ?? NSNull()
        ]
    }

    public var description: String { "BrowserLoginFill(\(LoginSecret.withheld))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What was wrong with a field a sign-in was asked to type into.
public enum BrowserLoginFieldProblem: Equatable, Sendable {
    /// `username_ref` is not a text, email or phone `<input>`.
    case notUsername
    /// `password_ref` is not an `<input type="password">`.
    case notPassword
    /// The two refs are in different documents.
    case twoDocuments
    /// The field would not take the focus, or the page took it away.
    case focus
}

/// What changed between `page.login_for` and `page.sign_in`.
public enum BrowserLoginChange: Equatable, Sendable {
    /// The tab's top origin is not the one `page.login_for` answered for,
    /// or no `page.login_for` was answered for this page.
    case origin
    /// The page script found the page, or a field's document, on another
    /// origin than the one the checks were made against.
    case documentOrigin
    /// The login saved for the page is gone or is not `login_site`'s.
    case login
}

/// Why a sign-in, or a capture while a filled password may show, was refused:
/// the host's protocol 2 reasons (`sign_in_*`, `secret_on_screen`). None of
/// these carries a username or a password.
public enum BrowserLoginRefusal: Error, Equatable, Sendable {
    case insecurePage
    /// `key(site)` is not the key of the tab's top host.
    case wrongSite(site: String)
    /// No saved login for the key of the tab's top host.
    case noLogin(host: String)
    case field(ref: Int?, BrowserLoginFieldProblem)
    case pageMoved(BrowserLoginChange)
    case storeUnavailable(LoginStoreError)
    /// A capture would show a filled password as text.
    case secretOnScreen
    /// The page has more documents and shadow roots than the capture guard
    /// checks, so a capture is refused rather than taken unchecked.
    case secretUncheckable
}

/// The page as a sign-in reads and fills it (M84 §8), and as the capture
/// guard checks it (§9). The store and the ledger are handed in by the wire
/// client, which owns both for the life of the app.
@MainActor
public protocol BrowserPageSigningIn: AnyObject {
    /// `page.login_for`: the saved login for the tab's page, attributes only.
    func loginFor(site: String, store: any LoginStore) async throws -> SavedLogin

    /// `page.sign_in`: the checks again, the password read only for a
    /// `passwordRef`, the ledger told before the page has it, then one fill.
    func signIn(
        _ request: BrowserSignInRequest,
        store: any LoginStore,
        ledger: LoginLedger,
        observing observation: BrowserSnapshotRequest
    ) async throws -> BrowserSignInOutcome

    /// Throws `secretOnScreen` when a value the ledger fingerprints shows as
    /// text on the page. Run before every screenshot and PDF while the ledger
    /// holds an entry.
    func refuseShownSecrets(_ fingerprints: [BrowserSecretFingerprint]) async throws
}

extension BrowserTab {
    /// The page as a sign-in fills it, or nil for a page with no web engine.
    var signingIn: (any BrowserPageSigningIn)? { driver as? any BrowserPageSigningIn }
}
