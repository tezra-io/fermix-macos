import AppKit
import Foundation
import Testing

@testable import FermixAppCore

/// The status item's menu (M34 §3.3). The popover is gone: what is left is a
/// real `NSMenu` whose first row states the condition in words, so nothing the
/// menu bar reports is carried by the glyph's colour alone.
@Suite("Status menu")
@MainActor
struct StatusMenuTests {
    private func source(
        daemon: DaemonCondition = .running,
        readiness: String = "ready",
        restartRequired: Bool = false,
        uptimeMs: Int = 8 * 60 * 1_000,
        unreachable: Bool = false
    ) throws -> StatusMenuSource {
        let model = AppModel()
        model.daemon = daemon

        let snapshot = unreachable
            ? HomeSnapshot.unreachable(attention: .unavailable("the socket is not there"))
            : HomeSnapshot(
                hello: try ManagementValueFixture.hello(),
                overview: try ManagementValueFixture.overview(
                    readiness: readiness,
                    restartRequired: restartRequired,
                    uptimeMs: uptimeMs
                ),
                attention: .rows([]),
                update: .unknown
            )

        return StatusMenuSource(model: model, snapshot: { snapshot })
    }

    /// The four state lines M34 §3.3 publishes, plus the starting one the glyph
    /// already had.
    @Test("the state line names the condition the daemon is actually in")
    func stateLines() throws {
        #expect(try source().line() == .running(uptimeSeconds: 480))
        #expect(try source().line().text == "Running for 8 minutes")
        #expect(try source(readiness: "setup_required").line() == .setupRequired)
        #expect(try source(restartRequired: true).line() == .restartPending)
        #expect(try source(daemon: .starting).line() == .starting)
        #expect(try source(daemon: .stopped).line() == .notRunning)
        #expect(try source(unreachable: true).line() == .notRunning)
    }

    /// A restart that is pending outranks an incomplete setup: it is the thing
    /// standing between the operator and the change they already made.
    @Test("a pending restart is named before an incomplete setup")
    func restartOutranksSetup() throws {
        #expect(try source(readiness: "setup_required", restartRequired: true).line() == .restartPending)
    }

    /// A daemon that reported no uptime has none to show. The line says the
    /// state and stops rather than inventing a duration.
    @Test("a daemon with no reported uptime leaves the line at its state")
    func runningWithoutUptime() throws {
        #expect(try source(uptimeMs: 0).line().text == "Running")
    }

    @Test("the state line is the first row, and it is disabled")
    func stateLineLeadsAndIsInert() throws {
        let controller = StatusMenuController(router: FakeCommandRouter(), source: try source())
        let menu = controller.menu()

        let first = try #require(menu.items.first)
        #expect(first.identifier == StatusMenuController.stateIdentifier)
        #expect(first.action == nil)
        #expect(first.title == "Running for 8 minutes")
        // The proposal line's place, empty and hidden while nothing waits.
        #expect(menu.items[1].identifier == StatusMenuController.proposalIdentifier)
        #expect(menu.items[1].isHidden)
        #expect(menu.items[2].isSeparatorItem)
    }

    // MARK: - Proposals waiting (M60 §4.7)

    private func controller(
        waiting: @escaping () -> [String],
        router: FakeCommandRouter? = nil,
        shown: @escaping (String) -> Void = { _ in }
    ) throws -> StatusMenuController {
        let model = AppModel()
        model.daemon = .running
        let snapshot = HomeSnapshot(
            hello: try ManagementValueFixture.hello(),
            overview: try ManagementValueFixture.overview(readiness: "ready", restartRequired: false, uptimeMs: 60_000),
            attention: .rows([]),
            update: .unknown
        )

        return StatusMenuController(
            router: router ?? FakeCommandRouter(),
            source: StatusMenuSource(model: model, snapshot: { snapshot }, proposals: { Self.line(waiting()) }),
            showProposal: shown
        )
    }

    /// The line a run of waiting proposals makes: their count, opening at
    /// the first.
    private static func line(_ waiting: [String]) -> StatusProposalLine? {
        waiting.first.map { StatusProposalLine(count: waiting.count, oldestProposalId: $0) }
    }

    // MARK: - The daemon's count (M60 §4.7)

    @Test("the proposal line is the daemon's count of proposals waiting, read with the list alone, opening at the oldest")
    func proposalLineReadsTheList() async throws {
        let gateway = FakeDaemonGateway()
        gateway.hello = try FakeDaemonGateway.fixtureResult(named: "hello", as: ManagementHello.self)
        gateway.cueProposalsResult = try Self.proposals(waiting: 3)
        let reader = StatusProposalReader(gateway: gateway, daemonAnswers: { true })

        await reader.refresh()

        let line = try #require(reader.line)
        #expect(line.count == 3, "the count is the list's own, not the length of the page it lists")
        #expect(line.oldestProposalId == "cpr_9f2c41d07a5e6b38c1d2e4f0")
        #expect(line.text == "3 tasks are waiting for your decision")
        #expect(gateway.cueProposalFilters == [.waiting])
        #expect(!gateway.calls.contains(.v2(.cuesStatus)), "the menu asks nothing of cues.status")
    }

    @Test("with the daemon not answering, the reader asks nothing, logs nothing, and draws no line")
    func proposalLineWhileTheDaemonIsDown() async throws {
        let gateway = FakeDaemonGateway()
        gateway.hello = try FakeDaemonGateway.fixtureResult(named: "hello", as: ManagementHello.self)
        let reader = StatusProposalReader(gateway: gateway, daemonAnswers: { false })

        await reader.refresh()

        #expect(reader.line == nil)
        #expect(gateway.calls.isEmpty, "a menu opened while Fermix is stopped reads nothing")
    }

    @Test("with nothing waiting there is no line, from the one read of the list")
    func proposalLineNothingWaiting() async throws {
        let gateway = FakeDaemonGateway()
        gateway.hello = try FakeDaemonGateway.fixtureResult(named: "hello", as: ManagementHello.self)
        gateway.cueProposalsResult = ManagementCueProposalList(proposals: [], waiting: 0)
        let reader = StatusProposalReader(gateway: gateway, daemonAnswers: { true })

        await reader.refresh()

        #expect(reader.line == nil)
        #expect(gateway.calls.filter { $0 == .v2(.cuesProposalsList) }.count == 1)
        #expect(!gateway.calls.contains(.v2(.cuesStatus)))
    }

    @Test("a daemon that does not list cues.proposals.list is never asked, and the menu draws no line")
    func proposalLineWithoutCues() async throws {
        let gateway = FakeDaemonGateway()
        gateway.hello = try ManagementValueFixture.hello()
        let reader = StatusProposalReader(gateway: gateway, daemonAnswers: { true })

        await reader.refresh()

        #expect(reader.line == nil)
        #expect(!gateway.calls.contains(.v2(.cuesProposalsList)))
        #expect(!gateway.calls.contains(.v2(.cuesStatus)))
    }

    @Test("the menu draws the line the reader last read, and picking it opens Chat at that card")
    func proposalLineFromTheReader() async throws {
        let gateway = FakeDaemonGateway()
        gateway.hello = try FakeDaemonGateway.fixtureResult(named: "hello", as: ManagementHello.self)
        let reader = StatusProposalReader(gateway: gateway, daemonAnswers: { true })
        await reader.refresh()
        let router = FakeCommandRouter()
        var shown: [String] = []
        let model = AppModel()
        model.daemon = .running
        let snapshot = HomeSnapshot(
            hello: try ManagementValueFixture.hello(),
            overview: try ManagementValueFixture.overview(readiness: "ready", restartRequired: false, uptimeMs: 60_000),
            attention: .rows([]),
            update: .unknown
        )
        let controller = StatusMenuController(
            router: router,
            source: StatusMenuSource(model: model, snapshot: { snapshot }, proposals: { reader.line }),
            showProposal: { shown.append($0) }
        )
        let row = try proposalRow(controller.menu())

        #expect(row.title == "A task is waiting for your decision")
        let action = try #require(row.action)
        _ = (row.target as? NSObject)?.perform(action, with: row)
        #expect(router.performed == [.showChat])
        #expect(shown == ["cpr_9f2c41d07a5e6b38c1d2e4f0"])
    }

    /// The golden list of proposals waiting, with the count a case needs.
    private static func proposals(waiting: Int) throws -> ManagementCueProposalList {
        let golden = try FakeDaemonGateway.fixtureResult(named: "cues_proposals_list", as: ManagementCueProposalList.self)

        return ManagementCueProposalList(proposals: golden.proposals, waiting: waiting)
    }

    private func proposalRow(_ menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.items.first { $0.identifier == StatusMenuController.proposalIdentifier })
    }

    @Test("while nothing waits there is no proposal line to see or pick")
    func noProposalLine() throws {
        let controller = try controller(waiting: { [] })
        let row = try proposalRow(controller.menu())

        #expect(row.isHidden)
        #expect(row.title.isEmpty)
        #expect(controller.validateMenuItem(row) == false)
    }

    @Test("the proposal line says one task is waiting, or how many, and follows as the menu opens")
    func proposalLineCounts() throws {
        var waiting = ["prop_old"]
        let controller = try controller(waiting: { waiting })
        let menu = controller.menu()
        let row = try proposalRow(menu)

        #expect(!row.isHidden)
        #expect(row.title == "A task is waiting for your decision")
        #expect(controller.validateMenuItem(row))

        waiting = ["prop_old", "prop_mid", "prop_new"]
        controller.menuNeedsUpdate(menu)
        #expect(row.title == "3 tasks are waiting for your decision")

        waiting = []
        controller.menuNeedsUpdate(menu)
        #expect(row.isHidden)
    }

    @Test("picking the proposal line opens Chat at the oldest card waiting")
    func proposalLineOpensChatAtTheOldest() throws {
        let router = FakeCommandRouter()
        var shown: [String] = []
        let controller = try controller(waiting: { ["prop_old", "prop_new"] }, router: router, shown: { shown.append($0) })
        let row = try proposalRow(controller.menu())

        let action = try #require(row.action)
        _ = (row.target as? NSObject)?.perform(action, with: row)

        #expect(router.performed == [.showChat])
        #expect(shown == ["prop_old"])
    }

    /// M60 §4.8: outside text never reaches a menu line. The line is built
    /// from a count and an id, and its words are the catalogue's alone.
    @Test("the proposal line carries no proposal's words, only the catalogue's")
    func proposalLineCarriesNoOutsideText() {
        for count in 1...3 {
            let line = StatusProposalLine(count: count, oldestProposalId: "prop_\(count)")
            let catalogue = count == 1
                ? ProductStrings[.menuProposalWaiting]
                : String(format: ProductStrings[.menuProposalsWaitingFormat], count)

            #expect(line.text == catalogue)
            #expect(!line.text.contains("prop_"))
        }
    }

    /// Every row after the state line is a command, so the menu cannot grow an
    /// action the command table has never heard of.
    @Test("every actionable row is a command from the table")
    func rowsAreCommands() throws {
        let controller = StatusMenuController(router: FakeCommandRouter(), source: try source())
        let commands = controller.menu().items
            .filter { !$0.isSeparatorItem && $0.identifier != StatusMenuController.stateIdentifier }
            .compactMap(MainMenuController.command(of:))

        #expect(commands == [
            .openFermix, .openSettings, .showDoctor, .restartDaemon, .toggleFloatingPet,
            .toggleVoiceCall, .toggleBackgroundService, .checkForUpdates, .hideMenuBarItem, .quit
        ])
    }

    /// With no window open the status item's row is how a call is ended, and
    /// its title is the sign one is up (M56 P3).
    @Test("the call row names where a click goes, and is dimmed while it would do nothing")
    func callRowFollowsTheCall() throws {
        let router = FakeCommandRouter()
        let controller = StatusMenuController(router: router, source: try source())
        let menu = controller.menu()
        let row = try #require(menu.items.first { MainMenuController.command(of: $0) == .toggleVoiceCall })

        #expect(row.title == "Begin Voice Call")

        router.on = [.toggleVoiceCall]
        controller.menuNeedsUpdate(menu)
        #expect(row.title == "End Voice Call")

        router.refused = [.toggleVoiceCall]
        #expect(controller.validateMenuItem(row) == false)
    }

    /// The owner's first point on 2026-09-04: "theres too much discription on
    /// the top right bar of fermix which makes the window wider". A menu is as
    /// wide as its widest row, and a 90-character disabled sentence under
    /// `Hide Menu Bar Item` was setting that width. The invariant is written
    /// over the whole menu rather than over that one row, so a hint added under
    /// any command later fails here.
    ///
    /// The proposal line (M60 §4.7) is the one other fact row: a status, not
    /// a hint, there only while a decision waits.
    @Test("no status item row is prose: every row is the state line, the proposal line or a command")
    func statusRowsCarryNoHints() throws {
        let controller = StatusMenuController(router: FakeCommandRouter(), source: try source())
        let factRows = [StatusMenuController.stateIdentifier, StatusMenuController.proposalIdentifier]

        for item in controller.menu().items where !item.isSeparatorItem {
            guard !factRows.contains(where: { $0 == item.identifier }) else { continue }

            #expect(MainMenuController.command(of: item) != nil, "\(item.title) is not a command row")
        }
    }

    /// And the rows that remain stay short, the state line included. The cap is
    /// the width of the longest row the design actually wants
    /// (`Disable Background Service`) plus headroom, so a sentence can never
    /// reach the menu through a title again.
    @Test("every status item row and state line fits the menu's width")
    func statusRowsAreShort() throws {
        let router = FakeCommandRouter()
        let controller = StatusMenuController(router: router, source: try source())

        for item in controller.menu().items where !item.isSeparatorItem {
            #expect(item.title.count <= Self.rowCharacterCap, "\(item.title) is \(item.title.count) characters")
        }

        // Both spellings of every toggling row this menu carries, because it
        // redraws them as it opens. The case set is the status table's own, so a
        // row added to it joins the cap rather than escaping it.
        router.on = Set(AppCommand.allCases)
        controller.menuNeedsUpdate(controller.menu())
        for entry in CommandTable.statusItem {
            guard case .command(let command) = entry else { continue }

            for isOn in [true, false] {
                let title = ProductStrings[CommandTable.statusItemTitle(of: command).key(isOn: isOn)]
                #expect(title.count <= Self.rowCharacterCap, "\(title)")
            }
        }

        // The three transaction lines are whole sentences the window also
        // draws, so they are the ones most likely to outgrow the menu.
        let lines: [StatusLine] = [
            .running(uptimeSeconds: 3 * 24 * 60 * 60), .running(uptimeSeconds: nil),
            .starting, .setupRequired, .restartPending, .notRunning,
            .transaction(.restart), .transaction(.enable), .transaction(.disable)
        ]
        for line in lines {
            #expect(line.text.count <= Self.rowCharacterCap, "\(line.text)")
        }

        // The proposal line is M60 §7's sentence, there only while a decision
        // waits: held to its own cap, at the most tasks it will plausibly say.
        for count in [1, 2, 99] {
            let line = StatusProposalLine(count: count, oldestProposalId: "prop_1")
            #expect(line.text.count <= Self.proposalLineCharacterCap, "\(line.text)")
        }
    }

    /// `Disable Background Service` is 26 characters; the cap leaves room for a
    /// longer row without leaving room for a sentence.
    private static let rowCharacterCap = 34
    /// "99 tasks are waiting for your decision" is 38 characters.
    private static let proposalLineCharacterCap = 38

    /// Apple's status menus show no shortcut column, and one drawn here would
    /// be a promise the menu cannot keep: a key equivalent fires only while
    /// Fermix is frontmost, and the menu opens with Fermix in the background.
    /// The case set is the menu's own rows, so a command added to the status
    /// table joins the invariant rather than escaping it.
    @Test("no status item row advertises a key equivalent")
    func statusRowsCarryNoShortcuts() throws {
        let controller = StatusMenuController(router: FakeCommandRouter(), source: try source())

        // The key equivalent is what the row draws and what fires; the
        // modifier mask defaults to Command on every `NSMenuItem` and means
        // nothing without a key, so it is not what this asserts.
        for item in controller.menu().items where !item.isSeparatorItem {
            #expect(item.keyEquivalent.isEmpty, "\(item.title) advertises \(item.keyEquivalent)")
        }

        // The shortcuts themselves are untouched: they live in the main menu,
        // which is the surface they actually work on.
        #expect(CommandTable.shortcut(of: .openSettings) != nil)
        #expect(CommandTable.shortcut(of: .quit) != nil)
    }

    /// Opening the menu is what refreshes it: the state line is a running fact
    /// and the toggling rows name where they will go.
    @Test("opening the menu refreshes the state line and the toggling titles")
    func menuRefreshesOnOpen() throws {
        let router = FakeCommandRouter()
        let controller = StatusMenuController(router: router, source: try source())
        let menu = controller.menu()

        router.on = [.toggleBackgroundService]
        controller.menuNeedsUpdate(menu)

        let service = try #require(
            menu.items.first { MainMenuController.command(of: $0) == .toggleBackgroundService }
        )
        #expect(service.title == "Disable Background Service")
    }

    /// A command whose condition does not hold is dimmed rather than silently
    /// ignored when it is picked.
    @Test("a refused command is dimmed rather than quietly inert")
    func refusedCommandsAreDimmed() throws {
        let router = FakeCommandRouter()
        router.refused = [.restartDaemon]
        let controller = StatusMenuController(router: router, source: try source())
        let menu = controller.menu()

        let restart = try #require(menu.items.first { MainMenuController.command(of: $0) == .restartDaemon })
        let quit = try #require(menu.items.first { MainMenuController.command(of: $0) == .quit })

        #expect(controller.validateMenuItem(restart) == false)
        #expect(controller.validateMenuItem(quit))
    }

    /// The glyph follows the daemon, and attention is its own raster rather
    /// than a colour laid over the running one.
    @Test("the glyph state follows the service and daemon condition")
    func glyphStateFollowsTheDaemon() {
        #expect(MenuBarGlyphState(daemon: .running, hasAttention: false) == .running)
        #expect(MenuBarGlyphState(daemon: .starting, hasAttention: false) == .starting)
        #expect(MenuBarGlyphState(daemon: .stopped, hasAttention: false) == .attention)
        #expect(MenuBarGlyphState(daemon: .running, hasAttention: true) == .attention)
        #expect(
            MenuBarGlyphImage.resourceName(for: .attention)
                != MenuBarGlyphImage.resourceName(for: .running)
        )
    }
}
