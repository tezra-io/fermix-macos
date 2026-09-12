import Foundation
import ServiceManagement

/// The two things this app registers with macOS, independently.
///
/// One consent never implies the other: the GUI opening at login and the daemon
/// running in the background are separate decisions, and disabling either never
/// changes the other.
public enum LoginItemPrincipal: String, CaseIterable, Sendable {
    /// The GUI itself, opened at login.
    case mainApp
    /// The signed launcher launchd runs, and the durable identity the daemon's
    /// App Management permission is keyed to.
    case agent

    /// The launchd plist inside `Contents/Library/LaunchAgents`, for the
    /// principal that has one. The main app registers itself and has none.
    public func plistName(_ configuration: ProductConfiguration) -> String? {
        self == .agent ? "\(configuration.agentServiceLabel).plist" : nil
    }
}

/// What macOS says about a registration, in exactly the four values
/// `SMAppService.Status` publishes.
///
/// `requiresApproval` is a state, not a failure: macOS reports it both while an
/// approval is pending and after the user has turned the background item off,
/// and re-registering in a loop against either is exactly what M34 forbids. It
/// is reported and left alone.
public enum ServiceRegistrationStatus: String, Codable, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    /// macOS cannot find the item this app claims to register.
    case notFound
}

public enum ServiceControlError: Error, Equatable, Sendable {
    case registrationFailed(principal: LoginItemPrincipal, underlying: String)
    case unregistrationFailed(principal: LoginItemPrincipal, underlying: String)
}

/// The seam over `SMAppService`.
///
/// Registering a background item mutates the account it runs in, so tests never
/// reach the real implementation: they inject a double, and the production type
/// below is the only code in the app that touches `SMAppService` at all.
public protocol LoginItemService {
    func register(_ principal: LoginItemPrincipal) throws
    func unregister(_ principal: LoginItemPrincipal) throws
    func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus
}

/// The one owner of `SMAppService` mutation in this app.
public struct SMAppServiceLoginItems: LoginItemService {
    private let configuration: ProductConfiguration

    public init(configuration: ProductConfiguration) {
        self.configuration = configuration
    }

    public func register(_ principal: LoginItemPrincipal) throws {
        do {
            try service(for: principal).register()
        } catch {
            throw ServiceControlError.registrationFailed(
                principal: principal,
                underlying: error.localizedDescription
            )
        }
    }

    public func unregister(_ principal: LoginItemPrincipal) throws {
        do {
            try service(for: principal).unregister()
        } catch {
            throw ServiceControlError.unregistrationFailed(
                principal: principal,
                underlying: error.localizedDescription
            )
        }
    }

    public func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        switch service(for: principal).status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    private func service(for principal: LoginItemPrincipal) -> SMAppService {
        guard let plistName = principal.plistName(configuration) else {
            return SMAppService.mainApp
        }

        return SMAppService.agent(plistName: plistName)
    }
}
