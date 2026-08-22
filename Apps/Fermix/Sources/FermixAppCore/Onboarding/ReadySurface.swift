import SwiftUI

/// Ready: the mascot with its two bloom rings, the success pill, and the one
/// admin moment.
///
/// The CLI row is unchecked and copies a Terminal command. There is no
/// privileged helper anywhere in this app, and the row says what it will do
/// before it does it.
struct ReadySurface: View {
    @ObservedObject var model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            BloomingMascot(size: 116)
                .padding(.bottom, 10)

            Text(ProductStrings[.readyTitle])
                .fermixType(Typography.style(.titleLarge))
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, 6)
                .fermixRiseIn(step: 0, ladder: MotionStagger.readyRiseIn)

            StatusPill(title: ProductStrings[.readyPill], tone: .pass)
                .padding(.bottom, Spacing.m)
                .fermixRiseIn(step: 1, ladder: MotionStagger.readyRiseIn)

            CLIInstallRow(model: model)
                .fermixRiseIn(step: 2, ladder: MotionStagger.readyRiseIn)

            HStack(spacing: 14) {
                PrimaryAction(ProductStrings[.readyOpen], size: .onboarding) { model.finish() }

                Button(ProductStrings[.readyAdvanced]) { model.openHostedSetup() }
                    .buttonStyle(SecondaryButtonStyle(.onboarding))
            }
            .padding(.top, 26)
            .fermixRiseIn(step: 3, ladder: MotionStagger.readyRiseIn)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 110)
        .onAppear { model.refreshCLIPlan() }
    }
}

/// The mascot's arrival, with the two one-shot bloom rings. Both are skipped
/// under Reduce Motion; the success is carried by the pill's words.
struct BloomingMascot: View {
    let size: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bloomed = false

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)

        return ZStack {
            if !motion.isSuppressed(.successBloom) {
                ForEach(Array(MotionStagger.successBloom.enumerated()), id: \.offset) { index, delay in
                    Circle()
                        .strokeBorder(Palette.accent.color.opacity(index == 0 ? 0.5 : 0.3), lineWidth: 2)
                        .padding(10)
                        .scaleEffect(bloomed ? 1.85 : 0.45)
                        .opacity(bloomed ? 0 : 1)
                        .animation(motion.animation(.successBloom)?.delay(delay), value: bloomed)
                }
            }

            MascotArtwork(size: size)
        }
        .frame(width: size, height: size)
        .onAppear { bloomed = true }
        .accessibilityHidden(true)
    }
}

/// The `fermix` command row.
///
/// Four states, one per plan: a command to copy, a link this app already owns,
/// a link Homebrew owns, and a foreign file the app refuses to replace.
struct CLIInstallRow: View {
    @ObservedObject var model: OnboardingModel

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Spacing.s) {
            checkbox

            VStack(alignment: .leading, spacing: 2) {
                Text(ProductStrings[.readyCLITitle])
                    .fermixType(Typography.style(.bodyCompact).weight(.semibold))
                    .foregroundStyle(Palette.ink.color)

                Text(model.cliPlan.hint)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.faint.color)
            }

            Spacer(minLength: Spacing.s)

            if model.cliPlan.offersCommand, model.cliSelected {
                Button(ProductStrings[.readyCLICopy]) {
                    model.copyCLICommand()
                }
                .buttonStyle(SecondaryButtonStyle(.inWindow))

                Button(ProductStrings[.readyCLIVerify]) {
                    model.refreshCLIPlan()
                }
                .buttonStyle(SecondaryButtonStyle(.inWindow))
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, 14)
        .frame(width: 470)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.cardFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
    }

    /// The row starts unchecked. A plan with no command to run has nothing to
    /// select, so it shows what it found instead of an inert box.
    @ViewBuilder
    private var checkbox: some View {
        if model.cliPlan.offersCommand {
            Toggle(isOn: $model.cliSelected) {
                Text(ProductStrings[.readyCLITitle])
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(ProductStrings[.readyCLITitle])
        } else {
            Image(systemName: model.cliInstalled ? "checkmark.circle" : "info.circle")
                .font(.system(size: 18))
                .foregroundStyle(model.cliInstalled ? Palette.success.color : Palette.faint.color)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}
