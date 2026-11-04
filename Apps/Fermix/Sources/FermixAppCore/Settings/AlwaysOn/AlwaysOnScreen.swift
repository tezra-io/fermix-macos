import Foundation

/// What the Always On pane draws (Always On setup §8.3): the engine's
/// summary, as it is.
///
/// Every sentence, label, line and confirm is the engine's
/// (`home.status.summary`), and every press is one `home.act` the engine
/// runs. The app keeps two things of its own: how it asks for the recovery
/// passphrase (its sheet), and that the engine is restarting after this
/// app's own Move now.

/// What the pane shows as a whole.
public enum AlwaysOnPage: Equatable, Sendable {
    /// The first read is out.
    case reading
    /// `home.status` was refused, or not answered, before any summary was:
    /// the daemon's sentence, or the app's for a daemon that is not there.
    case unreadable(String)
    /// The engine answers no summary: the existing "update Fermix" answer.
    case needsUpdate
    /// The engine restarts to carry out this app's own Move now, until it
    /// answers again with a summary that moved.
    case restarting
    case screen(AlwaysOnScreen)

    public var screen: AlwaysOnScreen? {
        if case .screen(let screen) = self { return screen }
        return nil
    }
}

extension AlwaysOnPage {
    /// The page for what the engine last answered.
    ///
    /// - Parameters:
    ///   - summary: the last summary a read or an act answered, kept while a
    ///     later read fails, so the screen does not blank between reads.
    ///   - olderEngine: the last read answered a `home.status` with no
    ///     summary.
    ///   - failure: the last read's refusal, while it is the latest word.
    ///   - restarting: this app's own Move now is waiting for the engine's
    ///     restart.
    public static func page(
        summary: ManagementHomeSummary?,
        olderEngine: Bool,
        failure: SettingsReadState<ManagementHomeStatus>?,
        restarting: Bool
    ) -> AlwaysOnPage {
        if restarting { return .restarting }
        if olderEngine { return .needsUpdate }
        if let summary { return .screen(AlwaysOnScreen(summary)) }

        switch failure {
        case .requiresNewerEngine?: return .needsUpdate
        case .unavailable(let sentence)?: return .unreadable(sentence)
        default: return .reading
        }
    }
}

/// One screen: the summary's sentence, the step in hand, the engine's other
/// sentences, its one action and the others, and what Details holds.
public struct AlwaysOnScreen: Equatable, Sendable {
    public let state: ManagementHomeSummaryState
    public let sentence: String
    /// The sentence of the step in hand while a move back or a restore runs.
    public let progress: String?
    /// The bar that claims no percentage shows while the engine says the
    /// screen moves on by itself (`outcome` `running`).
    public let showsBar: Bool
    /// A problem's one more sentence, where the engine gives one.
    public let note: String?
    /// The last review's warnings and blocks.
    public let readiness: [ManagementReadinessItem]
    /// The one main action, or none when all is well.
    public let action: ManagementHomeAction?
    /// The other actions, drawn as links.
    public let alternatives: [ManagementHomeAction]
    /// Details: the engine's lines, what lives on the server, and on `on`
    /// its actions.
    public let lines: [ManagementHomeSummaryLine]
    public let data: String?
    public let detailActions: [ManagementHomeAction]

    public init(_ summary: ManagementHomeSummary) {
        let detail = summary.detail
        state = summary.state
        sentence = summary.sentence
        progress = detail.progress
        showsBar = summary.outcome == .running
        note = detail.note
        readiness = detail.readiness ?? []
        action = summary.action.flatMap { $0.isOffered ? $0 : nil }
        alternatives = (detail.alternatives ?? []).filter(\.isOffered)
        lines = detail.lines ?? []
        data = detail.data
        detailActions = (detail.actions ?? []).filter(\.isOffered)
    }

    /// Whether Details has anything to hold.
    public var hasDetails: Bool { !lines.isEmpty || data != nil || !detailActions.isEmpty }
}

/// A press waiting on the owner: what its action needs, or its confirm.
public enum AlwaysOnAsk: Equatable, Sendable, Identifiable {
    /// The passphrase sheet, with the action's confirm: typed twice where
    /// none is set, once where one is.
    case passphrase(ManagementHomeAction, twice: Bool)
    /// The confirm of an action that collects nothing.
    case confirm(ManagementHomeAction)

    /// What the action needs collected first, then its confirm; nil when it
    /// is sent at once.
    public static func asking(for action: ManagementHomeAction) -> AlwaysOnAsk? {
        switch action.need {
        case .newRecoveryPassphrase?: return .passphrase(action, twice: true)
        case .recoveryPassphrase?: return .passphrase(action, twice: false)
        case .unrecognized?, nil: return action.confirm.map { _ in .confirm(action) }
        }
    }

    public var action: ManagementHomeAction {
        switch self {
        case .passphrase(let action, _), .confirm(let action): return action
        }
    }

    public var id: String { action.key }

    /// Whether this ask is drawn as a sheet.
    public var isSheet: Bool {
        if case .passphrase = self { return true }
        return false
    }
}
