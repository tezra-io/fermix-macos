import Combine
import Foundation

/// Which Setup Assistant screen the app is showing.
///
/// The eight screens of M34 §4: Welcome, Starting, Connect your AI, About you,
/// Applying, Ready, plus the two the journey can be replaced by, Boot failed and
/// Recovery. There is no hosted-Setup state and no channel step: a channel is
/// advisory in the readiness split, so it lives in the Channels pane.
public enum OnboardingStage: String, CaseIterable, Sendable {
    case welcome
    /// The masked boot: the four-row ladder of M34 §4.
    case starting
    /// The one required decision.
    case connectAI
    /// The owner's name, time zone, style, and what to call the assistant.
    case aboutYou
    /// The two-row ladder that saves those answers and restarts the daemon.
    case applying
    case ready
    /// Replaces Starting when activation ends in one of its named causes.
    case bootFailed
    case recovery

    /// The steps the progress dots count.
    ///
    /// Four, not eight: the two mechanical stages inherit the step they run
    /// inside (redlines §5.8), and the two failure screens carry no dots at all.
    public static let progressStepCount = 4

    /// Which dot is lit, or nil where the design draws none.
    public var progressIndex: Int? {
        switch self {
        case .welcome, .starting: return 0
        case .connectAI: return 1
        case .aboutYou, .applying: return 2
        case .ready: return 3
        case .bootFailed, .recovery: return nil
        }
    }

    /// Whether this stage runs on its own and takes no decision, which is what
    /// leaves the bottom bar without a continue action while it does.
    public var isMechanical: Bool { self == .starting || self == .applying }
}

/// How the daemon is doing, as the menu bar reads it.
public enum DaemonCondition: String, CaseIterable, Sendable {
    case running
    case starting
    case stopped
}

/// What one look at the daemon found.
///
/// The condition has exactly one writer, `AppCoordinator`, and two sources that
/// speak through this value: the read Home already makes on every refresh, and
/// the lifecycle transaction the user runs. Two sources and one shape is what
/// stops a launch against a daemon that is already up from sitting on
/// `starting` for the whole session, without giving the menu bar a poll of its
/// own to disagree with Home's.
public struct DaemonObservation: Equatable, Sendable {
    public let condition: DaemonCondition
    /// Whether the operator has something to look at. It reaches the menu bar
    /// as a shape cut into the glyph, never as a colour cue alone.
    public let needsAttention: Bool

    public init(condition: DaemonCondition, needsAttention: Bool) {
        self.condition = condition
        self.needsAttention = needsAttention
    }
}

/// Application-scoped presentation state.
///
/// The model owns no socket, no audio engine, and no window. It holds what the
/// window and the status item draw of the app itself. A call's facts are not
/// here: they change with every caption, and everything that observes this
/// model would redraw with them, so they have their own owner,
/// `VoiceCallModel`.
@MainActor
public final class AppModel: ObservableObject {
    @Published public var route: AppRoute = .home
    // Requested navigation can precede presentation while recovery is checked.
    // Keep it unpublished so List callbacks never publish a speculative route.
    var pendingNavigation: AppDestination?
    @Published public var onboardingStage: OnboardingStage = .welcome
    /// Starting, until something authoritative says otherwise. A launch has not
    /// asked the daemon anything yet, and the attention badge is a claim: it
    /// must mean "look at this", not "nobody has looked yet".
    ///
    /// Home's first refresh is what answers, through
    /// `AppCoordinator.daemonObserved`. Nothing else may write this: a second
    /// writer is how the glyph and the status line come to say different
    /// things about the same daemon.
    @Published public var daemon: DaemonCondition = .starting
    @Published public var petShown = false
    @Published public var needsAttention = false
    /// The lifecycle transaction this app started that is still running, or
    /// nil where none is.
    ///
    /// One writer, `AppCoordinator`, and one fact behind every surface that
    /// says a restart is under way: the toolbar's status sentence, Home's
    /// Status row and the status item's state line (owner report of
    /// 2026-09-20: the Restart sheet closed, the daemon went away for several
    /// seconds, and nothing on screen said why). It is the app's own fact and
    /// not the daemon's, which is the only reason the app may state it: the
    /// daemon is gone for most of a restart and publishes nothing about one.
    @Published public var transactionInFlight: LifecycleTransactionKind?
    /// Whether the Restart sheet is asking, in the one window that can host it.
    ///
    /// One owner for the whole app (M34 §5.10): Home's Attention row, the
    /// Settings banner, the Daemon menu and the status item all ask through
    /// `AppCoordinator.askForRestart`, so a restart is never taken without the
    /// sheet naming its reasons and the work it would interrupt.
    @Published public var restartSheetShown = false
    /// Why the last lifecycle transaction was refused, in one sentence, or nil
    /// where it was not.
    ///
    /// One writer, `AppCoordinator`, like the daemon condition beside it. It is
    /// what the Restart sheet reads: a refusal that only reached the log left
    /// the operator clicking a button that did nothing (owner report of
    /// 2026-09-04).
    @Published public var restartRefusal: String?
    /// The sheet of commands a surface asked to show, where one asked.
    ///
    /// One owner, like the Restart sheet: Home's Attention row, a Doctor
    /// remediation and the Help menu all ask through
    /// `AppCoordinator.showInstructions`, so the same lines are drawn the same
    /// way whichever door opened them (M34 §15.2).
    @Published public var instructionsShown: CoexistenceInstructions?

    public init() {}

    public var menuGlyph: MenuBarGlyphState {
        MenuBarGlyphState(daemon: daemon, hasAttention: needsAttention)
    }
}
