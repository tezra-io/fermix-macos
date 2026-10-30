import Foundation

/// A login store held in memory for the life of the process: every test above
/// the keychain, previews and the fixture configuration stand on it. It keeps
/// exactly the rules the keychain store keeps (`LoginStoreRules`).
public actor InMemoryLoginStore: LoginStore {
    private var logins: [UUID: SavedLogin] = [:]
    private var passwords: [UUID: LoginSecret] = [:]

    public init() {}

    public func list() async throws -> [SavedLogin] {
        LoginStoreRules.ordered(Array(logins.values))
    }

    public func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin {
        let existing = Array(logins.values)
        if let refusal = LoginStoreRules.refusals(site: site, username: username, password: password, existing: existing).first {
            throw refusal
        }
        let login = SavedLogin(id: UUID(), site: try LoginSite.key(site).mapError(LoginStoreError.site).get(), username: username)
        logins[login.id] = login
        passwords[login.id] = password
        return login
    }

    public func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin {
        guard let saved = logins[id] else { throw LoginStoreError.notFound }
        if let refusal = LoginStoreRules.refusals(username: username, password: password).first { throw refusal }

        let login = SavedLogin(id: id, site: saved.site, username: username)
        logins[id] = login
        if let replacement = LoginStoreRules.replaces(password) { passwords[id] = replacement }
        return login
    }

    public func delete(id: UUID) async throws {
        guard logins.removeValue(forKey: id) != nil else { throw LoginStoreError.notFound }
        passwords[id] = nil
    }

    public func login(forHost host: String) async throws -> SavedLogin? {
        let site = LoginSite.site(forHost: host, among: logins.values.map(\.site))
        return logins.values.first { $0.site == site }
    }

    public func password(for id: UUID) async throws -> LoginSecret {
        guard let password = passwords[id] else { throw LoginStoreError.notFound }
        return password
    }
}
