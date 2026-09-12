import SwiftUI

/// One long operation as a row (M34 §7.3).
///
/// Idle it is a button; running it is the daemon's own phase and progress with
/// one Cancel; finished badly it is the daemon's sentence. Appearing re-attaches
/// to a run already in flight rather than starting a second one, and
/// disappearing stops the polling and leaves the run alone.
struct JobRow: View {
    let title: String
    let actionTitle: String
    let kind: ManagementJobKind
    @ObservedObject var runner: JobRunner
    /// Mints the job. The caller owns which method starts it; this row owns
    /// what happens afterwards.
    let start: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            LabeledContent(title) {
                if runner.isRunning {
                    Button(ProductStrings[.settingsJobCancel]) {
                        Task { await runner.cancelJob() }
                    }
                } else {
                    Button(actionTitle) { Task { await start() } }
                        // The verb alone says nothing about which row it acts
                        // on: five `Install` buttons in one pane read the same.
                        .accessibilityLabel(ProductStrings.commaPair(actionTitle, title))
                }
            }

            JobProgress(runner: runner)
        }
        .task { await runner.attach(kind: kind) }
        .onDisappear { runner.dismiss() }
    }
}

/// What one run looks like while it runs, and what it says when it ended badly
/// (M34 §7.3).
///
/// Written once, because the row that offers a job and the switch that runs one
/// before its write show the same two things, and two spellings of "what a run
/// looks like" is two of them to keep in step.
struct JobProgress: View {
    @ObservedObject var runner: JobRunner

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            progress
            failure
        }
    }

    @ViewBuilder
    private var progress: some View {
        if runner.isRunning {
            HStack(spacing: Spacing.xs) {
                indicator
                    .accessibilityHidden(true)

                if let phase = runner.phase {
                    Text(phase)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
    }

    /// Determinate where the daemon published a total, indeterminate where it
    /// has not: the app never invents a denominator.
    @ViewBuilder
    private var indicator: some View {
        if let fraction = runner.progress?.fraction {
            ProgressView(value: fraction).controlSize(.small)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var failure: some View {
        if let sentence = runner.failure {
            Text(sentence)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
