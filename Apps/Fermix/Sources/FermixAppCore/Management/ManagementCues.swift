import Foundation

/// The typed results of the `cues.*` methods (M60 app surface §3).
///
/// Every sentence on a cue row is the daemon's: the status line, the consent
/// line, a load verdict, a gap or a refusal. A state is published for logs
/// and support; the app draws the sentence and switches on the published
/// action ids, never on a state. No row carries cue text: a proposal's
/// outside text is on `cues.proposals.get`'s card alone, kept apart by
/// structure, and nothing in Settings draws it.

// MARK: - Vocabularies

/// Where the cue subsystem stands, as `cues.status` publishes it.
public enum ManagementCueState: ManagementVocabulary, Hashable {
    case unavailable
    case off
    case needsMemory
    case needsRestart
    case running
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "unavailable": .unavailable,
        "off": .off,
        "needs_memory": .needsMemory,
        "needs_restart": .needsRestart,
        "running": .running
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Whether the door that takes pushes and webhooks is listening.
public enum ManagementCueDoorState: ManagementVocabulary, Hashable {
    case listening
    case unavailable
    case notRunning
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "listening": .listening,
        "unavailable": .unavailable,
        "not_running": .notRunning
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// How a source takes its items.
public enum ManagementCueSourceKind: ManagementVocabulary, Hashable {
    case localPush
    case feed
    case stream
    case webhook
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "local_push": .localPush,
        "feed": .feed,
        "stream": .stream,
        "webhook": .webhook
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a source stands (`x-cue-vocabulary.source_states`). Published for
/// logs and support: the row draws `status_sentence`. The one thing the app
/// reads it for is the attention tint §4.9 gives a source that stopped
/// working, which moves no control.
public enum ManagementCueSourceState: ManagementVocabulary, Hashable {
    case off
    case needsSecret
    case notRunning
    case idle
    case polling
    case connected
    case reconnecting
    case authFailed
    case overBudget
    case stopped
    case unavailable
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "off": .off,
        "needs_secret": .needsSecret,
        "not_running": .notRunning,
        "idle": .idle,
        "polling": .polling,
        "connected": .connected,
        "reconnecting": .reconnecting,
        "auth_failed": .authFailed,
        "over_budget": .overBudget,
        "stopped": .stopped,
        "unavailable": .unavailable
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }

    /// Whether §4.9 draws this source's sentence in the attention style. A
    /// state this build does not know is drawn plain.
    public var drawsAttention: Bool {
        switch self {
        case .authFailed, .stopped, .unavailable: return true
        case .off, .needsSecret, .notRunning, .idle, .polling, .connected, .reconnecting, .overBudget,
             .unrecognized:
            return false
        }
    }
}

/// Which control a source row draws (`cueSourceAction`). Edit and remove are
/// the app's own controls and never arrive here; an id this build does not
/// know draws no control.
public enum ManagementCueSourceAction: ManagementVocabulary, Hashable {
    case enable
    case disable
    case setSecret
    case newToken
    case getURL
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "enable": .enable,
        "disable": .disable,
        "set_secret": .setSecret,
        "new_token": .newToken,
        "get_url": .getURL
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// One secret a source's kind declares. `key` and `secret` are what the
/// owner types; `token` and `path_secret` are Fermix's to make.
public enum ManagementCueSecretField: ManagementVocabulary, Hashable {
    case token
    case key
    case secret
    case pathSecret
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "token": .token,
        "key": .key,
        "secret": .secret,
        "path_secret": .pathSecret
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }

    /// Whether the owner types this value with `secret.set`. Fermix makes
    /// the other two, and the daemon refuses them on that method.
    public var isTyped: Bool {
        switch self {
        case .key, .secret: return true
        case .token, .pathSecret, .unrecognized: return false
        }
    }
}

/// Where a watcher stands (`x-cue-vocabulary.watcher_states`), for the
/// attention tint alone.
public enum ManagementCueWatcherState: ManagementVocabulary, Hashable {
    case on
    case paused
    case held
    case noModel
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "on": .on,
        "paused": .paused,
        "held": .held,
        "no_model": .noModel
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }

    /// Whether §4.9 draws this watcher's sentence in the attention style.
    public var drawsAttention: Bool {
        switch self {
        case .held, .noModel: return true
        case .on, .paused, .unrecognized: return false
        }
    }
}

/// Whether a watcher asks a model about each item, or passes everything.
public enum ManagementCueWatcherFilter: ManagementVocabulary, Hashable {
    case llm
    case none
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["llm": .llm, "none": .none]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// What a mandate lets its task do: ask the owner first, or act.
public enum ManagementCueMandateMode: ManagementVocabulary, Hashable {
    case approve
    case auto
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["approve": .approve, "auto": .auto]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Which control a mandate row draws (`cueMandateAction`).
public enum ManagementCueMandateAction: ManagementVocabulary, Hashable {
    case approve
    case enable
    case disable
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["approve": .approve, "enable": .enable, "disable": .disable]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Whether a mandate loaded, by `Cues.Mandates`' own check.
public enum ManagementCueMandateLoad: ManagementVocabulary, Hashable {
    case active
    case inactive
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["active": .active, "inactive": .inactive]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a mandate's approval stands. Null on the wire where memory is off.
public enum ManagementCueApprovalState: ManagementVocabulary, Hashable {
    case unapproved
    case approved
    case changed
    case disabled
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "unapproved": .unapproved,
        "approved": .approved,
        "changed": .changed,
        "disabled": .disabled
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a proposal stands.
public enum ManagementCueProposalState: ManagementVocabulary, Hashable {
    case waiting
    case confirmed
    case denied
    case expired
    case refused
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "waiting": .waiting,
        "confirmed": .confirmed,
        "denied": .denied,
        "expired": .expired,
        "refused": .refused
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a proposal was answered.
public enum ManagementCueDecidedFrom: ManagementVocabulary, Hashable {
    case telegram
    case signal
    case whatsapp
    case imessage
    case companion
    case mobile
    case management
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "telegram": .telegram,
        "signal": .signal,
        "whatsapp": .whatsapp,
        "imessage": .imessage,
        "companion": .companion,
        "mobile": .mobile,
        "management": .management
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// How a confirmed proposal's call ended.
public enum ManagementCueResultStatus: ManagementVocabulary, Hashable {
    case ok
    case error
    case unknown
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["ok": .ok, "error": .error, "unknown": .unknown]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// The owner's answer to a proposal, by the words `cues.proposals.decide`
/// takes.
public enum ManagementCueDecision: ManagementVocabulary, Hashable {
    case confirm
    case deny
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["confirm": .confirm, "deny": .deny]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Which proposals `cues.proposals.list` reads: the waiting ones, or the
/// last seven days.
public enum ManagementCueProposalFilter: ManagementVocabulary, Hashable {
    case waiting
    case recent
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["waiting": .waiting, "recent": .recent]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

// MARK: - Status

/// `cues.status`: the switches, the door, and how many of each thing there
/// are. Answers on every build; `available` false is a build that does not
/// admit cues, and Settings then draws no pane.
public struct ManagementCueStatus: Decodable, Equatable, Sendable {
    public struct Door: Decodable, Equatable, Sendable {
        public let state: ManagementCueDoorState
        public let port: Int
        public let reason: String?
        public let sentence: String
    }

    public struct Counts: Decodable, Equatable, Sendable {
        public let sources: Int
        public let sourcesAttention: Int
        public let watchers: Int
        public let watchersHeld: Int
        public let mandates: Int
        public let mandatesAttention: Int
        public let proposalsWaiting: Int

        private enum CodingKeys: String, CodingKey {
            case sources, watchers, mandates
            case sourcesAttention = "sources_attention"
            case watchersHeld = "watchers_held"
            case mandatesAttention = "mandates_attention"
            case proposalsWaiting = "proposals_waiting"
        }
    }

    public let available: Bool
    public let enabled: Bool
    public let running: Bool
    public let memoryEnabled: Bool
    public let mandatesEnabled: Bool
    public let state: ManagementCueState
    public let statusSentence: String
    public let door: Door
    public let counts: Counts

    private enum CodingKeys: String, CodingKey {
        case available, enabled, running, state, door, counts
        case memoryEnabled = "memory_enabled"
        case mandatesEnabled = "mandates_enabled"
        case statusSentence = "status_sentence"
    }
}

// MARK: - Sources

/// One secret a source's kind declares, and whether it is stored. Never a
/// value.
public struct ManagementCueSecretSlot: Decodable, Equatable, Sendable {
    public let field: ManagementCueSecretField
    public let label: String
    public let present: Bool
}

/// One cue source in the daemon's own words. Never a payload, an item's
/// text, a cursor, a secret's value or a webhook's address.
public struct ManagementCueSource: Decodable, Equatable, Sendable {
    public struct Counts: Decodable, Equatable, Sendable {
        public let windowS: Int
        public let received: Int
        public let routed: Int
        public let notRouted: Int
        public let openGaps: Int

        private enum CodingKeys: String, CodingKey {
            case received, routed
            case windowS = "window_s"
            case notRouted = "not_routed"
            case openGaps = "open_gaps"
        }
    }

    public let ref: String
    public let kind: ManagementCueSourceKind
    public let preset: String?
    /// The preset's or the kind's name.
    public let label: String
    public let enabled: Bool
    public let state: ManagementCueSourceState
    public let statusSentence: String
    public let primaryAction: ManagementCueSourceAction?
    public let actions: [ManagementCueSourceAction]
    /// A feed or stream URL's host.
    public let location: String?
    /// The configured feed or stream URL. Never a webhook's address.
    public let url: String?
    /// Items a UTC day; 0 is none.
    public let dailyBudget: Int
    public let secrets: [ManagementCueSecretSlot]
    /// The field `set_secret` or `new_token` points at.
    public let missingSecret: ManagementCueSecretField?
    /// A webhook's address is made.
    public let hasURL: Bool
    public let counts: Counts
    public let lastGoodAt: String?
    public let lastAcceptedAt: String?
    /// The enabled watchers that listen to it.
    public let listening: [String]

    private enum CodingKeys: String, CodingKey {
        case ref, kind, preset, label, enabled, state, actions, location, url, secrets, counts, listening
        case statusSentence = "status_sentence"
        case primaryAction = "primary_action"
        case dailyBudget = "daily_budget"
        case missingSecret = "missing_secret"
        case hasURL = "has_url"
        case lastGoodAt = "last_good_at"
        case lastAcceptedAt = "last_accepted_at"
    }
}

/// `cues.sources.list`.
public struct ManagementCueSourceList: Decodable, Equatable, Sendable {
    public struct Limits: Decodable, Equatable, Sendable {
        public let maxSources: Int

        private enum CodingKeys: String, CodingKey {
            case maxSources = "max_sources"
        }
    }

    public let sources: [ManagementCueSource]
    public let canAdd: Bool
    public let limits: Limits

    public init(sources: [ManagementCueSource], canAdd: Bool, limits: Limits) {
        self.sources = sources
        self.canAdd = canAdd
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey {
        case sources, limits
        case canAdd = "can_add"
    }
}

/// `cues.sources.get`: one row, its editable fields as settings rows, its
/// open gaps and its refused requests, each with the daemon's sentence.
public struct ManagementCueSourceDetail: Decodable, Equatable, Sendable {
    public struct Gap: Decodable, Equatable, Sendable {
        public let reason: String
        public let count: Int
        public let sentence: String
    }

    public struct Refused: Decodable, Equatable, Sendable {
        public let reason: String
        public let count: Int
        public let sentence: String
    }

    public let source: ManagementCueSource
    public let values: [ManagementSettingRow]
    public let gaps: [Gap]
    public let rejected: [Refused]
}

/// `cues.sources.form`: the add form for one choice of kind, preset and
/// verification method. The rows are the daemon's; the app writes no field
/// list per kind.
public struct ManagementCueSourceForm: Decodable, Equatable, Sendable {
    public struct Kind: Decodable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let sentence: String
    }

    public struct Preset: Decodable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let kind: String
    }

    public let kinds: [Kind]
    public let presets: [Preset]
    public let rows: [ManagementSettingRow]
    public let consentSentence: String
    public let notes: [String]

    private enum CodingKeys: String, CodingKey {
        case kinds, presets, rows, notes
        case consentSentence = "consent_sentence"
    }
}

/// `cues.sources.add`: the new row, and a new local push source's first
/// token, handed out once.
public struct ManagementCueSourceAdded: Decodable, Equatable, Sendable {
    public let source: ManagementCueSource
    public let token: String?
}

/// The answer of `cues.sources.update`, `.enable` and `.disable`.
public struct ManagementCueSourceAnswer: Decodable, Equatable, Sendable {
    public let source: ManagementCueSource
}

/// `cues.sources.remove`: any secret that could not be deleted, as
/// sentences, and the watchers that listened to it.
public struct ManagementCueSourceRemoved: Decodable, Equatable, Sendable {
    public let ref: String
    public let removed: Bool
    public let left: [String]
    public let watchers: [String]
}

/// `cues.sources.token.new`: a fresh token, handed out once.
public struct ManagementCueSourceToken: Decodable, Equatable, Sendable {
    public let ref: String
    public let token: String
}

/// `cues.sources.url.get`: a webhook's address, a secret handed out on
/// every ask and never kept.
public struct ManagementCueSourceAddress: Decodable, Equatable, Sendable {
    public let ref: String
    public let url: String
    public let path: String
}

// MARK: - Watchers

/// One watcher, read-only: watchers are made and changed in chat. Never an
/// item's text, a reason or a hint.
public struct ManagementCueWatcher: Decodable, Equatable, Sendable {
    public struct FilterModel: Decodable, Equatable, Sendable {
        public let provider: String?
        public let model: String
    }

    public struct Task: Decodable, Equatable, Sendable {
        public let jobId: String
        public let name: String?
        public let paused: Bool

        private enum CodingKeys: String, CodingKey {
            case name, paused
            case jobId = "job_id"
        }
    }

    public struct Counts: Decodable, Equatable, Sendable {
        public let waiting: Int
        public let passed: Int
        public let dropped: Int
        public let acted: Int
        public let failed: Int
    }

    public let id: String
    public let name: String
    public let enabled: Bool
    public let filter: ManagementCueWatcherFilter
    /// Null where the watcher uses the default filter model.
    public let filterModel: FilterModel?
    public let state: ManagementCueWatcherState
    public let statusSentence: String
    public let sources: [String]
    public let task: Task
    public let taskNotes: Bool
    /// 0 is none.
    public let dailyCap: Int
    /// 0 is none.
    public let filterBudget: Int
    public let counts: Counts
    public let instructionCount: Int
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, filter, state, sources, task, counts
        case filterModel = "filter_model"
        case statusSentence = "status_sentence"
        case taskNotes = "task_notes"
        case dailyCap = "daily_cap"
        case filterBudget = "filter_budget"
        case instructionCount = "instruction_count"
        case createdAt = "created_at"
    }
}

/// `cues.watchers.list`.
public struct ManagementCueWatcherList: Decodable, Equatable, Sendable {
    public let watchers: [ManagementCueWatcher]
    public let windowS: Int
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case watchers, truncated
        case windowS = "window_s"
    }
}

/// `cues.watchers.get`: the row plus the owner's own words, its purpose and
/// its instructions, and its examples counted, never shown.
public struct ManagementCueWatcherDetail: Decodable, Equatable, Sendable {
    public struct Instruction: Decodable, Equatable, Sendable {
        public let number: Int
        public let text: String
        public let addedAt: String?

        private enum CodingKeys: String, CodingKey {
            case number, text
            case addedAt = "added_at"
        }
    }

    public struct Examples: Decodable, Equatable, Sendable {
        public let pass: Int
        public let drop: Int
    }

    public let row: ManagementCueWatcher
    public let purpose: String?
    public let instructions: [Instruction]
    public let examples: Examples

    private enum CodingKeys: String, CodingKey {
        case purpose, instructions, examples
    }

    /// The detail is the row's own object with three more fields, so the
    /// row is read from the same object.
    public init(from decoder: any Decoder) throws {
        row = try ManagementCueWatcher(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        instructions = try container.decode([Instruction].self, forKey: .instructions)
        examples = try container.decode(Examples.self, forKey: .examples)
    }
}

/// `cues.watchers.get`'s envelope.
public struct ManagementCueWatcherAnswer: Decodable, Equatable, Sendable {
    public let watcher: ManagementCueWatcherDetail
}

// MARK: - Mandates

/// A pinned argument's value: text, a number, or true or false.
public enum ManagementCuePinValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Probed in JSON's order of specificity. These are type tests, not
        // swallowed failures: a value matching none of them throws below.
        if let value = try? container.decode(Bool.self) {
            self = .flag(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "a pinned argument is text, a number, or true or false"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        }
    }
}

/// One argument a mandate fixes, whatever the task asks for.
public struct ManagementCuePin: Codable, Equatable, Sendable {
    public let key: String
    public let value: ManagementCuePinValue

    public init(key: String, value: ManagementCuePinValue) {
        precondition(!key.isEmpty, "a pinned argument names its key")
        self.key = key
        self.value = value
    }
}

/// One mandate. Durations are whole seconds; paths are the owner's own
/// configuration, published as written.
public struct ManagementCueMandate: Decodable, Equatable, Sendable {
    public struct Job: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String?
    }

    public struct Validator: Decodable, Equatable, Sendable {
        public let path: String
        public let interpreter: String?
        /// The environment variables it is given, by name.
        public let env: [String]
    }

    public struct Load: Decodable, Equatable, Sendable {
        public let state: ManagementCueMandateLoad
        public let sentence: String?
    }

    public struct Approval: Decodable, Equatable, Sendable {
        /// Nil where memory is off and the approval cannot be read.
        public let state: ManagementCueApprovalState?
        public let approvedAt: String?
        public let approvedFrom: String?
        public let disabledAt: String?
        public let disabledReason: String?
        public let detail: String?

        private enum CodingKeys: String, CodingKey {
            case state, detail
            case approvedAt = "approved_at"
            case approvedFrom = "approved_from"
            case disabledAt = "disabled_at"
            case disabledReason = "disabled_reason"
        }
    }

    public struct Counts: Decodable, Equatable, Sendable {
        public let windowS: Int
        public let allowed: Int
        public let proposed: Int
        public let refused: Int

        private enum CodingKeys: String, CodingKey {
            case allowed, proposed, refused
            case windowS = "window_s"
        }
    }

    public let name: String
    public let enabled: Bool
    public let job: Job
    public let mode: ManagementCueMandateMode
    public let approveWithinS: Int
    /// 0 is none.
    public let maxCueAgeS: Int
    public let tools: [String]
    public let readTools: [String]
    public let validator: Validator?
    public let idempotencyArg: String?
    public let unpinned: [String]
    public let pinArgs: [ManagementCuePin]
    public let load: Load
    public let approval: Approval
    public let counts: Counts
    /// What this mode lets the task do.
    public let consentSentence: String
    public let statusSentence: String
    public let primaryAction: ManagementCueMandateAction?
    public let actions: [ManagementCueMandateAction]

    private enum CodingKeys: String, CodingKey {
        case name, enabled, job, mode, tools, validator, unpinned, load, approval, counts, actions
        case approveWithinS = "approve_within_s"
        case maxCueAgeS = "max_cue_age_s"
        case readTools = "read_tools"
        case idempotencyArg = "idempotency_arg"
        case pinArgs = "pin_args"
        case consentSentence = "consent_sentence"
        case statusSentence = "status_sentence"
        case primaryAction = "primary_action"
    }
}

/// `cues.mandates.list`.
public struct ManagementCueMandateList: Decodable, Equatable, Sendable {
    public struct Limits: Decodable, Equatable, Sendable {
        public let maxMandates: Int

        private enum CodingKeys: String, CodingKey {
            case maxMandates = "max_mandates"
        }
    }

    public let mandates: [ManagementCueMandate]
    public let canAdd: Bool
    public let limits: Limits

    public init(mandates: [ManagementCueMandate], canAdd: Bool, limits: Limits) {
        self.mandates = mandates
        self.canAdd = canAdd
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey {
        case mandates, limits
        case canAdd = "can_add"
    }
}

/// `cues.mandates.choices`: the jobs that run on cues and the installed,
/// enabled `http` plugin tools a mandate may name.
public struct ManagementCueMandateChoices: Decodable, Equatable, Sendable {
    public struct Job: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let watcher: String?
        public let mandate: String?
    }

    public struct Tool: Decodable, Equatable, Sendable {
        public let name: String
        public let plugin: String
        public let title: String?
        public let readOnly: Bool

        private enum CodingKeys: String, CodingKey {
            case name, plugin, title
            case readOnly = "read_only"
        }
    }

    public let jobs: [Job]
    public let tools: [Tool]
}

/// The answer of every mandate write but remove.
public struct ManagementCueMandateAnswer: Decodable, Equatable, Sendable {
    public let mandate: ManagementCueMandate
}

/// `cues.mandates.remove`.
public struct ManagementCueMandateRemoved: Decodable, Equatable, Sendable {
    public let name: String
    public let removed: Bool
}

// MARK: - Proposals

/// Fermix's record of a proposal: ids, names from the owner's
/// configuration, times and Fermix's sentence. Never an argument or cue
/// text.
public struct ManagementCueProposal: Decodable, Equatable, Sendable {
    public struct Task: Decodable, Equatable, Sendable {
        public let jobId: String
        public let name: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case jobId = "job_id"
        }
    }

    public let proposalId: String
    public let state: ManagementCueProposalState
    public let mandate: String
    public let tool: String
    public let task: Task
    public let watcher: String?
    public let sourceRef: String?
    public let createdAt: String
    public let expiresAt: String
    public let decidedAt: String?
    public let decidedFrom: ManagementCueDecidedFrom?
    public let resultStatus: ManagementCueResultStatus?
    public let statusSentence: String

    private enum CodingKeys: String, CodingKey {
        case state, mandate, tool, task, watcher
        case proposalId = "proposal_id"
        case sourceRef = "source_ref"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case decidedAt = "decided_at"
        case decidedFrom = "decided_from"
        case resultStatus = "result_status"
        case statusSentence = "status_sentence"
    }
}

/// `cues.proposals.list`.
public struct ManagementCueProposalList: Decodable, Equatable, Sendable {
    public let proposals: [ManagementCueProposal]
    public let waiting: Int

    public init(proposals: [ManagementCueProposal], waiting: Int) {
        self.proposals = proposals
        self.waiting = waiting
    }
}

/// `cues.proposals.get`: the record, when the cue arrived and Fermix's
/// summary. The card's outside half, everything a model or a stranger wrote,
/// is not read here at all: Chat's card is the one place that reads and draws
/// it (M60 app surface §4.8), and Settings lists Fermix's record alone.
public struct ManagementCueProposalCard: Decodable, Equatable, Sendable {
    public let record: ManagementCueProposal
    public let receivedAt: String?
    /// Fermix's sentence, with no outside text in it.
    public let summary: String

    private enum CodingKeys: String, CodingKey {
        case summary
        case receivedAt = "received_at"
    }

    /// The card is the record's own object with more fields.
    public init(from decoder: any Decoder) throws {
        record = try ManagementCueProposal(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receivedAt = try container.decodeIfPresent(String.self, forKey: .receivedAt)
        summary = try container.decode(String.self, forKey: .summary)
    }
}

/// `cues.proposals.get`'s envelope.
public struct ManagementCueProposalCardAnswer: Decodable, Equatable, Sendable {
    public let proposal: ManagementCueProposalCard
}

/// `cues.proposals.decide`'s envelope: the record once the decision is
/// recorded.
public struct ManagementCueProposalAnswer: Decodable, Equatable, Sendable {
    public let proposal: ManagementCueProposal
}

// MARK: - Times

/// The cue rows' times, as the engine writes them: RFC 3339 UTC, to the
/// second or with a fraction of one. Nil for one in a shape this build
/// cannot read, which is then not drawn.
public enum ManagementCueTime {
    public static func date(_ value: String?) -> Date? {
        guard let value else { return nil }

        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
