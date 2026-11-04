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
    /// What the channel waits for while it is on and not running, where a
    /// restart alone would not start it: `setup` while this boot held it for
    /// setup that is still not finished. Nil otherwise, and from an engine
    /// older than the field, which publishes no hold.
    public let hold: ManagementMobileHold?
    public let listener: ManagementMobileListener
    public let mdns: ManagementMobileAnnouncement
    public let tailnet: ManagementMobileTailnet
    public let identity: ManagementMobileIdentity
    /// Reach from anywhere (M62). Nil from an engine older than the rail,
    /// which publishes neither the state nor the switch.
    public let remote: ManagementMobileRemote?
    public let apns: ManagementMobilePush
    public let pairedDevices: Int
    public let protocolVersion: Int
    /// The open pairing window, else the newest retained session, else nil.
    public let pairing: ManagementPairingSummary?

    private enum CodingKeys: String, CodingKey {
        case enabled, started, refused, hold, listener, mdns, tailnet, identity, remote, apns, pairing
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

/// The rail that lets a paired phone reach this daemon from any network
/// through Fermix's relays (M62). `endpointId`, `relay` and `relayError` are
/// set only while `ready`, as `connected` is true only then, and `failure` only
/// while `failed`: the helper's or the daemon's words, control characters
/// removed. `refused` counts the remote connections the helper turned away
/// since it started.
public struct ManagementMobileRemote: Decodable, Equatable, Sendable {
    public let state: ManagementMobileRemoteState
    public let endpointId: String?
    public let relay: String?
    public let connected: Bool
    public let relayError: String?
    public let failure: String?
    public let refused: ManagementMobileRemoteRefusals

    private enum CodingKeys: String, CodingKey {
        case state, relay, connected, failure, refused
        case endpointId = "endpoint_id"
        case relayError = "relay_error"
    }
}

/// The remote connections the helper refused, by reason: 64 already connected,
/// not a Fermix phone, or the daemon not taking them.
public struct ManagementMobileRemoteRefusals: Decodable, Equatable, Sendable {
    public let busy: Int
    public let alpn: Int
    public let bridgeUnreachable: Int

    private enum CodingKeys: String, CodingKey {
        case busy, alpn
        case bridgeUnreachable = "bridge_unreachable"
    }
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

/// A paired device: a phone, or a desktop engine a move paired (M75), which
/// has no platform, signer, boot state or push registration of its own.
public struct ManagementMobileDevice: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let name: String
    public let model: String
    /// Nil from an engine older than desktops, which pairs only phones.
    public let kind: ManagementMobileDeviceKind?

    /// Whether this is a phone: one the daemon names so, or any device of an
    /// engine older than desktops. A desktop, or a kind this build does not
    /// know, is not one.
    public var isPhone: Bool { kind == nil || kind == .phone }
    public let platform: String?
    public let signerRole: ManagementMobileSignerRole?
    public let bootState: ManagementMobileBootState?
    public let pushRegistered: Bool
    public let createdAt: String
    public let lastSeen: String?

    private enum CodingKeys: String, CodingKey {
        case name, model, kind, platform
        case deviceId = "device_id"
        case signerRole = "signer_role"
        case bootState = "boot_state"
        case pushRegistered = "push_registered"
        case createdAt = "created_at"
        case lastSeen = "last_seen"
    }
}

/// `mobile.devices.list`: every paired device, oldest first, at most 64.
public struct ManagementMobileDevices: Decodable, Equatable, Sendable {
    public let devices: [ManagementMobileDevice]

    /// The phones alone, which the Phone sheet lists and forgets. A desktop
    /// a move paired is no phone, by the kind the daemon publishes.
    public var phones: [ManagementMobileDevice] {
        devices.filter(\.isPhone)
    }
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
/// hardware. The engine this app pins verifies it, so a pairing reads
/// `verified` or `refused`; an older engine answers `unavailable`.
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
    case unavailable
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["ready": .ready, "down": .down, "unavailable": .unavailable]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `remote.state`: where the rail stands. `off` is its switch off or the
/// channel not running, `dormant` no phone paired yet, and `helper_missing`
/// a build that carries no rail to start.
/// What an enabled phone channel that is not running waits for
/// (`mobile.status.hold`).
public enum ManagementMobileHold: ManagementVocabulary {
    case setup
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["setup": .setup]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementMobileRemoteState: ManagementVocabulary {
    case off
    case dormant
    case helperMissing
    case starting
    case ready
    case failed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "off": .off,
        "dormant": .dormant,
        "helper_missing": .helperMissing,
        "starting": .starting,
        "ready": .ready,
        "failed": .failed
    ]

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

/// What a paired device is: a phone, or a desktop engine in the device role.
public enum ManagementMobileDeviceKind: ManagementVocabulary, Hashable {
    case phone
    case desktop
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "phone": .phone,
        "desktop": .desktop
    ]

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
