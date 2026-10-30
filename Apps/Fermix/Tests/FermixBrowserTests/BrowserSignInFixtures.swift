import FermixAppCore
import Foundation

@testable import FermixBrowser

/// The saved login every sign-in case types, and the pages it types it into.
/// The password carries every character the wire's JSON or a page's own
/// encoding treats specially.
enum SignInFixture {
    static let site = "github.com"
    static let username = "octo@example.com"
    static let password = "s3cret \"pa\\ss/&<é>"
    static let loginPage = "https://github.com/login"

    /// A store holding the one login, and counting every secret it hands out.
    static func store() async throws -> RecordingLoginStore {
        let store = RecordingLoginStore()
        _ = try await store.add(site: site, username: username, password: LoginSecret(password))
        return store
    }

    /// A plain login form: no `method`, no handler of the page's own.
    static let plainForm = """
        <!doctype html><html><head><title>Sign in</title></head><body>
        <form id="form">
          <input id="username" name="username" type="email" aria-label="Email">
          <input id="password" name="password" type="password" aria-label="Password">
          <input id="other" aria-label="Other">
          <button>Sign in</button>
        </form>
        </body></html>
        """

    /// A login form whose fields are reached through a shadow root.
    static let shadowForm = """
        <!doctype html><html><head><title>Sign in</title></head><body>
        <div id="host"></div>
        <script>
          const root = document.getElementById("host").attachShadow({ mode: "open" });
          root.innerHTML = '<form id="form"><input id="username" type="text" aria-label="Email">'
            + '<input id="password" type="password" aria-label="Password"></form>';
        </script>
        </body></html>
        """
}

/// A store over `InMemoryLoginStore` that counts the password reads, so a
/// case can prove the secret is read only when a password field is named.
actor RecordingLoginStore: LoginStore {
    private let inner = InMemoryLoginStore()
    private(set) var passwordReads = 0

    func list() async throws -> [SavedLogin] { try await inner.list() }

    func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin {
        try await inner.add(site: site, username: username, password: password)
    }

    func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin {
        try await inner.update(id: id, username: username, password: password)
    }

    func delete(id: UUID) async throws { try await inner.delete(id: id) }

    func login(forHost host: String) async throws -> SavedLogin? { try await inner.login(forHost: host) }

    func password(for id: UUID) async throws -> LoginSecret {
        passwordReads += 1
        return try await inner.password(for: id)
    }
}

extension BrowserPageHarness {
    /// The refs of the page's text fields, by their accessible names, from
    /// the page script's own snapshot.
    func fieldRefs() async throws -> [String: Int] {
        let snapshot = try await page.snapshot(BrowserSnapshotRequest(mode: .full, maxChars: 200_000, depth: 200))
        var refs: [String: Int] = [:]
        for node in snapshot.nodes where node.role == "textbox" {
            guard let ref = node.ref, refs[node.name] == nil else { continue }
            refs[node.name] = ref
        }
        return refs
    }

    /// Every text field's ref in document order, for a page whose fields
    /// carry no names of their own.
    func orderedFieldRefs() async throws -> [Int] {
        let snapshot = try await page.snapshot(BrowserSnapshotRequest(mode: .full, maxChars: 200_000, depth: 200))
        var refs: [Int] = []
        for node in snapshot.nodes where node.role == "textbox" {
            if let ref = node.ref, !refs.contains(ref) { refs.append(ref) }
        }
        return refs
    }

    /// The whole snapshot as the page script answered it, for a case that
    /// reads every name in it.
    func snapshotText() async throws -> String {
        let options: [String: Any] = ["mode": "full", "maxChars": 200_000, "depth": 200, "closedShadowRoots": false]
        return try await page.pageScriptResult.get().text("snapshot", [options])
    }

    /// A string the page's own script reads, `expression` evaluated there.
    func pageString(_ expression: String) async throws -> String? {
        try await pageWorld("return String(\(expression));") as? String
    }

    func pageBool(_ expression: String) async throws -> Bool? {
        try await pageWorld("return Boolean(\(expression));") as? Bool
    }
}
