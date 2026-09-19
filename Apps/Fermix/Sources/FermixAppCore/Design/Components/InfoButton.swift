import SwiftUI

/// The info control a settings row draws beside its label.
///
/// A footer is the one line that always sits under a control. Some rows owe a
/// paragraph instead: the Venice model list spells every model `Private`,
/// `Anonymized` or `Private (TEE)`, and what those three words mean is three
/// sentences that would sit under a row on every visit after the first. The
/// daemon publishes that paragraph as the row's `info`, and this is the control
/// that keeps it folded away until it is asked for.
///
/// A `Button` with a popover rather than `.help()`: a tooltip is reachable by
/// hover alone, so the text would exist for a mouse and for nobody else. This
/// is in the keyboard focus order, and VoiceOver reads the control by the row
/// it belongs to and then the paragraph inside the popover.
public struct InfoButton: View {
    private let text: String
    private let subject: String

    @State private var shown = false

    /// - Parameter subject: the row's own label, which is what makes the
    ///   control's spoken name say which setting it explains. A bare `About
    ///   this setting` on a form of twelve rows names none of them.
    public init(text: String, subject: String) {
        precondition(!text.isEmpty, "an info control carries the explanation it opens")
        precondition(!subject.isEmpty, "an info control names the row it explains")

        self.text = text
        self.subject = subject
    }

    public var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(Palette.secondary.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsRowInfo], subject))
        .accessibilityIdentifier(DesignComponent.infoButton.accessibilityIdentifier)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: SettingsRowMetrics.infoPopoverWidth, alignment: .leading)
                .padding(Spacing.s)
                .accessibilityLabel(text)
        }
    }
}

/// A row's label with its info control beside it, where the daemon published
/// one.
///
/// One view rather than an `HStack` per control: a row's label is drawn by
/// whichever control the row resolved to, and an affordance written out at each
/// of those sites is an affordance that eventually differs at one of them.
public struct DescriptorRowLabel: View {
    private let label: String
    private let info: String?

    public init(_ label: String, info: String?) {
        self.label = label
        self.info = info
    }

    public var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text(label)

            if let info, !info.isEmpty {
                InfoButton(text: info, subject: label)
            }
        }
    }
}
