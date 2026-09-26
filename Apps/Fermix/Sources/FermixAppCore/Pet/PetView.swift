import AppKit
import SwiftUI

/// The floating companion. It draws the voice state and offers the three
/// actions a call has; every one of them goes through the voice controller.
struct PetView: View {
    @ObservedObject var model: PetFeatureModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mascot) private var mascot

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                mascotView
                    .frame(width: PetMetrics.mascotSize.width, height: PetMetrics.mascotSize.height)
                    // The mascot draws and never takes the click, so the whole
                    // of its frame is this one button: a click starts the call
                    // or ends it (owner, 2026-09-25: "the click on the mascot
                    // leads to enabling or disabling it").
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleCall() }
                    .help(model.callHelpText)
            }
            .frame(width: PetMetrics.stageSize.width, height: PetMetrics.stageSize.height)

            ControlDock(model: model)
                .opacity(shouldShowControls ? 1 : 0)
                .animation(motion.animation(.stepCrossfade), value: shouldShowControls)
        }
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
            withAnimation(motion.animation(.stepCrossfade)) { hovered = inside }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.accessibilityValue)
        .contextMenu {
            Button(model.callActionTitle) { model.toggleCall() }

            if model.callActive {
                Button(model.muteActionTitle) { model.toggleMute() }
            }

            Button(model.interruptActionTitle) { model.interrupt() }

            Button(model.openFermixActionTitle) { model.open() }
        }
    }

    private var motion: Motion { Motion(reduceMotion: reduceMotion) }

    private var shouldShowControls: Bool {
        hovered || model.callActive || model.visualMode == .speaking
    }

    /// The Rive mascot, fed the pose and the live level.
    ///
    /// Reduce Motion and a window off screen both park the loops; the pose
    /// still changes, so no state is lost. The level is read by the renderer
    /// rather than published here, because it changes with every audio chunk.
    private var mascotView: some View {
        mascot?.mascot(
            pose: model.expression,
            level: { [model] in model.audioLevel },
            animates: model.windowVisible && !reduceMotion
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
