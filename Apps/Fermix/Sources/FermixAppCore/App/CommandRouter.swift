import Foundation

/// What every command actually does.
///
/// One owner for "what a command means", so the main menu, the status item and
/// the toolbars cannot answer differently. It holds nothing of its own: the
/// coordinator owns windows and lifecycle transactions, the surfaces own their
/// runs, and the sidebar model owns the collapse.
@MainActor
public final class CommandRouter: CommandPerforming {
    private let model: AppModel
    private let coordinator: AppCoordinator
    private let surfaces: MainWindowSurfaces
    private let sidebar: SidebarModel
    /// The status item, which the last row of its own menu can remove.
    private let menuBar: any MenuBarItemPresenting
    /// The one command that puts `fermix` on PATH, where this install has one
    /// to offer. A closure because the answer is `CLILinkPlanner`'s.
    private let commandLine: () -> CoexistenceInstructions?
    /// The updater, so `Check for Updates` follows what it would actually
    /// accept rather than a value written here (M34 §6, R2).
    private let updates: any UpdateChecking
    /// "Show browser": opens the pane on its own, with nothing to show yet
    /// (plan §4.10).
    private let browser: BrowserCoordinator
    private let log = AppLog.logger(.app)

    public init(
        model: AppModel,
        coordinator: AppCoordinator,
        surfaces: MainWindowSurfaces,
        sidebar: SidebarModel,
        menuBar: any MenuBarItemPresenting,
        updates: any UpdateChecking,
        browser: BrowserCoordinator,
        commandLine: @escaping () -> CoexistenceInstructions? = { nil }
    ) {
        self.model = model
        self.coordinator = coordinator
        self.surfaces = surfaces
        self.sidebar = sidebar
        self.menuBar = menuBar
        self.updates = updates
        self.browser = browser
        self.commandLine = commandLine
    }

    public func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        // The updater's own answer, never a value written here: it stays true
        // while an update is merely being shown, because asking again is what
        // brings that alert back into focus (M34 §6, R2). A build that runs no
        // updater at all answers false, and M34 §3.3 publishes the row dimmed
        // rather than hiding it.
        case .checkForUpdates:
            return updates.canCheckForUpdates
        case .runLocalChecks, .runNetworkChecks:
            return !surfaces.doctor.isRunning
        case .exportSupportBundle:
            return !surfaces.doctor.exporting
        case .exportLogs, .copyLogs:
            return !surfaces.logs.entries.isEmpty
        case .restartDaemon, .toggleBackgroundService:
            return !coordinator.isRunningTransaction
        // Home's tinted primary exists only while its condition holds
        // (M34 §3.2), and the *table* is what decides that: the toolbar draws
        // no primary for a finished install. The command itself stays
        // performable, because the Daemon menu's `Open Setup Assistant` lands
        // on the settings presentation when nothing gates (M34 §3.4) and a
        // dimmed row there would refuse a url the app honours.
        case .continueSetup:
            return true
        // Removing the item is refused while it is already off the bar: the row
        // is only reachable from the menu the item opens, but a second surface
        // asking would otherwise get a silent no-op.
        case .hideMenuBarItem:
            return menuBar.menuBarItemShown
        // Nothing to show where the launcher is already linked, Homebrew owns
        // the link, or this bundle ships none.
        case .linkCommandLineTool:
            return commandLine() != nil
        // The gate's own answer: dimmed while voice is degraded or unread,
        // and never while there is a call to end (M56 §4.1).
        case .toggleVoiceCall:
            return surfaces.callGate.action != .unavailable
        case .openFermix, .openSettings, .quit, .revealLogFolder, .toggleSidebar, .showChat, .showHome,
             .showDoctor, .showLogs, .showPet, .showBrowser, .pauseLogs, .toggleFloatingPet:
            return true
        }
    }

    public func isOn(_ command: AppCommand) -> Bool {
        switch command {
        case .toggleSidebar: return sidebar.visibility.showsSidebar
        case .pauseLogs: return surfaces.logs.paused
        case .toggleBackgroundService: return surfaces.home.backgroundServiceEnabled
        // The same fact `perform` acts on. `model.petShown` is a mirror the
        // coordinator writes, and a title taken from a mirror can name the
        // opposite direction to the action beside it.
        case .toggleFloatingPet: return coordinator.isPetWindowOpen
        // The gate's answer, which is the call model's phase: "End" while a
        // start or a call is up, "Begin" otherwise, including while the last
        // call is still ending.
        case .toggleVoiceCall: return surfaces.callGate.action == .end
        default: return false
        }
    }

    /// The call's tag is the pet's façade's: what a click does now ("Set up
    /// voice" while voice is not set up), or, while it does nothing, why. Every
    /// other command's is the table's.
    public func toolbarHelp(of command: AppCommand) -> String? {
        guard command == .toggleVoiceCall else { return CommandTable.toolbarHelp(of: command) }

        return surfaces.pet.callUnavailableReason ?? surfaces.pet.callActionTitle
    }

    public func perform(_ command: AppCommand) {
        guard canPerform(command) else {
            log.log("refusing \(command.rawValue, privacy: .public): its condition does not hold")
            return
        }

        switch command {
        case .showChat:
            coordinator.open(.chat)
        case .openFermix, .showHome:
            coordinator.open(.home)
        case .showDoctor:
            coordinator.open(.doctor)
        case .showLogs:
            coordinator.open(.logs)
        case .showPet:
            coordinator.open(.pet)
        // The pane opens on its own, with nothing to show yet, so the person
        // can watch or browse without waiting for a link (plan §4.10).
        case .showBrowser:
            browser.showPane()
        case .openSettings:
            coordinator.openSettings()
        // The same resolution `fermix://setup` takes: the assistant while a
        // gating readiness failure stands, the settings presentation once none
        // does (M34 §3.4).
        case .continueSetup:
            coordinator.open(.setup)
        case .checkForUpdates:
            updates.checkForUpdates()
        case .quit:
            coordinator.quit()
        case .toggleSidebar:
            sidebar.toggle()
        // Never on the click. The sheet names the daemon's reasons and the work
        // a restart would interrupt, and only its own action takes the
        // transaction (M34 §5.10) — which is what the title's ellipsis says.
        case .restartDaemon:
            coordinator.askForRestart()
        case .toggleBackgroundService:
            coordinator.setBackgroundService(enabled: !surfaces.home.backgroundServiceEnabled)
        case .toggleFloatingPet:
            coordinator.setPetWindow(!coordinator.isPetWindowOpen)
        // Through the gate the Pet page and the floating pet click through,
        // so all four doors behave the same.
        case .toggleVoiceCall:
            surfaces.callGate.toggleCall()
        case .hideMenuBarItem:
            menuBar.setMenuBarItemShown(false)
            // An accessory app with no item and no window has no Dock tile, so
            // this opens Home: the switch there is the way to put it back, and
            // its footer says so.
            coordinator.reopen()
        case .linkCommandLineTool:
            guard let instructions = commandLine() else {
                preconditionFailure("the command line row is refused without a command to show")
            }

            coordinator.showInstructions(instructions)
        default:
            performSurfaceCommand(command)
        }
    }

    /// The commands that act on a surface rather than on a window. Split out so
    /// neither half of `perform` grows past one screen.
    private func performSurfaceCommand(_ command: AppCommand) {
        switch command {
        case .runLocalChecks:
            coordinator.open(.doctor)
            Task { await surfaces.doctor.runLocal() }
        case .runNetworkChecks:
            coordinator.open(.doctor)
            Task { await surfaces.doctor.runNetwork() }
        case .exportSupportBundle:
            coordinator.open(.doctor)
            surfaces.doctor.requestSupportBundle()
        case .revealLogFolder:
            surfaces.doctor.openLogFolder()
        case .pauseLogs:
            surfaces.logs.togglePause()
        case .copyLogs:
            Clipboard.write(surfaces.logs.copyVisible())
        case .exportLogs:
            coordinator.open(.logs)
            surfaces.logs.requestExport()
        default:
            preconditionFailure("\(command.rawValue) is not a surface command")
        }
    }
}
