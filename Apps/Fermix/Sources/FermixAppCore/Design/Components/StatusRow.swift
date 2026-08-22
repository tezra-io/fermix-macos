import SwiftUI

/// One Runtime or Attention row: an icon tile, a title, a detail, and an
/// optional trailing fact.
public struct StatusRow: View {
    private let model: StatusRowModel

    @Environment(\.colorSchemeContrast) private var contrast

    public init(model: StatusRowModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 13) {
            iconTile

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .fermixType(Typography.style(.callout).weight(.medium))
                    .foregroundStyle(Palette.ink.color)

                Text(model.detail)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.faint.color)
            }

            Spacer(minLength: Spacing.s)

            if let meta = model.meta, !meta.isEmpty {
                Text(meta)
                    .fermixType(Typography.style(.monoLog))
                    .foregroundStyle(Palette.faint.color)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.accessibilityValue)
        .accessibilityIdentifier(DesignComponent.statusRow.accessibilityIdentifier)
    }

    private var iconTile: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.iconTile, style: .continuous)

        return Image(systemName: model.systemImage)
            .font(.system(size: 15))
            .foregroundStyle(model.tone == .neutral ? Palette.secondary.color : model.tone.textColor.color)
            .frame(width: 30, height: 30)
            .background(shape.fill(Palette.chipFill.color))
            .overlay(
                shape.strokeBorder(
                    Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                    lineWidth: Stroke.hairline
                )
            )
            .accessibilityHidden(true)
    }
}

/// A status pill: a dot plus a word. The word is the state, so the dot is
/// decoration rather than the only signal.
public struct StatusPill: View {
    private let title: String
    private let tone: StatusTone

    @Environment(\.colorSchemeContrast) private var contrast

    public init(title: String, tone: StatusTone) {
        precondition(!title.isEmpty, "a status pill needs a title")

        self.title = title
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(title)
                .fermixType(Typography.style(.calloutSmall).weight(.medium))
                .foregroundStyle(labelColor)
        }
        .padding(.horizontal, 11)
        .frame(height: 24)
        .background(Capsule().fill(fill.color))
        .overlay(Capsule().strokeBorder(border.color, lineWidth: Stroke.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier(DesignComponent.statusPill.accessibilityIdentifier)
    }

    private var dotColor: Color {
        switch tone {
        case .pass: return Palette.success.color
        case .warn: return Palette.warning.color
        case .fail: return Palette.error.color
        case .neutral: return Palette.faint.color
        }
    }

    private var labelColor: Color {
        tone == .pass ? Palette.successText.color : tone.textColor.color
    }

    private var fill: ThemedColor {
        switch tone {
        case .pass: return Palette.successPillFill
        case .warn: return Palette.warnPillFill
        case .fail: return Palette.errorDiscFill
        case .neutral: return Palette.chipFill
        }
    }

    private var border: ThemedColor {
        switch tone {
        case .pass: return Palette.successPillBorder
        case .warn: return Palette.warnPillBorder
        case .fail: return Palette.errorDiscBorder
        case .neutral: return Palette.hairline(.standard, increaseContrast: contrast == .increased)
        }
    }
}

/// A Doctor letter-pill. Text only in a low-chroma tone; §5.9 forbids a flood
/// fill here, and the letters are what make the status readable without colour.
public struct LetterPill: View {
    private let badge: CheckBadge

    public init(badge: CheckBadge) {
        self.badge = badge
    }

    public var body: some View {
        Text(badge.letters)
            .fermixType(Typography.style(.caption).weight(.semibold).uppercased())
            .foregroundStyle(badge.tone.textColor.color)
            .accessibilityLabel(badge.letters)
            .accessibilityIdentifier(DesignComponent.letterPill.accessibilityIdentifier)
    }
}
