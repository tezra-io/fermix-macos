import Foundation
import Testing

@testable import FermixAppCore

@Suite("Installed app build identity")
struct AppBuildIdentityTests {
    @Test("release-stamped bundle values identify the installed app")
    func readsTheInstalledIdentity() throws {
        let build = try AppBuild(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "42"
        ])

        #expect(build == AppBuild(marketingVersion: "0.2.0", buildNumber: 42))
    }

    @Test("a bundle without an identity is refused instead of using source defaults")
    func refusesMissingIdentity() {
        #expect(throws: AppBuildError.missingMarketingVersion) {
            try AppBuild(infoDictionary: [:])
        }
    }

    @Test("invalid bundle build numbers are refused", arguments: ["0", "-1", "01", "1.2", ""])
    func refusesInvalidBuild(_ value: String) {
        #expect(throws: AppBuildError.invalidBuildNumber) {
            try AppBuild(infoDictionary: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": value])
        }
    }
}
