import SwiftUI

/// The restart sheet (M34 §5.10).
///
/// It states the daemon's reasons, says how much work a restart would
/// interrupt, and offers the two ways to take it. A restart is never automatic
/// after a save, so this sheet is the only place in Settings one starts.
///
/// The engine-reconcile restart is the same sheet under a different title: the
/// daemon in memory is older than the engine in the bundle, and the restart is
/// what applies it. The Setup Assistant's Applying screen opens this same sheet
/// rather than one of its own, so `Restart when idle` exists everywhere a
/// restart is asked for.
struct RestartSheet: View {
    @ObservedObject var model: SettingsModel
    /// Takes the restart once the sheet's chosen moment arrives.
    ///
    /// A closure rather than the command router, because the assistant takes the
    /// same journaled transaction through its own `DaemonRestarting` seam and
    /// has to learn when it finished. The sheet still decides only *when*.
    let restart: () -> Void
    /// Whether this restart is the one that finishes an update, which is the
    /// only thing that changes about the sheet.
    ///
    /// It is passed in rather than read here because the assistant's Starting
    /// screen opens this sheet before any of it has been read. Both facts that
    /// can make a restart an update — a v2 method refusing (M34 §7.1) and the
    /// launch reconcile finding a different build (§7.2) — are one value on the
    /// one settings model, so the two doors cannot title the sheet differently.
    let isFinishingUpdate: Bool
    /// Why the last restart was refused, in one sentence, where one was.
    ///
    /// The sheet is where the restart was asked for, so it is where the refusal
    /// has to be readable: a preflight that only reached the log left `Restart
    /// now` looking like a button that does nothing.
    let refusal: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(title)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            reasons
            inFlight
            progress
            refused

            // Cancel sits next to the default action, which is where macOS
            // puts it: the third button is an alternative to `Restart now`
            // rather than a second way out, so it leads the row and leaves the
            // cancel-then-default pair together at the trailing edge.
            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsRestartWhenIdle]) {
                    Task { await take(.whenIdle) }
                }
                .disabled(model.restartProgress == .waitingForIdle)

                Button(ProductStrings[.settingsRestartCancel]) {
                    model.cancelRestartWait()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(ProductStrings[.settingsRestartNow]) {
                    Task { await take(.now) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
        .task { await model.readConversationsInFlight() }
    }

    private var title: String {
        isFinishingUpdate
            ? ProductStrings[.settingsEngineSheetTitle]
            : ProductStrings[.settingsRestartSheetTitle]
    }

    var reasonSentences: [String] {
        let sentences = model.restart.reasons.map(\.sentence)
        guard sentences.isEmpty, isFinishingUpdate else { return sentences }

        return [ProductStrings[.settingsRequiresNewerEngine]]
    }

    @ViewBuilder
    private var reasons: some View {
        if !reasonSentences.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(Array(reasonSentences.enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .fermixType(Typography.style(.bodyCompact))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What a restart would interrupt. Zero says nothing: an empty line under
    /// the reasons reads better than "0 conversations are in progress". An
    /// unanswered read says nothing either, rather than claiming a free restart.
    @ViewBuilder
    private var inFlight: some View {
        if let count = model.conversationsInFlight, count > 0 {
            Text(
                String(
                    format: ProductStrings[
                        count == 1 ? .settingsRestartInFlightOne : .settingsRestartInFlightMany
                    ],
                    count
                )
            )
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.warning.color)
        }
    }

    @ViewBuilder
    private var refused: some View {
        if let refusal {
            Text(refusal)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch model.restartProgress {
        case .idle:
            EmptyView()
        case .waitingForIdle:
            Text(ProductStrings[.settingsRestartWaiting])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .accessibilityAddTraits(.updatesFrequently)
        case .stillBusy:
            Text(ProductStrings[.settingsRestartStillBusy])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// The restart itself is the app's journaled lifecycle transaction, which
    /// the caller owns; this sheet decides only when it runs. What the panes
    /// show afterwards is re-read when that transaction reports it finished,
    /// not here: this sheet has no way to know that it has.
    private func take(_ mode: RestartMode) async {
        await model.beginRestart(mode, perform: restart)

        guard model.restartProgress == .idle else { return }

        dismiss()
    }
}

/// Sheet geometry (M34 §3.1): one width for a credential sheet, one size for a
/// picker. Declared once so no sheet invents its own.
public enum SheetMetrics {
    public static let credentialWidth: Double = 460
    public static let pickerSize = CGSize(width: 520, height: 480)
}
