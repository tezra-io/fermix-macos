import AppKit
import Combine
import SwiftUI

/// The floating companion. It draws the voice state and offers the three
/// actions a call has; every one of them goes through the voice controller.
struct PetView: View {
    @ObservedObject var model: PetFeatureModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                AnimatedMascot(model: model)
                    .frame(width: PetMetrics.mascotSize.width, height: PetMetrics.mascotSize.height)
                    .compositingGroup()
                    .shadow(color: glowColor, radius: 12, y: 6)
                    .animation(motion.animation(.mascotEntrance), value: model.visualMode)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleCall() }
                    .help(model.callActionTitle)
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

    /// The glow is the tint the presentation already chose, softened. One
    /// source for the colour, so the pet cannot drift from the palette.
    private var glowColor: Color {
        model.presentation.tint.color.opacity(model.callActive ? 0.34 : 0.18)
    }
}

/// Time-driven mascot: a single `TimelineView` drives sine motion on all
/// three axes (breath, bob, sway) plus an audio-RMS speaking pulse, and
/// wraps a `MascotCrossfade` so expression changes fade rather than swap.
/// Motion is blended across mode changes so a switch eases in over ~0.5s
/// instead of snapping, and the timeline pauses when the window is hidden.
private struct AnimatedMascot: View {
    @ObservedObject var model: PetFeatureModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var fromMode: VoiceMode = .offline
    @State private var modeMirror: VoiceMode = .offline
    @State private var modeChangedAt: TimeInterval = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            MascotCrossfade(
                expression: model.expression,
                blinkOpacity: reduceMotion ? 0 : MascotMotion.blinkOpacity(at: now)
            )
            .scaleEffect(lerpedScale(at: now))
            .offset(y: lerpedOffset(at: now))
            .rotationEffect(.degrees(lerpedRotation(at: now)))
        }
        .onChange(of: model.visualMode) { _, visual in
            beginTransition(to: visual)
        }
    }

    /// Reduce Motion parks the mascot: the expression still changes, so no
    /// state is lost, but nothing loops.
    private var paused: Bool {
        !model.windowVisible || reduceMotion
    }

    /// Start a 0.5s eased blend toward a new visual mode. Deduped so the server
    /// flipping state to listening mid-playback — while the pet is still
    /// visually speaking — doesn't retrigger a transition.
    private func beginTransition(to visual: VoiceMode) {
        guard visual != modeMirror else { return }
        fromMode = modeMirror
        modeMirror = visual
        modeChangedAt = Date().timeIntervalSinceReferenceDate
    }

    /// 0→1 ease over 0.5s since the last mode change; 1 means "settled".
    private func transitionProgress(at time: TimeInterval) -> Double {
        let duration = 0.5
        let age = time - modeChangedAt
        guard age >= 0, age < duration else { return 1 }
        let position = age / duration
        return position * position * (3 - 2 * position)
    }

    private func lerpedScale(at time: TimeInterval) -> CGFloat {
        let target = scale(for: modeMirror, at: time)
        let progress = transitionProgress(at: time)
        guard progress < 1 else { return target }
        let from = scale(for: fromMode, at: time)
        return from + (target - from) * CGFloat(progress)
    }

    private func lerpedOffset(at time: TimeInterval) -> CGFloat {
        let target = offset(for: modeMirror, at: time)
        let progress = transitionProgress(at: time)
        guard progress < 1 else { return target }
        let from = offset(for: fromMode, at: time)
        return from + (target - from) * CGFloat(progress)
    }

    private func lerpedRotation(at time: TimeInterval) -> Double {
        let target = rotation(for: modeMirror, at: time)
        let progress = transitionProgress(at: time)
        guard progress < 1 else { return target }
        let from = rotation(for: fromMode, at: time)
        return from + (target - from) * progress
    }

    private func scale(for mode: VoiceMode, at time: TimeInterval) -> CGFloat {
        let breath = MascotMotion.breathAmp(mode)
            * sin(2 * .pi * time / MascotMotion.breathPeriod(mode))
        let speakingPulse = mode == .speaking ? Double(0.06 * model.audioLevel) : 0
        return CGFloat(1 + breath + speakingPulse)
    }

    private func offset(for mode: VoiceMode, at time: TimeInterval) -> CGFloat {
        let amplitude = MascotMotion.bobAmp(mode)
        let period = MascotMotion.bobPeriod(mode)
        return CGFloat(-amplitude * sin(2 * .pi * time / period))
    }

    private func rotation(for mode: VoiceMode, at time: TimeInterval) -> Double {
        MascotMotion.swayAmp(mode) * sin(2 * .pi * time / 4.2)
    }
}

/// Cross-fades the four mascot expressions with a brief scale pop instead
/// of hard-swapping the PNG stack on mode change. The head "ball" lives here,
/// above the fading faces, so the shared pearl stays put across expression
/// changes instead of fading and popping with every swap.
@MainActor
private struct MascotCrossfade: View {
    let expression: PetExpression
    let blinkOpacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(PetExpression.allCases, id: \.self) { candidate in
                if candidate == expression {
                    MascotImage(expression: candidate, blinkOpacity: blinkOpacity)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }

            ball
                .offset(y: -15)
        }
        .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: expression)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ball: some View {
        if let image = PetAssetCache.shared.image("pet_ball") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }
}

@MainActor
private struct MascotImage: View {
    let expression: PetExpression
    let blinkOpacity: Double

    var body: some View {
        if hasLayers {
            layered
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Palette.accent.color)
        }
    }

    // Ring sits behind the body at 1.20x so the orbit reads as passing behind
    // the mascot (its authored 3D depth). The ball is drawn by MascotCrossfade.
    private var layered: some View {
        ZStack {
            layer(.ring)
                .scaleEffect(1.20)

            ZStack {
                layer(.body)
                faceLayer
            }

            layer(.decor)
                .opacity(0.75)
        }
    }

    // Face plate plus a blink: the idle face is a closed-eye frame, so cross-
    // fading it over the open-eye listening/thinking faces reads as an eyelid
    // blink with no new art. Speaking is excluded — its face carries the mouth
    // and is separately mis-registered (see speakingFaceCompensation).
    @ViewBuilder
    private var faceLayer: some View {
        ZStack {
            layer(.face)

            if blinkOpacity > 0, expression == .listening || expression == .thinking {
                closedEyeFace
                    .opacity(blinkOpacity)
            }
        }
        .offset(speakingFaceCompensation)
    }

    @ViewBuilder
    private var closedEyeFace: some View {
        if let image = PetAssetCache.shared.image(PetExpression.idle.layerAssetName(.face)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    // The speaking face PNG is baked ~12px right / ~24px up vs the other faces
    // (measured alpha bboxes on the shared 1024px canvas). Undo it at display
    // scale — the mascot height governs, since scaledToFit fits the square art
    // into the stage by height.
    private var speakingFaceCompensation: CGSize {
        guard expression == .speaking else { return .zero }
        let scale = PetMetrics.mascotSize.height / PetMetrics.artworkCanvas
        return CGSize(width: -12 * scale, height: 24 * scale)
    }

    @ViewBuilder
    private func layer(_ which: PetLayer) -> some View {
        if let image = PetAssetCache.shared.image(expression.layerAssetName(which)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    private var hasLayers: Bool {
        PetAssetCache.shared.image(expression.layerAssetName(.body)) != nil
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
