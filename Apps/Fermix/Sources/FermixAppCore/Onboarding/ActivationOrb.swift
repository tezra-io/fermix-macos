import SwiftUI

/// The breathing orb on Activate: a glass sphere over a blue core, with a halo
/// behind both.
///
/// It is decorative. The ladder beside it carries the state in words and
/// shapes, which is what lets the whole thing hold still under Reduce Motion
/// without losing any meaning.
struct ActivationOrb: View {
    /// The redline's 96-point orb.
    static let diameter: Double = 96
    private static let haloInset: Double = -22
    private static let coreInset: Double = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var breathing = false

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        let resting = motion.restingProgress(.orbBreath)

        return ZStack {
            halo(intensity: intensity(resting))
            sphere
            core(intensity: intensity(resting))
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect(breathing ? 1.05 : 1)
        .onAppear {
            guard let animation = motion.animation(.orbBreath) else { return }

            withAnimation(animation) { breathing = true }
        }
        .accessibilityHidden(true)
    }

    /// A suppressed loop parks at its high value, so the orb keeps its full
    /// glow rather than its dimmest frame.
    private func intensity(_ resting: Double) -> Double {
        breathing || resting == 1 ? 1 : 0.5
    }

    private func halo(intensity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Palette.orbHalo.color, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: (Self.diameter - Self.haloInset * 2) / 2 * 0.65
                )
            )
            .padding(Self.haloInset)
            .opacity(intensity)
    }

    private var sphere: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Palette.orbHighlight.color, Palette.orbLow.color],
                    center: UnitPoint(x: 0.32, y: 0.28),
                    startRadius: 0,
                    endRadius: Self.diameter * 0.7
                )
            )
            .overlay(Circle().strokeBorder(Palette.orbRim.color, lineWidth: Stroke.hairline))
            .shadow(color: Palette.orbShadow.color, radius: 17, y: 14)
    }

    private func core(intensity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Palette.accent.color, Palette.accentPressed.color],
                    center: .center,
                    startRadius: 0,
                    endRadius: (Self.diameter - Self.coreInset * 2) / 2
                )
            )
            .padding(Self.coreInset)
            .shadow(color: Palette.orbCoreGlow.color, radius: 12)
            .opacity(0.6 + 0.4 * intensity)
    }
}

/// The chip in Activate's titlebar: the pulsing bolt and the sentence that says
/// the menu bar mirrors this state.
struct ActivationMirrorChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var pulsing = false

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)

        return HStack(spacing: 6) {
            FermixBoltShape()
                .fill(Palette.accent.color)
                .frame(width: 13, height: 13)
                .opacity(pulsing || motion.restingProgress(.orbBreath) == 1 ? 1 : 0.5)
                .accessibilityHidden(true)

            Text(ProductStrings[.activateMirrorChip])
                .fermixType(Typography.style(.caption))
                .foregroundStyle(Palette.secondary.color)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.chipFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
        .onAppear {
            guard let animation = motion.animation(.orbBreath) else { return }

            withAnimation(animation) { pulsing = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProductStrings[.activateMirrorChip])
    }
}
