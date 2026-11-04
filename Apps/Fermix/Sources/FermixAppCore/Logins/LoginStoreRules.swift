import Foundation

/// What a login must be before any store saves it (M84 §7). Pure, and the one
/// owner of these rules: every store throws the first refusal from these
/// lists, and the save sheet shows all of them at once, so the two cannot
/// disagree.
public enum LoginStoreRules {
    /// The scrub matches exact text, and a very short password would both
    /// scrub ordinary words and be guessable from what it leaves. Counted as
    /// characters (`String.count`), what the owner typed.
    public static let minimumPasswordLength = 8
    public static let maximumLogins = 500

    /// Every refusal a new login meets, in field order: the site, the username,
    /// the password, then the site already taken and the store full, against
    /// the logins already saved.
    public static func refusals(
        site: String,
        username: String,
        password: LoginSecret,
        existing: [SavedLogin]
    ) -> [LoginStoreError] {
        var refusals: [LoginStoreError] = []
        let key = LoginSite.key(site)
        if case .failure(let refusal) = key { refusals.append(.site(refusal)) }
        refusals += usernameAndPassword(username: username, password: password)
        if case .success(let site) = key, existing.contains(where: { $0.site == site }) {
            refusals.append(.siteTaken)
        }
        if existing.count >= maximumLogins { refusals.append(.full) }
        return refusals
    }

    /// Every refusal an edit meets. The site never changes, and a nil or empty
    /// password keeps the saved one, so neither is refused here.
    public static func refusals(username: String, password: LoginSecret?) -> [LoginStoreError] {
        usernameAndPassword(username: username, password: replaces(password))
    }

    /// Whether an edit's password replaces the saved one.
    static func replaces(_ password: LoginSecret?) -> LoginSecret? {
        guard let password, !password.withValue(\.isEmpty) else { return nil }
        return password
    }

    /// The order every store lists in.
    static func ordered(_ logins: [SavedLogin]) -> [SavedLogin] {
        logins.sorted { ($0.site, $0.id.uuidString) < ($1.site, $1.id.uuidString) }
    }

    private static func usernameAndPassword(username: String, password: LoginSecret?) -> [LoginStoreError] {
        var refusals: [LoginStoreError] = []
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refusals.append(.usernameRequired)
        }
        if let password, password.withValue({ $0.count }) < minimumPasswordLength {
            refusals.append(.passwordTooShort)
        }
        return refusals
    }
}
