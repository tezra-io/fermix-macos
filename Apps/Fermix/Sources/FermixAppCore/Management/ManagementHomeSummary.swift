import Foundation

/// `home.status.summary` (Always On setup §3.1): the Always On screen, worked
/// out once by the engine so the Mac app, the Linux app, the setup page and
/// `fermix always-on` draw the same thing.
///
/// The app maps `state` to a screen, prints `sentence` and every label as
/// they are, and switches on the published ids (`state`, an action's `id` and
/// `needs`), never on a sentence. Every press of an action is one `home.act`
/// with the action's `id` and `key`; the engine runs the steps behind it.

// MARK: - Vocabularies

/// The screen a summary maps to.
public enum ManagementHomeSummaryState: ManagementVocabulary, Hashable {
    /// Nothing is set up. Use my own Linux server opens a code for the
    /// owner's server.
    case off
    /// A code for the owner's server is open, waiting for it.
    case connect
    /// The owner's server used its code and connects, or a move back
    /// connects to the server.
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

/// What one summary action is, by its published id. Two are opened by the
/// app itself and never sent: `learnMore` opens the action's `url`, and
/// `update` is the app's own update. Every other one is sent as `home.act`.
public enum ManagementHomeActionId: ManagementVocabulary, Hashable {
    case cancel
    case moveNow
    case tryAgain
    case learnMore
    case update
    case backUpNow
    case checkAgain
    case ownServer
    /// On a linked desktop: Fermix moves back from its server to this
    /// computer.
    case moveBack
    /// Fermix is restored on this computer from the copy of the server's
    /// backups it keeps, once the owner deleted the server that stopped
    /// answering, or stopped it for good.
    case restoreHere
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "cancel": .cancel,
        "move_now": .moveNow,
        "try_again": .tryAgain,
        "learn_more": .learnMore,
        "update": .update,
        "back_up_now": .backUpNow,
        "check_again": .checkAgain,
        "own_server": .ownServer,
        "move_back": .moveBack,
        "restore_here": .restoreHere
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }

    /// Whether the app opens this one itself rather than sending it.
    public var isOpenedHere: Bool {
        self == .learnMore || self == .update
    }
}

/// What the app collects before it sends an action.
public enum ManagementHomeActionNeed: ManagementVocabulary, Hashable {
    /// The recovery passphrase that is set, typed once: the engine checks it.
    case recoveryPassphrase
    /// A new recovery passphrase, where none is set: typed twice, and the
    /// two compared here.
    case newRecoveryPassphrase
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "recovery_passphrase": .recoveryPassphrase,
        "new_recovery_passphrase": .newRecoveryPassphrase
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where the screen stands, in the engine's word: what a surface following
/// a step reads.
public enum ManagementHomeOutcome: ManagementVocabulary, Hashable {
    /// Always On is at something that moves the screen on by itself: the
    /// server connecting, a move from its request on, a restore.
    case running
    /// It waits on the owner's server to use its code.
    case waiting
    /// The next step is the owner's.
    case done
    /// A problem.
    case failed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "running": .running,
        "waiting": .waiting,
        "done": .done,
        "failed": .failed
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// What went wrong, on a `problem` summary.
public enum ManagementHomeProblemKind: ManagementVocabulary, Hashable {
    case cannotReach
    case notSetUp
    case waitedTooLong
    case update
    case diskFull
    case backupOld
    case notReady
    /// A move back to this computer, or a restore here, ended or stopped
    /// part-way.
    case returnFailed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "cannot_reach": .cannotReach,
        "not_set_up": .notSetUp,
        "waited_too_long": .waitedTooLong,
        "update": .update,
        "disk_full": .diskFull,
        "backup_old": .backupOld,
        "not_ready": .notReady,
        "return_failed": .returnFailed
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

// MARK: - The summary

/// One action a summary offers, the same record wherever it sits: its id, the
/// label it is shown under, what the app collects first, the sentence the
/// owner accepts first, the page the app opens for it, and the key it is
/// sent with.
public struct ManagementHomeAction: Decodable, Equatable, Hashable, Sendable {
    public let id: ManagementHomeActionId
    public let label: String
    public let needs: [ManagementHomeActionNeed]
    /// What the owner accepts before Fermix moves or restores; nil
    /// otherwise.
    public let confirm: String?
    /// `learnMore`'s docs page; nil otherwise.
    public let url: URL?
    /// The digest `home.act` checks against the summary as it is when the
    /// press arrives.
    public let key: String

    /// Whether this build can offer it: an id it knows, and at most one need,
    /// one it knows how to collect. A button that could not be sent as the
    /// engine asks would do nothing.
    public var isOffered: Bool {
        id.isPublished && needs.count <= 1 && needs.allSatisfy(\.isPublished)
    }

    /// The one thing the app collects before sending it, if any.
    public var need: ManagementHomeActionNeed? { needs.first }
}

/// One line of Details, finished by the engine.
public struct ManagementHomeSummaryLine: Decodable, Equatable, Hashable, Sendable {
    public let label: String
    public let value: String
}

/// The occurrence the app raises as a system notification. Its `id` stays
/// the same while the occurrence stands.
public struct ManagementHomeNotice: Decodable, Equatable, Sendable {
    public let id: String
    public let sentence: String
}

/// What the state draws, a field only where it has something (the schema's
/// `homeSummaryDetail`). The engine sends more (the server's facts, the
/// backups, when it last saw a problem): their words are in `lines`.
public struct ManagementHomeSummaryDetail: Decodable, Equatable, Sendable {
    /// Details, each line finished by the engine.
    public let lines: [ManagementHomeSummaryLine]?
    /// The sentence of the step in hand while a move back or a restore runs.
    public let progress: String?
    /// The other actions the screen offers.
    public let alternatives: [ManagementHomeAction]?
    /// `on`: the actions Details offers.
    public let actions: [ManagementHomeAction]?
    /// `ready` and `not_ready`: the last review's warnings and blocks.
    public let readiness: [ManagementReadinessItem]?
    /// `on`: what lives on the server, and that its host can read its disk.
    public let data: String?
    /// `problem`: what went wrong.
    public let kind: ManagementHomeProblemKind?
    /// `problem`: one more sentence, where the engine gives one.
    public let note: String?
}

/// `home.status.summary`, and the summary `home.act` answers with.
public struct ManagementHomeSummary: Decodable, Equatable, Sendable {
    /// The one digest of the summary, which moves with every change the app
    /// draws and never with the clock alone.
    public let key: String
    public let state: ManagementHomeSummaryState
    public let sentence: String
    /// The one main action, or none when all is well.
    public let action: ManagementHomeAction?
    public let detail: ManagementHomeSummaryDetail
    /// The occurrence to raise as a notification, or none.
    public let notice: ManagementHomeNotice?
    /// Whether the screen moves on by itself, waits, failed or waits for the
    /// owner.
    public let outcome: ManagementHomeOutcome

    /// The problem's kind, on a `problem` summary.
    public var problem: ManagementHomeProblemKind? {
        state == .problem ? detail.kind : nil
    }

    /// Whether the summary still offers this action under this key,
    /// wherever it sits.
    public func offers(_ action: ManagementHomeAction) -> Bool {
        let all = [self.action].compactMap { $0 } + (detail.alternatives ?? []) + (detail.actions ?? [])

        return all.contains { $0.id == action.id && $0.key == action.key }
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
