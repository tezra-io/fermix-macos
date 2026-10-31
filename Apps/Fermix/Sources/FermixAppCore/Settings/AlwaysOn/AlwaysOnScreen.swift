import Foundation

/// What the Always On pane draws (M75 lean v1 §7), worked out from what the
/// engine said and the few things the app keeps itself.
///
/// Every sentence and action label is the engine's (`home.status.summary`).
/// The app keeps only the steps nothing in the engine records: Set up, which
/// opens the token screen; Paste a new token, which opens the field in place;
/// and the restart after its own Move now, while the engine is away.

/// The steps the app keeps itself.
public struct AlwaysOnLocal: Equatable, Sendable {
    /// Set up was pressed on `off`: the token screen shows until a token or a
    /// code exists.
    public var settingUp = false
    /// Paste a new token was pressed on a problem that offers it.
    public var pastingToken = false
    /// The engine's sentence for the move this app started, while the engine
    /// restarts to carry it out and until it answers again.
    public var moveStarted: String?

    public init(settingUp: Bool = false, pastingToken: Bool = false, moveStarted: String? = nil) {
        self.settingUp = settingUp
        self.pastingToken = pastingToken
        self.moveStarted = moveStarted
    }
}

/// The screen a summary maps to.
public enum AlwaysOnScreenKind: Equatable, Sendable {
    case off
    /// The token screen: the paste field, "How to get one" and the own-server
    /// link. Opened by Set up, and the engine's `connect`.
    case token
    case choose
    case creating
    case ready
    case moving
    case on
    case undone
    case retired
    /// The server's own page, before its move.
    case candidate
    /// The server's own page, after its move.
    case primary
    case problem(ManagementHomeProblemKind)
    /// A state this build does not know: its sentence, and nothing more.
    case unknown
}

/// One screen: one sentence, at most one main action, and what Details and
/// the screen's links hold.
public struct AlwaysOnScreen: Equatable, Sendable {
    public let kind: AlwaysOnScreenKind
    public let sentence: String
    /// The one main action, or none when all is well.
    public let action: ManagementHomeAction?
    /// The token screen's "How to get one" steps.
    public let steps: [String]
    /// The other actions the screen offers: Details on a problem and on `on`,
    /// the own-server link on the token screen.
    public let alternatives: [ManagementHomeAction]
    /// The paste field shows (the token screen, or Paste a new token).
    public let tokenField: Bool
    /// The bar that claims no percentage shows (creating and moving).
    public let showsProgress: Bool
    /// The recovery passphrase fields sit below while none is set.
    public let asksPassphrase: Bool
    /// What Details holds.
    public let detail: ManagementHomeSummaryDetail
}

/// What the pane shows as a whole.
public enum AlwaysOnPage: Equatable, Sendable {
    /// The first read is out.
    case reading
    /// `home.status` was refused, or not answered: the daemon's sentence, or
    /// the app's for a daemon that is not there.
    case unreadable(String)
    /// The engine answers no summary, or does not serve what the screen
    /// needs: the existing "update Fermix" answer.
    case needsUpdate
    case screen(AlwaysOnScreen)

    public var screen: AlwaysOnScreen? {
        if case .screen(let screen) = self { return screen }
        return nil
    }
}

extension AlwaysOnPage {
    /// The page for what the reads answered.
    ///
    /// - Parameters:
    ///   - status: the last `home.status` the daemon answered, kept while a
    ///     later read fails, so the screen does not blank between reads.
    ///   - failure: the last read's refusal, while it is the latest word.
    ///   - local: the steps the app keeps itself.
    ///   - served: the methods the daemon's `hello` lists; the Hetzner path
    ///     is drawn only where every `home.provision.*` method is there.
    public static func page(
        status: ManagementHomeStatus?,
        failure: SettingsReadState<ManagementHomeStatus>?,
        local: AlwaysOnLocal,
        served: Set<ManagementMethod>
    ) -> AlwaysOnPage {
        if let started = local.moveStarted, awaitsOwnMove(status, failed: failure != nil) {
            return .screen(.moving(started))
        }
        guard let status else { return unread(failure) }
        guard let summary = status.summary else { return .needsUpdate }

        let screen = AlwaysOnScreen.screen(summary, home: status, local: local)
        let hetzner = served.isSuperset(of: ManagementMethod.homeProvisionMethods)
        return !hetzner && screen.needsHetzner ? .needsUpdate : .screen(screen)
    }

    /// Nothing answered yet: still reading, an engine too old for the home's
    /// methods, or the daemon's sentence for why not.
    private static func unread(_ failure: SettingsReadState<ManagementHomeStatus>?) -> AlwaysOnPage {
        switch failure {
        case .requiresNewerEngine?: return .needsUpdate
        case .unavailable(let sentence)?: return .unreadable(sentence)
        default: return .reading
        }
    }

    /// Whether the engine has not yet answered for the move this app
    /// started: it is away while it restarts, or still says what it said
    /// before the move began.
    private static func awaitsOwnMove(_ status: ManagementHomeStatus?, failed: Bool) -> Bool {
        failed || !saysWhereTheMoveStands(status?.summary?.state)
    }

    /// Whether a summary in this state says where a move stands: under way,
    /// done, undone, or gone wrong.
    public static func saysWhereTheMoveStands(_ state: ManagementHomeSummaryState?) -> Bool {
        switch state {
        case .moving?, .on?, .undone?, .retired?, .problem?: return true
        default: return false
        }
    }
}

extension AlwaysOnScreen {
    /// The actions that call the Hetzner provisioner.
    static let hetznerActions: Set<ManagementHomeActionId> = [
        .createServer, .cancel, .turnOn, .restartServer, .startAgain, .createIn, .pasteToken,
        .deleteServer, .replaceServer
    ]

    /// The review's warnings and blocks the summary carries, which a screen
    /// lists only when there are some.
    public var warnings: [ManagementReadinessItem] {
        (detail.readiness ?? []).filter { $0.status != .ok }
    }

    /// Whether this screen calls the Hetzner provisioner.
    var needsHetzner: Bool {
        if kind == .choose { return true }
        if let action, Self.hetznerActions.contains(action.id) { return true }
        return false
    }

    /// The screen for one summary.
    static func screen(_ summary: ManagementHomeSummary, home: ManagementHomeStatus, local: AlwaysOnLocal) -> AlwaysOnScreen {
        switch summary.state {
        case .off where local.settingUp:
            return token(summary.detail.connect, fallback: summary)
        case .connect:
            return AlwaysOnScreen(
                kind: .token, sentence: summary.sentence, action: nil, steps: summary.detail.steps ?? [],
                alternatives: offered(summary.detail.alternatives), tokenField: true, showsProgress: false,
                asksPassphrase: false, detail: summary.detail
            )
        case .problem:
            return problem(summary, local: local)
        default:
            return plain(summary, kind: kind(of: summary.state), home: home)
        }
    }

    /// The app's own Set up step: `off`'s token words.
    private static func token(_ connect: ManagementHomeSummaryConnect?, fallback summary: ManagementHomeSummary) -> AlwaysOnScreen {
        AlwaysOnScreen(
            kind: .token,
            sentence: connect?.sentence ?? summary.sentence,
            action: nil,
            steps: connect?.steps ?? [],
            alternatives: offered(connect?.alternatives),
            tokenField: true,
            showsProgress: false,
            asksPassphrase: false,
            detail: summary.detail
        )
    }

    private static func problem(_ summary: ManagementHomeSummary, local: AlwaysOnLocal) -> AlwaysOnScreen {
        let kind = summary.detail.kind ?? .unrecognized("problem")
        let pasting = local.pastingToken && summary.action?.id == .pasteToken

        return AlwaysOnScreen(
            kind: .problem(kind),
            sentence: summary.sentence,
            action: pasting ? nil : offered(summary.action),
            steps: [],
            alternatives: offered(summary.detail.alternatives),
            tokenField: pasting,
            showsProgress: false,
            asksPassphrase: false,
            detail: summary.detail
        )
    }

    private static func plain(_ summary: ManagementHomeSummary, kind: AlwaysOnScreenKind, home: ManagementHomeStatus) -> AlwaysOnScreen {
        AlwaysOnScreen(
            kind: kind,
            sentence: summary.sentence,
            action: offered(summary.action),
            steps: [],
            alternatives: offered(summary.detail.actions),
            tokenField: false,
            showsProgress: kind == .creating || kind == .moving,
            asksPassphrase: kind == .creating && home.role == .primary && !home.snapshots.recipientSet,
            detail: summary.detail
        )
    }

    /// The moving screen while the engine restarts for this app's own move.
    static func moving(_ sentence: String) -> AlwaysOnScreen {
        AlwaysOnScreen(
            kind: .moving, sentence: sentence, action: nil, steps: [], alternatives: [], tokenField: false,
            showsProgress: true, asksPassphrase: false, detail: Self.noDetail
        )
    }

    private static func kind(of state: ManagementHomeSummaryState) -> AlwaysOnScreenKind {
        switch state {
        case .off: return .off
        case .connect: return .token
        case .choose: return .choose
        case .creating: return .creating
        case .ready: return .ready
        case .moving: return .moving
        case .on: return .on
        case .undone: return .undone
        case .retired: return .retired
        case .candidate: return .candidate
        case .primary: return .primary
        case .problem: return .problem(.unrecognized("problem"))
        case .unrecognized: return .unknown
        }
    }

    /// An action this build knows, or none: a button whose id it does not
    /// know would do nothing.
    private static func offered(_ action: ManagementHomeAction?) -> ManagementHomeAction? {
        guard let action, action.id.isPublished else { return nil }

        return action
    }

    /// The alternatives this build knows. "Use my own Linux server" is left
    /// out while a server Fermix created stands (Details then offers to
    /// delete it): only one code is open at a time, and a new one would strand
    /// that server (L15).
    private static func offered(_ actions: [ManagementHomeAction]?) -> [ManagementHomeAction] {
        let known = (actions ?? []).filter(\.id.isPublished)
        guard known.contains(where: { $0.id == .deleteServer }) else { return known }

        return known.filter { $0.id != .ownServer }
    }

    private static let noDetail: ManagementHomeSummaryDetail = {
        guard let detail = try? JSONDecoder().decode(ManagementHomeSummaryDetail.self, from: Data("{}".utf8)) else {
            preconditionFailure("an empty detail decodes")
        }

        return detail
    }()
}
