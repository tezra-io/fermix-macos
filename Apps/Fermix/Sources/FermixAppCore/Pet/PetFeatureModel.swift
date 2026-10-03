import Combine
import CoreGraphics
import Foundation

/// The pet window's geometry, in one place rather than spread across the view.
public enum PetMetrics {
    public static let windowSize = CGSize(width: 180, height: 168)
    public static let stageSize = CGSize(width: 132, height: 116)
    /// Square, because the animation's artboard is: the whole stage height,
    /// which draws the body at the size the painted mascot had.
    public static let mascotSize = CGSize(width: 116, height: 116)
}

/// Showing and hiding the optional floating pet window, behind a seam.
///
/// The pet asks for the window; the coordinator decides what a window is. That
/// split is what lets the surface be proven without a window server.
@MainActor
public protocol PetWindowPresenting: AnyObject {
    var isPetWindowOpen: Bool { get }
    func setPetWindow(_ shown: Bool)
}

/// The pet's own narrow model.
///
/// It owns the floating window's state and nothing of the call: the call's
/// facts are `VoiceCallModel`'s, which this republishes rather than copies, and
/// every action goes to the voice controller. The call control's click goes
/// through the gate the menus use, so the pet decides nothing about the call,
/// it only draws it.
@MainActor
public final class PetFeatureModel: ObservableObject {
    /// Whether the pet window is actually on screen. False pauses the animation
    /// timeline: an occluded, minimized, or off-Space window costs no frames.
    @Published public private(set) var windowVisible = true

    private let call: VoiceCallModel
    private let voice: any VoiceControlling
    /// The one call control's gate, shared with the menus and the status item.
    private let gate: VoiceCallGate
    private let windows: any PetWindowPresenting
    /// Opens the primary window. The pet floats without one, and with the menu
    /// bar item hidden its context menu is the only thing on screen.
    private let openFermix: () -> Void
    private var callChanges: AnyCancellable?
    private var readinessChanges: AnyCancellable?

    public init(
        call: VoiceCallModel,
        voice: any VoiceControlling,
        gate: VoiceCallGate,
        coordinator: any PetWindowPresenting,
        openFermix: @escaping () -> Void = {}
    ) {
        self.call = call
        self.voice = voice
        self.gate = gate
        self.windows = coordinator
        self.openFermix = openFermix
        self.callChanges = call.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.readinessChanges = gate.readinessChanges.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - What the pet draws

    public var presentation: VoicePresentation { call.voice.presentation }
    public var expression: PetExpression { presentation.expression }
    public var visualMode: VoiceMode { presentation.visualMode }
    public var mode: VoiceMode { call.voice.mode }
    public var callActive: Bool { call.voice.callActive }
    public var muted: Bool { call.voice.muted }
    public var audioActive: Bool { call.voice.audioActive }

    /// Not published: the timeline samples it every frame, so a per-chunk
    /// update must not invalidate the SwiftUI tree.
    public var audioLevel: Float { call.audioLevel }

    /// What a click on the call control does now: a start the daemon has not
    /// answered is ended like a call, a call that is still ending is already
    /// over as far as the control is concerned, and voice that is not set up
    /// is set up. Degraded or unread voice keeps the begin title over a
    /// control that is dimmed, with the reason as its help.
    public var callActionTitle: String {
        switch gate.action {
        case .end: return ProductStrings[.petCallEnd]
        case .setUp: return ProductStrings[.voiceReadinessSetUp]
        case .begin, .unavailable: return ProductStrings[.petCallBegin]
        }
    }

    /// What a click on the call control does now, as the gate decides it.
    public var callAction: VoiceCallAction { gate.action }

    /// Whether a click on the call control does anything. A control that
    /// would do nothing is dimmed rather than silently inert.
    public var callActionEnabled: Bool { gate.action != .unavailable }

    /// Why the call control is dimmed, while it is: the readiness sentence,
    /// since degraded or unread voice leaves no action to name.
    public var callUnavailableReason: String? {
        guard gate.action == .unavailable else { return nil }

        return gate.readiness.sentence
    }

    public var muteActionTitle: String {
        ProductStrings[muted ? .petUnmute : .petMute]
    }

    public var interruptActionTitle: String { ProductStrings[.petInterrupt] }

    /// The mascot's tooltip on the floating window.
    ///
    /// That window draws the mascot and the controls and has room for no
    /// sentence, so a failure would otherwise be readable only by opening the
    /// app. The action is the right thing to offer while there is an action to
    /// take, and the failure, or the readiness that leaves no action, is the
    /// right thing to offer once there is not.
    public var callHelpText: String {
        if call.voice.status.carriesItsOwnSentence { return statusText }

        return callUnavailableReason ?? callActionTitle
    }

    public var cancelTaskActionTitle: String { ProductStrings[.petCancelTask] }

    /// What the speaker who last spoke has said, prefixed with who it is: the
    /// daemon's own bytes, never reflowed, because a caption is verbatim or it
    /// is not a caption. The surface draws it on one line and cuts what does
    /// not fit from the middle, so the name and the newest words both show.
    public var captionLine: String? {
        let captions = call.voice.captions
        guard let speaker = captions.latest else { return nil }

        return String(
            format: ProductStrings[.voiceCaptionLineFormat],
            Self.speakerName(speaker),
            captions.text(of: speaker)
        )
    }

    /// What the backend work is doing, in the catalogue's status word or the
    /// daemon's own word where this build has never seen that status, with
    /// the daemon's summary beside it when it sent one: the newest task still
    /// running, or the last one to finish until the next starts.
    public var taskStatusText: String? {
        guard let task = call.voice.tasks.current else { return nil }

        let word: String
        switch task.status {
        case .pending: word = ProductStrings[.voiceTaskPending]
        case .running: word = ProductStrings[.voiceTaskRunning]
        case .completed: word = ProductStrings[.voiceTaskCompleted]
        case .failed: word = ProductStrings[.voiceTaskFailed]
        case .cancelled: word = ProductStrings[.voiceTaskCancelled]
        case .unrecognized(let value): word = String(format: ProductStrings[.voiceTaskStatusFormat], value)
        }

        guard let summary = task.summary, !summary.isEmpty else { return word }

        return ProductStrings.middot(word, summary)
    }

    /// What the call's voice has cost so far, where the daemon has said, while
    /// the call is up. The backend's share is reported as unknown rather than
    /// as a number, so it is never added in here as zero.
    public var voiceCostText: String? {
        guard callActive, let cents = call.voice.usage?.voiceCostCents else { return nil }

        return String(format: ProductStrings[.voiceCostFormat], CurrencyFormat.wholeCents(cents))
    }

    /// What the call cost, once it is over. The daemon settles the bill after
    /// the hang-up (PROTOCOL.md, Live call sequence), so this is the one final
    /// figure; a call ended at its cost limit keeps the bill that reached it.
    /// Drawn until the next call starts.
    public var settledBillText: String? {
        guard let cents = call.voice.settledCostCents else { return nil }

        return String(format: ProductStrings[.voiceCostSettledFormat], CurrencyFormat.wholeCents(cents))
    }

    /// Cancelling is offered only for work that is actually running: a pending
    /// task has nothing to call off yet, and a finished one cannot be.
    public var showsCancelTask: Bool { call.voice.tasks.current?.status == .running }

    private static func speakerName(_ speaker: VoiceCaptions.Speaker) -> String {
        switch speaker {
        case .user: return ProductStrings[.voiceCaptionSpeakerUser]
        case .assistant: return ProductStrings[.voiceCaptionSpeakerAssistant]
        }
    }

    public var showsInterrupt: Bool {
        mode == .thinking || visualMode == .speaking
    }

    public var accessibilityLabel: String { ProductStrings[.petAccessibilityLabel] }
    public var accessibilityValue: String { statusText }

    /// The state in words, so the sidebar surface reads it without the mascot.
    public var statusText: String { call.voice.statusText }

    /// Whether the optional floating companion window is on screen. It stays
    /// hidden until it is opened: a launch must not put a companion in front of
    /// someone who never asked for one.
    public var floatingWindowShown: Bool { windows.isPetWindowOpen }

    public var floatingWindowActionTitle: String {
        ProductStrings[floatingWindowShown ? .petHideWindow : .petShowWindow]
    }

    public func setFloatingWindow(_ shown: Bool) {
        guard shown != floatingWindowShown else { return }

        windows.setPetWindow(shown)
        objectWillChange.send()
    }

    // MARK: - What the pet does

    public var openFermixActionTitle: String { ProductStrings[.menuTitleOpenFermix] }

    /// Opens Home, which is the way back when the pet is the only thing on
    /// screen.
    public func open() {
        openFermix()
    }

    /// The call control's click, through the gate the menus use.
    public func toggleCall() {
        gate.toggleCall()
    }

    public func toggleMute() {
        voice.setMuted(!muted)
    }

    public func interrupt() {
        voice.interrupt()
    }

    /// Calls off the task the line shows, by the id and revision it shows.
    public func cancelTask() {
        guard let task = call.voice.tasks.newestRunning, task.status == .running else { return }

        voice.cancelTask(delegationId: task.delegationId, revision: task.revision)
    }

    public func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }

        windowVisible = visible
    }
}
