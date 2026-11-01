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
    /// Nothing is set up. Set up asks for a token.
    case off
    /// A code for a server of the owner's own is open, or the cloud provider
    /// refused the token before anything was created.
    case connect
    /// The token works: Create server, with the choice of size and place.
    case choose
    /// A step's job runs, or the server starts, installs Fermix or connects.
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

/// What one summary action is, by its published id. Three are opened by the
/// app itself and never sent: `learnMore` and `openConsole` open the action's
/// `url`, and `update` is the app's own update. Every other one is sent as
/// `home.act`.
public enum ManagementHomeActionId: ManagementVocabulary, Hashable {
    case createServer
    case cancel
    case moveNow
    case tryAgain
    case learnMore
    case turnOn
    case restartServer
    case startAgain
    case createIn
    case openConsole
    case pasteToken
    case update
    case backUpNow
    case replaceServer
    case checkAgain
    case ownServer
    case deleteServer
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "create_server": .createServer,
        "cancel": .cancel,
        "move_now": .moveNow,
        "try_again": .tryAgain,
        "learn_more": .learnMore,
        "turn_on": .turnOn,
        "restart_server": .restartServer,
        "start_again": .startAgain,
        "create_in": .createIn,
        "open_console": .openConsole,
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

    /// Whether the app opens this one itself rather than sending it.
    public var isOpenedHere: Bool {
        self == .learnMore || self == .openConsole || self == .update
    }
}

/// What the app collects before it sends an action.
public enum ManagementHomeActionNeed: ManagementVocabulary, Hashable {
    /// The provider's token, from the token screen in `detail.providers`.
    case token
    /// The recovery passphrase that is set, typed once: the engine checks it.
    case recoveryPassphrase
    /// A new recovery passphrase, where none is set: typed twice, and the
    /// two compared here.
    case newRecoveryPassphrase
    /// The size and place, from `home.provision.options`, whose
    /// recommendation is the default.
    case choice
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "token": .token,
        "recovery_passphrase": .recoveryPassphrase,
        "new_recovery_passphrase": .newRecoveryPassphrase,
        "choice": .choice
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
    /// Deleting a server stopped.
    case deleteFailed
    /// Turning the server on, or restarting it, stopped.
    case powerFailed
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
        "delete_failed": .deleteFailed,
        "power_failed": .powerFailed
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
    /// What the owner accepts before Fermix spends money, deletes, restarts a
    /// server or moves; nil otherwise.
    public let confirm: String?
    /// `learnMore`'s docs page and `openConsole`'s console; nil otherwise.
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

/// One provider's token screen: its id (what a token is given for), its
/// name, the token field's label, the screen's sentence, its "How to get one"
/// steps, its console and the docs page at its part.
public struct ManagementHomeSummaryProvider: Decodable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let tokenLabel: String
    public let sentence: String
    public let steps: [String]
    public let consoleUrl: URL
    public let docsUrl: URL

    private enum CodingKeys: String, CodingKey {
        case id, name, sentence, steps
        case tokenLabel = "token_label"
        case consoleUrl = "console_url"
        case docsUrl = "docs_url"
    }
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
    /// Every provider's token screen, wherever a token is asked for.
    public let providers: [ManagementHomeSummaryProvider]?
    /// Details, each line finished by the engine.
    public let lines: [ManagementHomeSummaryLine]?
    /// The sentence of the step in hand while a step's job runs.
    public let progress: String?
    /// The other actions the screen offers.
    public let alternatives: [ManagementHomeAction]?
    /// `on`: the actions Details offers.
    public let actions: [ManagementHomeAction]?
    /// `choose`: how the provider bills.
    public let billing: String?
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
