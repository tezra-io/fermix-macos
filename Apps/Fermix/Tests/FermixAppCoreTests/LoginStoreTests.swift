import Foundation
import Testing

@testable import FermixAppCore

/// The store's rules, proven on the in-memory store every test above the
/// keychain stands on (M84 §7). The keychain store applies the same
/// `LoginStoreRules`, so the rules have one owner and these tests cover both.
@Suite("Website login store")
struct LoginStoreTests {
    private let password = LoginSecret("correct horse")

    @Test("a saved login is listed by its site's key and its username, never its password")
    func addAndList() async throws {
        let store = InMemoryLoginStore()

        let saved = try await store.add(site: "https://www.GitHub.com/login", username: "alice", password: password)
        let listed = try await store.list()

        #expect(saved.site == "github.com")
        #expect(saved.username == "alice")
        #expect(listed == [saved])
        #expect(try await store.password(for: saved.id) == password)
    }

    @Test("the list is ordered by site")
    func listOrder() async throws {
        let store = InMemoryLoginStore()
        _ = try await store.add(site: "zeta.example", username: "z", password: password)
        _ = try await store.add(site: "alpha.example", username: "a", password: password)

        #expect(try await store.list().map(\.site) == ["alpha.example", "zeta.example"])
    }

    @Test("a refused site is refused with its reason, and nothing is saved")
    func refusedSite() async throws {
        let store = InMemoryLoginStore()

        await #expect(throws: LoginStoreError.site(.localhost)) {
            try await store.add(site: "localhost", username: "alice", password: password)
        }
        await #expect(throws: LoginStoreError.site(.addressLiteral)) {
            try await store.add(site: "192.168.1.1", username: "alice", password: password)
        }
        #expect(try await store.list().isEmpty)
    }

    @Test("one login per site, whatever form the second one was typed in")
    func oneLoginPerSite() async throws {
        let store = InMemoryLoginStore()
        _ = try await store.add(site: "github.com", username: "alice", password: password)

        await #expect(throws: LoginStoreError.siteTaken) {
            try await store.add(site: "https://www.github.com/", username: "bob", password: password)
        }
        #expect(try await store.list().count == 1)
    }

    @Test("a username is required")
    func usernameRequired() async throws {
        let store = InMemoryLoginStore()

        for blank in ["", "   ", "\n\t"] {
            await #expect(throws: LoginStoreError.usernameRequired) {
                try await store.add(site: "github.com", username: blank, password: password)
            }
        }
        #expect(try await store.list().isEmpty)
    }

    @Test("a password under eight characters is refused, counted as characters")
    func passwordFloor() async throws {
        let store = InMemoryLoginStore()

        await #expect(throws: LoginStoreError.passwordTooShort) {
            try await store.add(site: "github.com", username: "alice", password: LoginSecret("1234567"))
        }
        await #expect(throws: LoginStoreError.passwordTooShort) {
            try await store.add(site: "github.com", username: "alice", password: LoginSecret(""))
        }
        // Seven characters, far more than eight UTF-16 units: the floor is
        // what the owner typed, not how it is encoded.
        await #expect(throws: LoginStoreError.passwordTooShort) {
            try await store.add(site: "github.com", username: "alice", password: LoginSecret("👩‍👩‍👧‍👦🔑🔑🔑🔑🔑🔑"))
        }
        let eight = try await store.add(site: "github.com", username: "alice", password: LoginSecret("12345678"))
        #expect(eight.site == "github.com")
    }

    @Test("the five hundredth login is the last one")
    func capped() async throws {
        let store = InMemoryLoginStore()
        for index in 0..<LoginStoreRules.maximumLogins {
            _ = try await store.add(site: "site\(index).example", username: "u", password: password)
        }

        await #expect(throws: LoginStoreError.full) {
            try await store.add(site: "one-more.example", username: "u", password: password)
        }
        #expect(try await store.list().count == 500)
    }

    @Test("an edit changes the username and keeps the site and the id")
    func editKeepsSite() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "github.com", username: "alice", password: password)

        let edited = try await store.update(id: saved.id, username: "alice@example.com", password: nil)

        #expect(edited == SavedLogin(id: saved.id, site: "github.com", username: "alice@example.com"))
        #expect(try await store.list() == [edited])
    }

    @Test("an empty password on edit keeps the saved one; a nil one too")
    func emptyPasswordKeeps() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "github.com", username: "alice", password: password)

        _ = try await store.update(id: saved.id, username: "alice", password: LoginSecret(""))
        #expect(try await store.password(for: saved.id) == password)
        _ = try await store.update(id: saved.id, username: "alice", password: nil)
        #expect(try await store.password(for: saved.id) == password)
    }

    @Test("a new password on edit replaces the saved one, under the same floor")
    func replacePassword() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "github.com", username: "alice", password: password)

        await #expect(throws: LoginStoreError.passwordTooShort) {
            try await store.update(id: saved.id, username: "alice", password: LoginSecret("short"))
        }
        #expect(try await store.password(for: saved.id) == password)

        _ = try await store.update(id: saved.id, username: "alice", password: LoginSecret("battery staple"))
        #expect(try await store.password(for: saved.id) == LoginSecret("battery staple"))
    }

    @Test("an edit still needs a username")
    func editNeedsUsername() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "github.com", username: "alice", password: password)

        await #expect(throws: LoginStoreError.usernameRequired) {
            try await store.update(id: saved.id, username: " ", password: nil)
        }
        #expect(try await store.list().first?.username == "alice")
    }

    @Test("a login that is gone is notFound for every call that names it")
    func notFound() async throws {
        let store = InMemoryLoginStore()
        let missing = UUID()

        await #expect(throws: LoginStoreError.notFound) {
            try await store.update(id: missing, username: "alice", password: nil)
        }
        await #expect(throws: LoginStoreError.notFound) { try await store.delete(id: missing) }
        await #expect(throws: LoginStoreError.notFound) { try await store.password(for: missing) }
    }

    @Test("a deleted login leaves the list and its site free")
    func delete() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "github.com", username: "alice", password: password)

        try await store.delete(id: saved.id)

        #expect(try await store.list().isEmpty)
        let again = try await store.add(site: "github.com", username: "bob", password: password)
        #expect(again.id != saved.id)
    }

    @Test("a page's host finds the login saved for its key, and only that one")
    func loginForHost() async throws {
        let store = InMemoryLoginStore()
        let github = try await store.add(site: "github.com", username: "alice", password: password)
        _ = try await store.add(site: "accounts.google.com", username: "alice@gmail.com", password: password)

        #expect(try await store.login(forHost: "www.github.com") == github)
        #expect(try await store.login(forHost: "GITHUB.COM.") == github)
        #expect(try await store.login(forHost: "gist.github.com") == nil)
        #expect(try await store.login(forHost: "evilgithub.com") == nil)
        #expect(try await store.login(forHost: "github.com.evil.example") == nil)
        #expect(try await store.login(forHost: "google.com") == nil)
        #expect(try await store.login(forHost: "127.0.0.1") == nil)
    }

    @Test("the pure refusals list every reason at once, in field order")
    func refusalsAtOnce() async throws {
        let existing = [SavedLogin(id: UUID(), site: "github.com", username: "alice")]

        #expect(
            LoginStoreRules.refusals(site: "www.github.com", username: " ", password: LoginSecret("short"), existing: existing)
                == [.usernameRequired, .passwordTooShort, .siteTaken]
        )
        #expect(
            LoginStoreRules.refusals(site: "localhost", username: "alice", password: password, existing: existing)
                == [.site(.localhost)]
        )
        #expect(LoginStoreRules.refusals(site: "gitlab.com", username: "alice", password: password, existing: existing).isEmpty)
        #expect(LoginStoreRules.refusals(username: "alice", password: nil).isEmpty)
        #expect(LoginStoreRules.refusals(username: "alice", password: LoginSecret("")).isEmpty)
        #expect(LoginStoreRules.refusals(username: "", password: LoginSecret("short")) == [.usernameRequired, .passwordTooShort])
    }

    @Test("a build without the store answers unavailable, with no status, on every call")
    func unavailableStore() async {
        let store = UnavailableLoginStore()
        let refusal = LoginStoreError.unavailable(status: nil)

        await #expect(throws: refusal) { try await store.list() }
        await #expect(throws: refusal) { try await store.add(site: "github.com", username: "alice", password: password) }
        await #expect(throws: refusal) { try await store.update(id: UUID(), username: "alice", password: nil) }
        await #expect(throws: refusal) { try await store.delete(id: UUID()) }
        await #expect(throws: refusal) { try await store.login(forHost: "github.com") }
        await #expect(throws: refusal) { try await store.password(for: UUID()) }
    }
}

/// A password prints, debug-prints, interpolates and mirrors as withheld, so
/// no log line, error text or crash report built from one can hold it (§6).
@Suite("Website login secrets")
struct LoginSecretTests {
    private let value = "hunter2-correct-horse"

    @Test("every textual form of a secret is withheld")
    func withheldEverywhere() {
        let secret = LoginSecret(value)
        var dumped = ""
        dump(secret, to: &dumped)
        var dumpedInside = ""
        dump(["login": secret], to: &dumpedInside)

        let forms = [
            String(describing: secret),
            String(reflecting: secret),
            "\(secret)",
            "\([secret])",
            "\(Optional(secret) as Any)",
            dumped,
            dumpedInside,
            String(describing: Mirror(reflecting: secret).children.map(\.value))
        ]

        for form in forms {
            #expect(!form.contains(value), "a form printed the password: \(form.count) characters")
            #expect(!form.contains("hunter"))
        }
        #expect(String(describing: secret) == LoginSecret.withheld)
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }

    @Test("the value is reachable only inside withValue, and counts UTF-16 units")
    func scopedValue() {
        let secret = LoginSecret("pässwörd🔑")

        #expect(secret.withValue { $0 } == "pässwörd🔑")
        #expect(secret.utf16Count == "pässwörd🔑".utf16.count)
        #expect(secret.utf16Count == 10)
    }

    @Test("a saved login prints and mirrors its site, never its username")
    func savedLoginWithholdsUsername() {
        let login = SavedLogin(id: UUID(), site: "github.com", username: "alice.marsh@example.com")
        var dumped = ""
        dump(login, to: &dumped)

        for form in [String(describing: login), String(reflecting: login), "\(login)", "\([login])", dumped] {
            #expect(form.contains("github.com"))
            #expect(!form.contains("alice"), "a form printed the username")
        }
        #expect(login.username == "alice.marsh@example.com")
    }

    @Test("an error or a request carrying a login prints no username or password")
    func errorsCarryNoValues() {
        let errors: [LoginStoreError] = [
            .unavailable(status: -34018), .unavailable(status: nil), .timedOut, .site(.noDot),
            .siteTaken, .usernameRequired, .passwordTooShort, .full, .notFound
        ]

        for error in errors {
            var dumped = ""
            dump(error, to: &dumped)
            #expect(!dumped.contains("alice"))
            #expect(!"\(error)".contains("alice"))
        }
    }
}
