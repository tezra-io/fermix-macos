import Foundation

/// The two login registrations, kept independent.
///
/// Every mutation goes through one seam, so this is the only place in the app
/// that can change what macOS runs at login, and the only place a registration
/// failure is turned into a typed refusal.
public struct ServiceController {
    private let loginItems: any LoginItemService
    private let log = AppLog.logger(.service)

    public init(loginItems: any LoginItemService) {
        self.loginItems = loginItems
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
