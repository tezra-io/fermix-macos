import Foundation

/// An update the window offers, as the updater read it off the feed.
public struct UpdatePromptOffer: Equatable, Sendable {
    /// The version a person reads, `0.7.0`.
    public let version: String
    public let isCritical: Bool
    /// A release that installs from the website rather than in place.
    public let isInformationOnly: Bool
    /// Where an information-only release is described.
    public let infoURL: URL?
    public let stage: UpdateUserStage

    public init(version: String, isCritical: Bool, isInformationOnly: Bool, infoURL: URL?, stage: UpdateUserStage) {
        self.version = version
        self.isCritical = isCritical
        self.isInformationOnly = isInformationOnly
        self.infoURL = infoURL
        self.stage = stage
    }
}

/// Why a check the person asked for offered nothing.
public enum UpdateNotFoundReason: Equatable, Sendable {
    case onLatest
    case newerThanLatest
    case systemTooOld
    case systemTooNew
    case hardwareUnsupported
    case unknown
}

/// Why an update stopped, in the app's own vocabulary. The updater's English
/// never reaches the window: each case is one sentence this product wrote.
public enum UpdateFailure: Equatable, Sendable {
    case feedUnreachable
    case downloadFailed
    case notVerified
    case installFailed
    /// A restart, another update or the launch's own check is changing
    /// Fermix's background service, so this one waits its turn.
    case busy
    /// The last update did not finish, and starting another over its record
    /// would lose what stopped it.
    case recoveryPending
    /// A daemon this account did not register is answering, and stopping it
    /// would be a takeover.
    case unownedDaemon
    /// This copy cannot transact the release the feed offers.
    case notInstallable
    case other

    /// The coordinator's refusal, which the updater hands back as the reason
    /// a check the person asked for stopped (M34 §6). Each says what will
    /// change it, which a generic try-again does not: retrying never clears a
    /// record Recovery has not looked at.
    public init(_ refusal: UpdateRefusal) {
        switch refusal {
        case .busy: self = .busy
        case .recoveryPending: self = .recoveryPending
        case .unownedDaemon: self = .unownedDaemon
        case .notConfigured, .bundledEngineUnknown, .priorReleaseUnknown, .feed, .notAnUpgrade:
            self = .notInstallable
        }
    }
}

/// Every moment of an update the window draws.
public enum UpdatePromptPhase: Equatable, Sendable {
    /// The first launch's question: may Fermix check on its own.
    case permission
    case checking
    case offered(UpdatePromptOffer)
    case downloading(received: UInt64, expected: UInt64?)
    case preparing(fraction: Double)
    /// Downloaded and verified; the next step replaces the app.
    case ready
    case installing
    case notFound(UpdateNotFoundReason)
    /// Installed without a relaunch, which only a relaunch the system refused
    /// leaves.
    case installed
    case failed(UpdateFailure)
}

/// Everything a person can press in the update window.
public enum UpdatePromptAction: Equatable, Sendable {
    case allowChecks
    case declineChecks
    case install
    case later
    case skip
    case learnMore
    case cancel
    /// Install and relaunch, once the update is ready.
    case relaunch
    case done
}

/// Where the update window goes on screen, and what the app can say about
/// being in front. The composition implements it over the window coordinator,
/// so the prompt's rules are provable without a window server.
@MainActor
public protocol UpdateWindowPresenting: AnyObject {
    var isAppActive: Bool { get }
    func showUpdateWindow()
    func closeUpdateWindow()
    /// Bounces the Dock icon once, for a moment that waits on the person while
    /// they may be in another app.
    func requestAttention()
    func open(_ url: URL)
}

/// The update window's state, between the updater and the person.
///
/// The updater says what is happening and leaves one answer pending; the
/// window draws the phase and sends back what was pressed. Nothing here
/// decides whether an update may happen, which is `UpdateCoordinator`'s, and
/// nothing here names an updater type, so `FermixAppCore` keeps importing no
/// updater at all (M34 §6).
///
/// Each pending answer is sent exactly once. The updater holds its session
/// open until it hears back, and an answer sent twice is one the updater was
/// not waiting for.
@MainActor
public final class UpdatePrompt: ObservableObject {
    /// What the window shows, or nil when there is no window.
    @Published public private(set) var phase: UpdatePromptPhase?

    /// The version this copy of Fermix is, which an offer is read against.
    public let installedVersion: String
    public weak var presenter: (any UpdateWindowPresenting)?

    private enum Pending {
        case permission((Bool) -> Void)
        case choice((UpdateUserChoice) -> Void)
        case cancellation(() -> Void)
        case relaunch(() -> Void)
        case acknowledgement(() -> Void)
    }

    private var pending: Pending?
    /// Whether the window is on screen. A new phase on a shown window swaps
    /// its content in place.
    private var windowShown = false
    /// A phase that arrived while Fermix was behind other apps, waiting for
    /// the app to come forward.
    private var waitingForActivation = false
    /// A relaunch the system refused: kept so asking for the update again can
    /// offer it once more, with no window in the meantime.
    private var parkedRelaunch: (() -> Void)?

    public init(installedVersion: String) {
        precondition(!installedVersion.isEmpty, "the installed app has a version")

        self.installedVersion = installedVersion
    }

    // MARK: - What the updater says

    /// The first launch's question. It comes forward at once, as a check the
    /// person asked for does: until it is answered nothing checks at all.
    public func askPermission(reply: @escaping (Bool) -> Void) {
        show(.permission, waiting: .permission(reply), urgent: true)
    }

    public func showChecking(cancel: @escaping () -> Void) {
        show(.checking, waiting: .cancellation(cancel), urgent: true)
    }

    /// An update was found. One the person asked for comes forward at once;
    /// one a scheduled check found waits until Fermix is in front, because the
    /// menu bar and Home already say it is there.
    public func offer(_ offer: UpdatePromptOffer, userInitiated: Bool, reply: @escaping (UpdateUserChoice) -> Void) {
        show(.offered(offer), waiting: .choice(reply), urgent: userInitiated)
    }

    public func showDownloading(cancel: @escaping () -> Void) {
        show(.downloading(received: 0, expected: nil), waiting: .cancellation(cancel), urgent: false)
    }

    public func downloadExpected(_ length: UInt64) {
        guard case .downloading(let received, _) = phase else { return }

        phase = .downloading(received: received, expected: length > 0 ? length : nil)
    }

    public func downloadReceived(_ length: UInt64) {
        guard case .downloading(let received, let expected) = phase else { return }

        phase = .downloading(received: received + length, expected: expected)
    }

    /// The download is in, and the updater is unpacking and checking it,
    /// which cannot be cancelled.
    public func showPreparing() {
        show(.preparing(fraction: 0), waiting: nil, urgent: false)
    }

    public func preparingProgress(_ fraction: Double) {
        guard case .preparing = phase else { return }

        phase = .preparing(fraction: min(max(fraction, 0), 1))
    }

    /// A download can take long enough for the person to have gone to another
    /// app, so this is the one phase that also asks for their attention.
    public func showReady(relaunch: @escaping () -> Void) {
        show(.ready, waiting: .relaunch(relaunch), urgent: false)
        presenter?.requestAttention()
    }

    public func showInstalling() {
        show(.installing, waiting: nil, urgent: false)
    }

    /// The system kept Fermix from quitting, so the install waits. The window
    /// goes, rather than standing over whatever kept the app open, and asking
    /// for the update again brings the relaunch back.
    public func parkRelaunch(retry: @escaping () -> Void) {
        close()
        parkedRelaunch = retry
    }

    public func showNotFound(_ reason: UpdateNotFoundReason, acknowledge: @escaping () -> Void) {
        show(.notFound(reason), waiting: .acknowledgement(acknowledge), urgent: true)
    }

    public func showInstalled(acknowledge: @escaping () -> Void) {
        show(.installed, waiting: .acknowledgement(acknowledge), urgent: true)
    }

    public func showFailure(_ failure: UpdateFailure, acknowledge: @escaping () -> Void) {
        show(.failed(failure), waiting: .acknowledgement(acknowledge), urgent: true)
    }

    /// The person asked for the update while one is under way.
    public func bringForward() {
        if phase == nil, let retry = parkedRelaunch {
            show(.ready, waiting: .relaunch(retry), urgent: true)
            return
        }
        guard phase != nil else { return }

        present()
    }

    /// The updater ended the session. Whatever was pending is dropped unsent:
    /// the updater is no longer waiting for it.
    public func dismiss() {
        parkedRelaunch = nil
        close()
    }

    /// Fermix came in front: a phase that was waiting for that is shown now.
    public func appBecameActive() {
        guard waitingForActivation, phase != nil else { return }

        present()
    }

    // MARK: - What the person pressed

    /// One press, sent to the answer the updater is waiting for. A press with
    /// nothing pending, the second click on a button whose answer already
    /// went, does nothing.
    public func perform(_ action: UpdatePromptAction) {
        guard let phase,
              UpdateWindowContent(phase: phase, installedVersion: installedVersion).offers(action),
              let answer = pending
        else { return }

        pending = nil

        switch (action, answer) {
        case (.allowChecks, .permission(let reply)):
            close()
            reply(true)
        case (.declineChecks, .permission(let reply)):
            close()
            reply(false)
        case (.install, .choice(let reply)), (.relaunch, .choice(let reply)):
            // The window stays: the updater moves it on to the download, or
            // straight to the relaunch for an update that is already staged.
            reply(.install)
        case (.later, .choice(let reply)):
            close()
            reply(.dismiss)
        case (.skip, .choice(let reply)):
            close()
            reply(.skip)
        case (.learnMore, .choice(let reply)):
            if case .offered(let offer) = phase, let url = offer.infoURL { presenter?.open(url) }
            close()
            reply(.dismiss)
        case (.cancel, .cancellation(let cancel)):
            close()
            cancel()
        case (.relaunch, .relaunch(let relaunch)):
            parkedRelaunch = nil
            relaunch()
        case (.done, .acknowledgement(let acknowledge)):
            close()
            acknowledge()
        default:
            preconditionFailure("the update window offered \(action) with no answer of that kind pending")
        }
    }

    // MARK: -

    /// A new phase replaces the window's content in place: one window for the
    /// whole update, never a second one stacked on the first.
    private func show(_ next: UpdatePromptPhase, waiting answer: Pending?, urgent: Bool) {
        phase = next
        pending = answer

        guard !windowShown else { return }

        if urgent || presenter?.isAppActive == true {
            present()
        } else {
            waitingForActivation = true
        }
    }

    private func present() {
        waitingForActivation = false
        windowShown = true
        presenter?.showUpdateWindow()
    }

    private func close() {
        phase = nil
        pending = nil
        waitingForActivation = false
        windowShown = false
        presenter?.closeUpdateWindow()
    }
}
