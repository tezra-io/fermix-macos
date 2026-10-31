import Foundation

/// Always On (M75): the pane is the engine's published descriptor rows under
/// `always_on`, the recovery snapshots' settings, and nothing of the app's
/// own. It is drawn only where the daemon lists `home.status` in its `hello`:
/// an engine from before Always On has neither the method nor the pane, and
/// the sidebar then lists no row and says nothing.
extension SettingsModel {
    public var drawsAlwaysOnPane: Bool {
        servedMethods.contains(.homeStatus)
    }

    /// Whether a route to Always On lands on Providers instead: on a daemon
    /// this window has read and found without the home. Before the methods
    /// are read, the route is taken and the gate decides as the window
    /// appears (`refreshAlwaysOnGate`).
    public func refusesAlwaysOnRoute() -> Bool {
        !servedMethods.isEmpty && !drawsAlwaysOnPane
    }

    /// A restored selection of the pane, on a daemon read and found without
    /// the home, goes back to the first pane, so the window never opens on
    /// nothing.
    func refreshAlwaysOnGate() {
        guard selectedPane == .alwaysOn, refusesAlwaysOnRoute() else { return }

        selectedPane = .providers
    }
}
