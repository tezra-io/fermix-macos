import CryptoKit
import Foundation

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
public struct ServiceController {
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
}

/// The digest for a caller that has no bundle to read, which is every context
/// but the running app. It answers absent rather than inventing a hash.
public struct AbsentAgentPlistDigest: AgentPlistDigesting {
    public init() {}

    public func bundledAgentPlistDigest() -> String? { nil }
}
