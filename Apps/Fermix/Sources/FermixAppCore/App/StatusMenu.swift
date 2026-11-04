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
    /// A lifecycle transaction this app started is running. The line says so
    /// for as long as it does, in the sentence the window's toolbar and Home's
    /// Status row say it in.
    case transaction(LifecycleTransactionKind)

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
        case .transaction(let kind):
            return LifecycleActivity.sentence(for: kind)
        }
    }
}

/// The status menu's line while cue proposals wait for the owner's decision
/// (M60 §4.7). It says how many, in Fermix's words alone: no proposal's
/// summary, tool or outside text ever reaches the menu.
public struct StatusProposalLine: Equatable, Sendable {
    public let count: Int
    /// The card the line opens Chat at: the oldest one waiting.
    public let oldestProposalId: String

    public var text: String {
        count == 1
            ? ProductStrings[.menuProposalWaiting]
            : String(format: ProductStrings[.menuProposalsWaitingFormat], count)
    }
}

/// Reads the proposal line on the status menu's own refresh (M60 §4.7) from
/// one `cues.proposals.list`: the daemon's count of proposals waiting, and the
/// oldest one, which is the card the line opens Chat at. A daemon whose
/// `hello` does not list the method is never asked, and the menu then draws
/// no line.
@MainActor
public final class StatusProposalReader {
    /// The line as last read, or nil while nothing waits or nothing answered.
    public private(set) var line: StatusProposalLine?

    private let gateway: any DaemonQuerying
    /// Whether Home last found the daemon answering.
    private let daemonAnswers: () -> Bool
    private let log = AppLog.logger(.app)

    public init(gateway: any DaemonQuerying, daemonAnswers: @escaping () -> Bool) {
        self.gateway = gateway
        self.daemonAnswers = daemonAnswers
    }

    /// Reads the line, or, while Home says the daemon is not answering, asks
    /// nothing and draws none: a menu opened with Fermix stopped is not a
    /// failure worth a log line.
    public func refresh() async {
        guard daemonAnswers() else {
            line = nil
            return
        }

        do {
            line = try await read()
        } catch {
            line = nil
            log.debug("proposal line unread: \(ManagementMessage.diagnostic(for: error), privacy: .public)")
        }
    }

    private func read() async throws -> StatusProposalLine? {
        guard try await gateway.servedMethods().contains(.cuesProposalsList) else { return nil }

        // Oldest first, and `waiting` counts every one, past the page it lists.
        let waiting = try await gateway.cueProposals(.waiting)
        guard waiting.waiting > 0, let oldest = waiting.proposals.first else { return nil }

        return StatusProposalLine(count: waiting.waiting, oldestProposalId: oldest.proposalId)
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
    /// The proposal line as last read, while any proposal waits
    /// (`StatusProposalReader`).
    private let proposals: () -> StatusProposalLine?

    public init(
        model: AppModel,
        snapshot: @escaping () -> HomeSnapshot,
        reconcile: @escaping () -> EngineReconcileOutcome = { .aligned },
        proposals: @escaping () -> StatusProposalLine? = { nil }
    ) {
        self.model = model
        self.snapshot = snapshot
        self.reconcile = reconcile
        self.proposals = proposals
    }

    /// The proposal line, while any proposal waits.
    public func proposalLine() -> StatusProposalLine? {
        proposals()
    }

    public func line() -> StatusLine {
        let home = snapshot()

        // First, because the daemon is away for the length of a restart: a menu
        // opened in those seconds reads it, finds nothing answering, and would
        // say Fermix isn't running about a restart the person just asked for.
        if let kind = model.transactionInFlight { return .transaction(kind) }
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
    /// Shows a proposal's card in Chat, once Chat is open.
    private let showProposal: (String) -> Void

    public init(
        router: any CommandPerforming,
        source: StatusMenuSource,
        refresh: @escaping () -> Void = {},
        showProposal: @escaping (String) -> Void = { _ in }
    ) {
        self.router = router
        self.source = source
        self.refresh = refresh
        self.showProposal = showProposal
    }

    public func menu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = true

        menu.addItem(stateItem())
        menu.addItem(proposalItem())
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

    /// The proposal line under the state line: there only while a proposal
    /// waits, and a click opens Chat at the oldest card. It is no command of
    /// the table, because it names no verb of the app's: it is the one way
    /// the menu says a decision is waiting, and it never answers one.
    private func proposalItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openProposal(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = Self.proposalIdentifier
        show(source.proposalLine(), in: item)

        return item
    }

    private func show(_ line: StatusProposalLine?, in item: NSMenuItem) {
        item.title = line?.text ?? ""
        item.representedObject = line?.oldestProposalId
        item.isHidden = line == nil
    }

    @objc
    private func openProposal(_ sender: NSMenuItem) {
        guard let proposalId = sender.representedObject as? String else { return }

        router.perform(.showChat)
        showProposal(proposalId)
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
        if menuItem.identifier == Self.proposalIdentifier { return menuItem.representedObject != nil }
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
            if item.identifier == Self.proposalIdentifier {
                show(source.proposalLine(), in: item)
                continue
            }

            guard let command = MainMenuController.command(of: item) else { continue }

            item.title = router.statusItemTitle(of: command)
        }
    }

    static let stateIdentifier = NSUserInterfaceItemIdentifier("fermix.statusItem.state")
    static let proposalIdentifier = NSUserInterfaceItemIdentifier("fermix.statusItem.proposals")
}
