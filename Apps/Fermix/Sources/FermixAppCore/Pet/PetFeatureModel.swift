import Combine
import CoreGraphics
import Foundation

/// The pet window's geometry, in one place rather than spread across the view.
public enum PetMetrics {
    public static let windowSize = CGSize(width: 180, height: 168)
    public static let stageSize = CGSize(width: 132, height: 116)
    public static let mascotSize = CGSize(width: 116, height: 108)
    /// The mascot art is authored on a square canvas at this size, which is
    /// what the face-registration offset is measured against.
    public static let artworkCanvas: Double = 1_024
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
/// It republishes the app model rather than holding a second copy of the voice
/// state, and forwards every action to the voice controller: the pet decides
/// nothing about the call, it only draws it.
@MainActor
public final class PetFeatureModel: ObservableObject {
    /// Whether the pet window is actually on screen. False pauses the animation
    /// timeline: an occluded, minimized, or off-Space window costs no frames.
    @Published public private(set) var windowVisible = true

    private let model: AppModel
    private let voice: any VoiceControlling
    private let windows: any PetWindowPresenting
    private var modelChanges: AnyCancellable?

    public init(model: AppModel, voice: any VoiceControlling, coordinator: any PetWindowPresenting) {
        self.model = model
        self.voice = voice
        self.windows = coordinator
        self.modelChanges = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - What the pet draws

    public var presentation: VoicePresentation { model.voice.presentation }
    public var expression: PetExpression { presentation.expression }
    public var visualMode: VoiceMode { presentation.visualMode }
    public var mode: VoiceMode { model.voice.mode }
    public var callActive: Bool { model.voice.callActive }
    public var muted: Bool { model.voice.muted }
    public var audioActive: Bool { model.voice.audioActive }

    /// Not published: the timeline samples it every frame, so a per-chunk
    /// update must not invalidate the SwiftUI tree.
    public var audioLevel: Float { model.audioLevel }

    public var callActionTitle: String {
        ProductStrings[callActive ? .petCallEnd : .petCallBegin]
    }

    public var muteActionTitle: String {
        ProductStrings[muted ? .petUnmute : .petMute]
    }

    public var interruptActionTitle: String { ProductStrings[.petInterrupt] }

    public var showsInterrupt: Bool {
        mode == .thinking || visualMode == .speaking
    }

    public var accessibilityLabel: String { ProductStrings[.petAccessibilityLabel] }
    public var accessibilityValue: String { presentation.accessibilityLabel }

    /// The state in words, so the sidebar surface reads it without the mascot.
    public var statusText: String { presentation.accessibilityLabel }

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

    public func toggleCall() {
        voice.toggleCall()
    }

    public func toggleMute() {
        voice.setMuted(!muted)
    }

    public func interrupt() {
        voice.interrupt()
    }

    public func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }

        windowVisible = visible
    }
}
