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
        #expect(menu.items[1].isSeparatorItem)
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
            .toggleBackgroundService, .checkForUpdates, .hideMenuBarItem, .quit
        ])
    }

    /// The owner's first point on 2026-09-04: "theres too much discription on
    /// the top right bar of fermix which makes the window wider". A menu is as
    /// wide as its widest row, and a 90-character disabled sentence under
    /// `Hide Menu Bar Item` was setting that width. The invariant is written
    /// over the whole menu rather than over that one row, so a hint added under
    /// any command later fails here.
    @Test("no status item row is prose: every row is the state line or a command")
    func statusRowsCarryNoHints() throws {
        let controller = StatusMenuController(router: FakeCommandRouter(), source: try source())

        for item in controller.menu().items where !item.isSeparatorItem {
            guard item.identifier != StatusMenuController.stateIdentifier else { continue }

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

        let lines: [StatusLine] = [
            .running(uptimeSeconds: 3 * 24 * 60 * 60), .running(uptimeSeconds: nil),
            .starting, .setupRequired, .restartPending, .notRunning
        ]
        for line in lines {
            #expect(line.text.count <= Self.rowCharacterCap, "\(line.text)")
        }
    }

    /// `Disable Background Service` is 26 characters; the cap leaves room for a
    /// longer row without leaving room for a sentence.
    private static let rowCharacterCap = 34

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
