import SwiftUI

/// Ready: the status, the optional next steps, and the one admin moment.
///
/// It refuses to render while a gating readiness failure stands (M34 §4): the
/// screen claims the install is live, and that claim has to be the daemon's.
/// Advisory failures render as one row whose action opens Home, never as a
/// block.
struct ReadySurface: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            content

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
        .onAppear { model.refreshCLIPlan() }
        // The claim this screen makes is the daemon's, so the screen asks the
        // daemon. Readiness used to arrive only from the activation that walked
        // here, which meant every other way in — a route that resumes at Ready
        // (§3.4), and every fixture launch of this surface — drew the "not
        // answering yet" block against a daemon that was up. Connect your AI
        // already reads readiness on appear for the same reason.
        .task { await model.refreshReadiness() }
    }

    /// The refusal is a state, not a crash: a gate that arrives after Ready has
    /// opened puts the blocking sentence on screen instead of a claim that
    /// everything is live.
    @ViewBuilder
    private var content: some View {
        if let blocked = model.readiness.block {
            VStack(spacing: 0) {
                SurfaceHeading(title: ProductStrings[.readyBlockedTitle], subcopy: model.message(for: blocked))

                // A gating failure on a pane the assistant has no screen for
                // names that pane and opens it. Without this the sentence said
                // something in Settings still needed an answer and offered no
                // way to reach it (M34 §3.4).
                if let pane = blocked.pane {
                    Form {
                        Section {
                            NextStepRow(
                                title: String(format: ProductStrings[.readyOpenPaneFormat], pane.title),
                                symbol: "gearshape"
                            ) {
                                model.open(.settings(pane))
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .assistantFormChrome()
                    .padding(.top, Spacing.l)
                }
            }
        } else {
            live
        }
    }

    /// The mascot, the claim, the state, and the optional next steps.
    ///
    /// §5.5 always asked for the mascot here; the wordmark that stood in its
    /// place said `Fermix` directly above a line that already says
    /// `Fermix is live`, which is the repeated label the owner's directive of
    /// 2026-09-03 asks the assistant to lose. The provider line is this
    /// screen's one line of subcopy, so the pill above it is the only other
    /// tier.
    private var live: some View {
        VStack(spacing: 0) {
            MascotArtwork(size: OnboardingMetrics.mascotSize)
                .padding(.bottom, Spacing.s)

            Text(ProductStrings[.readyTitle])
                .fermixType(Typography.style(.titleLarge))
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, Spacing.xs)
                .fermixRiseIn(step: 0, ladder: MotionStagger.readyRiseIn)

            StatusPill(title: ProductStrings[.readyStatus], tone: .pass)
                .fermixRiseIn(step: 1, ladder: MotionStagger.readyRiseIn)

            if let summary = providerSummary {
                Text(summary)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .padding(.top, Spacing.xs)
                    .fermixRiseIn(step: 1, ladder: MotionStagger.readyRiseIn)
            }

            nextSteps
                .padding(.top, Spacing.l)
                .fermixRiseIn(step: 2, ladder: MotionStagger.readyRiseIn)
        }
    }

    /// The provider and model line beneath the status, from the daemon's own
    /// snapshot. A home whose primary is not reported simply has no line.
    private var providerSummary: String? {
        guard let primary = model.settings.setupState.value?.providers.first(where: \.primary) else { return nil }
        guard let named = primary.defaultModel, !named.isEmpty else { return primary.label }

        return ProductStrings.middot(primary.label, named)
    }

    /// Two deep links into Settings, the advisory row where the daemon reported
    /// one, and the existing unchecked CLI row.
    ///
    /// The section label above them is gone: every row already names what it
    /// opens and carries its own chevron, so the eyebrow was a heading over
    /// three self-describing rows.
    ///
    /// They are grouped-form rows, which is the one grammar Connect your AI and
    /// About you keep: drawn bare on the window's ground they were the third
    /// container shape in three screens, and the `fermix` row beside them was a
    /// hand-drawn card in the middle of them.
    private var nextSteps: some View {
        Form {
            Section {
                if !model.readiness.advisory.isEmpty {
                    NextStepRow(title: ProductStrings[.readyAttention], symbol: "exclamationmark.circle") {
                        model.open(.surface(.home))
                    }
                }

                NextStepRow(title: ProductStrings[.readyNextChannels], symbol: "bubble.left.and.bubble.right") {
                    model.open(.settings(.channels))
                }

                NextStepRow(title: ProductStrings[.readyNextVoice], symbol: "waveform") {
                    model.open(.settings(.voice))
                }

                if model.cliPlan.offersRow {
                    CLIInstallRow(model: model)
                }
            }
        }
        .formStyle(.grouped)
        .assistantFormChrome(width: OnboardingMetrics.nextStepsWidth)
    }
}

/// One optional next step: a system symbol, a sentence, and the pane it opens.
///
/// The chevron is `chevron.forward` rather than `chevron.right`, which is the
/// direction-relative symbol the system's own disclosure rows draw and the only
/// one that mirrors under a right-to-left layout. The settings back control
/// takes `chevron.backward` for the same reason (redlines §5.8).
struct NextStepRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary.color)
                    .frame(width: SettingsRowMetrics.markSize)
                    .accessibilityHidden(true)

                Text(title)
                    .fermixType(Typography.style(.bodyCompact))
                    .foregroundStyle(Palette.ink.color)

                Spacer(minLength: Spacing.s)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint.color)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The `fermix` command row.
///
/// Four states, one per plan: a command to copy, a link this app already owns,
/// a link Homebrew owns, and a foreign file the app refuses to replace.
///
/// A grouped-form row like the rows above it. The card it used to draw made it
/// the one boxed thing in a column of bare rows, which is the container drift
/// the assistant's one grammar exists to stop.
struct CLIInstallRow: View {
    /// The row's title with the command itself in the mono face (redlines
    /// §5.5). The sentence is the catalogue's; only the face of the one token
    /// inside it belongs to this row.
    static var title: AttributedString {
        var text = AttributedString(ProductStrings[.readyCLITitle])
        guard let range = text.range(of: CLILinkPlanner.commandName) else { return text }

        text[range].font = Typography.style(.mono).font
        return text
    }

    @ObservedObject var model: OnboardingModel

    var body: some View {
        LabeledContent {
            if model.cliPlan.offersCommand, model.cliSelected {
                Button(ProductStrings[.readyCLICopy]) {
                    model.copyCLICommand()
                }

                Button(ProductStrings[.readyCLIVerify]) {
                    model.refreshCLIPlan()
                }
            }
        } label: {
            HStack(spacing: Spacing.s) {
                checkbox

                VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                    Text(CLIInstallRow.title)
                        .fermixType(Typography.style(.bodyCompact).weight(.semibold))
                        .foregroundStyle(Palette.ink.color)

                    Text(model.cliPlan.hint)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                }
            }
        }
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
                .font(.system(size: 15))
                .foregroundStyle(model.cliInstalled ? Palette.success.color : Palette.faint.color)
                .frame(width: SettingsRowMetrics.markSize, height: SettingsRowMetrics.markSize)
                .accessibilityHidden(true)
        }
    }
}
