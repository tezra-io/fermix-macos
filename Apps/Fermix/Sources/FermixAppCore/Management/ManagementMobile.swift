import Foundation

/// The phone channel's wire shapes: `mobile.status`, the pairing session a pane
/// polls, and the paired-phone list.
///
/// Typed here so the catalog stays exactly the schema's; no surface draws them
/// yet. A pairing session is polled rather than a job: its view grows while it
/// runs, and the operator decides mid-run (PROTOCOL.md).

/// `mobile.status`: the phone channel as it stands, answered with the channel
/// off too, so a pane can always read it.
public struct ManagementMobileStatus: Decodable, Equatable, Sendable {
    public let enabled: Bool
    /// False until the channel runs, which an enabled switch alone does not do
    /// before a restart.
    public let started: Bool
    /// True when the channel could not start this boot; the daemon log says why.
    public let refused: Bool
    public let listener: ManagementMobileListener
    public let mdns: ManagementMobileAnnouncement
    public let tailnet: ManagementMobileTailnet
    public let identity: ManagementMobileIdentity
    public let apns: ManagementMobilePush
    public let pairedDevices: Int
    public let protocolVersion: Int
    /// The open pairing window, else the newest retained session, else nil.
    public let pairing: ManagementPairingSummary?

    private enum CodingKeys: String, CodingKey {
        case enabled, started, refused, listener, mdns, tailnet, identity, apns, pairing
        case pairedDevices = "paired_devices"
        case protocolVersion = "protocol_version"
    }
}

public struct ManagementMobileListener: Decodable, Equatable, Sendable {
    public let status: ManagementMobileListenerStatus
    public let port: Int
    public let bind: String
    public let candidates: [String]
}

public struct ManagementMobileTailnet: Decodable, Equatable, Sendable {
    public let detected: Bool
    public let candidates: [String]
}

/// The gateway identity a phone pins at pairing. `fingerprint` is the SHA-256
/// of its public key, lowercase hex in groups of four, nil until the first
/// pairing creates it.
public struct ManagementMobileIdentity: Decodable, Equatable, Sendable {
    public let present: Bool
    public let fingerprint: String?
}

public struct ManagementMobilePush: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let credentials: ManagementMobileCredentials
}

public struct ManagementPairingSummary: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let state: ManagementPairingState

    private enum CodingKeys: String, CodingKey {
        case state
        case sessionId = "session_id"
    }
}

/// A pairing session as `mobile.pair.get`, `mobile.pair.decide` and
/// `mobile.pair.cancel` answer it. Every field is present, nil where it does
/// not apply: `state` is the switch, `ttlMs` is relative and nil once the
/// session is terminal, `outcome` is set on approved, denied, expired and
/// cancelled, `failure` on failed. A start refused for a reason the operator
/// can act on answers a failed view with a nil `sessionId`: nothing was opened
/// and there is nothing to poll.
public struct ManagementPairingSession: Decodable, Equatable, Sendable {
    public let sessionId: String?
    public let state: ManagementPairingState
    public let ttlMs: Int?
    public let request: ManagementPairingRequest?
    public let outcome: ManagementPairingOutcome?
    public let failure: ManagementPairingFailure?

    private enum CodingKeys: String, CodingKey {
        case state, request, outcome, failure
        case sessionId = "session_id"
        case ttlMs = "ttl_ms"
    }
}

/// `mobile.pair.start`'s result: the session view plus the pairing link the
/// daemon hands back exactly once.
///
/// The link is flat on the wire, so the session half is decoded from the same
/// container. It carries the one-time secret the phone pairs with: never
/// logged, never persisted, never put on the pasteboard.
public struct ManagementPairingStart: Decodable, Equatable, Sendable {
    public let session: ManagementPairingSession
    public let uri: String?

    private enum CodingKeys: String, CodingKey {
        case uri
    }

    public init(from decoder: Decoder) throws {
        session = try ManagementPairingSession(from: decoder)
        uri = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .uri)
    }
}

/// The phone waiting for a decision: the sanitized copy of what it sent, plus
/// what the daemon verified. `sas` is the six digits the operator compares with
/// the phone before approving.
public struct ManagementPairingRequest: Decodable, Equatable, Sendable {
    public let deviceName: String
    public let model: String
    public let platform: String?
    public let appVersion: String
    public let sas: String
    public let buildRole: ManagementMobileSignerRole?
    public let bootState: ManagementMobileBootState?
    public let attestation: ManagementPairingAttestation

    private enum CodingKeys: String, CodingKey {
        case model, platform, sas, attestation
        case deviceName = "device_name"
        case appVersion = "app_version"
        case buildRole = "build_role"
        case bootState = "boot_state"
    }
}

public struct ManagementMobileBootState: Decodable, Equatable, Sendable {
    public let verified: Bool
    public let locked: Bool
}

/// What the daemon verified about the phone's secure hardware, in its own
/// words. The sentence is rendered; the app never composes one from the status.
public struct ManagementPairingAttestation: Decodable, Equatable, Sendable {
    public let status: ManagementPairingAttestationStatus
    public let sentence: String
}

/// How a finished session ended: the paired device on approved, the reason on
/// denied, expired and cancelled. The field that does not apply is nil.
public struct ManagementPairingOutcome: Decodable, Equatable, Sendable {
    public let deviceId: String?
    public let reason: ManagementPairingOutcomeReason?

    private enum CodingKeys: String, CodingKey {
        case reason
        case deviceId = "device_id"
    }
}

/// Why a session failed, in the daemon's own words. The sentence is rendered;
/// the app never composes one from the code.
public struct ManagementPairingFailure: Decodable, Equatable, Sendable {
    public let code: ManagementPairingFailureCode
    public let sentence: String
}

public struct ManagementMobileDevice: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let name: String
    public let model: String
    public let platform: String?
    public let signerRole: ManagementMobileSignerRole?
    public let bootState: ManagementMobileBootState?
    public let pushRegistered: Bool
    public let createdAt: String
    public let lastSeen: String?

    private enum CodingKeys: String, CodingKey {
        case name, model, platform
        case deviceId = "device_id"
        case signerRole = "signer_role"
        case bootState = "boot_state"
        case pushRegistered = "push_registered"
        case createdAt = "created_at"
        case lastSeen = "last_seen"
    }
}

/// `mobile.devices.list`: every paired phone, oldest first, at most 64. Empty
/// whenever the channel is not running.
public struct ManagementMobileDevices: Decodable, Equatable, Sendable {
    public let devices: [ManagementMobileDevice]
}

/// `mobile.devices.revoke`: the id forgotten, and `revoked`, which the schema
/// publishes as always true.
public struct ManagementMobileDeviceRevoked: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let revoked: Bool

    private enum CodingKeys: String, CodingKey {
        case revoked
        case deviceId = "device_id"
    }
}

// MARK: - Vocabularies

/// A pairing session's `state`, the switch a pane reads.
public enum ManagementPairingState: ManagementVocabulary {
    case awaitingScan
    case awaitingDecision
    case approved
    case denied
    case expired
    case cancelled
    case failed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "awaiting_scan": .awaitingScan,
        "awaiting_decision": .awaitingDecision,
        "approved": .approved,
        "denied": .denied,
        "expired": .expired,
        "cancelled": .cancelled,
        "failed": .failed
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }

    /// Whether the session is over, which is when a pane stops polling it.
    public var isTerminal: Bool {
        switch self {
        case .awaitingScan, .awaitingDecision: return false
        case .approved, .denied, .expired, .cancelled, .failed: return true
        case .unrecognized: return false
        }
    }
}

/// Why a finished session did not pair: `outcome.reason`.
public enum ManagementPairingOutcomeReason: ManagementVocabulary {
    case denied
    case timeout
    case cancelled
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "denied": .denied,
        "timeout": .timeout,
        "cancelled": .cancelled
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `failure.code` on a failed session. The sentence beside it is what is drawn.
public enum ManagementPairingFailureCode: ManagementVocabulary {
    case unavailable
    case refused
    case internalError
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "unavailable": .unavailable,
        "refused": .refused,
        "internal_error": .internalError
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `attestation.status`: what the daemon verified about the phone's secure
/// hardware. `unavailable` for now, until the daemon verifies it.
public enum ManagementPairingAttestationStatus: ManagementVocabulary {
    case verified
    case refused
    case unavailable
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "verified": .verified,
        "refused": .refused,
        "unavailable": .unavailable
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `listener.status`: whether the phone can reach this Mac at all.
public enum ManagementMobileListenerStatus: ManagementVocabulary {
    case ready
    case down
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["ready": .ready, "down": .down]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `mdns`: the local-network announcement.
public enum ManagementMobileAnnouncement: ManagementVocabulary {
    case advertising
    case disabled
    case down
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "advertising": .advertising,
        "disabled": .disabled,
        "down": .down
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `apns.credentials`: whether push credentials are in place.
public enum ManagementMobileCredentials: ManagementVocabulary {
    case ready
    case missing
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["ready": .ready, "missing": .missing]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Who signed the phone's build: a request's `build_role` and a device's
/// `signer_role`. Nil until the daemon verifies attestation.
public enum ManagementMobileSignerRole: ManagementVocabulary {
    case release
    case development
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "release": .release,
        "development": .development
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}
