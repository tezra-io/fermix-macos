import Foundation
import Testing

@testable import FermixAppCore

/// The menu-bar panel, as a model: three groups, one row per action, and a
/// header that states the condition in words so nothing is carried by the
/// glyph's colour alone.
@Suite("Menu bar panel")
struct MenuBarPanelTests {
    private func model(
        glyph: MenuBarGlyphState = .running,
        uptimeSeconds: Int? = 3 * 86_400,
        petShown: Bool = true,
        serviceEnabled: Bool = true
    ) -> MenuPanelModel {
        MenuPanelModel(
            glyph: glyph,
            uptimeSeconds: uptimeSeconds,
            version: "0.1.0",
            petShown: petShown,
            serviceEnabled: serviceEnabled
        )
    }

    @Test("the panel is the redline's three groups")
    func threeGroups() {
        let panel = model()

        #expect(panel.groups.count == 3)
        #expect(panel.groups[0].rows.map(\.action) == [.openFermix, .setup, .runDoctor])
        #expect(panel.groups[1].rows.map(\.action) == [.restartDaemon, .togglePet, .pauseNotifications, .toggleService])
        #expect(panel.groups[2].rows.map(\.action) == [.checkForUpdates, .quit])
    }

    /// A row added later must join a group rather than becoming unreachable.
    @Test("every action appears exactly once")
    func everyActionAppearsOnce() {
        let actions = model().groups.flatMap { $0.rows.map(\.action) }

        #expect(Set(actions).count == actions.count)
        #expect(Set(actions) == Set(MenuAction.allCases))
    }

    @Test("open Fermix keeps its command shortcut and no other row takes one")
    func onlyOpenHasAShortcut() {
        let rows = model().groups.flatMap(\.rows)

        #expect(rows.first { $0.action == .openFermix }?.shortcut == "o")
        #expect(rows.filter { $0.shortcut != nil }.count == 1)
    }

    /// M34 §4 bans Start and Stop for the durable service, in the menu as
    /// everywhere else.
    @Test("the service row says enable or disable, never start or stop")
    func serviceRowWording() {
        let enabled = model(serviceEnabled: true).groups[1].rows.first { $0.action == .toggleService }
        let disabled = model(serviceEnabled: false).groups[1].rows.first { $0.action == .toggleService }

        #expect(enabled?.title == ProductStrings[.serviceDisable])
        #expect(disabled?.title == ProductStrings[.serviceEnable])
    }

    @Test("the pet row reports whether the pet is on screen")
    func petRowHint() {
        #expect(model(petShown: true).groups[1].rows[1].hint == ProductStrings[.menuShowPetHint])
        #expect(model(petShown: false).groups[1].rows[1].hint == nil)
    }

    /// Quitting the GUI sends no daemon lifecycle command, and the row says so
    /// in line rather than in a dialog after the fact.
    @Test("quit states the daemon consequence in line")
    func quitStatesTheConsequence() {
        let quit = model().groups[2].rows.last

        #expect(quit?.title == ProductStrings[.menuQuit])
        #expect(quit?.hint == ProductStrings[.menuQuitHint])
    }

    @Test("the header states running, starting, or attention in words")
    func headerStatesTheCondition() {
        #expect(model(glyph: .running).stateText == ProductStrings[.homeStatusRunning])
        #expect(model(glyph: .starting).stateText == ProductStrings[.menuStateStarting])
        #expect(model(glyph: .attention).stateText == ProductStrings[.menuStateAttention])
    }

    @Test("the header carries a coarse uptime beside the state")
    func headerCarriesUptime() {
        #expect(model(uptimeSeconds: 3 * 86_400).statusLine == "Running · 3 days")
        #expect(model(uptimeSeconds: nil).statusLine == "Running")
    }

    /// A glyph state must never be the only carrier of the condition: attention
    /// draws a badge shape as well as saying so in the header.
    @Test("the attention state is a badge shape as well as a word")
    func attentionIsShapeAndWord() {
        #expect(MenuBarGlyphState.attention.showsBadge)
        #expect(MenuBarGlyphState.running.showsBadge == false)
        #expect(model(glyph: .attention).stateText.isEmpty == false)
    }

    @Test("the glyph state follows the service and daemon condition")
    func glyphStateFollowsTheDaemon() {
        #expect(MenuBarGlyphState(daemon: .running, hasAttention: false) == .running)
        #expect(MenuBarGlyphState(daemon: .starting, hasAttention: false) == .starting)
        #expect(MenuBarGlyphState(daemon: .stopped, hasAttention: false) == .attention)
        #expect(MenuBarGlyphState(daemon: .running, hasAttention: true) == .attention)
    }

    @Test("the panel is the published 300 point width")
    func panelWidth() {
        #expect(WindowMetrics.popoverWidth == 300)
    }
}

/// Where the panel reads its facts. Home resolves uptime from the daemon's own
/// `overview`, and the panel reads that resolution rather than a second one, so
/// the two surfaces cannot disagree about how much the app knows.
@Suite("Menu panel source")
@MainActor
struct MenuPanelSourceTests {
    @Test("the panel header carries the uptime Home is already showing")
    func panelReadsHomesUptime() throws {
        let overview = try ManagementValueFixture.overview(uptimeMs: 3 * 86_400 * 1_000)
        let snapshot = HomeSnapshot(
            hello: try ManagementValueFixture.hello(),
            overview: overview,
            serviceEnabled: true,
            update: .unknown
        )
        let model = AppModel()
        model.daemon = .running

        let source = MenuPanelSource(
            model: model,
            version: "0.1.0",
            uptimeSeconds: { snapshot.uptimeSeconds }
        )

        #expect(snapshot.uptimeSeconds == 3 * 86_400)
        #expect(source.panel().statusLine == "Running · 3 days")
    }

    /// A daemon that has not reported an uptime has none to show. The header
    /// says the state and stops rather than inventing a duration.
    @Test("a daemon with no reported uptime leaves the header at its state")
    func panelWithoutUptime() {
        let model = AppModel()
        model.daemon = .running

        let source = MenuPanelSource(model: model, version: "0.1.0", uptimeSeconds: { nil })

        #expect(source.panel().statusLine == "Running")
    }
}
