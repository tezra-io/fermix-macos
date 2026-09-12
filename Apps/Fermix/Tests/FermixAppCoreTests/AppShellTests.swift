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

            #expect(parsed == .surface(route), "\(route.rawValue)")
            #expect(route.url.scheme == AppRoute.scheme)
        }
    }

    /// M34 §3.4's new family. Exactly one allowlisted segment, and it has to
    /// name a pane: the pane travels with the destination so the window and the
    /// selection come from one parsed value.
    @Test("every settings pane has a url and parses back to itself")
    func settingsPanesRoundTrip() throws {
        for pane in SettingsPane.allCases {
            let destination = AppDestination.settings(pane)

            #expect(try AppRoute.parse(destination.url) == destination, "\(pane.slug)")
            #expect(destination.url.absoluteString == "fermix://settings/\(pane.slug)")
            // Decision D1: settings is a presentation of the primary window,
            // so every settings url names that window and not one of its own.
            #expect(destination.window == .main)
        }
    }

    /// A slug this build does not publish is refused, and so is a bare host or
    /// a second segment: the family admits one segment and nothing else.
    @Test("an unknown settings slug is refused rather than resolved")
    func unknownSettingsSlugIsRefused() {
        #expect(throws: AppRouteError.unknownRoute("settings/teleport")) {
            _ = try AppRoute.parse(URL(string: "fermix://settings/teleport")!)
        }
        #expect(throws: AppRouteError.unknownRoute("settings/")) {
            _ = try AppRoute.parse(URL(string: "fermix://settings")!)
        }
        #expect(throws: AppRouteError.unknownRoute("settings/voice/extra")) {
            _ = try AppRoute.parse(URL(string: "fermix://settings/voice/extra")!)
        }
        #expect(throws: AppRouteError.unexpectedParameters("settings")) {
            _ = try AppRoute.parse(URL(string: "fermix://settings/voice?token=secret")!)
        }
    }

    /// The wire and the route speak one vocabulary, so a section the daemon
    /// assigns to a pane and a url that opens it cannot drift.
    @Test("every pane slug is the wire value the daemon publishes")
    func paneSlugsAreTheWireVocabulary() {
        #expect(SettingsPane.allCases.count == 13)
        #expect(Set(SettingsPane.allCases.map(\.slug)) == Set(ManagementSettingsPane.publishedValues.keys))

        for pane in SettingsPane.allCases {
            #expect(SettingsPane.pane(for: pane.wire) == pane, "\(pane.slug)")
        }
    }

    /// The four groups hold the thirteen panes exactly once each, in the
    /// design's own order.
    @Test("the four sidebar groups partition the thirteen panes")
    func groupsPartitionThePanes() {
        let grouped = SettingsPaneGroup.allCases.flatMap(\.panes)

        #expect(grouped == SettingsPane.allCases)
        #expect(SettingsPaneGroup.assistant.panes == [.providers, .personality, .memory])
        #expect(SettingsPaneGroup.connections.panes == [.channels, .integrations])
        #expect(SettingsPaneGroup.system.panes == [.sandbox, .permissions])
        #expect(SettingsPaneGroup.capabilities.panes.count == 6)
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
        #expect(try AppRoute.parse(URL(string: "fermix://upgrade")!) == .surface(.update))
        #expect(try AppRoute.parse(URL(string: "fermix://uninstall")!) == .surface(.uninstall))
        #expect(try AppRoute.parse(URL(string: "fermix://recovery")!) == .surface(.recovery))
    }

    /// Setup is a task rather than a sidebar destination, and the verb opens
    /// the assistant window (M34 §3.4). Where inside it is a question about the
    /// daemon's readiness, which `SetupRouting` answers.
    @Test("the setup verb uses the primary window and carries no parameters")
    func setupVerbOpensTheAssistant() throws {
        #expect(try AppRoute.parse(URL(string: "fermix://setup")!) == .surface(.setup))
        #expect(AppRoute.setup.window == .main)
        #expect(AppRoute.setup.sidebarItemIdentifier == nil)
        #expect(throws: AppRouteError.unexpectedParameters("setup")) {
            _ = try AppRoute.parse(URL(string: "fermix://setup?token=secret")!)
        }
    }

    /// A gating readiness failure names the screen that clears it, and a gap
    /// this assistant has no screen for opens the pane the daemon named rather
    /// than being folded onto a neighbour.
    @Test("fermix://setup lands on the screen the gating failure names")
    func setupRoutingFollowsTheGatingFailure() throws {
        let state = try ManagementValueFixture.setupState()

        // The golden home gates on the personalization one, which the About
        // you screen is what clears.
        #expect(SetupRouting.presentation(for: state) == .assistant(.aboutYou))
        // No daemon has answered, so Starting is the screen that finds out.
        #expect(SetupRouting.presentation(for: nil) == .assistant(.starting))
    }

    /// With nothing gating, the url opens Settings at the first advisory pane,
    /// or at Providers when there is none.
    @Test("fermix://setup with no gating failure opens Settings")
    func setupRoutingFallsToSettings() throws {
        let advisoryOnly = try ManagementValueFixture.setupState(gating: false)
        let clean = try ManagementValueFixture.setupState(gating: false, failures: false)

        #expect(SetupRouting.presentation(for: advisoryOnly) == .settings(.personality))
        #expect(SetupRouting.presentation(for: clean) == .settings(.providers))
    }

    /// No Uninstall sheet ships in the first release, so the verb lands on
    /// Doctor with one named sentence and the reveal action (M34 §3.1).
    @Test("fermix://uninstall lands on Doctor")
    func uninstallLandsOnDoctor() {
        #expect(
            AppCoordinator.presentation(for: .route(.surface(.uninstall)), bootstrap: .present)
                == .main(.doctor)
        )
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

    /// Setup, Recovery and Settings all share the primary window.
    @Test("every route uses the primary window")
    func routesNameTheirWindow() {
        for route in AppRoute.allCases {
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
        let reason = LaunchClassifier.classify(isLoginLaunch: true, destination: nil)

        #expect(reason == .login)
        #expect(AppCoordinator.presentation(for: reason, bootstrap: .present) == .menuBarOnly)
    }

    @Test("a user launch opens the main window once the account has a home")
    func userLaunchOpensMain() {
        let reason = LaunchClassifier.classify(isLoginLaunch: false, destination: nil)

        #expect(reason == .user)
        #expect(AppCoordinator.presentation(for: reason, bootstrap: .present) == .main(.home))
    }

    /// With no bootstrap record this account has never activated, so the truthful
    /// surface is onboarding rather than a Home with nothing behind it.
    @Test("an account with no bootstrap record lands in onboarding")
    func freshAccountOpensOnboarding() {
        let reason = LaunchClassifier.classify(isLoginLaunch: false, destination: nil)

        #expect(AppCoordinator.presentation(for: reason, bootstrap: .absent) == .assistant(.welcome))
    }

    /// A record that is there and unreadable is not a fresh account: sending it
    /// through onboarding would treat a broken install as a new one.
    @Test("an unreadable bootstrap record opens recovery, not onboarding")
    func unreadableBootstrapOpensRecovery() {
        let broken = BootstrapCondition.unreadable(.malformed(path: "/tmp/launcher.json"))

        #expect(AppCoordinator.presentation(for: .user, bootstrap: broken) == .assistant(.recovery))
        #expect(AppCoordinator.presentation(for: .route(.surface(.doctor)), bootstrap: broken) == .assistant(.recovery))
        // A login launch still opens nothing: the menu bar is where it says so.
        #expect(AppCoordinator.presentation(for: .login, bootstrap: broken) == .menuBarOnly)
    }

    /// §4 writes a record for every interrupted transaction so recovery can read
    /// it. A launch that walks past one leaves the app claiming everything is
    /// normal while a disable is half-applied.
    @Test("an interrupted lifecycle transaction opens recovery, not Home")
    func interruptedTransactionOpensRecovery() {
        let interrupted = RecoveryCondition.interrupted(kind: .disable, phase: .mutate)

        #expect(AppCoordinator.presentation(for: .user, bootstrap: .present, recovery: interrupted) == .assistant(.recovery))
        #expect(
            AppCoordinator.presentation(
                for: .route(.surface(.home)),
                bootstrap: .present,
                recovery: interrupted
            ) == .assistant(.recovery)
        )
        // A journal that cannot be read is a broken install too.
        #expect(
            AppCoordinator.presentation(for: .user, bootstrap: .present, recovery: .journalUnreadable)
                == .assistant(.recovery)
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
        let reason = LaunchClassifier.classify(isLoginLaunch: true, destination: .surface(.doctor))

        #expect(reason == .route(.surface(.doctor)))
        #expect(AppCoordinator.presentation(for: reason, bootstrap: .present) == .main(.doctor))
    }

    @Test("a recovery url opens onboarding even on a fresh account")
    func recoveryOpensOnboarding() {
        let reason = LaunchClassifier.classify(isLoginLaunch: false, destination: .surface(.recovery))

        #expect(AppCoordinator.presentation(for: reason, bootstrap: .absent) == .assistant(.recovery))
    }
}

/// Window geometry and single-instance policy, over an injected host so no
/// window server is involved.
@Suite("Window coordinator")
@MainActor
struct WindowCoordinatorTests {
    @Test("Home, Setup and Settings share the one primary window kind")
    func primaryWindowOwnsTheJourney() {
        #expect(WindowKind.allCases == [.main, .pet])
        #expect(AssistantBottomBar.height == 64)
    }

    @Test("both remaining windows keep system restoration")
    func windowsUseSystemRestoration() {
        for kind in WindowKind.allCases {
            #expect(WindowCoordinator.descriptor(for: kind).restorable)
        }
    }

    /// Decision D3: settings runs inside this window, so its default is the
    /// size that shows a 220 pt pane column beside a readable form.
    @Test("the main window opens at 1040 by 640 and is resizable")
    func mainGeometry() {
        let descriptor = WindowCoordinator.descriptor(for: .main)

        #expect(descriptor.size == CGSize(width: 1040, height: 640))
        #expect(descriptor.size == WindowMetrics.mainDefaultSize)
        #expect(descriptor.resizable)
        // One floor, whatever the sidebar is doing.
        #expect(descriptor.minimumSize == CGSize(width: 760, height: 520))
        #expect(descriptor.minimumSize == WindowMetrics.mainMinimumSize)
    }

    /// M34 §3.1 autosaves the primary window's frame as `main`. Without it the
    /// window reopens centred at the default size on every launch, and the
    /// sidebar's width rule is recomputed from a frame the operator never chose.
    @Test("the primary window is the one window that remembers its frame")
    func mainWindowRemembersItsFrame() {
        #expect(WindowCoordinator.descriptor(for: .main).frameAutosaveName == "main")
        #expect(WindowDescriptor.mainFrameAutosaveName == "main")
        #expect(WindowCoordinator.descriptor(for: .pet).frameAutosaveName == nil)
    }

    /// Entering settings grows the window to the default it is legible at
    /// (decision D3). The coordinator states the target; the geometry, the
    /// clamp and the one-way rule are `WindowGrowth`'s and are proved there.
    @Test("entering settings asks the primary window to grow to the default size")
    func settingsGrowsThePrimaryWindow() {
        let host = FakeWindowHost()
        let coordinator = WindowCoordinator(host: host)

        coordinator.show(.main)
        coordinator.growForSettings()

        #expect(host.growth.count == 1)
        #expect(host.growth.first?.kind == .main)
        #expect(host.growth.first?.size == WindowMetrics.mainDefaultSize)
    }

    /// Every window's content view is built by the one builder that clears the
    /// hosting view's `sizingOptions`, which is what stops SwiftUI writing the
    /// window's size extrema from the content it is showing.
    ///
    /// The gate is written over the whole tree rather than over the three
    /// windows there are today, so a window added later either joins the
    /// builder or fails here. It is a source scan because touching AppKit from
    /// this process starts a main run loop that outlives the run, and a suite
    /// that can hang is worth less than the assertion; the behaviour itself is
    /// measured live, where the Integrations pane drove the primary window to
    /// 980 by 2115 points on a 3840 by 1080 point display.
    @Test("every window content view is built by the one hosting builder")
    func hostingViewsNeverSizeTheirWindow() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let constructions = files.reduce(0) { total, file in
            total + occurrences(of: "NSHostingView(rootView:", in: file.text)
        }

        #expect(constructions == 1, "a hosting view is built outside the builder")

        let host = try SourceTree.swiftFiles(matching: "App/AppKitWindowHost.swift")
        let text = try #require(host.first?.text)

        #expect(text.contains("view.sizingOptions = []"), "the builder lets the content size the window")
        // One call site per window kind. The builder itself is generic, so its
        // own declaration reads `hosting<Content:` and is not counted here.
        #expect(
            occurrences(of: "hosting(", in: text) == WindowKind.allCases.count,
            "every window kind takes its content view from the builder"
        )
        #expect(text.contains("private func hosting<Content: View>("), "the builder is not declared")
    }

    /// Presenting fits the window to the screen it is opening on, after it has
    /// been positioned: a frame restored from an autosave is the one size the
    /// app did not choose. AppKit bounds a titled window itself, so on that
    /// path the two agree; it leaves a borderless one alone, and the floating
    /// pet opened 440 points below the bottom of the screen with this step
    /// removed. One ceiling for all three windows.
    @Test("presenting fits the window to its screen after positioning it")
    func presentingFitsTheWindowToItsScreen() throws {
        let host = try SourceTree.swiftFiles(matching: "App/AppKitWindowHost.swift")
        let text = try #require(host.first?.text)

        let positioned = try #require(text.range(of: "position(window, descriptor)"))
        let fitted = try #require(text.range(of: "\n        fit(window)"))
        let shown = try #require(text.range(of: "window.makeKeyAndOrderFront(nil)"))

        #expect(positioned.lowerBound < fitted.lowerBound, "a restored frame is fitted after it is restored")
        #expect(fitted.lowerBound < shown.lowerBound, "the fit happens before the window is shown")
        #expect(text.contains("WindowGrowth.frame(fitting:"), "the fit is not the shared geometry")
    }

    /// A window's size has one owner, the descriptor that builds it; a view
    /// that restates it is a second.
    ///
    /// The two answers differ, which is what makes this a defect rather than a
    /// duplication: a titled window insets its content by the titlebar, so the
    /// assistant's root holding its own 800 by 520 inside a 488 point safe area
    /// drew 16 points out of the top of the window and lost the bottom 16 —
    /// the continue button's last row on the window's last row, measured on all
    /// eight assistant screens.
    ///
    /// The case set is derived twice over: the symbols are whatever the
    /// descriptors name as a size, and the files are every one in the tree that
    /// draws SwiftUI. A window added later is covered by both.
    @Test("no view names the size its window descriptor owns")
    func windowSizesAreNamedOnlyWhereWindowsAreDescribed() throws {
        let coordinator = try SourceTree.swiftFiles(matching: "App/WindowCoordinator.swift")
        let symbols = try sizeSymbols(in: try #require(coordinator.first?.text))

        #expect(symbols.count >= 3, "the descriptors name no sizes to check: \(symbols)")

        let views = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("import SwiftUI") }

        for file in views {
            for symbol in symbols where file.text.contains(symbol) {
                Issue.record("\(file.path) names \(symbol), which its window descriptor owns")
            }
        }
    }

    /// The size symbols the descriptors name, as written: `size:` or
    /// `minimumSize:` taking a metric off one of the design's token enums.
    private func sizeSymbols(in text: String) throws -> Set<String> {
        let expression = try NSRegularExpression(
            pattern: #"(?:size|minimumSize):\s*([A-Za-z]+Metrics\.[A-Za-z]+)"#
        )
        let range = NSRange(text.startIndex..., in: text)

        return Set(
            expression.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
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
    /// What each window was asked to grow to, in order (decision D3).
    private(set) var growth: [(kind: WindowKind, size: CGSize)] = []

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

    func grow(_ kind: WindowKind, toAtLeast size: CGSize) {
        growth.append((kind, size))
    }
}
