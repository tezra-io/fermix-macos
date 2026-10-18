import SwiftUI

/// The two buttons a browser sign-in waits with, Cancel and Open the browser
/// again, for a provider and for a plugin or MCP server alike: one view, so
/// the two waits cannot draw them apart.
///
/// The app's monochrome capsules rather than the system's buttons, whose
/// default one filled with the accent and whose others took it as their label
/// colour: a primary action is the icon's ink, and the blue is kept for
/// switches, selection, focus and progress (owner, 2026-09-20).
struct SignInWaitActions: View {
    /// What is being signed in to, which the reopen button's spoken name
    /// carries.
    let label: String
    /// Whether Escape cancels. A page that answers the key itself while it
    /// waits passes false, so the key is answered once.
    let cancelTakesEscape: Bool
    /// Whether the run has published its page yet, which is what reopen opens.
    let canReopen: Bool
    let cancel: () -> Void
    /// Opens the run's page again, or nil where the run has none to open: a
    /// sign-in imported from another app.
    let reopen: (() -> Void)?

    var body: some View {
        Button(ProductStrings[.settingsSheetCancel], action: cancel)
            .buttonStyle(SecondaryButtonStyle(.row))
            .keyboardShortcut(cancelTakesEscape ? .cancelAction : nil)

        if let reopen {
            PrimaryAction(ProductStrings[.providerSignInReopen], size: .row, action: reopen)
                .disabled(!canReopen)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerSignInReopen], label))
        }
    }
}

/// The button an ended sign-in starts again with, in the same capsule as the
/// wait's Cancel.
struct SignInRetryAction: View {
    /// What is being signed in to, which the button's spoken name carries.
    let label: String
    let retry: () -> Void

    var body: some View {
        Button(ProductStrings[.providerSignInRetry], action: retry)
            .buttonStyle(SecondaryButtonStyle(.row))
            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.providerSignInRetry], label))
    }
}
