import Foundation

/// A website login the owner saved: its site in key form (`LoginSite.key`)
/// and the username typed into the sign-in page. Never the password, which is
/// read only through `LoginStore.password(for:)`.
public struct SavedLogin: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Key form: lower-cased, trailing dot trimmed, one leading `www.` removed.
    public let site: String
    public let username: String

    public init(id: UUID, site: String, username: String) {
        self.id = id
        self.site = site
        self.username = username
    }
}

/// A saved login prints, debug-prints and mirrors its id and site only: no log
/// line, error text, crash report or test failure built from one holds the
/// username (§6). Views read `username` itself.
extension SavedLogin: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SavedLogin(id: \(id.uuidString), site: \(site), username: \(LoginSecret.withheld))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "site": site], displayStyle: .struct)
    }
}

/// A password in memory. Prints, debug-prints and mirrors as withheld, so a
/// log line, an interpolated error, `dump` or a crash report never holds it.
public struct LoginSecret: Sendable, Equatable, CustomStringConvertible,
                           CustomDebugStringConvertible, CustomReflectable {
    /// What every textual form of a secret prints.
    public static let withheld = "<withheld>"

    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// The one way to the characters, scoped to the call that needs them.
    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(value)
    }

    /// UTF-16 code units, which is what a page's `input.value.length` counts
    /// (capture guard).
    public var utf16Count: Int { value.utf16.count }

    public var description: String { Self.withheld }
    public var debugDescription: String { Self.withheld }
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// Why a typed site cannot be saved (D2).
public enum LoginSiteRefusal: Error, Equatable, Sendable {
    case notAHost, addressLiteral, localhost, internationalized, noDot
}

/// Every error a `LoginStore` throws. None carries a username or a password.
public enum LoginStoreError: Error, Equatable, Sendable {
    /// The keychain refused with this `OSStatus`; nil: this build has no store
    /// (a dev or ad-hoc build without the access group).
    case unavailable(status: Int32?)
    /// The keychain did not answer within the store's bound.
    case timedOut
    case site(LoginSiteRefusal)
    case siteTaken
    case usernameRequired
    /// Fewer than `LoginStoreRules.minimumPasswordLength` characters (`String.count`).
    case passwordTooShort
    /// `LoginStoreRules.maximumLogins` logins already saved.
    case full
    case notFound
}

/// The store of website logins. Every call throws only `LoginStoreError`.
public protocol LoginStore: Sendable {
    /// Attributes only, never a password.
    func list() async throws -> [SavedLogin]
    func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin
    /// The site never changes; a nil password keeps the saved one.
    func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin
    func delete(id: UUID) async throws
    /// The login whose site matches `host` under D2, attributes only.
    func login(forHost host: String) async throws -> SavedLogin?
    /// The one secret read.
    func password(for id: UUID) async throws -> LoginSecret
}
