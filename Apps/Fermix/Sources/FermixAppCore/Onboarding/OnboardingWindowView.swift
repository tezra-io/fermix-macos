import SwiftUI

/// The onboarding window: the backdrop, the fixed 800 by 520 glass card, the
/// step that is showing, and the progress dots.
///
/// The window never moves between steps. Each surface crossfades in place,
/// which is what the redline's step-crossfade rule means and what keeps the
/// journey from feeling like five separate windows.
struct OnboardingWindowView: View {
    @ObservedObject var model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)

        return ZStack {
            BackdropView(model.stage == .welcome ? .welcome : .onboarding)

            GlassChrome(.required(for: .onboarding)) {
                VStack(spacing: 0) {
                    titlebar

                    surface
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(motion.stepTransition())
                        .id(model.stage)

                    dots
                }
            }
            .frame(
                width: WindowMetrics.onboardingSize.width,
                height: WindowMetrics.onboardingSize.height
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
            .fermixWindowEntrance()
        }
        .frame(
            width: WindowMetrics.onboardingSize.width,
            height: WindowMetrics.onboardingSize.height
        )
        .animation(motion.animation(.stepCrossfade), value: model.stage)
    }

    /// Traffic lights only. The chip is Activate's alone.
    private var titlebar: some View {
        HStack {
            Spacer(minLength: 0)

            if model.stage == .activate {
                ActivationMirrorChip().padding(.trailing, Spacing.m)
            }
        }
        .frame(height: WindowMetrics.titlebarHeight)
    }

    @ViewBuilder
    private var surface: some View {
        switch model.stage {
        case .welcome:
            WelcomeSurface(begin: model.begin)
        case .activate:
            ActivateSurface(ladder: model.ladder)
        case .bootFailed:
            BootFailedSurface(model: model)
        case .configureAI:
            ConnectAISurface(model: model)
        case .configureChannel:
            ConnectChannelSurface(model: model)
        case .configureSetup:
            SetupSurfaceView(model: model.setup)
        case .ready:
            ReadySurface(model: model)
        case .recovery:
            RecoverySurface(model: model)
        }
    }

    @ViewBuilder
    private var dots: some View {
        if let progress = model.progress {
            ProgressDots(model: progress)
        } else {
            Color.clear.frame(height: WindowMetrics.progressDotZoneHeight)
        }
    }
}

/// Welcome: the mascot, the wordmark, one sentence, and one call to action.
///
/// §5.1 brings the blocks in on a ladder rather than together: the mascot lands
/// first on its own curve, then the wordmark, the sentence, and the action
/// block at 120, 200, and 300 milliseconds.
struct WelcomeSurface: View {
    let begin: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var entered = false

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            MascotArtwork(size: 108)
                .padding(.bottom, 18)
                .scaleEffect(entered ? 1 : 0.92)
                .opacity(entered ? 1 : 0)

            FermixWordmark(height: 30)
                .padding(.bottom, 22)
                .fermixRiseIn(step: 0)

            Text(ProductStrings[.welcomeValue])
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fermixRiseIn(step: 1)

            VStack(spacing: 0) {
                PrimaryAction(ProductStrings[.welcomeCTA], size: .onboarding, action: begin)

                Text(ProductStrings[.welcomeCaption])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.faint.color)
                    .padding(.top, 14)
            }
            .padding(.top, Spacing.xl)
            .fermixRiseIn(step: 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 96)
        .onAppear {
            guard let animation = motion.animation(.mascotEntrance) else {
                entered = true
                return
            }

            withAnimation(animation) { entered = true }
        }
    }
}

/// Activate: the orb, the headline that tracks the active row, and the ladder.
struct ActivateSurface: View {
    let ladder: ProgressLadderModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ActivationOrb().padding(.bottom, 26)

            Text(ladder.headline)
                .fermixType(Typography.style(.title))
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.updatesFrequently)

            Text(ProductStrings[.activateCaption])
                .fermixType(Typography.style(.callout).weight(.regular))
                .foregroundStyle(Palette.faint.color)
                .padding(.bottom, 30)

            ProgressLadder(model: ladder)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120)
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
                ErrorPanel(
                    model: panel,
                    primaryAction: { model.openDoctor() },
                    secondaryAction: { model.openLogs() },
                    ghostAction: { model.retry() }
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120)
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

            Text(ProductStrings[.recoveryBody])
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HStack(spacing: 14) {
                PrimaryAction(ProductStrings[.recoveryTryAgain], size: .onboarding) { model.retry() }

                Button(ProductStrings[.bootFailedRunDoctor]) { model.openDoctor() }
                    .buttonStyle(SecondaryButtonStyle(.onboarding))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120)
    }
}

/// The mascot, at whatever size a warm moment calls for.
struct MascotArtwork: View {
    let size: Double

    var body: some View {
        Group {
            if let image = PetAssetCache.shared.image(PetExpression.idle.layerAssetName(.body)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                FermixBoltShape().fill(Palette.accent.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The wordmark.
///
/// The redline's inline SVG letterforms with their two accent eye-dots are an
/// approved asset this build does not have, and drawing an approximation of a
/// brand mark is the same mistake as fabricating a vendor monogram. The product
/// name is set in the ramp's own semibold instead, at the published height.
struct FermixWordmark: View {
    let height: Double

    var body: some View {
        Text(ProductStrings[.menuTitle])
            .font(.system(size: height * 0.86, weight: .semibold))
            .foregroundStyle(Palette.ink.color)
            .frame(height: height)
            .accessibilityLabel(ProductStrings[.menuTitle])
    }
}
