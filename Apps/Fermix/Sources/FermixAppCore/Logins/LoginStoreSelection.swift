import Foundation
import Security

/// Which login store this build gets, decided once at the composition root
/// (M84 §7, D6).
///
/// The keychain store needs the production keychain access group in this
/// process's own signature. Only a release signed with the Developer ID
/// provisioning profile carries it (`scripts/sign_app.sh`), and macOS kills a
/// process whose signature claims the group without a profile that authorizes
/// it, so a running process that holds the entitlement holds it legitimately.
/// The answer is read from the signature rather than inferred from a keychain
/// refusal: a build without the group gets `UnavailableLoginStore` by this one
/// decision, never by a retry of another store after the keychain said no.
///
/// A `DEBUG` build never sees the production group at all: it is compiled into
/// release builds only, because a debug build's web views are inspectable and
/// Web Inspector reads `input.value` in the page.
public enum LoginStoreSelection {
    /// What a build gets, and why.
    public enum Choice: Equatable, Sendable {
        case keychain(accessGroup: String)
        case unavailable(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// A `DEBUG` build: the production group is not compiled in.
        case debugBuild
        /// A release build whose signature does not grant the production group
        /// (ad-hoc, or Developer ID without the provisioning profile).
        case accessGroupNotGranted
    }

    /// The store for this process, chosen once and logged with its reason.
    public static func forThisProcess() -> any LoginStore {
        let choice = choose(productionGroup: productionGroup, grantedGroups: grantedAccessGroups())
        log(choice)
        return store(for: choice)
    }

    /// The decision, pure: the production group when this build compiles one in
    /// and the signature grants exactly it; otherwise no store, and why.
    public static func choose(productionGroup: String?, grantedGroups: [String]) -> Choice {
        guard let productionGroup else { return .unavailable(.debugBuild) }
        guard grantedGroups.contains(productionGroup) else { return .unavailable(.accessGroupNotGranted) }
        return .keychain(accessGroup: productionGroup)
    }

    static func store(for choice: Choice) -> any LoginStore {
        switch choice {
        case .keychain(let accessGroup): KeychainLoginStore(accessGroup: accessGroup)
        case .unavailable: UnavailableLoginStore()
        }
    }

    /// The `keychain-access-groups` this process's signature carries. An
    /// unreadable signature grants nothing, and says so in the log.
    static func grantedAccessGroups() -> [String] {
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
        case .unavailable(.debugBuild):
            logger.info("website logins: no store, this is a debug build")
        case .unavailable(.accessGroupNotGranted):
            logger.info("website logins: no store, this build's signature grants no login access group")
        }
    }
}

extension LoginStoreSelection {
    /// The production keychain access group, in release builds only. Nil in
    /// every `DEBUG` build, which therefore never gets the keychain store.
    #if !DEBUG
    static let productionGroup: String? = "54A57TH9BJ.io.tezra.FermixPet.logins"
    #else
    static let productionGroup: String? = nil
    #endif
}
