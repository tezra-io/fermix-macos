import Foundation

/// The store of a build that has none: every `DEBUG` build and every build
/// whose signature grants no keychain access group (`LoginStoreSelection`).
/// Every call answers `.unavailable(status: nil)`, which the Settings section
/// shows as "Website logins need the released Fermix app." and the browser
/// host answers as `sign_in_store_unavailable`.
public struct UnavailableLoginStore: LoginStore {
    public init() {}

    public func list() async throws -> [SavedLogin] { throw Self.refusal }

    public func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin {
        throw Self.refusal
    }

    public func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin {
        throw Self.refusal
    }

    public func delete(id: UUID) async throws { throw Self.refusal }

    public func login(forHost host: String) async throws -> SavedLogin? { throw Self.refusal }

    public func password(for id: UUID) async throws -> LoginSecret { throw Self.refusal }

    private static let refusal = LoginStoreError.unavailable(status: nil)
}
