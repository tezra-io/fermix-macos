import AppKit
import SwiftUI

/// The floating companion: the pet, in a window of its own that floats over
/// other apps.
///
/// What it draws is `PetCompanion`, the same view the chat's call box hosts;
/// what is the window's alone is here: the drag from anywhere on it, the first
/// press taken from an inactive app, the dock revealed by the pointer, and the
/// context menu that is the only way back when the pet is all that is on
/// screen.
struct PetView: View {
    @ObservedObject var model: PetFeatureModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovered = false

    var body: some View {
        // Reduce Motion and a window off screen both park the loops; the pose
        // still changes, so no state is lost. The intro plays on every show.
        PetCompanion(
            model: model,
            animates: model.windowVisible && !reduceMotion,
            playsIntro: !reduceMotion,
            dock: shouldShowControls ? .shown : .hidden,
            // Its dock's stop has nothing to close once a call is over.
            host: .floatingWindow
        )
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // The companion moves from wherever it is held. The window is movable
        // by its background, but AppKit only moves a window from a point nothing
        // else claims, and the mascot claims nearly all of it for its click: what
        // was left to hold was a few points of padding, so it read as a window
        // that would not move (owner report of 2026-09-20: "I'm unable to drag
        // and move it everywhere"). The drag is stated instead. A press that
        // moves drags the window and a press that does not is still the click,
        // and it is simultaneous so the mascot's own tap keeps the click.
        //
        // The companion floats over other apps, so the press that starts a drag
        // is usually also the one that would activate Fermix. Without the second
        // line that first press is spent on activation and the drag never starts.
        .simultaneousGesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .onHover { inside in
            withAnimation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade)) { hovered = inside }
        }
        .contextMenu {
            Button(model.callActionTitle) { model.toggleCall() }
                .disabled(!model.callActionEnabled)

            if model.callActive {
                Button(model.muteActionTitle) { model.toggleMute() }
            }

            Button(model.interruptActionTitle) { model.interrupt() }

            Button(model.openFermixActionTitle) { model.open() }
        }
    }

    /// The dock comes with a call. Its one control is the stop, which has
    /// nothing to do on this window with no call up, so the pointer reveals
    /// no empty dock at rest.
    private var shouldShowControls: Bool {
        guard model.stopAction(in: .floatingWindow) != nil else { return false }

        return hovered || model.callActive || model.visualMode == .speaking
    }
}

/// The pet: the Rive mascot, fed the call's pose and live level, and under it
/// the dock of its call controls.
///
/// One view, two hosts: the floating window (`PetView`) and the chat's call box
/// (`ChatCallBox`). Each host decides what is its own: whether the mascot may
/// move (its own window's visibility), whether the intro plays and whether the
/// dock shows. A click on the mascot is the call control's in both, through
/// the gate: it begins a call or ends it (owner, 2026-09-25: "the click on the
/// mascot leads to enabling or disabling it"; 2026-10-04: the chat's box does
/// the same). What the dock's stop offers is the façade's rule, read for the
/// host that draws it, so the two cannot drift. The animation never takes the
/// click, so the whole of the mascot's frame is that one action.
struct PetCompanion: View {
    /// Whether the dock of call controls is drawn.
    enum Dock: Equatable {
        case shown
        /// Not drawn, keeping its room, so revealing it moves nothing.
        case hidden
        /// Not drawn and taking no room.
        case absent
    }

    @ObservedObject var model: PetFeatureModel
    let animates: Bool
    let playsIntro: Bool
    let dock: Dock
    /// Which host draws it, which the façade reads for the dock's stop.
    let host: PetHost

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mascot) private var mascot

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                mascotView
                    .frame(width: PetMetrics.mascotSize.width, height: PetMetrics.mascotSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleCall() }
                    .help(model.callHelpText)
            }
            .frame(width: PetMetrics.stageSize.width, height: PetMetrics.stageSize.height)

            if dock != .absent {
                ControlDock(model: model, host: host)
                    .opacity(dock == .shown ? 1 : 0)
                    .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: dock)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.accessibilityValue)
    }

    /// The level is read by the renderer rather than published here, because
    /// it changes with every audio chunk.
    private var mascotView: some View {
        mascot?.mascot(
            pose: model.expression,
            level: { [model] in model.audioLevel },
            animates: animates,
            playsIntro: playsIntro
        )
    }
}

private struct ControlDock: View {
    @ObservedObject var model: PetFeatureModel
    let host: PetHost

    var body: some View {
        HStack(spacing: Spacing.s) {
            stop

            if model.showsInterrupt {
                PetControlButton(symbol: .interrupt, label: model.interruptActionTitle) {
                    model.interrupt()
                }
            }

            if model.callActive {
                PetControlButton(symbol: .mute(model), label: model.muteActionTitle) {
                    model.toggleMute()
                }
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Palette.hairline(.standard).color, lineWidth: Stroke.hairline)
        )
    }

    /// The one call control, the stop. Where it has nothing to do it keeps its
    /// place unseen, so the floating window's dock, hidden at rest, keeps the
    /// room it takes once a call is up, and revealing it moves nothing.
    @ViewBuilder private var stop: some View {
        if let action = model.stopAction(in: host) {
            PetControlButton(symbol: .stop, label: model.stopActionTitle(action)) {
                model.stopClicked(in: host)
            }
            .disabled(action == .ending)
        } else {
            PetControlButton(symbol: .stop, label: model.stopActionTitle(.end)) {}
                .hidden()
        }
    }
}

/// How one of the dock's controls draws: its symbol, whether the symbol takes
/// its filled form, and its tint. A value, so each state's drawing is proven
/// without a window.
struct PetDockSymbol: Equatable, Sendable {
    let name: String
    let filled: Bool
    let tint: ThemedColor

    /// The stop, the filled square, in ink in every state and never the
    /// accent: it ends a call, and in the chat's box it closes the box once
    /// the call is over (owner, 2026-10-04: "I prefer it was a stop button").
    /// The dock draws no phone: the chat toolbar's begins a call, and the
    /// dock's control never does. The mascot is what shows the call is live.
    static let stop = PetDockSymbol(name: "stop", filled: true, tint: Palette.ink)

    /// The slashed microphone, filled and in the warning tint while muted.
    @MainActor
    static func mute(_ pet: PetFeatureModel) -> PetDockSymbol {
        PetDockSymbol(name: "mic.slash", filled: pet.muted, tint: pet.muted ? Palette.warning : Palette.ink)
    }

    /// The silenced speaker, which cuts the reply off: never the stop's
    /// square, so the two cannot be confused.
    static let interrupt = PetDockSymbol(name: "speaker.slash", filled: false, tint: Palette.ink)
}

private struct PetControlButton: View {
    let symbol: PetDockSymbol
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The fill is a variant of the one name, as the toolbar draws it.
            Image(systemName: symbol.name)
                .symbolVariant(symbol.filled ? .fill : .none)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbol.tint.color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
