import SwiftUI

/// An empty section inside a `Form`: one centred caption line in the card the
/// section already draws, and no illustration. A whole surface with nothing on
/// it takes `SurfaceEmptyState` instead.
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

/// A whole surface with nothing on it: the system's own empty state.
///
/// macOS draws this shape itself, symbol and all, and Apple's apps use it for
/// exactly this case; the app's own one-line caption stays what an empty
/// *section* inside a `Form` draws, because a section is a box with a caption
/// in it rather than a surface.
public struct SurfaceEmptyState: View {
    private let model: EmptyStateModel
    /// The SF Symbol above the sentence. Named by the surface, because the
    /// symbol says what is missing and only the surface knows.
    private let symbol: String

    public init(model: EmptyStateModel, symbol: String) {
        precondition(!symbol.isEmpty, "a surface empty state needs a symbol")

        self.model = model
        self.symbol = symbol
    }

    public var body: some View {
        ContentUnavailableView(model.message, systemImage: symbol)
            .accessibilityIdentifier(DesignComponent.surfaceEmptyState.accessibilityIdentifier)
    }
}
