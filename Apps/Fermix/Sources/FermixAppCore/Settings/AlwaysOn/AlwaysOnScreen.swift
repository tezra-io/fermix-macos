import Foundation

/// What the Always On pane draws (Always On setup §8.3): the engine's
/// summary, as it is.
///
/// Every sentence, label, line and confirm is the engine's
/// (`home.status.summary`), and every press is one `home.act` the engine
/// runs. The app keeps three things of its own: how it asks for a secret
/// (the token field and the passphrase sheet), how it draws the choice of
/// size and place, and that the engine is restarting after this app's own
/// Move now.

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
    /// The sentence of the step in hand while a step's job runs.
    public let progress: String?
    /// The bar that claims no percentage shows: creating and moving.
    public let showsBar: Bool
    /// The engine's other sentences for the screen: how the provider bills,
    /// a problem's note.
    public let notes: [String]
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
    /// Every provider's token screen, where a token is asked for.
    public let providers: [ManagementHomeSummaryProvider]

    public init(_ summary: ManagementHomeSummary) {
        let detail = summary.detail
        state = summary.state
        sentence = summary.sentence
        progress = detail.progress
        showsBar = summary.state == .creating || summary.state == .moving
        notes = [detail.billing, detail.note].compactMap { $0 }
        readiness = detail.readiness ?? []
        action = summary.action.flatMap { $0.isOffered ? $0 : nil }
        alternatives = (detail.alternatives ?? []).filter(\.isOffered)
        lines = detail.lines ?? []
        data = detail.data
        detailActions = (detail.actions ?? []).filter(\.isOffered)
        providers = detail.providers ?? []
    }

    /// Whether Details has anything to hold.
    public var hasDetails: Bool { !lines.isEmpty || data != nil || !detailActions.isEmpty }

    /// Which provider's token the field takes: the only one listed, else the
    /// one the owner picked, else a pick from every one listed, in the
    /// engine's order. None where the summary lists no provider.
    public func tokenTarget(picked: String?) -> AlwaysOnTokenTarget? {
        if providers.count == 1, let only = providers.first { return .provider(only) }
        if let chosen = providers.first(where: { $0.id == picked }) { return .provider(chosen) }

        return providers.isEmpty ? nil : .pick(providers)
    }
}

/// The choice of size and place as its sheet draws it: the engine's sentence
/// for the recommendation, then each city's offers in the engine's order,
/// each its label and price as sent. A city with nothing in stock has no
/// rows, so it is not drawn.
public struct AlwaysOnChoice: Equatable, Sendable {
    public struct City: Equatable, Sendable {
        public let city: String
        public let offers: [ManagementProvisionOffer]
    }

    public let sentence: String
    public let cities: [City]
    /// The pick chosen until the owner picks another.
    public let recommended: ManagementProvisionPick?

    public init(_ options: ManagementProvisionOptions) {
        sentence = options.sentence
        cities = options.locations
            .map { location in City(city: location.city, offers: options.offers.filter { $0.location == location.id }) }
            .filter { !$0.offers.isEmpty }
        recommended = options.recommended
    }
}

/// Which provider's token a token field takes.
public enum AlwaysOnTokenTarget: Equatable, Sendable {
    /// More than one is listed and none is picked: the owner picks first.
    case pick([ManagementHomeSummaryProvider])
    case provider(ManagementHomeSummaryProvider)
}

/// A press waiting on the owner: what its action needs, or its confirm.
public enum AlwaysOnAsk: Equatable, Sendable, Identifiable {
    /// The token field, in place of the action.
    case token(ManagementHomeAction)
    /// The sheet of size and place, with the action's confirm.
    case choice(ManagementHomeAction)
    /// The passphrase sheet, with the action's confirm: typed twice where
    /// none is set, once where one is.
    case passphrase(ManagementHomeAction, twice: Bool)
    /// The confirm of an action that collects nothing.
    case confirm(ManagementHomeAction)

    /// What the action needs collected first, then its confirm; nil when it
    /// is sent at once.
    public static func asking(for action: ManagementHomeAction) -> AlwaysOnAsk? {
        switch action.need {
        case .token?: return .token(action)
        case .choice?: return .choice(action)
        case .newRecoveryPassphrase?: return .passphrase(action, twice: true)
        case .recoveryPassphrase?: return .passphrase(action, twice: false)
        case .unrecognized?, nil: return action.confirm.map { _ in .confirm(action) }
        }
    }

    public var action: ManagementHomeAction {
        switch self {
        case .token(let action), .choice(let action), .passphrase(let action, _), .confirm(let action): return action
        }
    }

    public var id: String { action.key }

    /// Whether this ask is drawn as a sheet.
    public var isSheet: Bool {
        switch self {
        case .choice, .passphrase: return true
        case .token, .confirm: return false
        }
    }

    /// Whether this ask is the token field, drawn in place of the action.
    public var isField: Bool {
        if case .token = self { return true }
        return false
    }
}
