import AppKit

/// The condition the status item states in words, as its first row.
///
/// It is a disabled menu item rather than a header view because the status item
/// is an `NSMenu` now: the condition has to survive as text the system draws,
/// and nothing here may be carried by the glyph's colour alone.
public enum StatusLine: Equatable, Sendable {
    case running(uptimeSeconds: Int?)
    case starting
    case setupRequired
    case restartPending
    case notRunning

    public var text: String {
        switch self {
        case .running(let seconds):
            guard let seconds else { return ProductStrings[.homeStatusRunning] }

            return String(
                format: ProductStrings[.statusMenuRunningFormat],
                HumaneTime.coarseUptime(seconds: seconds)
            )
        case .starting:
            return ProductStrings[.menuStateStarting]
        case .setupRequired:
            return ProductStrings[.homeStatusSetupRequired]
        case .restartPending:
            return ProductStrings[.statusMenuRestartPending]
        case .notRunning:
            return ProductStrings[.daemonStateNotRunning]
        }
    }
}

/// Where the status line reads its facts.
///
/// Home already resolved every one of them from `overview.get`; reading that
/// same snapshot is what keeps the two surfaces from disagreeing about how much
/// the app knows.
@MainActor
public struct StatusMenuSource {
    private let model: AppModel
    private let snapshot: () -> HomeSnapshot
    /// The launch reconcile's answer (M34 §7.2). It is a separate reading
    /// because a daemon running an engine the operator has already replaced
    /// reports no restart requirement of its own.
    private let reconcile: () -> EngineReconcileOutcome

    public init(
        model: AppModel,
        snapshot: @escaping () -> HomeSnapshot,
        reconcile: @escaping () -> EngineReconcileOutcome = { .aligned }
    ) {
        self.model = model
        self.snapshot = snapshot
        self.reconcile = reconcile
    }

    public func line() -> StatusLine {
        let home = snapshot()

        if model.daemon == .stopped || home.unreachable { return .notRunning }
        if model.daemon == .starting { return .starting }
        if reconcile().isPending { return .restartPending }
        if home.restartPending { return .restartPending }
        if !home.setupComplete { return .setupRequired }

        return .running(uptimeSeconds: home.uptimeSeconds)
    }
}

/// Builds the status item's menu from `CommandTable` (M34 §3.3).
///
/// The rows are the table's; the state line in front of them is this menu's
/// alone, because a status item that says nothing about the daemon is the one
/// thing the menu bar exists to avoid.
@MainActor
public final class StatusMenuController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private let router: any CommandPerforming
    private let source: StatusMenuSource
    /// Reads the daemon again. The menu's state line is built from the last
    /// snapshot, and with the window closed nothing else ever reads: without
    /// this the item said `Running for 8 minutes` three hours later, and a dead
    /// daemon still said running (M34 §7.2).
    private let refresh: () -> Void

    public init(
        router: any CommandPerforming,
        source: StatusMenuSource,
        refresh: @escaping () -> Void = {}
    ) {
        self.router = router
        self.source = source
        self.refresh = refresh
    }

    public func menu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = true

        menu.addItem(stateItem())
        menu.addItem(.separator())

        for entry in CommandTable.statusItem {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .command(let command):
                menu.addItem(item(for: command))
            case .system, .servicesMenu:
                preconditionFailure("the status item carries app commands only")
            }
        }

        return menu
    }

    /// The state line: a disabled row, so it reads as a fact rather than as
    /// something to click.
    private func stateItem() -> NSMenuItem {
        let item = NSMenuItem(title: source.line().text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.identifier = Self.stateIdentifier

        return item
    }

    /// One command row, with no key equivalent on any of them.
    ///
    /// A status item's menu opens with Fermix in the background, but a key
    /// equivalent drawn here fires only while Fermix is frontmost, so the
    /// shortcut column advertised a gesture that mostly does nothing, and the
    /// ⌘2 beside `Run Doctor` advertised the View menu's `Doctor` under
    /// a second name. Apple's own status menus carry none. The shortcuts
    /// themselves are unchanged: `CommandTable` still puts them in the main
    /// menu, which is where they work.
    private func item(for command: AppCommand) -> NSMenuItem {
        let item = NSMenuItem(
            title: router.statusItemTitle(of: command),
            action: #selector(performCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = command.rawValue

        return item
    }

    @objc
    private func performCommand(_ sender: NSMenuItem) {
        guard let command = MainMenuController.command(of: sender) else { return }

        router.perform(command)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = MainMenuController.command(of: menuItem) else { return false }

        return router.canPerform(command)
    }

    /// The daemon is read as the menu opens, so the rows below are drawn from a
    /// fresh answer rather than from whatever the last window visit left.
    public func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    /// The menu is rebuilt from live state every time it opens: the state line
    /// is a running fact and the toggling rows name where they will go.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.identifier == Self.stateIdentifier {
                item.title = source.line().text
                continue
            }

            guard let command = MainMenuController.command(of: item) else { continue }

            item.title = router.statusItemTitle(of: command)
        }
    }

    static let stateIdentifier = NSUserInterfaceItemIdentifier("fermix.statusItem.state")
}
