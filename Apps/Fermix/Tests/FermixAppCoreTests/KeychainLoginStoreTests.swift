import Foundation
import Security
import Testing

@testable import FermixAppCore

/// The keychain store's queries, proven on a fake keychain (M84 §7, D5).
///
/// The real data protection keychain refuses every call from a process whose
/// signature lacks the access group, which an unsigned test build always does,
/// so what can be proven here is what the store asks for: one generic-password
/// item per login in the data protection keychain, the access group on every
/// call, this Mac only, the list read as attributes alone, and every call off
/// the main actor and inside its bound. The store's rules are
/// `LoginStoreRules`, proven on both stores. The real keychain is exercised by
/// `KeychainLoginStoreSignedBuildTests`, on a signed build only.
@Suite("Website login keychain store")
@MainActor
struct KeychainLoginStoreTests {
    private let group = "TEAMID1234.example.app.logins"
    private let password = LoginSecret("correct horse")

    private func store(_ keychain: FakeKeychain, bound: TimeInterval = 5) -> KeychainLoginStore {
        KeychainLoginStore(accessGroup: group, calls: keychain, bound: bound)
    }

    @Test("every call names the data protection keychain, the group, the service, and this Mac only")
    func everyCallIsScoped() async throws {
        let keychain = FakeKeychain()
        let store = store(keychain)

        let saved = try await store.add(site: "github.com", username: "alice", password: password)
        _ = try await store.list()
        _ = try await store.login(forHost: "www.github.com")
        _ = try await store.password(for: saved.id)
        _ = try await store.update(id: saved.id, username: "alice2", password: LoginSecret("battery staple"))
        try await store.delete(id: saved.id)

        let calls = keychain.calls
        #expect(calls.count >= 7)
        for call in calls {
            #expect(call.query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(call.query[kSecAttrService as String] as? String == "io.tezra.FermixPet.login")
            #expect(call.query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(call.query[kSecAttrAccessGroup as String] as? String == group)
            #expect(call.query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(!call.onMainThread, "a keychain call ran on the main thread")
        }
    }

    @Test("a login is one generic-password item: its id, its JSON attributes, its password, this device only")
    func itemShape() async throws {
        let keychain = FakeKeychain()

        let saved = try await store(keychain).add(site: "https://www.GitHub.com/login", username: "alice", password: password)

        let add = try #require(keychain.calls.first { $0.kind == .add })
        #expect(add.query[kSecAttrAccount as String] as? String == saved.id.uuidString)
        #expect(add.query[kSecValueData as String] as? Data == Data("correct horse".utf8))
        #expect(
            add.query[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        let generic = try #require(add.query[kSecAttrGeneric as String] as? Data)
        let object = try #require(try JSONSerialization.jsonObject(with: generic) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect(object["site"] as? String == "github.com")
        #expect(object["username"] as? String == "alice")
        #expect(object.count == 3)
        #expect(add.query[kSecAttrAccessControl as String] == nil, "no user-presence flag on the item")
    }

    @Test("the list and the host lookup read attributes only; the one data read is password(for:)")
    func listNeverReadsData() async throws {
        let keychain = FakeKeychain()
        let store = store(keychain)
        let saved = try await store.add(site: "github.com", username: "alice", password: password)

        let listed = try await store.list()
        _ = try await store.login(forHost: "github.com")
        #expect(listed == [saved])

        let reads = keychain.calls.filter { $0.kind == .copyMatching }
        #expect(!reads.isEmpty)
        for read in reads {
            #expect(read.query[kSecReturnAttributes as String] as? Bool == true)
            #expect(read.query[kSecReturnData as String] == nil, "a list read asked for data")
            #expect(read.query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        }

        #expect(try await store.password(for: saved.id) == password)
        let secretRead = try #require(keychain.calls.last)
        #expect(secretRead.query[kSecReturnData as String] as? Bool == true)
        #expect(secretRead.query[kSecReturnAttributes as String] == nil)
        #expect(secretRead.query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(secretRead.query[kSecAttrAccount as String] as? String == saved.id.uuidString)
    }

    @Test("the store's rules hold on the keychain store: one per site, the floor, a username")
    func rulesHold() async throws {
        let keychain = FakeKeychain()
        let store = store(keychain)
        _ = try await store.add(site: "github.com", username: "alice", password: password)

        await #expect(throws: LoginStoreError.siteTaken) {
            try await store.add(site: "www.github.com", username: "bob", password: password)
        }
        await #expect(throws: LoginStoreError.passwordTooShort) {
            try await store.add(site: "gitlab.com", username: "bob", password: LoginSecret("short"))
        }
        await #expect(throws: LoginStoreError.usernameRequired) {
            try await store.add(site: "gitlab.com", username: "", password: password)
        }
        await #expect(throws: LoginStoreError.site(.localhost)) {
            try await store.add(site: "localhost", username: "bob", password: password)
        }
        #expect(keychain.calls.filter { $0.kind == .add }.count == 1, "a refused login reached the keychain")
    }

    @Test("the five hundred and first login is refused before the keychain is written")
    func capped() async throws {
        let keychain = FakeKeychain()
        for index in 0..<LoginStoreRules.maximumLogins {
            keychain.seed(site: "site\(index).example", username: "u", password: "12345678")
        }

        await #expect(throws: LoginStoreError.full) {
            try await store(keychain).add(site: "one-more.example", username: "u", password: password)
        }
        #expect(keychain.calls.allSatisfy { $0.kind != .add })
    }

    @Test("an edit keeps the site; an empty password writes no data, a new one replaces it")
    func editRules() async throws {
        let keychain = FakeKeychain()
        let store = store(keychain)
        let saved = try await store.add(site: "github.com", username: "alice", password: password)

        let edited = try await store.update(id: saved.id, username: "alice@example.com", password: LoginSecret(""))
        let keep = try #require(keychain.calls.last { $0.kind == .update })
        #expect(edited == SavedLogin(id: saved.id, site: "github.com", username: "alice@example.com"))
        #expect(keep.attributes?[kSecValueData as String] == nil, "an empty password replaced the saved one")
        #expect(try await store.password(for: saved.id) == password)

        _ = try await store.update(id: saved.id, username: "alice@example.com", password: LoginSecret("battery staple"))
        let replace = try #require(keychain.calls.last { $0.kind == .update })
        #expect(replace.attributes?[kSecValueData as String] as? Data == Data("battery staple".utf8))
        #expect(try await store.list() == [edited])
    }

    @Test("a missing login is notFound for update, delete and the password read")
    func notFound() async throws {
        let store = store(FakeKeychain())
        let missing = UUID()

        await #expect(throws: LoginStoreError.notFound) {
            try await store.update(id: missing, username: "alice", password: nil)
        }
        await #expect(throws: LoginStoreError.notFound) { try await store.delete(id: missing) }
        await #expect(throws: LoginStoreError.notFound) { try await store.password(for: missing) }
        #expect(try await store.list().isEmpty)
    }

    @Test("a keychain refusal is answered with its OSStatus")
    func refusalNamesStatus() async throws {
        let keychain = FakeKeychain()
        keychain.failing = -34018

        await #expect(throws: LoginStoreError.unavailable(status: -34018)) { try await store(keychain).list() }
        await #expect(throws: LoginStoreError.unavailable(status: -34018)) {
            try await store(keychain).add(site: "github.com", username: "alice", password: password)
        }
    }

    @Test("an item this store cannot read is refused loudly, not skipped")
    func unreadableItem() async throws {
        let keychain = FakeKeychain()
        keychain.seedRaw(generic: Data(#"{"v":2,"site":"github.com","username":"alice"}"#.utf8))

        await #expect(throws: LoginStoreError.unavailable(status: errSecDecode)) { try await store(keychain).list() }
    }

    /// The bound is the store's own; the keychain call below never returns
    /// until the test releases it, so the answer can only be the bound's.
    @Test("a call past its bound answers timedOut, and a call queued behind it never runs late")
    func bounded() async throws {
        let keychain = FakeKeychain()
        let store = store(keychain, bound: 0.05)
        keychain.block()

        await #expect(throws: LoginStoreError.timedOut) { try await store.list() }
        await #expect(throws: LoginStoreError.timedOut) {
            try await store.add(site: "github.com", username: "alice", password: password)
        }
        keychain.release()

        let unblocked = KeychainLoginStore(accessGroup: group, calls: keychain, bound: 5, queue: store.queue)
        #expect(try await unblocked.list().isEmpty)
        #expect(keychain.calls.allSatisfy { $0.kind != .add }, "an add that timed out ran later")
    }
}

/// The real data protection keychain, on a build that can reach it.
///
/// `swift test` runs an unsigned test runner, which no keychain access group
/// is ever granted to, so these tests are skipped with their reason off a
/// signed build; on one they add, list, read, replace and delete one real item
/// and remove it on every path. They are part of the S1 acceptance on a signed
/// build (§13), not of CI.
@Suite("Website login keychain store, signed build")
struct KeychainLoginStoreSignedBuildTests {
    private static let granted = LoginStoreSelection.grantedAccessGroups()

    @Test(
        "add, list without data, read one, replace and delete a real item",
        .enabled(if: !granted.isEmpty, "needs a build signed with keychain-access-groups; this test runner carries none")
    )
    func roundTrip() async throws {
        let store = KeychainLoginStore(accessGroup: try #require(Self.granted.first))
        let site = "m84-acceptance-\(UUID().uuidString.prefix(8).lowercased()).example"
        let saved = try await store.add(site: site, username: "acceptance", password: LoginSecret("first password"))

        do {
            #expect(try await store.list().contains(saved))
            #expect(try await store.password(for: saved.id) == LoginSecret("first password"))
            _ = try await store.update(id: saved.id, username: "acceptance", password: LoginSecret("second password"))
            #expect(try await store.password(for: saved.id) == LoginSecret("second password"))
        } catch {
            try await store.delete(id: saved.id)
            throw error
        }
        try await store.delete(id: saved.id)
        #expect(try await store.login(forHost: site) == nil)
    }
}

/// A keychain in memory that records every call the store makes and answers
/// as `SecItem` does for the few query shapes the store uses.
final class FakeKeychain: KeychainItemCalls, @unchecked Sendable {
    enum Kind { case copyMatching, add, update, delete }

    struct Call {
        let kind: Kind
        let query: [String: Any]
        let attributes: [String: Any]?
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var blocked = false
    private var items: [String: [String: Any]] = [:]
    private var recorded: [Call] = []
    private var failure: OSStatus?

    var calls: [Call] { lock.withLock { recorded } }

    var failing: OSStatus? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    func block() { lock.withLock { blocked = true } }

    func release() {
        lock.withLock { blocked = false }
        gate.signal()
    }

    func seed(site: String, username: String, password: String) {
        let generic = try? JSONSerialization.data(withJSONObject: ["v": 1, "site": site, "username": username])
        seedRaw(generic: generic ?? Data(), password: password)
    }

    func seedRaw(generic: Data, password: String = "12345678") {
        let account = UUID().uuidString
        lock.withLock {
            items[account] = [
                kSecAttrAccount as String: account,
                kSecAttrGeneric as String: generic,
                kSecValueData as String: Data(password.utf8)
            ]
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        record(.copyMatching, query)
        if let failing { return (failing, nil) }
        return lock.withLock {
            if query[kSecReturnData as String] as? Bool == true {
                guard let item = items[query[kSecAttrAccount as String] as? String ?? ""] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, item[kSecValueData as String])
            }
            let found = items.values.map { $0.filter { $0.key != kSecValueData as String } }
            return found.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, found)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        record(.add, attributes)
        if let failing { return failing }
        return lock.withLock {
            items[attributes[kSecAttrAccount as String] as? String ?? ""] = attributes
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        record(.update, query, attributes)
        if let failing { return failing }
        return lock.withLock {
            let account = query[kSecAttrAccount as String] as? String ?? ""
            guard let item = items[account] else { return errSecItemNotFound }
            items[account] = item.merging(attributes) { _, new in new }
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        record(.delete, query)
        if let failing { return failing }
        return lock.withLock {
            items.removeValue(forKey: query[kSecAttrAccount as String] as? String ?? "") == nil
                ? errSecItemNotFound : errSecSuccess
        }
    }

    private func record(_ kind: Kind, _ query: [String: Any], _ attributes: [String: Any]? = nil) {
        lock.withLock {
            recorded.append(Call(kind: kind, query: query, attributes: attributes, onMainThread: Thread.isMainThread))
        }
        if lock.withLock({ blocked }) { gate.wait() }
    }
}
