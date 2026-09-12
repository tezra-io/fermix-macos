import AppKit
import Foundation
import Testing

@testable import FermixAppCore

/// The one table behind the main menu, the status item and every toolbar
/// (M34 §3.3). The invariant worth having is structural: a toolbar action is a
/// menu command by construction, not by somebody adding it twice.
@Suite("Command table")
@MainActor
struct CommandTableTests {
    @Test("the main menu is the seven menus M34 names, in order")
    func mainMenuStructure() {
        let titles = CommandTable.mainMenu.map { ProductStrings[$0.titleKey] }

        #expect(titles == ["Fermix", "File", "Edit", "View", "Daemon", "Window", "Help"])
    }

    /// The gate the design asks for: every toolbar action is reachable from the
    /// menu bar, so a command cannot be advertised on one surface only.
    @Test("every toolbar action on every surface is also a main-menu command")
    func toolbarActionsAreMenuCommands() {
        let menuCommands = CommandTable.mainMenuCommands

        for route in AppRoute.allCases {
            for command in CommandTable.toolbar(for: route).commands {
                #expect(menuCommands.contains(command), "\(command.rawValue) on \(route.rawValue)")
            }
        }
    }

    /// The View menu carries the four surfaces on Command-1 to Command-4 and
    /// Show/Hide Sidebar on Control-Command-S.
    @Test("the View menu carries the sidebar toggle and the four surface shortcuts")
    func viewMenuShortcuts() throws {
        let view = try #require(CommandTable.mainMenu.first { $0.titleKey == .menuTitleView })

        #expect(view.commands.prefix(5) == [.toggleSidebar, .showHome, .showDoctor, .showLogs, .showPet])
        #expect(CommandTable.shortcut(of: .showHome) == CommandShortcut("1"))
        #expect(CommandTable.shortcut(of: .showDoctor) == CommandShortcut("2"))
        #expect(CommandTable.shortcut(of: .showLogs) == CommandShortcut("3"))
        #expect(CommandTable.shortcut(of: .showPet) == CommandShortcut("4"))

        let sidebar = try #require(CommandTable.shortcut(of: .toggleSidebar))
        #expect(sidebar.key == "s")
        #expect(sidebar.holdsControl)
    }

    /// A command in the table is one this build performs. The router is the
    /// only place that answers that, so the two are checked against each other
    /// rather than against a list.
    @Test("every command in the table is one the router knows how to answer")
    func everyCommandIsAnswerable() {
        let router = FakeCommandRouter()

        for command in AppCommand.allCases {
            #expect(!router.menuTitle(of: command).isEmpty, "\(command.rawValue)")
        }
    }

    /// A toggling command declares both spellings, so a menu can never show the
    /// state it is already in.
    @Test("toggling commands name where they will go, not where they are")
    func togglingTitles() {
        let router = FakeCommandRouter()

        router.on = [.toggleBackgroundService, .pauseLogs, .toggleFloatingPet, .toggleSidebar]
        #expect(router.menuTitle(of: .toggleBackgroundService) == "Disable Background Service")
        #expect(router.menuTitle(of: .pauseLogs) == "Resume Logs")
        #expect(router.menuTitle(of: .toggleFloatingPet) == "Hide Pet")
        #expect(router.menuTitle(of: .toggleSidebar) == "Hide Sidebar")

        router.on = []
        #expect(router.menuTitle(of: .toggleBackgroundService) == "Enable Background Service")
        #expect(router.menuTitle(of: .pauseLogs) == "Pause Logs")
        #expect(router.menuTitle(of: .toggleFloatingPet) == "Show Pet")
        #expect(router.menuTitle(of: .toggleSidebar) == "Show Sidebar")
    }

    /// M34 §4 bans Start and Stop for the durable service, in the menu as
    /// everywhere else.
    @Test("the service command says enable or disable, never start or stop")
    func serviceWording() {
        let router = FakeCommandRouter()

        for isOn in [true, false] {
            router.on = isOn ? [.toggleBackgroundService] : []
            let title = router.menuTitle(of: .toggleBackgroundService)

            #expect(title.hasPrefix("Enable") || title.hasPrefix("Disable"), "\(title)")
        }
    }

    /// The status item says `Run Doctor` where the View menu says `Doctor`:
    /// one command, two spellings, both in the table.
    @Test("the status item overrides only the spellings the design changes")
    func statusItemSpellings() {
        let router = FakeCommandRouter()

        #expect(router.statusItemTitle(of: .showDoctor) == "Run Doctor")
        #expect(router.menuTitle(of: .showDoctor) == "Doctor")

        for command in AppCommand.allCases where command != .showDoctor {
            #expect(
                router.statusItemTitle(of: command) == router.menuTitle(of: command),
                "\(command.rawValue) has an unexplained second spelling"
            )
        }
    }

    /// M34 §3.3: the status item's rows are the design's, and it carries only
    /// app commands so the disabled state line stays the one non-command row.
    @Test("the status item lists the published rows and nothing else")
    func statusItemRows() {
        let commands = CommandTable.statusItem.compactMap { entry -> AppCommand? in
            guard case .command(let command) = entry else { return nil }

            return command
        }

        #expect(commands == [
            .openFermix, .openSettings, .showDoctor, .restartDaemon, .toggleFloatingPet,
            .toggleBackgroundService, .checkForUpdates, .hideMenuBarItem, .quit
        ])
        #expect(!CommandTable.statusItem.contains(.servicesMenu))
    }

    /// A surface's trailing side is at most three groups, and the type is what
    /// enforces that: three slots, with no way to declare a fourth. What can
    /// still go wrong is a command drawn twice in one toolbar, so that is what
    /// this asserts over every surface, alongside today's two shapes.
    @Test("a toolbar carries at most three groups, and Doctor and Logs carry two")
    func toolbarGroups() {
        for route in AppRoute.allCases {
            let commands = CommandTable.toolbar(for: route).commands

            #expect(Set(commands).count == commands.count, "\(route.rawValue) draws a command twice")
        }

        let doctor = CommandTable.toolbar(for: .doctor)
        #expect(doctor.primary == nil)
        #expect(doctor.secondary == [.runNetworkChecks])
        #expect(doctor.more == [.exportSupportBundle, .revealLogFolder])

        let logs = CommandTable.toolbar(for: .logs)
        #expect(logs.secondary == [.pauseLogs])
        #expect(logs.more == [.copyLogs, .exportLogs])

        // Home's one tinted primary (M34 §3.2). It exists only while its
        // condition holds, which the router answers, so the table publishes it
        // and nothing else.
        let home = CommandTable.toolbar(for: .home)
        #expect(home.primary == .continueSetup)
        #expect(home.secondary.isEmpty)
        #expect(home.more.isEmpty)
        #expect(CommandTable.toolbar(for: .pet).isEmpty)
    }

    /// Every command a toolbar draws needs a sentence-case label; the menu's
    /// title-case spelling must never leak into a button.
    @Test("every toolbar command has a sentence-case label of its own")
    func toolbarLabelsExist() {
        let router = FakeCommandRouter()

        for route in AppRoute.allCases {
            for command in CommandTable.toolbar(for: route).commands {
                let title = router.toolbarTitle(of: command)

                #expect(!title.isEmpty, "\(command.rawValue)")
                #expect(ProductCopyRules.violations(in: title).isEmpty, "\(title)")
            }
        }
    }

    /// M34 §6 promises Command-F focuses the settings search, and `.searchable`
    /// is focused by the standard Find item and by nothing else: without it in
    /// the Edit menu the key did nothing at all. The tag is the action the
    /// receiver reads, so it is pinned against the enum case it names.
    @Test("the Edit menu carries the standard Find item Command-F needs")
    func editMenuCarriesFind() throws {
        let edit = try #require(CommandTable.mainMenu.first { $0.titleKey == .menuTitleEdit })
        let find = try #require(
            edit.entries.compactMap { entry -> SystemMenuItem? in
                guard case .system(let item) = entry, item.titleKey == .menuTitleFind else { return nil }

                return item
            }.first
        )

        #expect(find.selectorName == "performTextFinderAction:")
        #expect(find.keyEquivalent == "f")
        #expect(!find.holdsShift && !find.holdsOption)
        #expect(find.tag == SystemMenuItem.showFindInterfaceTag)
        #expect(SystemMenuItem.showFindInterfaceTag == NSTextFinder.Action.showFindInterface.rawValue)
        // And the renderer carries the tag onto the item, which is the half the
        // responder chain actually reads.
        #expect(MainMenuController.menuItem(for: find).tag == find.tag)
    }

    /// The one control that costs something says so where it is, not only in a
    /// catalogue nobody draws: `doctor.network.body` was written and never
    /// rendered, so the button that spends real requests explained itself
    /// nowhere.
    @Test("the network run carries the sentence that says what it costs")
    func networkRunCarriesItsCost() {
        #expect(CommandTable.toolbarHelpKey(of: .runNetworkChecks) == .doctorNetworkBody)
        #expect(ProductStrings[.doctorNetworkBody].contains("30 seconds"))
        // Every other toolbar command carries none: a help tag on a button
        // whose label already says everything is noise.
        for route in AppRoute.allCases {
            for command in CommandTable.toolbar(for: route).commands where command != .runNetworkChecks {
                #expect(CommandTable.toolbarHelpKey(of: command) == nil, "\(command.rawValue)")
            }
        }
    }

    /// The AppKit renderer round-trips a command through the item it builds, so
    /// a menu row cannot lose the command it was built for.
    @Test("a menu item carries back the command it was built for")
    func menuItemsCarryTheirCommand() {
        let item = NSMenuItem(title: "Doctor", action: nil, keyEquivalent: "")
        item.representedObject = AppCommand.showDoctor.rawValue

        #expect(MainMenuController.command(of: item) == .showDoctor)

        let systemItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "c")
        #expect(MainMenuController.command(of: systemItem) == nil)
    }
}

/// A router that performs nothing and records what it was asked, so the table
/// and the menus can be proven without a window, a daemon, or a lifecycle
/// transaction.
@MainActor
final class FakeCommandRouter: CommandPerforming {
    var on: Set<AppCommand> = []
    var refused: Set<AppCommand> = []
    private(set) var performed: [AppCommand] = []

    func canPerform(_ command: AppCommand) -> Bool {
        !refused.contains(command)
    }

    func isOn(_ command: AppCommand) -> Bool {
        on.contains(command)
    }

    func perform(_ command: AppCommand) {
        performed.append(command)
    }
}
