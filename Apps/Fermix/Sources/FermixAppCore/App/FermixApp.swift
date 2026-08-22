import AppKit
import Foundation

/// The executable's whole body.
///
/// `Sources/Fermix/main.swift` does nothing but call this, so every line of
/// application behavior stays inside the testable core library.
///
/// The app is AppKit-first rather than a SwiftUI `App`: the activation policy
/// has to be accessory *before* anything is presented, and the windows are
/// coordinated (exactly one onboarding window, one main window, an optional
/// floating pet) rather than spawned by an unrestricted `WindowGroup`.
public enum FermixApp {
    @MainActor
    public static func main() {
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

        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
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

/// Brings the composition up, wires the two AppKit-only signals it needs (url
/// events and window occlusion), and tears voice down on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var composition: AppComposition?
    private let log = AppLog.logger(.app)

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
        let composition = AppComposition()
        self.composition = composition

        composition.installApplicationIcon()
        composition.menuBar.install()
        observeWindowOcclusion(composition)

        composition.coordinator.start(
            reason: LaunchClassifier.classify(isLoginLaunch: LoginLaunchProbe.isLoginLaunch(), route: nil)
        )
    }

    /// Closing every window leaves the menu bar app running: the daemon is
    /// still there, and the panel is how it is reached.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
