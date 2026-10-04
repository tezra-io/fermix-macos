import AppKit
import CryptoKit
import Foundation
import os

/// The bundled agent plist, as bytes to compare a registration against.
///
/// `SMAppService` publishes a status and never the plist it registered, so the
/// only way to notice a changed `ProgramArguments` or label is to hash what this
/// bundle ships and compare it with the receipt the last registration wrote
/// (M34 §7.2 step 5).
public protocol AgentPlistDigesting: Sendable {
    func bundledAgentPlistDigest() -> String?
}

/// Reads the plist out of `Contents/Library/LaunchAgents` and hashes it.
public struct BundledAgentPlistDigest: AgentPlistDigesting {
    private let bundleURL: URL
    private let plistName: String

    public init(configuration: ProductConfiguration, bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
        self.plistName = "\(configuration.agentServiceLabel).plist"
    }

    public func bundledAgentPlistDigest() -> String? {
        let url = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName, isDirectory: false)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }

        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The two login registrations, kept independent.
///
/// Every mutation goes through one seam, so this is the only place in the app
/// that can change what macOS runs at login, and the only place a registration
/// failure is turned into a typed refusal.
public struct ServiceController: Sendable {
    private let loginItems: any LoginItemService
    private let plists: any AgentPlistDigesting
    private let log = AppLog.logger(.service)

    public init(loginItems: any LoginItemService, plists: any AgentPlistDigesting = AbsentAgentPlistDigest()) {
        self.loginItems = loginItems
        self.plists = plists
    }

    /// The digest of the plist this bundle ships, or nil where it ships none.
    /// An absent digest is a difference to the reconciler, never a match.
    public func bundledAgentPlistDigest() -> String? {
        plists.bundledAgentPlistDigest()
    }

    public func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        loginItems.status(principal)
    }

    /// Registers one principal. A status of `requiresApproval` afterwards is
    /// the truthful outcome, not a reason to register again.
    public func enable(_ principal: LoginItemPrincipal) throws {
        try loginItems.register(principal)
        log.log("registered \(principal.rawValue, privacy: .public): \(status(principal).rawValue, privacy: .public)")
    }

    public func disable(_ principal: LoginItemPrincipal) throws {
        try loginItems.unregister(principal)
        log.log("unregistered \(principal.rawValue, privacy: .public)")
    }

    /// Whether the daemon is registered to run in the background.
    public var backgroundServiceEnabled: Bool {
        status(.agent) == .enabled
    }

    /// Asks macOS to run the background agent, once, and says what that came
    /// to. The one place a registration attempt is interpreted, so setup and
    /// Home's switch cannot answer the same refusal two ways.
    ///
    /// The status is read again after `register()` whether or not it threw.
    /// macOS refuses to register an item the person switched off ("Operation
    /// not permitted") and goes on holding it, and the same error code has
    /// other causes, so the status decides and the error never does.
    public func requestBackgroundService() -> BackgroundServiceConsent {
        let before = status(.agent)
        var refusal: String?
        do {
            try loginItems.register(.agent)
        } catch ServiceControlError.registrationFailed(_, let underlying) {
            refusal = underlying
        } catch {
            refusal = error.localizedDescription
        }
        if let refusal {
            log.error("the background agent could not be registered: \(refusal, privacy: .public)")
        }

        let after = status(.agent)
        log.log("asked for the background agent: \(before.rawValue, privacy: .public) to \(after.rawValue, privacy: .public)")
        switch after {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .awaitingApproval(before == .requiresApproval ? .switchedOff : .awaited)
        case .notRegistered, .notFound:
            return .refused(after, underlying: refusal)
        }
    }

    /// Waits for macOS to stop holding the background agent, and answers the
    /// status it moved to, or nil once the task is cancelled.
    ///
    /// It only reads. The person's switch is the one thing that ends the hold,
    /// and registering again against it is the loop M34 forbids. macOS
    /// announces no change, so it reads once as it starts and then whenever the
    /// schedule says a read is worth its cost, each one off the main thread
    /// (`LoginRegistrations`). Nothing bounds it but cancellation: the person
    /// may take as long as they need in System Settings.
    public func awaitBackgroundApproval(
        readingOn schedule: any ApprovalReadSchedule
    ) async -> ServiceRegistrationStatus? {
        while !Task.isCancelled {
            let current = await Task.detached(priority: .userInitiated) { [self] in status(.agent) }.value
            guard current == .requiresApproval else { return current }

            do {
                try await schedule.nextRead()
            } catch {
                return nil
            }
        }

        return nil
    }

    /// Opens System Settings on Login Items, through the documented opener.
    /// Every button that sends the person there calls this one.
    public func openLoginItemsSettings() {
        loginItems.openSettings()
    }

    /// Both registrations, read off the main thread.
    public func registrations() async -> LoginRegistrations {
        await Task.detached(priority: .userInitiated) { [self] in
            LoginRegistrations(agent: status(.agent), mainApp: status(.mainApp))
        }.value
    }
}

/// Why macOS is holding the background item, as far as this app can tell.
///
/// macOS publishes one status, `requiresApproval`, for both, and no API tells
/// them apart. The only sign is what the status was before this attempt
/// registered.
public enum BackgroundApproval: Equatable, Sendable {
    /// Registered by this attempt, and the person has not answered yet.
    case awaited
    /// Held before this attempt too: the person switched Fermix off.
    case switchedOff
}

/// What asking macOS to run the background agent came to.
public enum BackgroundServiceConsent: Equatable, Sendable {
    /// Registered and allowed, so launchd runs the agent.
    case enabled
    /// Registered, and macOS is holding it for the person.
    case awaitingApproval(BackgroundApproval)
    /// macOS would not register it and is not holding it either: the status it
    /// reported afterwards, and what `register()` threw where it threw.
    case refused(ServiceRegistrationStatus, underlying: String?)
}

/// When a held background item is worth reading again.
///
/// A seam because the moments are the app's and the clock's: a test decides
/// when the person flips the switch without either.
public protocol ApprovalReadSchedule: Sendable {
    /// Returns at the next moment a read is worth its cost, and throws once
    /// the task is cancelled.
    func nextRead() async throws
}

/// The app coming to the front, which is when the person returns from System
/// Settings, or the backstop, for a person who flips the switch and never
/// clicks back into Fermix.
public struct ReturnOrBackstop: ApprovalReadSchedule {
    /// About 70 ms a read every 3 seconds: a few percent of one core while the
    /// step is on screen, and nothing otherwise.
    public static let backstop: TimeInterval = 3

    private let backstop: TimeInterval

    public init(backstop: TimeInterval = ReturnOrBackstop.backstop) {
        self.backstop = backstop
    }

    public func nextRead() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(backstop * 1_000_000_000))
            }
            group.addTask {
                let returns = NotificationCenter.default.notifications(
                    named: NSApplication.didBecomeActiveNotification
                )
                for await _ in returns { return }
                try Task.checkCancellation()
            }

            try await group.next()
            group.cancelAll()
        }
    }
}

/// The two login registrations as macOS last answered, for a surface to draw.
///
/// A surface holds this and never asks `SMAppService` itself. Each status read
/// is a synchronous XPC round trip in which macOS re-verifies this app's
/// signature and ticket, about 70 ms on a Developer ID build, and a switch
/// binding asks for its value several times per redraw. Read through from
/// Home's switches, pressing Back to Fermix made 52 of them: three and a half
/// seconds with the main thread blocked (measured 2026-09-24). A transaction
/// that decides something from the registration still reads it live through
/// `ServiceController.status(_:)`.
public struct LoginRegistrations: Equatable, Sendable {
    public var agent: ServiceRegistrationStatus
    public var mainApp: ServiceRegistrationStatus

    public init(agent: ServiceRegistrationStatus, mainApp: ServiceRegistrationStatus) {
        self.agent = agent
        self.mainApp = mainApp
    }
}

/// The digest for a caller that has no bundle to read, which is every context
/// but the running app. It answers absent rather than inventing a hash.
public struct AbsentAgentPlistDigest: AgentPlistDigesting {
    public init() {}

    public func bundledAgentPlistDigest() -> String? { nil }
}
