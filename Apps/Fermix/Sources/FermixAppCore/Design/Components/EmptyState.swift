import SwiftUI

/// An empty section: the same card, one centred caption line, no illustration.
public struct EmptyState: View {
    private let model: EmptyStateModel

    public init(model: EmptyStateModel) {
        self.model = model
    }

    public var body: some View {
        Text(model.message)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.faint.color)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.l)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityIdentifier(DesignComponent.emptyState.accessibilityIdentifier)
    }
}
