import SwiftUI

/// The recovery surface: an amber-outline disc, plain language, the last log
/// lines, and one primary next action.
///
/// No red flood anywhere. The panel reads what happened, what is untouched,
/// and the one thing to do, which is the shape every Fermix error takes.
public struct ErrorPanel: View {
    private let model: ErrorPanelModel
    private let primaryAction: () -> Void
    private let secondaryAction: () -> Void
    private let ghostAction: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        model: ErrorPanelModel,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void,
        ghostAction: @escaping () -> Void
    ) {
        self.model = model
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.ghostAction = ghostAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            disc.padding(.bottom, 22)

            Text(model.title)
                .fermixType(Typography.style(.title))
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, Spacing.xs)

            Text(model.body)
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.bottom, 26)

            logCard.padding(.bottom, 26)

            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DesignComponent.errorPanel.accessibilityIdentifier)
    }

    private var disc: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(Palette.error.color)
            .frame(width: 76, height: 76)
            .background(Circle().fill(Palette.errorDiscFill.color))
            .overlay(Circle().strokeBorder(Palette.errorDiscBorder.color, lineWidth: Stroke.hairline))
            .accessibilityHidden(true)
    }

    private var logCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.logHeader)
                    .fermixType(Typography.sectionLabel)
                    .foregroundStyle(Palette.faint.color)
                    .padding(.horizontal, Spacing.m)
                    .frame(height: 40, alignment: .leading)

                Divider().overlay(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .fermixType(Typography.style(.monoLog))
                            .foregroundStyle(Palette.secondary.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
            }
        }
        .frame(width: 470)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.logHeader)
    }

    private var actions: some View {
        HStack(spacing: Spacing.s + 2) {
            PrimaryAction(model.primaryAction, size: .onboarding, action: primaryAction)

            Button(model.secondaryAction, action: secondaryAction)
                .buttonStyle(SecondaryButtonStyle(.onboarding))

            LinkButton(title: model.ghostAction, action: ghostAction)
        }
    }
}
