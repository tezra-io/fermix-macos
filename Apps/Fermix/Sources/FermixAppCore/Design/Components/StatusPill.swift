import SwiftUI

/// A status pill: a dot plus a word. The word is the state, so the dot is
/// decoration rather than the only signal.
///
/// The last one left is Ready's. M34 §6's container rule left the primary
/// window's rows to the system, and the decorated `StatusRow` that used to sit
/// beside this went with it.
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
