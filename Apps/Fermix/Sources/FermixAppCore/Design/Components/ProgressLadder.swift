import SwiftUI

/// A native progress checklist. Step state remains available as text and
/// announcements, with a system indicator for the current step.
public struct ProgressLadder: View {
    private let model: ProgressLadderModel
    private let announcer: any AccessibilityAnnouncing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var announced: ProgressLadderModel?

    public init(model: ProgressLadderModel, announcer: any AccessibilityAnnouncing = AppKitAccessibilityAnnouncer()) {
        self.model = model
        self.announcer = announcer
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                LadderRow(row: row, reduceMotion: reduceMotion)
            }
        }
        .frame(maxWidth: WindowMetrics.ladderMaxWidth)
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
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            marker
                .frame(width: SettingsRowMetrics.markSize, height: SettingsRowMetrics.markSize)
                .accessibilityHidden(true)

            Text(row.title)
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(row.state == .pending ? Palette.secondary.color : Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
    }

    @ViewBuilder
    private var marker: some View {
        switch row.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.accent.color)
        case .active:
            if reduceMotion {
                Image(systemName: "circle.dotted").foregroundStyle(Palette.accent.color)
            } else {
                ProgressView().controlSize(.small)
            }
        case .pending:
            Image(systemName: "circle").foregroundStyle(Palette.secondary.color)
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
