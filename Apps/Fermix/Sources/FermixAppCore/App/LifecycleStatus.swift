import SwiftUI

/// The window's own status sentence: a lifecycle transaction this app started,
/// said in the toolbar of whichever surface is showing (owner report of
/// 2026-09-20).
///
/// Progress at the point of action plus a sentence, with everything else left
/// readable. A blurred window under a spinner is not what this draws: the
/// window's contents are still true while the daemon restarts, a cover would
/// hide the context the person was in, and it would cost a compositing filter
/// for as long as the restart runs.
///
/// It hangs off the window rather than off each surface, because the window is
/// the one view that observes `AppModel` and spans Home, Doctor, Logs, Pet, the
/// update surface and the settings presentation alike. A sentence passed down
/// each surface's own toolbar would need every surface model to republish the
/// app's fact, and the two surfaces with no toolbar of their own would stay
/// silent.
struct LifecycleStatus: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content.toolbar {
            if let sentence = LifecycleActivity.toolbarSentence(for: model.transactionInFlight, on: model.route) {
                ToolbarStatus(text: sentence, showsProgress: true)
            }
        }
    }
}

extension View {
    /// Says what the app is doing to the background service, in this window's
    /// toolbar, for as long as it is doing it.
    func lifecycleStatus(of model: AppModel) -> some View {
        modifier(LifecycleStatus(model: model))
    }
}
