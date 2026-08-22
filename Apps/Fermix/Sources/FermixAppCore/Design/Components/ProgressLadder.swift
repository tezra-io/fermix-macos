import SwiftUI

/// The activation ladder: three rows, one active, with the row state carried
/// by a shape and a word rather than by the spinner.
public struct ProgressLadder: View {
    private let model: ProgressLadderModel
    private let announcer: any AccessibilityAnnouncing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var announced: ProgressLadderModel?

    public init(model: ProgressLadderModel, announcer: any AccessibilityAnnouncing = AppKitAccessibilityAnnouncer()) {
        self.model = model
        self.announcer = announcer
    }

    public var body: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                            .overlay(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)
                    }

                    LadderRow(
                        row: row,
                        motion: Motion(reduceMotion: reduceMotion),
                        increaseContrast: contrast == .increased
                    )
                }
            }
        }
        .frame(width: WindowMetrics.ladderCardWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DesignComponent.progressLadder.accessibilityIdentifier)
        .onAppear { announce() }
        .onChange(of: model) { announce() }
    }

    /// Focus stays on the window for the whole masked boot, so a row that
    /// changed is spoken rather than left to be discovered.
    private func announce() {
        for sentence in LadderAnnouncement.sentences(from: announced, to: model) {
            announcer.announce(sentence)
        }

        announced = model
    }
}

private struct LadderRow: View {
    let row: LadderRowModel
    let motion: Motion
    let increaseContrast: Bool

    @State private var spinnerAngle: Double = 0
    @State private var sheenOffset: Double = -1.2

    private var pendingRing: Color {
        Palette.hairline(.strong, increaseContrast: increaseContrast).color
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            // The marker is rebuilt per state so the spinner-to-check swap is a
            // transition the stage-advance spring can overshoot through: the
            // 320ms pop is the ladder's signature moment.
            marker
                .id(row.state)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .animation(motion.animation(.stageAdvance), value: row.state)

            Text(row.title)
                .fermixType(Typography.style(.bodyCompact).weight(.medium))
                .foregroundStyle(row.state == .pending ? Palette.faint.color : Palette.ink.color)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(sheen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .onAppear(perform: startLoops)
    }

    @ViewBuilder
    private var marker: some View {
        switch row.state {
        case .done:
            ZStack {
                Circle().fill(Palette.accent.color)
                FermixCheckShape()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 12)
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

        case .active:
            ZStack {
                Circle()
                    .strokeBorder(pendingRing, lineWidth: 2.5)
                FermixArcShape()
                    .stroke(Palette.accent.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(spinnerAngle))
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

        case .pending:
            Circle()
                .strokeBorder(pendingRing, lineWidth: 2)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }

    /// The sweep across an active row. Decorative: the row already says
    /// "in progress" to VoiceOver and draws an arc for everyone else.
    @ViewBuilder
    private var sheen: some View {
        if row.state == .active, !motion.isSuppressed(.sheenSweep) {
            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.30),
                        .init(color: Palette.sheen.color, location: 0.50),
                        .init(color: .clear, location: 0.70)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width)
                .offset(x: sheenOffset * proxy.size.width)
            }
            .accessibilityHidden(true)
        }
    }

    private func startLoops() {
        if row.state == .active, let spin = motion.animation(.ladderSpinner) {
            withAnimation(spin) { spinnerAngle = 360 }
        }

        if row.state == .active, let sweep = motion.animation(.sheenSweep) {
            withAnimation(sweep) { sheenOffset = 2.4 }
        }
    }
}

/// The progress-dot zone at the foot of every onboarding screen.
public struct ProgressDots: View {
    private let model: ProgressDotsModel

    @Environment(\.colorSchemeContrast) private var contrast

    public init(model: ProgressDotsModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: ProgressDotMetrics.gap) {
            ForEach(Array(model.states.enumerated()), id: \.offset) { _, state in
                Capsule()
                    .fill(color(for: state))
                    .frame(
                        width: state == .active ? ProgressDotMetrics.activeSize.width : ProgressDotMetrics.inactiveDiameter,
                        height: state == .active ? ProgressDotMetrics.activeSize.height : ProgressDotMetrics.inactiveDiameter
                    )
            }
        }
        .frame(height: WindowMetrics.progressDotZoneHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityIdentifier(DesignComponent.progressDots.accessibilityIdentifier)
    }

    private func color(for state: ProgressDotsModel.DotState) -> Color {
        switch state {
        case .active: return Palette.accent.color
        case .done: return Palette.dotDone.color
        case .pending: return Palette.hairline(.strong, increaseContrast: contrast == .increased).color
        }
    }
}
