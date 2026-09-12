import Combine
import Foundation
import Testing

@testable import FermixAppCore

@Suite("Sidebar selection feedback")
@MainActor
struct SidebarSelectionFeedbackTests {
    @Test("repeating the current settings selection publishes nothing")
    func repeatedSettingsSelectionIsIdle() async throws {
        let harness = try SettingsHarness()
        let column = SettingsPaneColumn(model: harness.model)
        var publications = 0
        let observation = harness.model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        column.selection.wrappedValue = harness.model.selectedPane
        column.selection.wrappedValue = harness.model.selectedPane
        column.selection.wrappedValue = nil

        #expect(publications == 0)
        await drainMainQueue()
        #expect(publications == 0)

        column.selection.wrappedValue = .integrations
        #expect(publications == 0, "List selection must not publish during its view update")
        #expect(harness.model.selectedPane != .integrations)
        await drainMainQueue()
        #expect(harness.model.selectedPane == .integrations)
        #expect(publications == 1)
    }

    @Test("rapid settings selections preserve their requested order")
    func rapidSettingsSelections() async throws {
        let harness = try SettingsHarness()
        let column = SettingsPaneColumn(model: harness.model)
        let original = harness.model.selectedPane
        var publications = 0
        let observation = harness.model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        column.selection.wrappedValue = .integrations
        column.selection.wrappedValue = .channels

        #expect(harness.model.selectedPane == original)
        #expect(publications == 0)
        await drainMainQueue()
        #expect(harness.model.selectedPane == .channels)
        #expect(publications == 2)
    }

    @Test("returning to the original pane does not lose the last queued selection")
    func returnToOriginalSettingsSelection() async throws {
        let harness = try SettingsHarness()
        let column = SettingsPaneColumn(model: harness.model)
        let original = harness.model.selectedPane
        var publications = 0
        let observation = harness.model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        column.selection.wrappedValue = .integrations
        column.selection.wrappedValue = original
        column.selection.wrappedValue = nil

        #expect(publications == 0)
        await drainMainQueue()
        #expect(harness.model.selectedPane == original)
        #expect(publications == 2)
    }

    @Test("repeating the current main route dispatches no navigation", arguments: [AppRoute.home, .doctor, .logs, .pet])
    func repeatedMainSelectionIsIdle(_ route: AppRoute) async throws {
        let harness = try RouterHarness()
        harness.model.route = route
        let commands = FakeCommandRouter()
        let view = mainView(harness, commands: commands)

        view.selection.wrappedValue = SidebarItem.selection(route: route)
        view.selection.wrappedValue = nil

        #expect(commands.performed.isEmpty)
        await drainMainQueue()
        #expect(commands.performed.isEmpty)
    }

    @Test("main sidebar navigation does not publish inside the List binding", arguments: [AppRoute.logs, .home])
    func queuedMainSelections(_ last: AppRoute) async throws {
        let harness = try RouterHarness()
        harness.model.route = .home
        let view = mainView(harness, commands: harness.router)
        var routes: [AppRoute] = []
        let observation = harness.model.$route.dropFirst().sink { routes.append($0) }
        defer { observation.cancel() }

        view.selection.wrappedValue = SidebarItem.selection(route: .doctor)
        view.selection.wrappedValue = SidebarItem.selection(route: last)

        #expect(routes.isEmpty, "routing must run outside the List update callback")
        #expect(harness.model.route == .home)
        await drainMainQueue()
        try await harness.coordinator.drainPendingWork()
        #expect(routes == [.doctor, last])
        #expect(harness.model.route == last)
    }

    @Test("the pinned Settings selection dispatches after the binding returns")
    func queuedSettingsRequest() async throws {
        let harness = try RouterHarness()
        let commands = FakeCommandRouter()
        let view = mainView(harness, commands: commands)

        view.selection.wrappedValue = SidebarItem.settingsIdentifier

        #expect(commands.performed.isEmpty)
        await drainMainQueue()
        #expect(commands.performed == [.openSettings])
    }

    @Test("the retired main List cannot navigate while Settings is showing")
    func settingsAndChangedRouteSelection() async throws {
        let harness = try RouterHarness()
        let commands = FakeCommandRouter()
        let view = mainView(harness, commands: commands)
        harness.presentation.enter(from: .home)

        view.selection.wrappedValue = SidebarItem.settingsIdentifier
        view.selection.wrappedValue = SidebarItem.selection(route: .home)
        view.selection.wrappedValue = SidebarItem.selection(route: .doctor)
        #expect(commands.performed.isEmpty)
        await drainMainQueue()
        #expect(commands.performed.isEmpty)

        harness.presentation.leave()
        view.selection.wrappedValue = SidebarItem.selection(route: .doctor)
        #expect(commands.performed.isEmpty)
        await drainMainQueue()
        #expect(commands.performed == [.showDoctor])
    }

    @Test("a queued Settings entry ignores a stale Home write from the replaced List")
    func settingsEntryIgnoresStaleHome() async throws {
        let harness = try RouterHarness()
        harness.model.route = .home
        let view = mainView(harness, commands: harness.router)

        view.selection.wrappedValue = SidebarItem.settingsIdentifier
        view.selection.wrappedValue = SidebarItem.selection(route: .home)

        #expect(!harness.presentation.isShowing)
        await drainMainQueue()
        try await harness.coordinator.drainPendingWork()
        #expect(harness.presentation.isShowing)
        #expect(harness.model.route == .home)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func mainView(_ harness: RouterHarness, commands: any CommandPerforming) -> MainWindowView {
        MainWindowView(
            model: harness.model,
            sidebar: harness.sidebar,
            surfaces: harness.surfaces,
            router: commands,
            presentation: harness.presentation,
            settings: harness.settings,
            leaveSettings: {},
            openRecovery: {},
            restart: {}
        )
    }
}
