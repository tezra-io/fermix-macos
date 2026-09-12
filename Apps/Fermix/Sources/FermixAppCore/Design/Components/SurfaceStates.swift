import SwiftUI

/// One failure state, shared by every surface that can be refused: what
/// happened, in the daemon's own words, and the one next action.
struct SurfaceFailure: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            Text(message)
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(actionTitle, action: action)
                .buttonStyle(SecondaryButtonStyle(.inWindow))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
