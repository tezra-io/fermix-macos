import Foundation
import Security

/// The four `SecItem` calls the keychain store makes, behind one seam so the
/// store's queries can be proven on a build no keychain access group is
/// granted to. `SystemKeychain` is the only implementation that ships.
protocol KeychainItemCalls: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychain: KeychainItemCalls {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// The release store: website logins in the Mac's data protection keychain,
/// in an access group only the Fermix app signed by its team can open (M84 §7).
///
/// One generic-password item per login: the service names the store, the
/// account is the login's id, the generic attribute is the JSON
/// `{"v":1,"site":…,"username":…}`, and the data is the password as UTF-8.
/// Every call names the data protection keychain and the access group, every
/// item is this Mac's only (`AfterFirstUnlockThisDeviceOnly`, D5, so a sign-in
/// approved from the phone works while the Mac is locked; never synchronized),
/// and no item carries a user-presence flag: the owner approves in the chat.
///
/// Every operation runs as one job on the store's own serial queue, never the
/// main actor, so a rule that reads the list before it writes (one login per
/// site, the cap) sees no other write in between. Each is bounded: past the
/// bound the caller is answered `.timedOut`, and a job that had not started by
/// then never starts. A `SecItem` call that has started cannot be withdrawn, so
/// one that hangs past the bound and then returns still completes its write.
public struct KeychainLoginStore: LoginStore {
    static let service = "io.tezra.FermixPet.login"
    static let defaultBound: TimeInterval = 5

    let accessGroup: String
    let calls: any KeychainItemCalls
    let bound: TimeInterval
    let queue: DispatchQueue

    public init(accessGroup: String) {
        self.init(accessGroup: accessGroup, calls: SystemKeychain(), bound: Self.defaultBound)
    }

    init(
        accessGroup: String,
        calls: any KeychainItemCalls,
        bound: TimeInterval,
        queue: DispatchQueue = DispatchQueue(label: "ai.fermix.app.logins.keychain")
    ) {
        precondition(!accessGroup.isEmpty, "a keychain login store needs an access group")
        precondition(bound > 0, "a keychain login store's bound must be positive")
        self.accessGroup = accessGroup
        self.calls = calls
        self.bound = bound
        self.queue = queue
    }

    public func list() async throws -> [SavedLogin] {
        try await run { [self] in LoginStoreRules.ordered(try readList()) }
    }

    public func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin {
        try await run { [self] in
            let existing = try readList()
            if let refusal = LoginStoreRules.refusals(site: site, username: username, password: password, existing: existing).first {
                throw refusal
            }
            let login = SavedLogin(id: UUID(), site: try LoginSite.key(site).mapError(LoginStoreError.site).get(), username: username)
            var item = itemQuery(login.id)
            item[kSecAttrGeneric as String] = try Self.encode(login)
            item[kSecValueData as String] = password.withValue { Data($0.utf8) }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(calls.add(item), "add")
            return login
        }
    }

    public func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin {
        try await run { [self] in
            guard let saved = try readList().first(where: { $0.id == id }) else { throw LoginStoreError.notFound }
            if let refusal = LoginStoreRules.refusals(username: username, password: password).first { throw refusal }

            let login = SavedLogin(id: id, site: saved.site, username: username)
            var changes: [String: Any] = [kSecAttrGeneric as String: try Self.encode(login)]
            if let replacement = LoginStoreRules.replaces(password) {
                changes[kSecValueData as String] = replacement.withValue { Data($0.utf8) }
            }
            try check(calls.update(itemQuery(id), changes), "update")
            return login
        }
    }

    public func delete(id: UUID) async throws {
        try await run { [self] in try check(calls.delete(itemQuery(id)), "delete") }
    }

    public func login(forHost host: String) async throws -> SavedLogin? {
        try await run { [self] in
            let logins = try readList()
            let site = LoginSite.site(forHost: host, among: logins.map(\.site))
            return logins.first { $0.site == site }
        }
    }

    public func password(for id: UUID) async throws -> LoginSecret {
        try await run { [self] in
            var query = itemQuery(id)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = calls.copyMatching(query)
            try check(status, "password read")
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw refused(errSecDecode, "password read")
            }
            return LoginSecret(value)
        }
    }

    // MARK: - Queries

    /// What every call names: the store's items, in the data protection
    /// keychain, in the access group, this Mac's only.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func itemQuery(_ id: UUID) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = id.uuidString
        return query
    }

    /// Every login's attributes, never a password.
    private func readList() throws -> [SavedLogin] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        let (status, result) = calls.copyMatching(query)
        if status == errSecItemNotFound { return [] }
        try check(status, "list")
        guard let items = result as? [[String: Any]] else { throw refused(errSecDecode, "list") }
        return try items.map(decode)
    }

    // MARK: - Attributes

    private struct ItemAttributes: Codable {
        let v: Int
        let site: String
        let username: String
    }

    private static func encode(_ login: SavedLogin) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(ItemAttributes(v: 1, site: login.site, username: login.username))
        } catch {
            throw LoginStoreError.unavailable(status: errSecParam)
        }
    }

    /// One item's login. An item this version cannot read is refused rather
    /// than skipped, so a list never silently loses a login.
    private func decode(_ item: [String: Any]) throws -> SavedLogin {
        guard
            let account = item[kSecAttrAccount as String] as? String,
            let id = UUID(uuidString: account),
            let generic = item[kSecAttrGeneric as String] as? Data,
            let attributes = try? JSONDecoder().decode(ItemAttributes.self, from: generic),
            attributes.v == 1
        else {
            throw refused(errSecDecode, "list")
        }
        return SavedLogin(id: id, site: attributes.site, username: attributes.username)
    }

    // MARK: - Statuses

    private func check(_ status: OSStatus, _ operation: String) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw LoginStoreError.notFound
        default: throw refused(status, operation)
        }
    }

    /// A refusal names its `OSStatus` and the operation, never a site, a
    /// username or a password.
    private func refused(_ status: OSStatus, _ operation: String) -> LoginStoreError {
        AppLog.logger(.app).error("website logins: the keychain refused the \(operation, privacy: .public): OSStatus \(status, privacy: .public)")
        return .unavailable(status: status)
    }

    // MARK: - The bound

    /// Runs `work` as one job on the store's queue, answering `.timedOut` once
    /// the bound passes. A job the bound answered before it started never runs.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let call = BoundedCall<T>()
        return try await withCheckedThrowingContinuation { continuation in
            call.install(continuation)
            queue.async {
                guard call.start() else { return }
                call.finish(Result { try work() })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + bound) {
                if call.expire() {
                    AppLog.logger(.app).error("website logins: the keychain did not answer within the bound")
                }
            }
        }
    }
}

/// One bounded keychain call's answer, given exactly once: by the call when it
/// finishes, or by the bound when it passes first.
private final class BoundedCall<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// The queue's turn. False when the bound already answered, so the work is
    /// never started late.
    func start() -> Bool {
        lock.withLock { continuation != nil }
    }

    func finish(_ result: Result<T, Error>) {
        take()?.resume(with: result)
    }

    /// The bound's turn. True when it answered the caller.
    func expire() -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(throwing: LoginStoreError.timedOut)
        return true
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
