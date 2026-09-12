import AppKit
import Foundation

/// The executable's whole body.
///
/// `Sources/Fermix/main.swift` does nothing but call this, so every line of
/// application behavior stays inside the testable core library.
///
/// The app is AppKit-first rather than a SwiftUI `App`: the activation policy
/// has to be accessory *before* anything is presented, and the windows are
/// coordinated (one primary window for setup and settings, and an optional
/// floating pet) rather than spawned by an unrestricted `WindowGroup`.
public enum FermixApp {
    /// - Parameter updater: the updater the executable owns. It arrives as an
    ///   argument because the implementation behind this seam links Sparkle,
    ///   and only the GUI executable may (M34 §6: the daemon and `FermixAgent`
    ///   never load Sparkle). This library declares the seam and imports
    ///   nothing.
    @MainActor
    public static func main(updater: any UpdaterDriving) {
        // Maintenance entry, before any AppKit UI: the login-item
        // registrations belong to this bundle identity, so only the app
        // itself can withdraw them. This is the primitive the uninstall route
        // uses, and the recovery for registrations left by an interrupted or
        // refused first run.
        if CommandLine.arguments.contains("--unregister-login-items") {
            unregisterLoginItems()
        }

        let application = NSApplication.shared

        // Before any UI: the menu bar is the app, so a launch must not put a
        // Dock tile or a menu bar owner on screen. This is the first thing the
        // process does with AppKit. The window host promotes the app to a
        // Dock app for exactly as long as a real window is open.
        application.setActivationPolicy(.accessory)

        let delegate = AppDelegate(plan: launchPlan(updater: updater))
        application.delegate = delegate
        application.run()
    }

    /// Which of the app's declared configurations this launch asked for.
    ///
    /// The selection happens once, here, before any window exists. No
    /// configuration is reachable from inside another, and a launch that names
    /// two is refused rather than resolved to one of them: silently running the
    /// other would report the argument as having worked.
    @MainActor
    private static func launchPlan(updater: any UpdaterDriving) -> AppLaunchPlan {
        let arguments = CommandLine.arguments
        let fixture = fixtureRequest(arguments)
        let development = developmentEngineRequest(arguments)

        if fixture != nil, development { refuse(.combinedWithFixture) }
        if let fixture { return fixturePlan(named: fixture) }
        if development {
            return developmentEnginePlan(
                registerBackground: arguments.contains(DevelopmentEngineLaunchRequest.registrationFlag),
                updater: updater
            )
        }

        return .product(updater: updater)
    }

    /// The surface a fixture launch named, or nil where it asked for none.
    @MainActor
    private static func fixtureRequest(_ arguments: [String]) -> String? {
        do {
            return try FixtureLaunchRequest.parse(arguments)
        } catch let refusal as FixtureLaunchRequest.Refusal {
            refuse(refusal)
        } catch {
            preconditionFailure("FixtureLaunchRequest.parse throws only Refusal, got \(error)")
        }
    }

    /// Whether this launch asked for the development configuration.
    @MainActor
    private static func developmentEngineRequest(_ arguments: [String]) -> Bool {
        do {
            return try DevelopmentEngineLaunchRequest.parse(arguments)
        } catch let refusal as DevelopmentEngineLaunchRequest.Refusal {
            refuse(refusal)
        } catch {
            preconditionFailure("DevelopmentEngineLaunchRequest.parse throws only Refusal, got \(error)")
        }
    }

    #if DEBUG
    @MainActor
    private static func fixturePlan(named name: String) -> AppLaunchPlan {
        guard let start = FixtureStart(name: name) else {
            FileHandle.standardError.write(
                Data("surfaces: \(FixtureStart.publishedNames.joined(separator: ", "))\n".utf8)
            )
            refuse(.unknownStart(name))
        }

        return .fixture(FixtureLaunch(start: start))
    }
    @MainActor
    private static func developmentEnginePlan(
        registerBackground: Bool,
        updater: any UpdaterDriving
    ) -> AppLaunchPlan {
        .developmentEngine(registerBackground: registerBackground, updater: updater)
    }
    #else
    /// A release build has no fixture configuration compiled into it, so the
    /// flag names nothing this binary can do.
    @MainActor
    private static func fixturePlan(named _: String) -> AppLaunchPlan {
        refuse(FixtureLaunchRequest.Refusal.notAvailableInThisBuild)
    }

    /// Nor a development configuration: the engine a shipped app runs is the one
    /// in its own bundle, started by launchd.
    @MainActor
    private static func developmentEnginePlan(
        registerBackground: Bool,
        updater: any UpdaterDriving
    ) -> AppLaunchPlan {
        refuse(DevelopmentEngineLaunchRequest.Refusal.notAvailableInThisBuild)
    }
    #endif

    private static func refuse(_ refusal: FixtureLaunchRequest.Refusal) -> Never {
        refuse(sentence: refusal.sentence)
    }

    private static func refuse(_ refusal: DevelopmentEngineLaunchRequest.Refusal) -> Never {
        refuse(sentence: refusal.sentence)
    }

    private static func refuse(sentence: String) -> Never {
        FileHandle.standardError.write(Data("fermix: \(sentence)\n".utf8))
        exit(2)
    }

    @MainActor
    private static func unregisterLoginItems() -> Never {
        var failures = 0

        do {
            let configuration = try ProductConfiguration.bundled()
            let services = ServiceController(
                loginItems: SMAppServiceLoginItems(configuration: configuration)
            )

            for principal in [LoginItemPrincipal.agent, .mainApp] {
                do {
                    try services.disable(principal)
                    print("unregistered \(principal.rawValue)")
                } catch {
                    failures += 1
                    FileHandle.standardError.write(
                        Data("could not unregister \(principal.rawValue): \(error)\n".utf8)
                    )
                }
            }
        } catch {
            FileHandle.standardError.write(Data("unregister failed: \(error)\n".utf8))
            exit(70)
        }

        exit(failures == 0 ? 0 : 70)
    }
}

/// How this process brings the app up: which configuration it composes, and
/// what that configuration puts on screen.
///
/// Two values of one type rather than a flag the delegate reads, so the delegate
/// has nothing to decide and the two configurations cannot reach into each
/// other.
@MainActor
struct AppLaunchPlan {
    let compose: () -> AppComposition
    let present: (AppComposition) -> Void

    /// The shipped launch: the product graph, opened at whatever the launch
    /// reason resolves to.
    static func product(updater: any UpdaterDriving) -> AppLaunchPlan {
        AppLaunchPlan(compose: { AppComposition(updater: updater) }, present: openLaunchReason)
    }

    /// What a real launch opens: whatever the launch reason resolves to.
    static func openLaunchReason(_ composition: AppComposition) {
        composition.coordinator.start(
            reason: LaunchClassifier.classify(
                isLoginLaunch: LoginLaunchProbe.isLoginLaunch(),
                destination: nil
            )
        )
    }

    #if DEBUG
    /// The fixture launch: the same graph over the contract's golden answers,
    /// opened at the surface the argument named.
    static func fixture(_ launch: FixtureLaunch) -> AppLaunchPlan {
        AppLaunchPlan(
            compose: {
                do {
                    return try AppComposition(fixture: launch)
                } catch {
                    // A bundle whose own golden fixtures cannot be read is
                    // broken, exactly as an unreadable product configuration is.
                    preconditionFailure("the fixture configuration is unreadable: \(error)")
                }
            },
            present: { $0.present(fixture: launch) }
        )
    }

    static func openDevelopmentLaunch(
        coordinator: AppCoordinator,
        reason: LaunchReason,
        registerBackground: Bool
    ) {
        coordinator.start(reason: reason)
        if registerBackground { coordinator.setBackgroundService(enabled: true) }
    }

    /// The development launch: the product graph on this Mac, activated against
    /// the staged background agent. It opens the same surfaces as an installed
    /// launch, with development installation preflights.
    static func developmentEngine(
        registerBackground: Bool = false,
        updater: any UpdaterDriving
    ) -> AppLaunchPlan {
        AppLaunchPlan(
            compose: { AppComposition(environment: .developmentEngine(updater: updater)) },
            present: { composition in
                openDevelopmentLaunch(
                    coordinator: composition.coordinator,
                    reason: LaunchClassifier.classify(
                        isLoginLaunch: LoginLaunchProbe.isLoginLaunch(), destination: nil
                    ),
                    registerBackground: registerBackground
                )
            }
        )
    }
    #endif
}

/// Brings the composition up, wires the two AppKit-only signals it needs (url
/// events and window occlusion), and tears voice down on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let plan: AppLaunchPlan
    private var composition: AppComposition?
    private let log = AppLog.logger(.app)

    @MainActor
    init(plan: AppLaunchPlan) {
        self.plan = plan
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Delivered before the first window can be presented, which is where
        // the url handler has to be installed: a `fermix://` launch delivers
        // its event immediately after this.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let composition = plan.compose()
        self.composition = composition

        composition.installApplicationIcon()
        composition.mainMenu.install(into: NSApplication.shared)
        composition.installMenuBar()
        observeWindowOcclusion(composition)

        plan.present(composition)
    }

    /// Closing every window leaves the menu bar app running: the daemon is
    /// still there, and the status item is how it is reached.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The one barrier every exit passes through: the app's own Quit, the Dock
    /// tile's Quit, an AppleScript quit, and a log out or a restart.
    ///
    /// A staged update replaces the bundle on any exit of this process with no
    /// further call into it, so the exits that never reach the menu bar are
    /// exactly the ones that would swap it under a live engine (M34 §6, R3).
    /// The coordinator holds the termination while it finishes that stop and
    /// answers AppKit itself.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let composition else { return .terminateNow }

            return composition.coordinator.terminationRequested()
        }
    }

    /// The Dock tile, Launchpad or Spotlight, on an app that is already
    /// running.
    ///
    /// The status item is the user's to remove, so this is the path that keeps
    /// Fermix reachable without it: with nothing on screen, reopening opens the
    /// window a user launch would. True either way, so macOS still does its own
    /// unminiaturizing when there is a window to bring back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            composition?.coordinator.reopen()
        }

        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            route(url)
        }
    }

    @objc
    private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: value)
        else {
            log.error("a url event carried no url")
            return
        }

        route(url)
    }

    private func route(_ url: URL) {
        // Apple event delivery is not main-actor isolated, and the coordinator
        // is: one hop, at the boundary, rather than an assumption inside it.
        MainActor.assumeIsolated {
            guard let composition else { return }

            do {
                try composition.coordinator.open(url: url)
            } catch {
                // A url this build does not know is refused: opening Home
                // instead would tell the user their command worked.
                log.error("refusing url: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Pause the pet's animation whenever its window isn't actually on screen
    /// (other Space, minimized, fully covered).
    private func observeWindowOcclusion(_ composition: AppComposition) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }

            MainActor.assumeIsolated {
                composition.windowHost.occlusionChanged(
                    window: window,
                    visible: window.occlusionState.contains(.visible)
                )
            }
        }
    }

    /// `willTerminate` is delivered synchronously and is the guaranteed window
    /// to release the microphone and the socket before the process exits. No
    /// daemon lifecycle command is sent here or anywhere on the quit path.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            composition?.voice.shutdown()
        }
    }
}

/// Whether macOS started this process from its login-item registration.
///
/// The launch AppleEvent carries the answer; nothing else does, so a login
/// launch is read once, at launch, and never inferred later.
enum LoginLaunchProbe {
    static func isLoginLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication)
        else { return false }

        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
