import Foundation

/// The typed results of the `home.*` methods (M75).
///
/// `home.status` is the one picture every Always On surface draws: where this
/// home runs, the primary a desktop reaches, the desktops a primary serves,
/// the recovery snapshots, and the move. Every sentence on it is the
/// daemon's; the app draws the sentence and switches on the published words
/// (`role`, a target's `last_result`), never on a sentence.

// MARK: - Vocabularies

/// The role this engine runs its home in.
public enum ManagementHomeRole: ManagementVocabulary, Hashable {
    /// The home's one primary: it answers the agent loop, the channels and
    /// the schedules.
    case primary
    /// A desktop whose home moved to a primary elsewhere: it keeps this
    /// machine's sandbox and tools and carries chat to the primary.
    case device
    /// A fresh engine that enrolled with a primary and waits for its move.
    /// A server is one; this Mac's engine never is in the flows the app
    /// draws.
    case candidate
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "primary": .primary,
        "device": .device,
        "candidate": .candidate
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// How a snapshot target's last attempt ended. Null on the wire before its
/// first attempt. `waiting` is no failure: the target could not take the
/// snapshot then (a desktop asleep or offline) and takes one at a later run.
public enum ManagementSnapshotResult: ManagementVocabulary, Hashable {
    case verified
    case failed
    case waiting
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "verified": .verified,
        "failed": .failed,
        "waiting": .waiting
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where the one enrollment window stands: open for a server to check in,
/// used by the one that did, or expired.
public enum ManagementEnrollmentState: ManagementVocabulary, Hashable {
    case open
    case used
    case expired
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "open": .open,
        "used": .used,
        "expired": .expired
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a move stands: on the home that moves, `requested` to
/// `done` or `aborted`; on a candidate, `enrolling` to `activating`, or
/// `expired` or `failed`.
///
/// `committed` and `undoing` are the engine about to restart, as a desktop or
/// back as the primary; `done` and `aborted` are written only by the engine
/// that came back, so reading either is reading the engine that stays.
public enum ManagementMovePhase: ManagementVocabulary, Hashable {
    case requested
    case streaming
    case committing
    case committed
    case done
    case aborting
    case undoing
    case aborted
    case enrolling
    case enrolled
    case receiving
    case staged
    case activating
    case expired
    case failed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "requested": .requested,
        "streaming": .streaming,
        "committing": .committing,
        "committed": .committed,
        "done": .done,
        "aborting": .aborting,
        "undoing": .undoing,
        "aborted": .aborted,
        "enrolling": .enrolling,
        "enrolled": .enrolled,
        "receiving": .receiving,
        "staged": .staged,
        "activating": .activating,
        "expired": .expired,
        "failed": .failed
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }

    /// Whether the move is still under way, so the picture moves by itself.
    /// A phase this build does not know is followed too: the move records
    /// each one as it reaches it, and `done`, `aborted`, `expired` and
    /// `failed` are the ones it ends on. `committed` and `undoing` are not an
    /// ending: the engine that reads them is about to restart.
    public var isPending: Bool {
        switch self {
        case .done, .aborted, .expired, .failed: return false
        case .requested, .streaming, .committing, .committed, .aborting, .undoing, .enrolling, .enrolled,
             .receiving, .staged, .activating, .unrecognized:
            return true
        }
    }
}

// MARK: - Enrollment and the move

/// `home.enroll.open`: the code a server enrolls with, answered once and
/// never kept in a status, and when the window closes.
public struct ManagementEnrollmentCode: Decodable, Equatable, Sendable {
    public let code: String
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
    }
}

/// Which code a window holds: the one a person copies, or the one inside a
/// server Fermix created (24 hours).
public enum ManagementEnrollmentKind: ManagementVocabulary, Hashable {
    case manual
    case provisioned
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["manual": .manual, "provisioned": .provisioned]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `home.enroll.withdraw`: the server's 24-hour window released. The app
/// never asks it (`ManagementMethod.homeEnrollWithdraw`).
public struct ManagementEnrollmentWithdrawn: Decodable, Equatable, Sendable {
    public let withdrawn: Bool
}

/// `home.status`'s `enrollment`: the window, without its code.
public struct ManagementEnrollmentWindow: Decodable, Equatable, Sendable {
    public let state: ManagementEnrollmentState
    public let expiresAt: String
    /// Which code the window holds; absent from an engine before it.
    public let kind: ManagementEnrollmentKind?
    /// The server that enrolled with the window's code, which is how the
    /// server Fermix created is known; null until one did.
    public let candidateId: String?

    public init(state: ManagementEnrollmentState, expiresAt: String, kind: ManagementEnrollmentKind? = nil, candidateId: String? = nil) {
        self.state = state
        self.expiresAt = expiresAt
        self.kind = kind
        self.candidateId = candidateId
    }

    private enum CodingKeys: String, CodingKey {
        case state, kind
        case expiresAt = "expires_at"
        case candidateId = "candidate_id"
    }
}

/// A server that enrolled and waits for the move, as the primary holds it,
/// never with its keys.
public struct ManagementCandidate: Decodable, Equatable, Sendable {
    public let candidateId: String
    public let name: String
    public let os: String
    public let arch: String
    public let version: String
    public let enrolledAt: String
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case name, os, arch, version
        case candidateId = "candidate_id"
        case enrolledAt = "enrolled_at"
        case expiresAt = "expires_at"
    }
}

/// `home.candidates.list`.
public struct ManagementCandidates: Decodable, Equatable, Sendable {
    public let candidates: [ManagementCandidate]
}

/// `home.status`'s `move`: the phase, the server's name, and the daemon's
/// sentence for where it stands.
public struct ManagementMove: Decodable, Equatable, Sendable {
    public let phase: ManagementMovePhase
    public let candidate: String?
    public let sentence: String
}

/// `home.move.start`: the move begun, before the engine restarts to carry it
/// out. The passphrase it was given is never answered.
public struct ManagementMoveStarted: Decodable, Equatable, Sendable {
    public let moveId: String
    public let candidate: ManagementCandidate
    /// Whether the home that moves stays a desktop of the new primary: false
    /// when a server is replaced, which then serves nothing.
    public let keepAsDesktop: Bool
    public let sentence: String

    private enum CodingKeys: String, CodingKey {
        case candidate, sentence
        case moveId = "move_id"
        case keepAsDesktop = "keep_as_desktop"
    }
}

/// How one fact about a move stands: fine, worth reading, or in the way.
public enum ManagementReadinessStatus: ManagementVocabulary, Hashable {
    case ok
    case warn
    case block
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "ok": .ok,
        "warn": .warn,
        "block": .block
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// One fact the owner reviews before a move, in the daemon's sentence. The
/// app draws an id it does not know by its sentence, as it is.
public struct ManagementReadinessItem: Decodable, Equatable, Sendable {
    public let id: String
    public let status: ManagementReadinessStatus
    public let sentence: String
}

/// `home.move.readiness`: what blocks or warns before a move to one server.
/// `ready` is false while any item blocks, and `home.move.start` refuses then.
public struct ManagementMoveReadiness: Decodable, Equatable, Sendable {
    public let ready: Bool
    public let items: [ManagementReadinessItem]
}

// MARK: - Snapshots

/// A snapshot a target proved it holds: when, its name, the epoch it was
/// taken at, its size and digest, and where it is.
public struct ManagementSnapshotPoint: Decodable, Equatable, Sendable {
    public let at: String
    public let name: String?
    public let epoch: Int?
    public let size: Int?
    public let sha256: String?
    public let location: String?
    /// The recovery key the snapshot was written for, as
    /// `home.snapshots.passphrase` names it; null for one recorded before
    /// keys were named.
    public let keyId: String?

    private enum CodingKeys: String, CodingKey {
        case at, name, epoch, size, sha256, location
        case keyId = "key_id"
    }
}

/// One place snapshots go, as the daemon reports it.
public struct ManagementSnapshotTarget: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let configured: Bool
    /// Where the target puts snapshots; null while it is off.
    public let destination: String?
    public let lastAttemptAt: String?
    public let lastResult: ManagementSnapshotResult?
    /// The newest snapshot the target proved it holds. It outlives a later
    /// failure, which is what "the last verified point" means.
    public let lastVerified: ManagementSnapshotPoint?
    /// The newest failure's sentence, in the storage service's own words;
    /// cleared at the next verified or waiting run.
    public let lastError: String?
    /// While the last run left the target waiting, the daemon's sentence for
    /// why (`Your <name> is not connected; ...`); null otherwise.
    public let waiting: String?

    private enum CodingKeys: String, CodingKey {
        case id, label, configured, destination, waiting
        case lastAttemptAt = "last_attempt_at"
        case lastResult = "last_result"
        case lastVerified = "last_verified"
        case lastError = "last_error"
    }
}

/// The recovery snapshots: `home.snapshots.status`, and `home.status`'s
/// `snapshots`.
public struct ManagementHomeSnapshots: Decodable, Equatable, Sendable {
    public let configured: Bool
    /// Whether a recovery key is set, without which nothing is written.
    public let recipientSet: Bool
    public let intervalHours: Int
    public let running: Bool
    public let nextRunAt: String?
    public let targets: [ManagementSnapshotTarget]
    public let sentence: String

    private enum CodingKeys: String, CodingKey {
        case configured, running, targets, sentence
        case recipientSet = "recipient_set"
        case intervalHours = "interval_hours"
        case nextRunAt = "next_run_at"
    }
}

/// `home.snapshots.run`: a snapshot started, and the view as it now stands.
public struct ManagementSnapshotsStarted: Decodable, Equatable, Sendable {
    public let started: Bool
    public let snapshots: ManagementHomeSnapshots
}

/// `home.snapshots.passphrase`: the recovery key's public half, its short id,
/// and the view. The passphrase it came from is never answered.
public struct ManagementRecoveryKey: Decodable, Equatable, Sendable {
    public let recipient: String
    public let keyId: String
    public let snapshots: ManagementHomeSnapshots
    /// That snapshots from now on open with this passphrase, naming its key
    /// id, and those written before only with the earlier one.
    public let sentence: String

    private enum CodingKeys: String, CodingKey {
        case recipient, snapshots, sentence
        case keyId = "key_id"
    }
}

// MARK: - The picture

/// Where this home went: the primary's name, when, and the epoch it moved at.
public struct ManagementHomeMoved: Decodable, Equatable, Sendable {
    public let to: String
    public let movedAt: String
    public let epoch: Int

    private enum CodingKeys: String, CodingKey {
        case to, epoch
        case movedAt = "moved_at"
    }
}

/// The link to the server in one closed word.
public enum ManagementPrimaryLinkState: ManagementVocabulary, Hashable {
    /// A session is up.
    case connected
    /// A session is opening with nothing known to be wrong: the first since
    /// the engine started, or a quiet renewal. Drawn quietly, never as an
    /// outage.
    case renewing
    /// An outage, retried with a backoff.
    case unreachable
    /// The server no longer knows this computer; never retried until the
    /// engine restarts.
    case revoked
    /// The server answered as an older copy of itself; retried.
    case stale
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "connected": .connected,
        "renewing": .renewing,
        "unreachable": .unreachable,
        "revoked": .revoked,
        "stale": .stale
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// In the device role, the primary this desktop reaches over the rail.
public struct ManagementHomePrimary: Decodable, Equatable, Sendable {
    /// Null while this desktop does not know it yet.
    public let name: String?
    public let connected: Bool
    /// The link's state, which says how to draw the sentence.
    public let status: ManagementPrimaryLinkState
    /// When the link came up; null while it is down.
    public let since: String?
    /// The highest primary epoch this desktop has seen.
    public let epoch: Int?
    public let sentence: String
}

/// On a primary, one desktop that holds a session to it.
public struct ManagementHomeDesktop: Decodable, Equatable, Sendable {
    public let deviceId: String
    public let name: String
    public let connected: Bool
    public let since: String?

    private enum CodingKeys: String, CodingKey {
        case name, connected, since
        case deviceId = "device_id"
    }
}

/// `home.status`: the one picture of this home every surface draws.
public struct ManagementHomeStatus: Decodable, Equatable, Sendable {
    public let role: ManagementHomeRole
    /// Null before the home's first boot as the primary.
    public let epoch: Int?
    /// The marker a home that moved away keeps, or null.
    public let moved: ManagementHomeMoved?
    /// In the device role with a link to the primary, that primary.
    public let primary: ManagementHomePrimary?
    /// On the primary, its desktops.
    public let desktops: [ManagementHomeDesktop]
    /// This engine's own snapshots. A desktop's list no target: its status
    /// file is a retired copy, and the server's are in `primaryHome`.
    public let snapshots: ManagementHomeSnapshots
    /// On the primary, the enrollment window, or null.
    public let enrollment: ManagementEnrollmentWindow?
    /// On the primary, the servers that enrolled and wait for the move.
    public let candidates: [ManagementCandidate]
    /// The move this home started, or null when it never started one.
    public let move: ManagementMove?
    /// On the primary, the ids (as `secret.set` takes them) of the secrets its
    /// settings name that did not resolve on this host, each to enter again.
    public let secretsMissing: [String]
    /// On a linked desktop, the server's own picture: its recovery,
    /// enrollment, servers that checked in and move. Null elsewhere, and
    /// while the server's answer is missing.
    public let primaryHome: ManagementPrimaryHome?
    /// On a linked desktop, the daemon's sentence for why `primaryHome` is
    /// missing; null otherwise.
    public let primaryMissing: String?
    /// Where Always On stands, in one sentence and at most one action. Absent
    /// from an engine older than it, which the pane answers as one that needs
    /// updating.
    public let summary: ManagementHomeSummary?
    /// On the primary, how full its disk is; null elsewhere and when it
    /// cannot be read.
    public let disk: ManagementHomeDisk?
    /// This engine's version; absent from an engine older than the summary.
    public let version: String?

    private enum CodingKeys: String, CodingKey {
        case role, epoch, moved, primary, desktops, snapshots, enrollment, candidates, move, summary, disk, version
        case secretsMissing = "secrets_missing"
        case primaryHome = "primary_home"
        case primaryMissing = "primary_missing"
    }

    /// The server's picture on a linked desktop, unboxed.
    public var server: ManagementHomeStatus? { primaryHome?.status }
}

/// A linked desktop's `primary_home`: the server's own `home.status`, held
/// by reference because a picture cannot hold a picture by value.
public final class ManagementPrimaryHome: Decodable, Equatable, Sendable {
    public let status: ManagementHomeStatus

    public init(_ status: ManagementHomeStatus) {
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        status = try ManagementHomeStatus(from: decoder)
    }

    public static func == (lhs: ManagementPrimaryHome, rhs: ManagementPrimaryHome) -> Bool {
        lhs.status == rhs.status
    }
}
