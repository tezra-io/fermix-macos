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
            // The whole of the mascot's frame is this one button: a click
            // starts the call or ends it (owner, 2026-09-25: "the click on
            // the mascot leads to enabling or disabling it").
            mascotClick: { model.toggleCall() }
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

    private var shouldShowControls: Bool {
        hovered || model.callActive || model.visualMode == .speaking
    }
}

/// The pet: the Rive mascot, fed the call's pose and live level, and under it
/// the dock of its call controls.
///
/// One view, two hosts: the floating window (`PetView`) and the chat's call box
/// (`ChatCallBox`). Each host decides what is its own: whether the mascot may
/// move (its own window's visibility), whether the intro plays, whether the
/// dock shows, and what a click on the mascot does. The mascot draws and never
/// takes the click, so the whole of its frame is that one action.
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
    let mascotClick: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mascot) private var mascot

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                mascotView
                    .frame(width: PetMetrics.mascotSize.width, height: PetMetrics.mascotSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { mascotClick() }
                    .help(model.callHelpText)
            }
            .frame(width: PetMetrics.stageSize.width, height: PetMetrics.stageSize.height)

            if dock != .absent {
                ControlDock(model: model)
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

    var body: some View {
        HStack(spacing: Spacing.s) {
            PetControlButton(
                systemName: model.callActive ? "mic.fill" : "mic",
                tint: model.callActive ? Palette.accent.color : Palette.ink.color,
                label: model.callActionTitle
            ) {
                model.toggleCall()
            }
            .disabled(!model.callActionEnabled)

            if model.showsInterrupt {
                PetControlButton(
                    systemName: "stop.circle",
                    tint: Palette.ink.color,
                    label: model.interruptActionTitle
                ) {
                    model.interrupt()
                }
            }

            if model.callActive {
                PetControlButton(
                    systemName: model.muted ? "mic.slash.fill" : "mic.slash",
                    tint: model.muted ? Palette.warning.color : Palette.ink.color,
                    label: model.muteActionTitle
                ) {
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
}

private struct PetControlButton: View {
    let systemName: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
