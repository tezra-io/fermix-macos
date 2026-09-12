import SwiftUI

/// The recovery surface: an amber-outline disc, plain language, the last log
/// lines, and one primary next action.
///
/// No red flood anywhere. The panel reads what happened, what is untouched,
/// and the one thing to do, which is the shape every Fermix error takes.
public struct ErrorPanel: View {
    private let model: ErrorPanelModel
    /// One entry point for all three controls. The card decides which intent
    /// leads from the cause; the surface only says what each intent does, so
    /// the two cannot disagree about which button is which.
    private let perform: (ErrorPanelIntent) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    public init(model: ErrorPanelModel, perform: @escaping (ErrorPanelIntent) -> Void) {
        self.model = model
        self.perform = perform
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
                // The body names what to do, and on the coexistence refusals it
                // names commands and paths. A sentence nobody can select is a
                // sentence nobody can act on.
                .textSelection(.enabled)
                .padding(.bottom, 26)

            evidence

            commands

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

    /// What the refusal found on this Mac, under the sentence that describes it.
    @ViewBuilder
    private var evidence: some View {
        if !model.evidence.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.evidence, id: \.self) { line in
                    Text(line)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.faint.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 470, alignment: .leading)
            .padding(.bottom, 20)
        }
    }

    /// The lines the sentence names, each with one way onto the pasteboard.
    @ViewBuilder
    private var commands: some View {
        if !model.commands.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(model.commands, id: \.self) { command in
                    commandRow(command)
                }
            }
            .frame(width: 470, alignment: .leading)
            .padding(.bottom, 26)
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(command)
                .fermixType(Typography.style(.mono))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)

            Spacer(minLength: Spacing.s)

            Button(ProductStrings[.coexistenceCopyCommand]) { Clipboard.write(command) }
                .accessibilityLabel(
                    ProductStrings.commaPair(ProductStrings[.coexistenceCopyCommand], command)
                )
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.cardFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
    }

    /// The last log lines. M34 §6 deleted the card and the divider this drew,
    /// so the header sits above the lines on the surface's own ground.
    @ViewBuilder
    private var logCard: some View {
        if !model.logLines.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(model.logHeader)
                    .fermixType(Typography.sectionLabel)
                    .foregroundStyle(Palette.faint.color)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .fermixType(Typography.style(.monoLog))
                            .foregroundStyle(Palette.secondary.color)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 470, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.logHeader)
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.s + 2) {
            PrimaryAction(model.primary.title, size: .onboarding) { perform(model.primary) }

            Button(model.secondary.title) { perform(model.secondary) }
                .buttonStyle(SecondaryButtonStyle(.onboarding))

            LinkButton(title: model.ghost.title) { perform(model.ghost) }
        }
    }
}
