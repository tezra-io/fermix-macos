import Foundation
import Testing

@testable import FermixAppCore

/// Which store a build gets (M84 §7, D6), decided once, in one visible place.
///
/// The keychain store needs this build's access group in this process's
/// signature, which only a bundle signed with a Developer ID provisioning
/// profile for its identity carries: the release with the production profile,
/// the dev loop's `Fermix Dev` with the development one. macOS kills a process
/// that claims a group without a profile authorizing it, so a running process
/// that holds the entitlement holds it legitimately. Which group a build may use
/// is compiled in: a release build the production group, a `DEBUG` build the
/// development identity's, never the production one. A build without the
/// entitlement (ad-hoc, or Developer ID without a profile) gets the unavailable
/// store, by that decision and never by a retry after a keychain refusal.
@Suite("Website login store selection")
struct LoginStoreSelectionTests {
    private let group = "TEAMID1234.example.app.logins"
    private static let productionGroup = "54A57TH9BJ.io.tezra.FermixPet.logins"
    private static let developmentGroup = "54A57TH9BJ.io.tezra.FermixPet.dev.logins"

    @Test("a build granted its group gets the keychain store in that group")
    func granted() {
        let choice = LoginStoreSelection.choose(accessGroup: group, grantedGroups: ["TEAMID1234.other", group])

        #expect(choice == .keychain(accessGroup: group))
    }

    @Test("a build without its group, or with only another one, gets no store")
    func notGranted() {
        #expect(LoginStoreSelection.choose(accessGroup: group, grantedGroups: []) == .unavailable)
        #expect(
            LoginStoreSelection.choose(accessGroup: group, grantedGroups: ["TEAMID1234.example.app.dev.logins"])
                == .unavailable
        )
        #expect(
            LoginStoreSelection.choose(accessGroup: group, grantedGroups: ["TEAMID1234.*"]) == .unavailable,
            "a granted group is a literal; a wildcard belongs to a profile, never to a signature"
        )
    }

    @Test("each choice builds its own store")
    func storesMatchChoices() {
        #expect(LoginStoreSelection.store(for: .unavailable) is UnavailableLoginStore)
        let keychain = LoginStoreSelection.store(for: .keychain(accessGroup: group)) as? KeychainLoginStore
        #expect(keychain?.accessGroup == group)
    }

    #if DEBUG
    /// The suite runs as a debug build, so this is the fact a dev build ships
    /// with: the development identity's group, and the unavailable store until
    /// a signature grants it, which this test process's does not.
    @Test("this debug build uses the development group, and its unsigned test process gets no store")
    func thisBuildUsesTheDevelopmentGroup() {
        #expect(LoginStoreSelection.accessGroup == Self.developmentGroup)
        #expect(LoginStoreSelection.forThisProcess() is UnavailableLoginStore)
    }

    /// Web Inspector reads `input.value` in the page, so the pages of a debug
    /// build are inspectable only while its signature can hold no login.
    @Test("a debug build's pages are inspectable only while its signature grants no access group")
    func inspectorOnlyWithoutLogins() {
        #expect(LoginStoreSelection.allowsWebInspector(grantedGroups: []))
        #expect(!LoginStoreSelection.allowsWebInspector(grantedGroups: [Self.developmentGroup]))
        #expect(!LoginStoreSelection.allowsWebInspector(grantedGroups: ["TEAMID1234.other"]))
    }
    #endif

    /// Each group's literal lives in one file, under its own compilation
    /// branch, so no debug build can be compiled with the production group and
    /// no release with the development one (§7). A second copy, or one outside
    /// its branch, fails here.
    @Test("each group appears once in the sources, and only in its own build's branch")
    func groupsAreCompiledPerBuild() throws {
        for (literal, branch) in [(Self.productionGroup, "!DEBUG"), (Self.developmentGroup, "DEBUG")] {
            let holders = try SourceTree.swiftFiles(under: "", excluding: false).filter { $0.text.contains(literal) }

            #expect(holders.count == 1, "\(literal) is held by \(holders.map(\.path))")
            let text = try #require(holders.first?.text)
            #expect(text.components(separatedBy: literal).count == 2, "\(literal) appears more than once")
            #expect(Self.branch(of: literal, in: text) == branch, "\(literal) is outside the \(branch) branch")
        }
    }

    /// The group a build looks for is the one its identity's signature is
    /// given: `scripts/sign_app.sh` signs each bundle identifier with the
    /// keychain entitlements named for it, and a drift between the two would
    /// build an app that never finds its own logins.
    @Test("each compiled group is the one its identity's keychain entitlements grant")
    func groupsMatchTheSignedEntitlements() throws {
        let identities = [("io.tezra.FermixPet", Self.productionGroup), ("io.tezra.FermixPet.dev", Self.developmentGroup)]
        for (bundleIdentifier, literal) in identities {
            let url = SourceTree.repositoryRoot
                .appendingPathComponent("scripts/entitlements/keychain/\(bundleIdentifier).entitlements")
            let entitlements = try #require(
                try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
            )

            #expect(entitlements["keychain-access-groups"] as? [String] == [literal], "\(url.lastPathComponent)")
        }
    }

    /// Which compilation branch is open at `needle`: the condition of the last
    /// `#if` before it, negated when an `#else` of that `#if` comes between,
    /// and nil when an `#endif` closes it first or no `#if` is open.
    private static func branch(of needle: String, in text: String) -> String? {
        guard let range = text.range(of: needle) else { return nil }
        let before = text[..<range.lowerBound].split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let open = before.lastIndex(where: { $0.hasPrefix("#if ") }) else { return nil }
        let after = before[(open + 1)...]
        if after.contains(where: { $0.hasPrefix("#endif") || $0.hasPrefix("#elseif") }) { return nil }
        let condition = String(before[open].dropFirst("#if ".count))
        return after.contains(where: { $0.hasPrefix("#else") }) ? "!" + condition : condition
    }
}
