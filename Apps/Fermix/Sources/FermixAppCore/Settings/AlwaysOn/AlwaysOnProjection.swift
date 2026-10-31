import Foundation

/// The Always On guide on fermix.ai: what the pane keeps short, explained, and
/// the page that links the AWS template. A constant rather than a daemon
/// field, like the cues guide: it is the product's own page, the same for
/// every home, and carries nothing private.
public enum AlwaysOnGuide {
    public static let url: URL = {
        guard let url = URL(string: "https://fermix.ai/docs/always-on") else {
            preconditionFailure("the Always On guide forms a url")
        }

        return url
    }()
}

/// What the Always On pane draws, read from `home.status` alone (M75 §14).
///
/// The stage switches on the published role and nothing else: every sentence
/// the pane shows is the daemon's, drawn as written.
public enum AlwaysOnStage: Equatable, Sendable {
    /// Nothing has answered yet.
    case unanswered
    /// The daemon in memory is older than the pane.
    case requiresNewerEngine
    /// The daemon refused, in its own words.
    case refused(String)
    /// This Mac runs Fermix: the way to move it, its recovery, and any
    /// desktops it serves.
    case primary
    /// This Mac is a desktop of a primary elsewhere: that primary, this Mac's
    /// own switches, and the recovery the primary keeps.
    case device
    /// This engine waits to become a primary through a move: only the move's
    /// own sentence is drawn.
    case candidate
    /// A role this build does not know, named as the daemon sent it.
    case unknownRole(String)

    public static func stage(_ status: SettingsReadState<ManagementHomeStatus>) -> AlwaysOnStage {
        switch status {
        case .unread, .loading: return .unanswered
        case .requiresNewerEngine: return .requiresNewerEngine
        case .unavailable(let sentence): return .refused(sentence)
        case .loaded(let home): return stage(home.role)
        }
    }

    private static func stage(_ role: ManagementHomeRole) -> AlwaysOnStage {
        switch role {
        case .primary: return .primary
        case .device: return .device
        case .candidate: return .candidate
        case .unrecognized(let value): return .unknownRole(value)
        }
    }
}

/// Where the owner chose to run the server: the app's own question, which
/// changes the steps it shows beside the code and nothing the daemon does.
public enum AlwaysOnDestination: String, CaseIterable, Identifiable, Sendable {
    case aws
    case existingHost

    public var id: String { rawValue }

    public var titleKey: ProductStringKey {
        switch self {
        case .aws: return .alwaysOnSetupAWS
        case .existingHost: return .alwaysOnSetupExistingHost
        }
    }
}

/// A code an enrollment window handed out, held by the pane only while it
/// shows it: the daemon answers it once and keeps it in no status.
public struct EnrollmentHandout: Equatable, Sendable {
    public let code: String
    public let expiresAt: String

    public init(code: String, expiresAt: String) {
        precondition(!code.isEmpty, "a handed code has a value")
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// Which step of moving the primary the pane draws, from `home.status` and
/// the two things only this pane knows: the code it holds, and that it asked
/// for a move the engine is restarting to carry out.
public enum AlwaysOnSetupStep: Equatable, Sendable {
    /// Nothing under way: what moving does, where to, and Get a code.
    case choose
    /// A code handed out and its window open: the code, once, and the steps.
    case code(EnrollmentHandout)
    /// The window is open and the code is gone: waiting, or a new code.
    case waiting
    /// Servers checked in: review one and move to it.
    case review([ManagementCandidate])
    /// The move is under way, in the daemon's words.
    case moving(ManagementMove)
    /// The move was asked for and the engine is away, restarting to do it.
    case restarting

    public static func step(
        _ home: ManagementHomeStatus,
        handout: EnrollmentHandout?,
        moveRequested: Bool,
        restarting: Bool
    ) -> AlwaysOnSetupStep {
        if moveRequested, restarting || home.move == nil { return .restarting }
        if let move = home.move, move.phase.isPending { return .moving(move) }
        if !home.candidates.isEmpty { return .review(home.candidates) }
        if let handout, !spendsCode(home) { return .code(handout) }

        return home.enrollment?.state == .open ? .waiting : .choose
    }

    /// The daemon's sentence about a move that was undone, said above the
    /// steps that start another; nil otherwise.
    public static func undoneMove(_ home: ManagementHomeStatus) -> String? {
        guard let move = home.move, move.phase == .aborted else { return nil }

        return move.sentence
    }

    /// Whether a handed code is spent: a server checked in with it, or its
    /// window was used or expired. The pane then forgets it.
    public static func spendsCode(_ home: ManagementHomeStatus) -> Bool {
        if !home.candidates.isEmpty { return true }

        switch home.enrollment?.state {
        case .used?, .expired?: return true
        case .open?, .unrecognized?, nil: return false
        }
    }
}

/// What the pane says about the primary a desktop reaches: its name, whether
/// the link is up, the daemon's sentence, and since when.
public struct AlwaysOnPrimaryLine: Equatable, Sendable {
    public let name: String
    public let tone: StatusTone
    /// The rail's own sentence; nil where this desktop has no link to report.
    public let sentence: String?
    public let since: String?

    /// The linked primary where the rail reports one, else the name the
    /// home's marker says it moved to, with nothing said about a link the
    /// daemon does not report. Nil in any other role.
    public static func line(_ home: ManagementHomeStatus) -> AlwaysOnPrimaryLine? {
        guard home.role == .device else { return nil }

        if let primary = home.primary {
            return AlwaysOnPrimaryLine(
                name: primary.name ?? home.moved?.to ?? ProductStrings[.alwaysOnPrimaryTitle],
                tone: tone(primary),
                sentence: primary.sentence,
                since: primary.connected ? primary.since : nil
            )
        }

        guard let moved = home.moved else { return nil }

        return AlwaysOnPrimaryLine(name: moved.to, tone: .neutral, sentence: nil, since: nil)
    }

    /// The link's dot, by its published word: well while connected, quiet
    /// while a session is renewing (no outage), amber for an outage or a
    /// stale server, red once the server no longer knows this computer.
    public static func tone(_ primary: ManagementHomePrimary) -> StatusTone {
        switch primary.status {
        case .connected: return .pass
        case .renewing: return .neutral
        case .unreachable, .stale: return .warn
        case .revoked: return .fail
        case .unrecognized: return primary.connected ? .pass : .warn
        }
    }

    /// Whether the line asks for attention: an outage, a stale server or a
    /// revoked link, never a renewal.
    public var attention: Bool { tone == .warn || tone == .fail }
}

/// A snapshot target's row: its label, the place it writes, the last verified
/// point and the newest failure, each the daemon's.
public enum AlwaysOnRecoveryProjection {
    /// Well while the last attempt was verified, amber after a failure, and
    /// quiet while the target is off, has not run, or waits for a later run
    /// (a desktop asleep), which is no failure.
    public static func tone(_ target: ManagementSnapshotTarget) -> StatusTone {
        guard target.configured else { return .neutral }

        switch target.lastResult {
        case .verified?: return .pass
        case .failed?: return .warn
        case .waiting?, .unrecognized?, nil: return .neutral
        }
    }

    /// The line under the target's name: its last verified point, by the
    /// time the target proved it holds it.
    public static func verifiedLine(_ target: ManagementSnapshotTarget, time: (Date) -> String) -> String {
        guard let point = target.lastVerified else { return ProductStrings[.alwaysOnRecoveryNotVerified] }

        let when = ManagementCueTime.date(point.at).map(time) ?? point.at
        return String(format: ProductStrings[.alwaysOnRecoveryLastVerifiedFormat], when)
    }

    /// The dot before the daemon's sentence about the snapshots: quiet while
    /// nothing is configured here, amber while a configured target's last
    /// attempt failed, and well otherwise.
    public static func tone(_ snapshots: ManagementHomeSnapshots) -> StatusTone {
        guard snapshots.configured else { return .neutral }

        let failing = snapshots.targets.contains { $0.configured && $0.lastResult == .failed }
        return failing ? .warn : .pass
    }

    /// Back up now is offered where the daemon says snapshots are configured
    /// here: it writes nothing anywhere else, and the daemon would refuse it.
    public static func offersBackup(_ snapshots: ManagementHomeSnapshots) -> Bool {
        snapshots.configured
    }

    /// The recovery key a target's last verified point was written for, as a
    /// line, or nil where the point names none.
    public static func keyLine(_ target: ManagementSnapshotTarget) -> String? {
        guard let key = target.lastVerified?.keyId, !key.isEmpty else { return nil }

        return String(format: ProductStrings[.alwaysOnRecoveryKeyFormat], key)
    }

    /// What Recovery draws from a picture: the primary's own snapshots; on a
    /// linked desktop the server's, which Back up now and the passphrase reach
    /// through it, or the daemon's sentence while the server's picture is
    /// missing; on a desktop with no link, its own sentence and nothing to do.
    public static func source(_ home: ManagementHomeStatus) -> AlwaysOnRecoverySource {
        guard home.role == .device else { return .snapshots(home.snapshots, setsKey: home.role == .primary) }
        if let server = home.server { return .snapshots(server.snapshots, setsKey: true) }
        if let missing = home.primaryMissing { return .missing(missing) }

        return .snapshots(home.snapshots, setsKey: false)
    }

    /// The secrets the home's settings name that did not resolve where it
    /// runs, each to enter again: the primary's own, or on a desktop the
    /// server's.
    public static func secretsMissing(_ home: ManagementHomeStatus) -> [String] {
        home.role == .device ? (home.server?.secretsMissing ?? []) : home.secretsMissing
    }
}

/// Where Recovery's facts come from.
public enum AlwaysOnRecoverySource: Equatable, Sendable {
    /// Snapshots to draw, and whether this Mac sets their recovery key: the
    /// primary's own, or a linked desktop's server's.
    case snapshots(ManagementHomeSnapshots, setsKey: Bool)
    /// A linked desktop whose server's picture is missing, in the daemon's
    /// words.
    case missing(String)
}

/// The readiness report's lines: each fact's dot, in the daemon's words.
public enum AlwaysOnReadinessProjection {
    /// Well when it is fine, amber when it is worth reading, red when it is in
    /// the way, and quiet for a status this build does not know.
    public static func tone(_ item: ManagementReadinessItem) -> StatusTone {
        switch item.status {
        case .ok: return .pass
        case .warn: return .warn
        case .block: return .fail
        case .unrecognized: return .neutral
        }
    }
}

/// The recovery passphrase as it is typed: twice, never kept past the call
/// that sends it, and sent only when both match. Its length and every other
/// rule are the daemon's, which answers a refusal with its own sentence.
public struct RecoveryPassphraseEntry: Equatable, Sendable {
    public var first = ""
    public var second = ""

    public init(first: String = "", second: String = "") {
        self.first = first
        self.second = second
    }

    /// Whether the entry may be sent: typed, and the same both times.
    public var matches: Bool { !first.isEmpty && first == second }

    /// Whether to say the two differ: only once the second has been typed,
    /// so the field is not wrong while the owner is still typing it.
    public var showsMismatch: Bool { !second.isEmpty && first != second }

    /// The passphrase to send, or nil while the entry does not match.
    public var passphrase: String? { matches ? first : nil }

    /// Forgets both, which the pane does as soon as the call is sent.
    public mutating func clear() {
        first = ""
        second = ""
    }
}

/// How the pane follows `home.status` while something can move by itself: a
/// snapshot running, a server checking in, a move under way. A read every two
/// seconds, backing off to ten while the daemon refuses or is restarting, for
/// at most fifteen minutes; then it stops and the pane offers to look again.
struct AlwaysOnFollow: Equatable {
    static let pollSeconds: TimeInterval = 2
    static let backoffSeconds: TimeInterval = 10
    static let maxReads = 450

    private(set) var reads = 0
    private(set) var refusals = 0

    var exhausted: Bool { reads >= Self.maxReads }

    var wait: TimeInterval {
        min(Self.pollSeconds * pow(2, Double(refusals)), Self.backoffSeconds)
    }

    mutating func answered() {
        reads += 1
        refusals = 0
    }

    mutating func refused() {
        reads += 1
        refusals += 1
    }
}
