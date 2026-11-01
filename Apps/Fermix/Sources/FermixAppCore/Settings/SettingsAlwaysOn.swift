import Foundation

/// Always On (M75, Always On setup §8.3): the pane draws `home.status.summary`
/// (`AlwaysOnPane`) and sends every press as `home.act`, with the engine's
/// snapshot rows under `always_on` behind its Details. It is listed only
/// where the daemon lists `home.act` in its `hello`: an engine from before
/// the one Always On flow has no step the pane could send, and the sidebar
/// then lists no row and says nothing.
extension SettingsModel {
    public var drawsAlwaysOnPane: Bool {
        servedMethods.contains(.homeAct)
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
