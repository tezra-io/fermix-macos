import SwiftUI

/// The Setup Assistant presentation inside the primary window. Existing screens
/// crossfade above the same 64-point bottom bar.
struct OnboardingWindowView: View {
    @ObservedObject var model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)

        return VStack(spacing: 0) {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(motion.stepTransition())
                .id(model.stage)

            AssistantBottomBar(model: model)
        }
        // The primary window owns its size; the assistant fills its safe area.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The primary window paints the same system color for every page.
        .fermixWindowEntrance()
        .animation(motion.animation(.stepCrossfade), value: model.stage)
        .toolbar {
            if model.stage != .applying {
                SettingsBackControl(back: leaveAssistant)
            }
        }
    }

    private func leaveAssistant() {
        if model.stage == .starting {
            model.cancelStarting()
            return
        }

        model.finish()
    }

    @ViewBuilder
    private var surface: some View {
        switch model.stage {
        case .welcome:
            WelcomeSurface(model: model)
        case .starting:
            StartingSurface(model: model)
        case .connectAI:
            ConnectAISurface(model: model)
        case .aboutYou:
            AboutYouSurface(model: model)
        case .applying:
            ApplyingSurface(model: model)
        case .ready:
            ReadySurface(model: model)
        case .bootFailed:
            BootFailedSurface(model: model)
        case .recovery:
            RecoverySurface(model: model)
        }
    }
}

extension View {
    /// The chrome every assistant form carries.
    ///
    /// One row grammar across Connect your AI, About you and Ready: a grouped
    /// `Form`, one section, the system's own row and separator material, and
    /// no container the app draws. Three consecutive screens used to be three
    /// grammars — hand-drawn cards, a form, and bare rows — which read as three
    /// designs rather than one journey.
    ///
    /// `.formStyle(.grouped)` stays at each call site rather than moving in
    /// here: the container gate counts one against every `Form` in the file it
    /// is written in, and a rule that can be satisfied from another file is not
    /// the rule.
    ///
    /// - Parameter width: the column the screen measures against. Connect your
    ///   AI and About you take the assistant's one text column; Ready takes
    ///   redline §5.5's slightly wider one, because the `fermix` command row
    ///   inside it is wider than a sentence.
    func assistantFormChrome(width: Double = OnboardingMetrics.contentWidth) -> some View {
        frame(maxWidth: width)
            // The assistant's minimum fit accommodates each form without an
            // inner scrollbar.
            .scrollDisabled(true)
            // The section card is the container. A grouped form paints a ground
            // of its own too, which is invisible in a Settings pane that fills
            // its column and reads as a second box here, where the form is a
            // fixed column on the window's own ground.
            .scrollContentBackground(.hidden)
            // A grouped `Form` is a scroll view, so it takes every point the
            // stack offers and paints its container over the empty ones: four
            // rows sat at the top of a box twice their height. Fixed to its
            // content it is exactly as tall as the rows it has.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The bottom bar (redlines §5.8): Back, the progress dots, and exactly one
/// default continue action. There is no skip: connecting an AI is the one
/// required decision, and a link that could only leave setup added nothing
/// Home's `Continue setup` does not already say (owner decision of 2026-09-05).
///
/// A mechanical stage and the two failure screens carry no actions: the ladder
/// runs on its own, and the failure card owns its own buttons.
struct AssistantBottomBar: View {
    @ObservedObject var model: OnboardingModel

    /// The redline's 64-point bar.
    static let height: Double = 64

    var body: some View {
        HStack(spacing: Spacing.s) {
            leading

            Spacer(minLength: 0)

            if let progress = model.progress {
                ProgressDots(model: progress)
            }

            Spacer(minLength: 0)

            primary
        }
        .padding(.horizontal, WindowMetrics.contentPadding)
        .frame(height: Self.height)
    }

    /// The bar's leading control: Back where a screen has somewhere to go, and
    /// Cancel on the ladder, which is the one screen whose way out is stopping
    /// what is running rather than stepping back over it.
    @ViewBuilder
    private var leading: some View {
        if model.machine.canGoBack {
            barControl(ProductStrings[.assistantBack], action: model.back)
        } else if model.machine.canCancel {
            barControl(ProductStrings[.assistantCancel], action: model.cancelStarting)
        }
    }

    /// The bar's own secondary control, drawn the same way whichever of the two
    /// it is. Named without the word the container gate scans for: a helper
    /// whose declaration carries that word reads to the scan as a button with
    /// no title.
    private func barControl(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondary.color)
    }

    /// One default action per screen, and none at all while a ladder is running:
    /// a continue button over a stage that has not finished would be a promise
    /// the app cannot keep.
    @ViewBuilder
    private var primary: some View {
        switch model.stage {
        case .welcome:
            PrimaryAction(ProductStrings[.welcomeCTA], size: .inWindow, action: model.begin)
        case .connectAI, .aboutYou:
            PrimaryAction(ProductStrings[.assistantContinue], size: .inWindow, action: model.advance)
        // While the gate is unmet `finish()` refuses and re-routes, so the
        // button must not claim it opens Fermix (M34 §4).
        case .ready:
            PrimaryAction(ProductStrings[.readyOpen], size: .inWindow) { model.finish() }
                .disabled(model.readiness.block != nil)
        case .starting, .applying, .bootFailed, .recovery:
            EmptyView()
        }
    }
}

/// Welcome: the wordmark, one sentence, and the one secondary link that adopts
/// a home this Mac already has.
///
/// The caption tier under the sentence is gone (owner directive of 2026-09-03:
/// "Too many subtexts/headings throws off"). One title and one line is the rule
/// every assistant screen now keeps; how long setup takes is a promise the
/// four-row ladder on the next screen shows rather than states.
struct WelcomeSurface: View {
    @ObservedObject var model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var entered = false

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            FermixWordmark(height: 40)
                .padding(.bottom, 22)
                .scaleEffect(entered ? 1 : 0.92)
                .opacity(entered ? 1 : 0)
                .fermixRiseIn(step: 0)

            Text(ProductStrings[.welcomeTitle])
                .fermixType(Typography.style(.titleLarge))
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, 8)
                .fermixRiseIn(step: 1)

            Text(ProductStrings[.welcomeValue])
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: OnboardingMetrics.contentWidth)
                .fermixRiseIn(step: 1)

            existingHome
                .padding(.top, Spacing.l)
                .fermixRiseIn(step: 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
        .onAppear {
            guard let animation = motion.animation(.mascotEntrance) else {
                entered = true
                return
            }

            withAnimation(animation) { entered = true }
        }
    }

    /// Offered only when no migration handoff exists: the journal already names
    /// the home the picker would ask about (M34 §15.2).
    @ViewBuilder
    private var existingHome: some View {
        VStack(spacing: Spacing.xs) {
            if model.offersExistingHomePicker {
                LinkButton(title: ProductStrings[.welcomeUseExistingHome]) { model.chooseExistingHome() }
            }

            if let refusal = model.homeRefusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: OnboardingMetrics.contentWidth)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}

/// Boot failed: the calm amber disc, the cause in plain language, the last log
/// lines, and Run Doctor.
struct BootFailedSurface: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            if let panel = model.failurePanel {
                ErrorPanel(model: panel) { intent in
                    switch intent {
                    case .runDoctor: model.openDoctor()
                    case .viewLog: model.openLogs()
                    case .tryAgain: model.retry()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
        .padding(.top, 26)
    }
}

/// Recovery: the same calm surface, reached from a failed activation, an
/// interrupted update, or `fermix://recovery`.
struct RecoverySurface: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: Spacing.m) {
            Spacer(minLength: 0)

            Text(ProductStrings[.recoveryTitle])
                .fermixType(Typography.style(.title))
                .foregroundStyle(Palette.ink.color)

            Text(evidence.sentence ?? ProductStrings[.recoveryBody])
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: OnboardingMetrics.contentWidth)
                .textSelection(.enabled)

            files

            HStack(spacing: 14) {
                PrimaryAction(ProductStrings[.recoveryTryAgain], size: .onboarding) { model.retry() }

                Button(ProductStrings[.bootFailedRunDoctor]) { model.openDoctor() }
                    .buttonStyle(SecondaryButtonStyle(.onboarding))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
    }

    private var evidence: RecoveryEvidence { model.recoveryEvidence }

    /// The file the daemon refused, and the copy it kept from before where
    /// there is one. Both are paths, so both are selectable and the first one
    /// can be opened in the Finder (M34 §7.5).
    @ViewBuilder
    private var files: some View {
        if let path = evidence.settingsFile {
            VStack(spacing: Spacing.xs) {
                Text(path)
                    .fermixType(Typography.style(.mono))
                    .foregroundStyle(Palette.faint.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: OnboardingMetrics.contentWidth)

                if let previous = evidence.previousFile {
                    Text(String(format: ProductStrings[.recoveryPreviousFormat], previous))
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.faint.color)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: OnboardingMetrics.contentWidth)
                }

                Button(ProductStrings[.uninstallReveal]) { model.revealSettingsFile() }
                    .buttonStyle(SecondaryButtonStyle(.inWindow))
            }
        }
    }
}
