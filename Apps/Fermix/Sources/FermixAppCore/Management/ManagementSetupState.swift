import Foundation

/// The typed results of `setup.state.get` and `setup.detect`.
///
/// This is the whole state the assistant and the Settings window read: the app
/// parses no config file, resolves no credential, and decides what no check
/// means. Every field is the daemon's.

/// One readiness failure. `gating` is on the wire because M34 §3.4 routes on
/// *which* failure gates and a status alone cannot say which; `detailKey` is the
/// single copy key, over the failure constructor's own closed set.
public struct ManagementReadinessFailure: Decodable, Equatable, Sendable {
    public let component: String
    public let gating: Bool
    public let pane: ManagementSettingsPane
    public let detailKey: String

    private enum CodingKeys: String, CodingKey {
        case component, gating, pane
        case detailKey = "detail_key"
    }
}

public struct ManagementSetupReadiness: Decodable, Equatable, Sendable {
    public let status: String?
    public let failures: [ManagementReadinessFailure]

    /// The failures that block onboarding, as against the ones that are advice.
    public var gating: [ManagementReadinessFailure] { failures.filter(\.gating) }
}

/// One provider, as setup sees it. No credential crosses this boundary:
/// `presentKey` and `accountLabel` are what a key or a session looks like from
/// outside the secret store.
public struct ManagementSetupProvider: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let authModes: [String]
    public let authMode: String?
    public let configured: Bool
    public let primary: Bool
    public let presentKey: Bool
    public let defaultModel: String?
    public let reasoningEffort: String?
    /// Fast mode, which M34 §5.1 renders as a Toggle. A boolean because
    /// `Providers.RouteResolver.validate_fast!/1` accepts only nil or a boolean.
    public let fast: Bool?
    public let accountLabel: String?
    /// M34 §7.3 names this field and publishes no value set, so it is carried
    /// as the daemon's own string until the engine publishes one.
    public let tokenState: String?

    private enum CodingKeys: String, CodingKey {
        case id, label, configured, primary, fast
        case authModes = "auth_modes"
        case authMode = "auth_mode"
        case presentKey = "present_key"
        case defaultModel = "default_model"
        case reasoningEffort = "reasoning_effort"
        case accountLabel = "account_label"
        case tokenState = "token_state"
    }
}

public struct ManagementSetupChannel: Decodable, Equatable, Sendable {
    public let name: String
    public let enabled: Bool
    public let configured: Bool
    public let status: String?
    public let mode: String?
}

/// Which parts of the owner's own description exist. Presence only: the values
/// are never carried on this method.
public struct ManagementPersonalizationPresence: Decodable, Equatable, Sendable {
    public let userName: Bool
    public let timezone: Bool
    public let communicationStyle: Bool

    private enum CodingKeys: String, CodingKey {
        case timezone
        case userName = "user_name"
        case communicationStyle = "communication_style"
    }
}

public struct ManagementSetupPersonalization: Decodable, Equatable, Sendable {
    public let present: ManagementPersonalizationPresence
}

public struct ManagementComputerHistoryState: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let installed: Bool
    public let ready: Bool
}

public struct ManagementSetupFeatures: Decodable, Equatable, Sendable {
    public let voice: Bool
    public let voiceNotes: Bool
    public let meetings: Bool
    public let computerUse: Bool
    public let computerHistory: ManagementComputerHistoryState

    private enum CodingKeys: String, CodingKey {
        case voice, meetings
        case voiceNotes = "voice_notes"
        case computerUse = "computer_use"
        case computerHistory = "computer_history"
    }
}

/// A Fermix service unit this app does not own. The scope decides both the
/// sentence and the removal command, so both are read rather than inferred.
public struct ManagementLegacyServiceUnit: Decodable, Equatable, Sendable {
    public let present: Bool
    public let scope: ManagementServiceScope?
    public let path: String?
}

/// Whether the keychain is holding a stored key back from this daemon.
///
/// `present` is three-valued because deciding it means reading every key, which
/// costs one keychain subprocess per key and prompts on exactly the keys the row
/// exists to name. `setup.state.get` publishes the last measurement the
/// `secret_acl_restricted` Doctor check took, and `nil` is "not measured", which
/// the contract states is not the same answer as `false`.
public struct ManagementSecretACLRestriction: Decodable, Equatable, Sendable {
    public let present: Bool?
    public let keys: [String]

    /// Whether a restriction was measured and found. Nothing is claimed from an
    /// unmeasured probe: a row raised on `nil` would tell the operator their
    /// keychain is holding keys back on the strength of a question nobody has
    /// asked yet.
    public var isRestricted: Bool { present == true }
}

/// What else on this machine touches the same home (M34 §15).
public struct ManagementSetupCoexistence: Decodable, Equatable, Sendable {
    public let legacyServiceUnit: ManagementLegacyServiceUnit
    public let configState: ManagementConfigState
    public let secretACLRestricted: ManagementSecretACLRestriction

    private enum CodingKeys: String, CodingKey {
        case legacyServiceUnit = "legacy_service_unit"
        case configState = "config_state"
        case secretACLRestricted = "secret_acl_restricted"
    }
}

public struct ManagementSetupState: Decodable, Equatable, Sendable {
    public let readiness: ManagementSetupReadiness
    public let restart: ManagementRestartState
    public let providers: [ManagementSetupProvider]
    public let channels: [ManagementSetupChannel]
    public let personalization: ManagementSetupPersonalization
    public let features: ManagementSetupFeatures
    /// The keychain namespace this home writes under. Not a settings row:
    /// `settings.apply` refuses it.
    public let profile: String?
    public let coexistence: ManagementSetupCoexistence
}

public enum ManagementHarnessAuth: String, Decodable, Equatable, Sendable {
    case authenticated
    case unverified
    case absent
}

/// Nonsecret facts from the daemon's bounded coding CLI detector.
public struct ManagementHarnessVendor: Decodable, Equatable, Identifiable, Sendable {
    public let vendor: String
    public let installed: Bool
    public let version: String?
    public let auth: ManagementHarnessAuth

    public var id: String { vendor }
}

/// One probe answer. Coding readiness is optional for earlier protocol-2 engines.
public struct ManagementDetection: Decodable, Equatable, Sendable {
    public let target: ManagementDetectTarget
    public let present: Bool
    public let detail: String?
    public let vendors: [ManagementHarnessVendor]?
    public let guidance: String?
}

public struct ManagementDetections: Decodable, Equatable, Sendable {
    public let results: [ManagementDetection]

    public func result(for target: ManagementDetectTarget) -> ManagementDetection? {
        results.first { $0.target == target }
    }
}
