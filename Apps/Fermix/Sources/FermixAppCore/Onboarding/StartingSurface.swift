import SwiftUI

/// Starting: a compact headline and the steps this activation actually runs.
///
/// The last row is the one that reads what is already set up, which is what
/// makes an upgrade land on Ready rather than re-asking a configured home.
struct StartingSurface: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        LadderSurface(ladder: model.ladder, subcopy: model.startingCaption)
    }
}

/// Applying: the two-row ladder that saves the About you answers and takes the
/// restart the new provider needs.
///
/// Decision 11 restarts without asking on a fresh install with nothing in
/// flight; anything else opens the Restart sheet. It is literally the Settings
/// window's sheet, so `Restart when idle` — the option this screen most needs,
/// because it only asks when work is in flight — exists here too.
struct ApplyingSurface: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        LadderSurface(ladder: model.ladder, subcopy: nil)
            .overlay(alignment: .bottom) { block }
            .sheet(isPresented: $model.restartSheetPresented) {
                RestartSheet(
                    model: model.settings,
                    restart: { model.takeRestartFromSheet() },
                    isFinishingUpdate: model.settings.engineReconcile.isFinishingUpdate,
                    refusal: model.restartRefusal
                ) { model.restartSheetPresented = false }
            }
    }

    /// Why the gate refused, where it did, and what a restart that was asked for
    /// and did not happen has to say. A pending restart has no screen of its
    /// own, so it is stated here beside the way to take it.
    @ViewBuilder
    private var block: some View {
        VStack(spacing: Spacing.s) {
            if let refusal = model.restartRefusal {
                sentence(refusal)
            }

            if let blocked = model.blocked {
                sentence(model.message(for: blocked))
            }

            if model.offersRestart {
                Button(ProductStrings[.applyingTakeRestart]) { model.restartSheetPresented = true }
                    .buttonStyle(SecondaryButtonStyle(.inWindow))
            }
        }
        .padding(.bottom, Spacing.m)
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.warning.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: OnboardingMetrics.contentWidth)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Mechanical stages share one quiet progress column. Decision screens keep
/// their existing headings and artwork.
private struct LadderSurface: View {
    let ladder: ProgressLadderModel?
    let subcopy: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: Spacing.m) {
                if let ladder {
                    Text(ladder.headline)
                        .fermixType(Typography.style(.headline))
                        .foregroundStyle(Palette.ink.color)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let subcopy {
                    Text(subcopy)
                        .fermixType(Typography.style(.bodyCompact))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ladder { ProgressLadder(model: ladder) }
            }
            .frame(maxWidth: OnboardingMetrics.contentWidth)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
    }
}
