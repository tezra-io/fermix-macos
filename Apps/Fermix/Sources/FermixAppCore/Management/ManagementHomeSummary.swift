import Foundation

/// `home.status.summary` (M75 lean v1 §7): where Always On stands, worked out
/// once by the engine so the Mac app, the Linux app, the setup page and
/// `fermix home status` say the same thing.
///
/// The app maps `state` to a screen, prints `sentence` and an action's
/// `label` as they are, and switches on the published ids (`state`, an
/// action's `id`, a problem's `kind`), never on a sentence. `detail` is what
/// Details holds.

// MARK: - Vocabularies

/// The screen a summary maps to.
public enum ManagementHomeSummaryState: ManagementVocabulary, Hashable {
    /// Nothing is set up. Set up opens the token screen, the app's own step.
    case off
    /// A code for a server of the owner's own is open, or Hetzner refused the
    /// token before anything was created.
    case connect
    /// The token works: the recommendation and Create server.
    case choose
    /// Starting, installing Fermix on, connecting, or deleting the server.
    case creating
    /// The server is held and waits for Move now.
    case ready
    /// The move runs.
    case moving
    /// Fermix runs on the server.
    case on
    /// The move was undone.
    case undone
    /// This computer has no link to the server any more.
    case retired
    /// The server, before its move.
    case candidate
    /// The server, after its move.
    case primary
    /// Something went wrong: `detail.kind` names it.
    case problem
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "off": .off,
        "connect": .connect,
        "choose": .choose,
        "creating": .creating,
        "ready": .ready,
        "moving": .moving,
        "on": .on,
        "undone": .undone,
        "retired": .retired,
        "candidate": .candidate,
        "primary": .primary,
        "problem": .problem
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// What one summary action does, by its published id (PROTOCOL.md, *The
/// Always On summary*, says which calls each one makes).
public enum ManagementHomeActionId: ManagementVocabulary, Hashable {
    case setUp
    case createServer
    case cancel
    case moveNow
    case tryAgain
    case learnMore
    case turnOn
    case restartServer
    case startAgain
    case createIn
    case openHetzner
    case pasteToken
    case update
    case backUpNow
    case replaceServer
    case checkAgain
    case ownServer
    case deleteServer
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "set_up": .setUp,
        "create_server": .createServer,
        "cancel": .cancel,
        "move_now": .moveNow,
        "try_again": .tryAgain,
        "learn_more": .learnMore,
        "turn_on": .turnOn,
        "restart_server": .restartServer,
        "start_again": .startAgain,
        "create_in": .createIn,
        "open_hetzner": .openHetzner,
        "paste_token": .pasteToken,
        "update": .update,
        "back_up_now": .backUpNow,
        "replace_server": .replaceServer,
        "check_again": .checkAgain,
        "own_server": .ownServer,
        "delete_server": .deleteServer
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// What went wrong, on a `problem` summary.
public enum ManagementHomeProblemKind: ManagementVocabulary, Hashable {
    case turnedOff
    case cannotReach
    case deleted
    case notSetUp
    case waitedTooLong
    case noCapacity
    case accountLimit
    case readOnlyToken
    case tokenRefused
    case createFailed
    case update
    case diskFull
    case backupOld
    case notReady
    case unreadable
    /// After a replace's move, deleting the old server stopped.
    case deleteFailed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "turned_off": .turnedOff,
        "cannot_reach": .cannotReach,
        "deleted": .deleted,
        "not_set_up": .notSetUp,
        "waited_too_long": .waitedTooLong,
        "no_capacity": .noCapacity,
        "account_limit": .accountLimit,
        "read_only_token": .readOnlyToken,
        "token_refused": .tokenRefused,
        "create_failed": .createFailed,
        "update": .update,
        "disk_full": .diskFull,
        "backup_old": .backupOld,
        "not_ready": .notReady,
        "unreadable": .unreadable,
        "delete_failed": .deleteFailed
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// A Hetzner location Fermix creates a server in.
public enum ManagementHetznerLocation: ManagementVocabulary, Hashable {
    case falkenstein
    case nuremberg
    case helsinki
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "fsn1": .falkenstein,
        "nbg1": .nuremberg,
        "hel1": .helsinki
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

// MARK: - The summary

/// One action a summary offers: its id and the engine's label for it.
public struct ManagementHomeAction: Decodable, Equatable, Hashable, Sendable {
    public let id: ManagementHomeActionId
    public let label: String

    public init(id: ManagementHomeActionId, label: String) {
        precondition(!label.isEmpty, "an action is shown under a label")
        self.id = id
        self.label = label
    }
}

/// `off`'s token step, which its Set up opens: the token screen's sentence,
/// the "How to get one" steps and the own-server link.
public struct ManagementHomeSummaryConnect: Decodable, Equatable, Sendable {
    public let sentence: String
    public let steps: [String]
    public let alternatives: [ManagementHomeAction]
}

/// The server a summary names. Hetzner's facts (type, location as a city,
/// ipv4) are null for a server of the owner's own; on `ready` the system and
/// version it enrolled with, on `on` the version it answers with.
public struct ManagementHomeSummaryServer: Decodable, Equatable, Sendable {
    public let name: String?
    public let type: String?
    public let location: String?
    public let ipv4: String?
    public let system: String?
    public let version: String?
}

/// The newest verified backup in one place.
public struct ManagementHomeSummaryBackup: Decodable, Equatable, Sendable {
    public let place: String
    public let at: String
}

/// What Details holds for the state, and nothing else (the schema's
/// `homeSummaryDetail`). Every field is absent where the state has none.
public struct ManagementHomeSummaryDetail: Decodable, Equatable, Sendable {
    /// `off`: the token step its Set up opens.
    public let connect: ManagementHomeSummaryConnect?
    /// `connect`: the "How to get one" steps.
    public let steps: [String]?
    /// `connect` and `problem`: the other actions.
    public let alternatives: [ManagementHomeAction]?
    /// `on`: the actions Details offers.
    public let actions: [ManagementHomeAction]?
    /// `choose`: how Hetzner bills.
    public let billing: String?
    public let server: ManagementHomeSummaryServer?
    /// `ready` and `not_ready`: the last review's warnings and blocks.
    public let readiness: [ManagementReadinessItem]?
    public let waitsUntil: String?
    public let backups: [ManagementHomeSummaryBackup]?
    public let copiesBytes: Int?
    public let diskUsed: Double?
    /// `on`: what lives on the server, and that its host can read its disk.
    public let data: String?
    /// `problem`: what went wrong.
    public let kind: ManagementHomeProblemKind?
    public let note: String?
    /// `problem`: when Fermix last saw what the problem rests on.
    public let seenAt: String?
    /// `no_capacity`: where the type is in stock next.
    public let nextLocation: ManagementHetznerLocation?

    private enum CodingKeys: String, CodingKey {
        case connect, steps, alternatives, actions, billing, server, readiness, backups, data, kind, note
        case waitsUntil = "waits_until"
        case copiesBytes = "copies_bytes"
        case diskUsed = "disk_used"
        case seenAt = "seen_at"
        case nextLocation = "next_location"
    }
}

/// `home.status.summary`.
public struct ManagementHomeSummary: Decodable, Equatable, Sendable {
    public let state: ManagementHomeSummaryState
    public let sentence: String
    /// The one main action, or none when all is well.
    public let action: ManagementHomeAction?
    public let detail: ManagementHomeSummaryDetail

    /// The problem's kind, on a `problem` summary.
    public var problem: ManagementHomeProblemKind? {
        state == .problem ? detail.kind : nil
    }
}

/// On the primary, how full its disk is.
public struct ManagementHomeDisk: Decodable, Equatable, Sendable {
    public let used: Double
    public let nearlyFull: Bool

    private enum CodingKeys: String, CodingKey {
        case used
        case nearlyFull = "nearly_full"
    }
}
