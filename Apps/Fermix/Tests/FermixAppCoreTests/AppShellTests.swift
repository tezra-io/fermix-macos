import Foundation
import Testing

@testable import FermixAppCore

/// The `fermix://` vocabulary. Every route is explicit: an unknown one is
/// refused rather than quietly resolved to Home.
@Suite("App routes")
struct AppRouteTests {
    @Test("every route has a url and parses back to itself")
    func routesRoundTrip() throws {
        for route in AppRoute.allCases {
            let parsed = try AppRoute.parse(route.url)

            #expect(parsed == route, "\(route.rawValue)")
            #expect(route.url.scheme == AppRoute.scheme)
        }
    }

    /// The scheme is registered in the bundle's Info.plist from Product.json,
    /// and parsed here from a Swift constant. This is the gate that keeps the
    /// two from drifting into a url the app advertises but refuses.
    @Test("the parsed scheme is the one the bundle registers")
    func schemeMatchesTheConfiguration() throws {
        let configuration = try ProductConfiguration.decode(from: ProductFixture.json())

        #expect(AppRoute.scheme == configuration.urlScheme)
    }

    /// The CLI's `upgrade` verb opens the update surface, so the published url
    /// keeps the verb the user typed.
    @Test("the CLI verbs open the routes M34 names")
    func cliVerbsMapToRoutes() throws {
        #expect(try AppRoute.parse(URL(string: "fermix://setup")!) == .setup)
        #expect(try AppRoute.parse(URL(string: "fermix://upgrade")!) == .update)
        #expect(try AppRoute.parse(URL(string: "fermix://uninstall")!) == .uninstall)
        #expect(try AppRoute.parse(URL(string: "fermix://recovery")!) == .recovery)
    }

    @Test("a foreign scheme, an unknown route, or parameters are refused")
    func refusesAnythingUnrecognized() {
        #expect(throws: AppRouteError.foreignScheme("https")) {
            _ = try AppRoute.parse(URL(string: "https://fermix.ai/setup")!)
        }
        #expect(throws: AppRouteError.unknownRoute("teleport")) {
            _ = try AppRoute.parse(URL(string: "fermix://teleport")!)
        }
        #expect(throws: AppRouteError.routeMissing) {
            _ = try AppRoute.parse(URL(string: "fermix://")!)
        }
        #expect(throws: AppRouteError.unexpectedParameters("setup")) {
            _ = try AppRoute.parse(URL(string: "fermix://setup?token=secret")!)
        }
        #expect(throws: AppRouteError.unexpectedParameters("setup")) {
            _ = try AppRoute.parse(URL(string: "fermix://setup/extra")!)
        }
    }

    @Test("recovery is an onboarding state and every other route is the main window")
    func routesNameTheirWindow() {
        #expect(AppRoute.recovery.window == .onboarding)

        for route in AppRoute.allCases where route != .recovery {
            #expect(route.window == .main, "\(route.rawValue)")
        }
    }

    /// The sidebar is the main window's navigation, so the routes that are
    /// sidebar destinations must name rows that exist.
    @Test("sidebar routes name real sidebar rows")
    func sidebarRoutesExist() {
        let identifiers = Set(SidebarItem.mainWindow.map(\.id))

        for route in AppRoute.allCases {
            guard let item = route.sidebarItemIdentifier else { continue }

            #expect(identifiers.contains(item), "\(route.rawValue)")
        }
    }
}

@Suite("Launch reason")
struct LaunchReasonTests {
    @Test("a login launch opens nothing and leaves the menu bar in charge")
    func loginLaunchIsQuiet() {
        let reason = LaunchClassifier.classify(isLoginLaunch: true, route: nil)

        #expect(reason == .login)
        #expect(AppCoordinator.presentation(for: reason, bootstrap: .present) == .menuBarOnly)
    }

    @Test("a user launch opens the main window once the account has a home")
    func userLaunchOpensMain() {
        let reason = LaunchClassifier.classify(isLoginLaunch: false, route: nil)

        #expect(reason == .user)
        #expect(AppCoordinator.presentation(for: reason, bootstrap: .present) == .main(.home))
    }

    /// With no bootstrap record this account has never activated, so the truthful
    /// surface is onboarding rather than a Home with nothing behind it.
    @Test("an account with no bootstrap record lands in onboarding")
    func freshAccountOpensOnboarding() {
        let reason = LaunchClassifier.classify(isLoginLaunch: false, route: nil)

        #expect(AppCoordinator.presentation(for: reason, bootstrap: .absent) == .onboarding)
    }

    /// A record that is there and unreadable is not a fresh account: sending it
    /// through onboarding would treat a broken install as a new one.
    @Test("an unreadable bootstrap record opens recovery, not onboarding")
    func unreadableBootstrapOpensRecovery() {
        let broken = BootstrapCondition.unreadable(.malformed(path: "/tmp/launcher.json"))

        #expect(AppCoordinator.presentation(for: .user, bootstrap: broken) == .recovery)
        #expect(AppCoordinator.presentation(for: .route(.doctor), bootstrap: broken) == .recovery)
        // A login launch still opens nothing: the menu bar is where it says so.
        #expect(AppCoordinator.presentation(for: .login, bootstrap: broken) == .menuBarOnly)
    }

    /// §4 writes a record for every interrupted transaction so recovery can read
    /// it. A launch that walks past one leaves the app claiming everything is
    /// normal while a disable is half-applied.
    @Test("an interrupted lifecycle transaction opens recovery, not Home")
    func interruptedTransactionOpensRecovery() {
        let interrupted = RecoveryCondition.interrupted(kind: .disable, phase: .mutate)

        #expect(AppCoordinator.presentation(for: .user, bootstrap: .present, recovery: interrupted) == .recovery)
        #expect(
            AppCoordinator.presentation(for: .route(.home), bootstrap: .present, recovery: interrupted) == .recovery
        )
        // A journal that cannot be read is a broken install too.
        #expect(
            AppCoordinator.presentation(for: .user, bootstrap: .present, recovery: .journalUnreadable) == .recovery
        )
        // A login launch still opens nothing: the menu bar is where it says so.
        #expect(
            AppCoordinator.presentation(for: .login, bootstrap: .present, recovery: interrupted) == .menuBarOnly
        )
        #expect(AppCoordinator.presentation(for: .user, bootstrap: .present, recovery: .none) == .main(.home))
    }

    /// A url is an explicit request, so it wins over a quiet login launch.
    @Test("a url launch opens its route even when macOS launched us at login")
    func urlLaunchWinsOverLogin() {
        let reason = LaunchClassifier.classify(isLoginLaunch: true, route: .doctor)

        #expect(reason == .route(.doctor))
        #expect(AppCoordinator.presentation(for: reason, bootstrap: .present) == .main(.doctor))
    }

    @Test("a recovery url opens onboarding even on a fresh account")
    func recoveryOpensOnboarding() {
        let reason = LaunchClassifier.classify(isLoginLaunch: false, route: .recovery)

        #expect(AppCoordinator.presentation(for: reason, bootstrap: .absent) == .recovery)
    }
}

/// Window geometry and single-instance policy, over an injected host so no
/// window server is involved.
@Suite("Window coordinator")
@MainActor
struct WindowCoordinatorTests {
    @Test("onboarding is a fixed 800 by 520 window")
    func onboardingGeometry() {
        let descriptor = WindowCoordinator.descriptor(for: .onboarding)

        #expect(descriptor.size == CGSize(width: 800, height: 520))
        #expect(descriptor.size == WindowMetrics.onboardingSize)
        #expect(descriptor.resizable == false)
        #expect(descriptor.floating == false)
    }

    @Test("the main window opens at 880 by 560 and is resizable")
    func mainGeometry() {
        let descriptor = WindowCoordinator.descriptor(for: .main)

        #expect(descriptor.size == CGSize(width: 880, height: 560))
        #expect(descriptor.size == WindowMetrics.mainDefaultSize)
        #expect(descriptor.resizable)
        #expect(descriptor.minimumSize == CGSize(width: WindowMetrics.sidebarWidth + 360, height: 420))
    }

    @Test("the pet window floats, is borderless, and is not resizable")
    func petGeometry() {
        let descriptor = WindowCoordinator.descriptor(for: .pet)

        #expect(descriptor.floating)
        #expect(descriptor.borderless)
        #expect(descriptor.resizable == false)
    }

    @Test("showing a window twice presents exactly one")
    func windowsAreSingleInstance() {
        let host = FakeWindowHost()
        let coordinator = WindowCoordinator(host: host)

        coordinator.show(.main)
        coordinator.show(.main)

        // One window, raised twice: showing again brings the existing one to
        // the front rather than building a second.
        #expect(host.presentations.filter { $0.kind == .main }.count == 1)
        #expect(host.focused == [.main, .main])
        #expect(host.isPresented(.main))
    }

    @Test("onboarding and the main window are never open at the same time")
    func onboardingAndMainAreExclusive() {
        let host = FakeWindowHost()
        let coordinator = WindowCoordinator(host: host)

        coordinator.show(.onboarding)
        coordinator.show(.main)

        #expect(host.presented.contains(.main))
        #expect(host.presented.contains(.onboarding) == false)
    }

    /// The pet is the one window that coexists with the others.
    @Test("the pet window coexists with the main window")
    func petCoexists() {
        let host = FakeWindowHost()
        let coordinator = WindowCoordinator(host: host)

        coordinator.show(.main)
        coordinator.show(.pet)

        #expect(host.presented == [.main, .pet])
    }

    @Test("closing every window leaves the app running")
    func closingEveryWindowKeepsTheAppAlive() {
        let host = FakeWindowHost()
        let coordinator = WindowCoordinator(host: host)

        coordinator.show(.main)
        coordinator.show(.pet)
        coordinator.close(.main)
        coordinator.close(.pet)

        #expect(host.presented.isEmpty)
        #expect(coordinator.isVisible(.pet) == false)
    }

    /// Occlusion drives whether the pet animates: off screen, behind another
    /// window, or on another Space all mean "do not spend a frame".
    ///
    /// Driven through the entry point production uses, so deleting the app
    /// delegate's notification wiring would fail here rather than leave the
    /// invariant proven against a seam nothing calls.
    @Test("occlusion tracking is what reports pet visibility")
    func occlusionTracksVisibility() {
        let host = FakeWindowHost()
        let coordinator = WindowCoordinator(host: host)

        coordinator.show(.pet)
        #expect(coordinator.isVisible(.pet))

        #expect(coordinator.visibilityChanged(false, for: .pet) == false)
        #expect(coordinator.isVisible(.pet) == false)

        #expect(coordinator.visibilityChanged(true, for: .pet))
        #expect(coordinator.isVisible(.pet))
    }

    /// A window that is not open is not visible however the occlusion observer
    /// reports it: the observer sees every window in the process.
    @Test("a closed window stays invisible whatever occlusion reports")
    func occlusionNeverResurrectsAClosedWindow() {
        let host = FakeWindowHost()
        let coordinator = WindowCoordinator(host: host)

        #expect(coordinator.visibilityChanged(true, for: .pet) == false)
        #expect(coordinator.isVisible(.pet) == false)
    }

    @Test("a window that was never opened is not visible")
    func unopenedWindowsAreNotVisible() {
        let coordinator = WindowCoordinator(host: FakeWindowHost())

        #expect(coordinator.isVisible(.main) == false)
    }
}

@MainActor
final class FakeWindowHost: WindowHost {
    private(set) var presentations: [WindowDescriptor] = []
    private(set) var presented: [WindowKind] = []
    private(set) var focused: [WindowKind] = []

    func present(_ descriptor: WindowDescriptor) {
        presentations.append(descriptor)
        presented.append(descriptor.kind)
    }

    func focus(_ kind: WindowKind) {
        focused.append(kind)
    }

    func dismiss(_ kind: WindowKind) {
        presented.removeAll { $0 == kind }
    }

    func isPresented(_ kind: WindowKind) -> Bool {
        presented.contains(kind)
    }
}
