import Foundation
import Security

/// Which login store this build gets, decided once at the composition root
/// (M84 §7, D6).
///
/// The keychain store needs this build's keychain access group in this
/// process's own signature. Only a bundle signed with a Developer ID
/// provisioning profile for its identity carries it (`scripts/sign_app.sh`):
/// the release with the production profile, and the dev loop's `Fermix Dev`
/// with the development one. macOS kills a process whose signature claims the
/// group without a profile that authorizes it, so a running process that holds
/// the entitlement holds it legitimately. The answer is read from the signature
/// rather than inferred from a keychain refusal: a build without the group gets
/// `UnavailableLoginStore` by this one decision, never by a retry of another
/// store after the keychain said no.
///
/// Which group a build may use is compiled in: a release build only the
/// production group, a `DEBUG` build only the development identity's. A debug
/// build's web views are inspectable, and Web Inspector reads `input.value` in
/// the page, so the production group never goes into one, and a debug build
/// whose signature does hold a group turns the inspector off
/// (`allowsWebInspector`).
public enum LoginStoreSelection {
    /// What a build gets.
    public enum Choice: Equatable, Sendable {
        case keychain(accessGroup: String)
        /// A signature that does not grant this build's group: ad-hoc, or
        /// Developer ID without a provisioning profile for its identity.
        case unavailable
    }

    /// The store for this process, chosen once and logged.
    public static func forThisProcess() -> any LoginStore {
        let choice = choose(accessGroup: accessGroup, grantedGroups: grantedAccessGroups())
        log(choice)
        return store(for: choice)
    }

    /// The decision, pure: this build's group when the signature grants exactly
    /// it; otherwise no store.
    public static func choose(accessGroup: String, grantedGroups: [String]) -> Choice {
        guard grantedGroups.contains(accessGroup) else { return .unavailable }
        return .keychain(accessGroup: accessGroup)
    }

    /// Whether this build's web views may offer Web Inspector, which reads
    /// `input.value` in the page: only a debug build, and only while its
    /// signature grants no keychain access group, so no build that can hold a
    /// website login ever offers it.
    public static func allowsWebInspector(grantedGroups: [String]) -> Bool {
        #if DEBUG
        return grantedGroups.isEmpty
        #else
        return false
        #endif
    }

    static func store(for choice: Choice) -> any LoginStore {
        switch choice {
        case .keychain(let accessGroup): KeychainLoginStore(accessGroup: accessGroup)
        case .unavailable: UnavailableLoginStore()
        }
    }

    /// The `keychain-access-groups` this process's signature carries. An
    /// unreadable signature grants nothing, and says so in the log.
    public static func grantedAccessGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else {
            AppLog.logger(.app).error("website logins: this process's signature could not be read")
            return []
        }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, &error)
        if let error {
            let reason = error.takeRetainedValue().localizedDescription
            AppLog.logger(.app).error("website logins: the access groups could not be read: \(reason, privacy: .public)")
            return []
        }
        return value as? [String] ?? []
    }

    private static func log(_ choice: Choice) {
        let logger = AppLog.logger(.app)
        switch choice {
        case .keychain(let accessGroup):
            logger.info("website logins: the keychain store, access group \(accessGroup, privacy: .public)")
        case .unavailable:
            logger.info("website logins: no store, this build's signature does not grant \(accessGroup, privacy: .public)")
        }
    }
}

extension LoginStoreSelection {
    /// The keychain access group this build looks for: the production group in
    /// a release build, the development identity's in a `DEBUG` one. Each is
    /// granted only by its identity's provisioning profile.
    #if DEBUG
    static let accessGroup = "54A57TH9BJ.io.tezra.FermixPet.dev.logins"
    #else
    static let accessGroup = "54A57TH9BJ.io.tezra.FermixPet.logins"
    #endif
}
