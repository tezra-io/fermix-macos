import Foundation

/// Everything the app can be asked to do from a menu, the status item, or a
/// toolbar (M34 §3.3).
///
/// One closed set, so a toolbar button and a menu item are the same command
/// rather than two call sites that drift. A command is in this set only when
/// something in this build performs it: an entry with no owner would be a menu
/// row that lies about what the app can do.
public enum AppCommand: String, CaseIterable, Sendable {
    // Application
    case openFermix
    case checkForUpdates
    /// Command-comma, from every window (M34 §14 decision 2).
    case openSettings
    case quit

    // File
    case exportLogs
    case copyLogs
    case exportSupportBundle
    case revealLogFolder

    // View
    case toggleSidebar
    case showHome
    case showDoctor
    case showLogs
    case showPet
    case runLocalChecks
    case runNetworkChecks
    case pauseLogs

    // Daemon
    case restartDaemon
    case toggleBackgroundService
    /// `fermix://setup`, as a command. It is Home's tinted primary while
    /// readiness is not ready, and the Daemon menu's `Open Setup Assistant`;
    /// where nothing gates it lands on the settings presentation (M34 §3.4).
    case continueSetup

    // Status item only
    case toggleFloatingPet
    /// Takes the item off the menu bar. The same thing Command-drag does, said
    /// in words, because a drag is not discoverable.
    case hideMenuBarItem

    // Help
    /// Shows the one command that puts `fermix` on PATH. The assistant's Ready
    /// row is the other door; both print the planner's own line and neither
    /// runs it (M34 §4).
    case linkCommandLineTool
}

/// How a command titles itself.
///
/// A toggling command declares both spellings together, so neither is written
/// at a call site and the menu can never show the state it is already in.
public enum CommandTitle: Equatable, Sendable {
    case fixed(ProductStringKey)
    case toggling(whenOn: ProductStringKey, whenOff: ProductStringKey)

    public func key(isOn: Bool) -> ProductStringKey {
        switch self {
        case .fixed(let key): return key
        case .toggling(let on, let off): return isOn ? on : off
        }
    }
}

/// A command's keyboard shortcut, as the menu declares it.
public struct CommandShortcut: Equatable, Sendable {
    public let key: String
    public let holdsControl: Bool
    public let holdsShift: Bool

    public init(_ key: String, control: Bool = false, shift: Bool = false) {
        precondition(!key.isEmpty, "a shortcut needs a key")

        self.key = key
        self.holdsControl = control
        self.holdsShift = shift
    }
}

/// A menu item macOS performs itself, sent to the first responder.
///
/// These are declared beside the app's own commands rather than built inline in
/// AppKit, so "what is in the Edit menu" is one readable table.
public struct SystemMenuItem: Equatable, Sendable {
    public let titleKey: ProductStringKey
    /// The selector name. Held as a string because this table is a value and
    /// `Selector` belongs to the AppKit renderer.
    public let selectorName: String
    public let keyEquivalent: String
    public let holdsShift: Bool
    public let holdsOption: Bool
    /// The tag the receiver reads to know which action was asked for. Only
    /// `performTextFinderAction:` takes one, and `NSTextFinder.Action` is what
    /// the number means; everything else leaves it at zero.
    public let tag: Int

    public init(
        titleKey: ProductStringKey,
        selectorName: String,
        keyEquivalent: String = "",
        holdsShift: Bool = false,
        holdsOption: Bool = false,
        tag: Int = 0
    ) {
        precondition(!selectorName.isEmpty, "a system menu item needs a selector")

        self.titleKey = titleKey
        self.selectorName = selectorName
        self.keyEquivalent = keyEquivalent
        self.holdsShift = holdsShift
        self.holdsOption = holdsOption
        self.tag = tag
    }

    /// `NSTextFinder.Action.showFindInterface`, as a number.
    ///
    /// Written as a literal rather than imported for the same reason the
    /// selector is a string: this table is a value with no AppKit in it. It
    /// cannot drift, because `CommandTableTests` pins it against the enum case
    /// it names.
    public static let showFindInterfaceTag = 1

    /// The standard Find item, which is how macOS focuses a search field.
    ///
    /// M34 §6 promises Command-F focuses the settings search. `.searchable`
    /// answers `performTextFinderAction:` with the show-find-interface action
    /// through the responder chain and nothing else, so without this item in
    /// the Edit menu the key did nothing at all.
    public static let find = SystemMenuItem(
        titleKey: .menuTitleFind,
        selectorName: "performTextFinderAction:",
        keyEquivalent: "f",
        tag: showFindInterfaceTag
    )
}

public enum CommandMenuEntry: Equatable, Sendable {
    case command(AppCommand)
    case system(SystemMenuItem)
    case separator
    /// macOS fills this one in.
    case servicesMenu
}

public struct CommandMenu: Equatable, Sendable {
    public let titleKey: ProductStringKey
    public let entries: [CommandMenuEntry]

    public init(titleKey: ProductStringKey, entries: [CommandMenuEntry]) {
        precondition(!entries.isEmpty, "a menu needs entries")

        self.titleKey = titleKey
        self.entries = entries
    }

    public var commands: [AppCommand] {
        entries.compactMap { entry in
            guard case .command(let command) = entry else { return nil }

            return command
        }
    }
}

/// One surface's trailing toolbar (M34 §3.2).
///
/// At most one tinted primary action, then at most one secondary group, then at
/// most one overflow menu. The type is the ceiling: three slots and no way to
/// declare a fourth group, so the rule needs no runtime check to hold.
public struct ToolbarSpec: Equatable, Sendable {
    public let primary: AppCommand?
    public let secondary: [AppCommand]
    public let more: [AppCommand]

    public init(primary: AppCommand? = nil, secondary: [AppCommand] = [], more: [AppCommand] = []) {
        self.primary = primary
        self.secondary = secondary
        self.more = more
    }

    public var commands: [AppCommand] {
        (primary.map { [$0] } ?? []) + secondary + more
    }

    public var isEmpty: Bool { commands.isEmpty }
}

/// What a surface's toolbar has to know about the daemon right now (M34 §3.2).
///
/// A value rather than a model reference, so "which primary does Home carry"
/// stays provable without a daemon, a window or a snapshot.
public struct ToolbarCondition: Equatable, Sendable {
    /// Whether the daemon reports no gating readiness failure.
    public let setupComplete: Bool
    /// Whether the launch reconcile found the bundle newer than the daemon.
    public let reconcilePending: Bool

    public init(setupComplete: Bool, reconcilePending: Bool) {
        self.setupComplete = setupComplete
        self.reconcilePending = reconcilePending
    }

    /// Nothing has been read yet. Setup is not complete until the daemon says
    /// it is, so this is the same posture a fresh launch draws.
    public static let unknown = ToolbarCondition(setupComplete: false, reconcilePending: false)
}

/// The one table the main menu, the status item menu, and every toolbar are
/// built from (M34 §3.3).
///
/// Because all three renderers read this, a toolbar action is a menu command by
/// construction rather than by somebody remembering to add it twice.
public enum CommandTable {

    // MARK: - Titles

    public static func title(of command: AppCommand) -> CommandTitle {
        switch command {
        case .openFermix: return .fixed(.menuTitleOpenFermix)
        case .checkForUpdates: return .fixed(.menuTitleCheckForUpdates)
        case .openSettings: return .fixed(.menuTitleSettings)
        case .quit: return .fixed(.menuTitleQuit)
        case .exportLogs: return .fixed(.menuTitleExportLogs)
        case .copyLogs: return .fixed(.menuTitleCopyLogs)
        case .exportSupportBundle: return .fixed(.menuTitleExportSupportBundle)
        case .revealLogFolder: return .fixed(.menuTitleRevealLogFolder)
        case .toggleSidebar:
            return .toggling(whenOn: .menuTitleHideSidebar, whenOff: .menuTitleShowSidebar)
        case .showHome: return .fixed(.menuTitleHome)
        case .showDoctor: return .fixed(.menuTitleDoctor)
        case .showLogs: return .fixed(.menuTitleLogs)
        case .showPet: return .fixed(.menuTitlePet)
        case .runLocalChecks: return .fixed(.menuTitleRunLocalChecks)
        case .runNetworkChecks: return .fixed(.menuTitleRunNetworkChecks)
        case .pauseLogs:
            return .toggling(whenOn: .menuTitleResumeLogs, whenOff: .menuTitlePauseLogs)
        case .restartDaemon: return .fixed(.menuTitleRestartDaemon)
        case .continueSetup: return .fixed(.menuTitleOpenSetupAssistant)
        case .toggleBackgroundService:
            return .toggling(whenOn: .menuTitleDisableService, whenOff: .menuTitleEnableService)
        case .toggleFloatingPet:
            return .toggling(whenOn: .menuTitleHidePet, whenOff: .menuTitleShowPet)
        case .hideMenuBarItem: return .fixed(.menuTitleHideMenuBarItem)
        case .linkCommandLineTool: return .fixed(.menuTitleLinkCommandLineTool)
        }
    }

    /// The status item's own spelling, where the design gives one. The View
    /// menu says `Doctor` because it sits beside Home and Logs; the status item
    /// says `Run Doctor` because it sits beside Restart and Quit.
    public static func statusItemTitle(of command: AppCommand) -> CommandTitle {
        command == .showDoctor ? .fixed(.menuTitleRunDoctor) : title(of: command)
    }

    /// The sentence-case label a toolbar control carries. Only the commands a
    /// toolbar draws have one, so an unlabelled command cannot reach a toolbar.
    public static func toolbarLabelKey(of command: AppCommand) -> ProductStringKey? {
        switch command {
        case .runNetworkChecks: return .doctorNetworkRun
        case .exportSupportBundle: return .doctorSupportExport
        case .revealLogFolder: return .doctorSupportOpenLogFolder
        case .exportLogs: return .logsExport
        case .copyLogs: return .logsCopy
        // The menu says `Open Setup Assistant`; Home's toolbar says what the
        // button does from where the user is standing.
        case .continueSetup: return .homeContinueSetup
        // The one toolbar that draws a restart is Home's, and it draws one only
        // while the reconcile is pending: there the button finishes an update,
        // which is what the sheet it opens is titled (M34 §7.2).
        case .restartDaemon: return .settingsEngineSheetTitle
        case .pauseLogs: return nil
        case .openFermix, .checkForUpdates, .openSettings, .quit, .toggleSidebar, .showHome,
             .showDoctor, .showLogs, .showPet, .runLocalChecks,
             .toggleBackgroundService, .toggleFloatingPet, .hideMenuBarItem,
             .linkCommandLineTool:
            return nil
        }
    }

    /// `pauseLogs` is the one toolbar command whose label toggles, so it reads
    /// its two sentence-case spellings here rather than through the menu's.
    public static func toolbarTitle(of command: AppCommand, isOn: Bool) -> String {
        if command == .pauseLogs {
            return ProductStrings[isOn ? .logsResume : .logsPause]
        }

        guard let key = toolbarLabelKey(of: command) else {
            return ProductStrings[title(of: command).key(isOn: isOn)]
        }

        return ProductStrings[key]
    }

    /// The sentence a toolbar control carries as its help tag, where the button
    /// costs something the label cannot say.
    ///
    /// Only the network run has one: it spends real requests against real
    /// endpoints and can take half a minute, which is the whole reason it is a
    /// button rather than part of the local run (M34 §5.6).
    public static func toolbarHelpKey(of command: AppCommand) -> ProductStringKey? {
        command == .runNetworkChecks ? .doctorNetworkBody : nil
    }

    /// The SF Symbol a toolbar control draws beside or instead of its label.
    public static func symbol(of command: AppCommand) -> String? {
        switch command {
        case .runNetworkChecks: return "globe"
        case .pauseLogs: return "pause.circle"
        case .exportLogs, .exportSupportBundle: return "square.and.arrow.up"
        default: return nil
        }
    }

    public static func shortcut(of command: AppCommand) -> CommandShortcut? {
        switch command {
        case .openFermix: return CommandShortcut("o")
        case .openSettings: return CommandShortcut(",")
        case .quit: return CommandShortcut("q")
        case .toggleSidebar: return CommandShortcut("s", control: true)
        case .showHome: return CommandShortcut("1")
        case .showDoctor: return CommandShortcut("2")
        case .showLogs: return CommandShortcut("3")
        case .showPet: return CommandShortcut("4")
        case .runLocalChecks: return CommandShortcut("r")
        default: return nil
        }
    }

    // MARK: - The main menu

    /// The seven menus of M34 §3.3, in order.
    public static let mainMenu: [CommandMenu] = [
        CommandMenu(titleKey: .productName, entries: [
            .system(SystemMenuItem(titleKey: .menuTitleAbout, selectorName: "orderFrontStandardAboutPanel:")),
            .separator,
            .command(.checkForUpdates),
            .separator,
            .command(.openSettings),
            .separator,
            .servicesMenu,
            .separator,
            .system(SystemMenuItem(titleKey: .menuTitleHide, selectorName: "hide:", keyEquivalent: "h")),
            .system(
                SystemMenuItem(
                    titleKey: .menuTitleHideOthers,
                    selectorName: "hideOtherApplications:",
                    keyEquivalent: "h",
                    holdsOption: true
                )
            ),
            .system(SystemMenuItem(titleKey: .menuTitleShowAll, selectorName: "unhideAllApplications:")),
            .separator,
            .command(.quit)
        ]),
        CommandMenu(titleKey: .menuTitleFile, entries: [
            .system(SystemMenuItem(titleKey: .menuTitleCloseWindow, selectorName: "performClose:", keyEquivalent: "w")),
            .separator,
            // File owns export, which is where the log actions live too: the
            // toolbar draws them, so the menu has to carry them for the
            // toolbar-is-a-menu-command invariant to hold.
            .command(.exportLogs),
            .command(.copyLogs),
            .separator,
            .command(.exportSupportBundle),
            .command(.revealLogFolder)
        ]),
        CommandMenu(titleKey: .menuTitleEdit, entries: [
            .system(SystemMenuItem(titleKey: .menuTitleUndo, selectorName: "undo:", keyEquivalent: "z")),
            .system(
                SystemMenuItem(titleKey: .menuTitleRedo, selectorName: "redo:", keyEquivalent: "z", holdsShift: true)
            ),
            .separator,
            .system(SystemMenuItem(titleKey: .menuTitleCut, selectorName: "cut:", keyEquivalent: "x")),
            .system(SystemMenuItem(titleKey: .menuTitleCopy, selectorName: "copy:", keyEquivalent: "c")),
            .system(SystemMenuItem(titleKey: .menuTitlePaste, selectorName: "paste:", keyEquivalent: "v")),
            .system(SystemMenuItem(titleKey: .menuTitleDelete, selectorName: "delete:")),
            .separator,
            .system(SystemMenuItem(titleKey: .menuTitleSelectAll, selectorName: "selectAll:", keyEquivalent: "a")),
            .separator,
            .system(.find)
        ]),
        CommandMenu(titleKey: .menuTitleView, entries: [
            .command(.toggleSidebar),
            .separator,
            .command(.showHome),
            .command(.showDoctor),
            .command(.showLogs),
            .command(.showPet),
            .separator,
            .command(.runLocalChecks),
            .command(.runNetworkChecks),
            .command(.pauseLogs)
        ]),
        CommandMenu(titleKey: .menuTitleDaemon, entries: [
            .command(.restartDaemon),
            .command(.toggleBackgroundService),
            .command(.continueSetup)
        ]),
        CommandMenu(titleKey: .menuTitleWindow, entries: [
            .system(SystemMenuItem(titleKey: .menuTitleMinimize, selectorName: "performMiniaturize:", keyEquivalent: "m")),
            .system(SystemMenuItem(titleKey: .menuTitleZoom, selectorName: "performZoom:")),
            .separator,
            .system(SystemMenuItem(titleKey: .menuTitleBringAllToFront, selectorName: "arrangeInFront:"))
        ]),
        CommandMenu(titleKey: .menuTitleHelpMenu, entries: [
            .system(
                SystemMenuItem(
                    titleKey: .menuTitleHelpItem,
                    selectorName: "showHelp:",
                    keyEquivalent: "?",
                    holdsShift: true
                )
            ),
            .separator,
            .command(.linkCommandLineTool)
        ])
    ]

    /// Every command the main menu carries, which is the set a toolbar may draw
    /// from.
    public static var mainMenuCommands: Set<AppCommand> {
        Set(mainMenu.flatMap(\.commands))
    }

    // MARK: - The status item

    /// The status item's rows, after the disabled state line the controller
    /// puts first (M34 §3.3).
    public static let statusItem: [CommandMenuEntry] = [
        .command(.openFermix),
        .command(.openSettings),
        .command(.showDoctor),
        .separator,
        .command(.restartDaemon),
        .command(.toggleFloatingPet),
        .command(.toggleBackgroundService),
        .separator,
        .command(.checkForUpdates),
        // Beside Quit because both are ways of getting Fermix out of the way.
        // What it costs is said in Home's menu-bar switch footer, not here: a
        // status menu is as wide as its widest row, and the 90-character
        // explanation under this one set the width of the whole item (owner
        // report of 2026-09-04). Apple's own status menus carry no such rows.
        .command(.hideMenuBarItem),
        .command(.quit)
    ]

    // MARK: - Toolbars

    public static func toolbar(for route: AppRoute, condition: ToolbarCondition = .unknown) -> ToolbarSpec {
        switch route {
        case .doctor:
            return ToolbarSpec(
                secondary: [.runNetworkChecks],
                more: [.exportSupportBundle, .revealLogFolder]
            )
        case .logs:
            return ToolbarSpec(secondary: [.pauseLogs], more: [.copyLogs, .exportLogs])
        case .home:
            return home(condition)
        case .pet, .setup, .update, .uninstall, .recovery:
            return ToolbarSpec()
        }
    }

    /// Home's tinted primary is a function of what the daemon reported
    /// (M34 §3.2): the two conditions the design names, and nothing otherwise.
    ///
    /// A finished install with an aligned engine has no primary at all. Emitting
    /// one and dimming it would put a permanently dead prominent button on the
    /// main screen of every working Mac.
    private static func home(_ condition: ToolbarCondition) -> ToolbarSpec {
        guard condition.setupComplete else { return ToolbarSpec(primary: .continueSetup) }
        guard !condition.reconcilePending else { return ToolbarSpec(primary: .restartDaemon) }

        return ToolbarSpec()
    }
}

/// What performs a command, and what it can say about one right now.
///
/// The renderers ask; they never decide. That is what keeps a menu item, a
/// status row, and a toolbar button in the same state without three copies of
/// the condition.
@MainActor
public protocol CommandPerforming: AnyObject {
    func canPerform(_ command: AppCommand) -> Bool
    /// Whether a toggling command is in its "on" state, which picks its title.
    func isOn(_ command: AppCommand) -> Bool
    func perform(_ command: AppCommand)
}

extension CommandPerforming {
    /// The title to draw in a menu right now.
    public func menuTitle(of command: AppCommand) -> String {
        ProductStrings[CommandTable.title(of: command).key(isOn: isOn(command))]
    }

    public func statusItemTitle(of command: AppCommand) -> String {
        ProductStrings[CommandTable.statusItemTitle(of: command).key(isOn: isOn(command))]
    }

    public func toolbarTitle(of command: AppCommand) -> String {
        CommandTable.toolbarTitle(of: command, isOn: isOn(command))
    }
}
