import Foundation
import Testing

@testable import FermixAppCore

/// Which store a build gets (M84 §7, D6), decided once, in one visible place.
///
/// The keychain store needs the production access group in this process's
/// signature, which only a release signed with the Developer ID provisioning
/// profile carries; macOS kills a process that claims the group without a
/// profile authorizing it, so a running process that holds the entitlement
/// holds it legitimately. A `DEBUG` build has no production group compiled in
/// at all, and a build without the entitlement (ad-hoc, or Developer ID
/// without the profile, as the dev loop signs) gets the unavailable store, by
/// that decision and never by a retry after a keychain refusal.
@Suite("Website login store selection")
struct LoginStoreSelectionTests {
    private let group = "TEAMID1234.example.app.logins"

    @Test("a build granted the production group gets the keychain store in that group")
    func granted() {
        let choice = LoginStoreSelection.choose(productionGroup: group, grantedGroups: ["TEAMID1234.other", group])

        #expect(choice == .keychain(accessGroup: group))
    }

    @Test("a build without the group, or with only another one, gets no store")
    func notGranted() {
        #expect(LoginStoreSelection.choose(productionGroup: group, grantedGroups: []) == .unavailable(.accessGroupNotGranted))
        #expect(
            LoginStoreSelection.choose(productionGroup: group, grantedGroups: ["TEAMID1234.example.app.dev.logins"])
                == .unavailable(.accessGroupNotGranted)
        )
        #expect(
            LoginStoreSelection.choose(productionGroup: group, grantedGroups: ["TEAMID1234.*"])
                == .unavailable(.accessGroupNotGranted),
            "a granted group is a literal; a wildcard belongs to a profile, never to a signature"
        )
    }

    @Test("a DEBUG build gets no store, even if its signature claimed a group")
    func debugBuild() {
        #expect(LoginStoreSelection.choose(productionGroup: nil, grantedGroups: [group]) == .unavailable(.debugBuild))
        #expect(LoginStoreSelection.choose(productionGroup: nil, grantedGroups: []) == .unavailable(.debugBuild))
    }

    @Test("each choice builds its own store")
    func storesMatchChoices() {
        #expect(LoginStoreSelection.store(for: .unavailable(.debugBuild)) is UnavailableLoginStore)
        #expect(LoginStoreSelection.store(for: .unavailable(.accessGroupNotGranted)) is UnavailableLoginStore)
        let keychain = LoginStoreSelection.store(for: .keychain(accessGroup: group)) as? KeychainLoginStore
        #expect(keychain?.accessGroup == group)
    }

    #if DEBUG
    /// The suite runs as a debug build, so this is the fact a dev build ships
    /// with: no production group, and so the unavailable store, whatever this
    /// test process's signature carries.
    @Test("this debug build has no production group compiled in, and so no store")
    func thisBuildHasNoGroup() {
        #expect(LoginStoreSelection.productionGroup == nil)
        #expect(LoginStoreSelection.forThisProcess() is UnavailableLoginStore)
    }
    #endif

    /// The production group's literal lives in one file, inside `#if !DEBUG`,
    /// so no debug build can be compiled with it (§6). A second copy, or one
    /// outside the condition, fails here.
    @Test("the production group appears once in the sources, and only in a release-only branch")
    func productionGroupIsReleaseOnly() throws {
        let literal = "54A57TH9BJ.io.tezra.FermixPet.logins"
        let holders = try SourceTree.swiftFiles(under: "", excluding: false).filter { $0.text.contains(literal) }

        #expect(holders.count == 1, "held by \(holders.map(\.path))")
        let text = try #require(holders.first?.text)
        #expect(text.components(separatedBy: literal).count == 2, "the literal appears more than once")
        #expect(Self.enclosingCondition(of: literal, in: text) == "#if !DEBUG")
    }

    /// The innermost compilation condition open at `needle`: the last `#if`
    /// line before it, provided no `#else`, `#elseif` or `#endif` closes or
    /// flips it first.
    private static func enclosingCondition(of needle: String, in text: String) -> String? {
        guard let range = text.range(of: needle) else { return nil }
        let before = text[..<range.lowerBound].split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let open = before.lastIndex(where: { $0.hasPrefix("#if") }) else { return nil }
        let closed = before[(open + 1)...].contains { $0.hasPrefix("#else") || $0.hasPrefix("#elseif") || $0.hasPrefix("#endif") }
        return closed ? nil : before[open]
    }
}
