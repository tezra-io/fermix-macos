#if DEBUG
import Foundation
import Testing

@testable import FermixAppCore

@Suite("Development background registration")
@MainActor
struct DevelopmentBackgroundRegistrationTests {
    @Test("development registration refuses a production home or port", arguments: [false, true])
    func isolationIsRequired(wrongHome: Bool) throws {
        let harness = try ActivationHarness(registered: false, daemonRunning: false)
        let product = try ProductConfiguration.bundled()
        let bundle = harness.root.appendingPathComponent("Fermix.app", isDirectory: true)
        let home = harness.root.appendingPathComponent(wrongHome ? ".fermix" : ".fermix-macos")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try harness.store.save(fermixHome: home)
        try writePlist(bundle: bundle, product: product, port: wrongHome ? "4530" : "4030")

        let refusal: DevelopmentEngineRegistration.Refusal = wrongHome
            ? .developmentHomeRequired : .developmentPortRequired
        #expect(throws: refusal) {
            try DevelopmentEngineRegistration.validate(
                location: harness.location, bundleURL: bundle, product: product
            )
        }
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    @Test("the isolated bundle validates before the GUI registers it")
    func isolatedBundleIsAccepted() throws {
        let harness = try ActivationHarness(registered: false, daemonRunning: false)
        let product = try ProductConfiguration.bundled()
        let bundle = harness.root.appendingPathComponent("Fermix.app", isDirectory: true)
        let home = harness.root.appendingPathComponent(".fermix-macos", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try harness.store.save(fermixHome: home)
        try writePlist(bundle: bundle, product: product, port: "4530")
        try DevelopmentEngineRegistration.validate(location: harness.location, bundleURL: bundle, product: product)
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    @Test("explicit startup uses the GUI lifecycle and keeps its window", arguments: [false, true])
    func startupUsesTheCoordinator(registerBackground: Bool) async throws {
        let harness = try CoordinatorHarness(bootstrap: .present)
        AppLaunchPlan.openDevelopmentLaunch(
            coordinator: harness.coordinator, reason: .user, registerBackground: registerBackground
        )
        try await harness.coordinator.drainPendingWork()

        #expect(harness.lifecycle.calls == (registerBackground ? [.enable] : []))
        #expect(harness.windows.presented == [.main])
        #expect(harness.model.route == .home)
    }

    private func writePlist(bundle: URL, product: ProductConfiguration, port: String) throws {
        let directory = bundle.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["EnvironmentVariables": ["PORT": port]], format: .xml, options: 0
        )
        try data.write(to: directory.appendingPathComponent("\(product.agentServiceLabel).plist"))
    }
}
#endif
