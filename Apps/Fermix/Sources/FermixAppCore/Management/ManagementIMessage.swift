import Foundation

/// The iMessage channel's wire shapes: the Fermix Messages helper's
/// non-prompting probe, and what an iMessage grant asks for.
///
/// Typed here so the catalog stays exactly the schema's; no surface draws them
/// yet. The channel's own rows arrive through `settings.get
/// {channels.imessage}` and render through the descriptor form. A grant and a
/// recipient confirmation each wait on a person, so both are jobs whose
/// `result` is this same view; a confirmation adds `outcome` to it, and the
/// owner pressing Cancel completes the job rather than failing it
/// (PROTOCOL.md).

/// `imessage.permissions.get`. Non-prompting: it reports what the helper holds
/// and never asks for it, which `imessage.grant.start` does explicitly.
///
/// With `installed` false every other field is nil. `signedIn` is nil while
/// Automation is not granted, because the helper cannot ask Messages without
/// it. `policyMatchesConfig` is true only when the confirmed recipients are
/// exactly the saved ones; anything else is the daemon's "Awaiting
/// confirmation".
public struct ManagementIMessagePermissions: Decodable, Equatable, Sendable {
    public let installed: Bool
    public let helperVersion: String?
    public let fullDiskAccess: ManagementIMessageFullDiskAccess?
    public let db: ManagementIMessageDatabase?
    public let automation: ManagementIMessageAutomation?
    public let messagesRunning: Bool?
    public let signedIn: Bool?
    public let userSession: Bool?
    public let policy: ManagementIMessagePolicy?
    public let policyMatchesConfig: Bool?
    public let probedAt: String?

    private enum CodingKeys: String, CodingKey {
        case installed, db, automation, policy
        case helperVersion = "helper_version"
        case fullDiskAccess = "full_disk_access"
        case messagesRunning = "messages_running"
        case signedIn = "signed_in"
        case userSession = "user_session"
        case policyMatchesConfig = "policy_matches_config"
        case probedAt = "probed_at"
    }
}

// MARK: - Vocabularies

/// The one grant `imessage.grant.start` asks for: `automation` raises the one
/// system prompt, and `full_disk_access` registers the helper, opens the Full
/// Disk Access pane and reveals the helper for drag-in.
public enum ManagementIMessageGrantService: ManagementVocabulary {
    case automation
    case fullDiskAccess
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "automation": .automation,
        "full_disk_access": .fullDiskAccess
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `full_disk_access`: whether the helper can read the Messages database.
public enum ManagementIMessageFullDiskAccess: ManagementVocabulary {
    case granted
    case denied
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["granted": .granted, "denied": .denied]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `db`: the Messages database as the helper found it.
public enum ManagementIMessageDatabase: ManagementVocabulary {
    case readable
    case missing
    case unreadable
    case schemaUnexpected
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "readable": .readable,
        "missing": .missing,
        "unreadable": .unreadable,
        "schema_unexpected": .schemaUnexpected
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `automation`: whether the helper may drive Messages. `unknown` is Messages
/// not running, which leaves the grant unreadable.
public enum ManagementIMessageAutomation: ManagementVocabulary {
    case granted
    case denied
    case notDetermined
    case unknown
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "granted": .granted,
        "denied": .denied,
        "not_determined": .notDetermined,
        "unknown": .unknown
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `policy`: the recipient record the helper holds.
public enum ManagementIMessagePolicy: ManagementVocabulary {
    case confirmed
    case unconfirmed
    case absent
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "confirmed": .confirmed,
        "unconfirmed": .unconfirmed,
        "absent": .absent
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}
