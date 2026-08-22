import Foundation

/// Everything the menu-bar panel can do. The set is closed, so a row added
/// later joins a group rather than becoming unreachable.
public enum MenuAction: String, CaseIterable, Sendable {
    case openFermix
    case setup
    case runDoctor
    case restartDaemon
    case togglePet
    case pauseNotifications
    case toggleService
    case checkForUpdates
    case quit
}

/// One row: a label, an optional trailing hint, and a shortcut where the design
/// gives one.
public struct MenuPanelRow: Equatable, Sendable, Identifiable {
    public let action: MenuAction
    public let title: String
    public let hint: String?
    public let shortcut: Character?

    public var id: String { action.rawValue }

    public init(action: MenuAction, title: String, hint: String? = nil, shortcut: Character? = nil) {
        precondition(!title.isEmpty, "a menu row needs a title")

        self.action = action
        self.title = title
        self.hint = hint
        self.shortcut = shortcut
    }
}

public struct MenuPanelGroup: Equatable, Sendable, Identifiable {
    public let rows: [MenuPanelRow]

    public var id: String { rows.map(\.id).joined(separator: "+") }

    public init(rows: [MenuPanelRow]) {
        precondition(!rows.isEmpty, "a menu group needs rows")

        self.rows = rows
    }
}

/// The menu-bar panel as data: a header that states the condition in words, and
/// the three groups the design publishes.
public struct MenuPanelModel: Equatable, Sendable {
    public let glyph: MenuBarGlyphState
    public let uptimeSeconds: Int?
    public let version: String
    public let groups: [MenuPanelGroup]

    public init(
        glyph: MenuBarGlyphState,
        uptimeSeconds: Int?,
        version: String,
        petShown: Bool,
        serviceEnabled: Bool
    ) {
        precondition(!version.isEmpty, "the panel shows the running version")

        self.glyph = glyph
        self.uptimeSeconds = uptimeSeconds
        self.version = version
        self.groups = [
            MenuPanelGroup(rows: [
                MenuPanelRow(action: .openFermix, title: ProductStrings[.menuOpenFermix], shortcut: "o"),
                MenuPanelRow(action: .setup, title: ProductStrings[.menuSetup]),
                MenuPanelRow(action: .runDoctor, title: ProductStrings[.menuRunDoctor])
            ]),
            MenuPanelGroup(rows: [
                MenuPanelRow(action: .restartDaemon, title: ProductStrings[.menuRestartDaemon]),
                MenuPanelRow(
                    action: .togglePet,
                    title: ProductStrings[.menuShowPet],
                    hint: petShown ? ProductStrings[.menuShowPetHint] : nil
                ),
                MenuPanelRow(action: .pauseNotifications, title: ProductStrings[.menuPauseNotifications]),
                // M34 §4: the durable state is the registration, so the verb is
                // enable or disable and never start or stop.
                MenuPanelRow(
                    action: .toggleService,
                    title: ProductStrings[serviceEnabled ? .serviceDisable : .serviceEnable]
                )
            ]),
            MenuPanelGroup(rows: [
                MenuPanelRow(
                    action: .checkForUpdates,
                    title: ProductStrings[.menuCheckForUpdates],
                    hint: ProductStrings[.menuUpdatesHint]
                ),
                // Quitting the GUI sends no daemon lifecycle command, and the
                // row says so in line rather than in a dialog afterwards.
                MenuPanelRow(
                    action: .quit,
                    title: ProductStrings[.menuQuit],
                    hint: ProductStrings[.menuQuitHint]
                )
            ])
        ]
    }

    /// The condition, in words. The glyph's badge is a shape and the header is
    /// a sentence, so nothing is carried by colour alone.
    public var stateText: String {
        switch glyph {
        case .running: return ProductStrings[.homeStatusRunning]
        case .starting: return ProductStrings[.menuStateStarting]
        case .attention: return ProductStrings[.menuStateAttention]
        }
    }

    /// The header line: the state, and the coarse uptime when there is one.
    public var statusLine: String {
        guard let uptimeSeconds else { return stateText }

        return ProductStrings.middot(stateText, HumaneTime.coarseUptime(seconds: uptimeSeconds))
    }
}

/// Where the menu-bar panel reads the facts it shows.
///
/// The panel is rebuilt on every open, so its facts are read then rather than
/// held. Uptime comes from the same resolution Home draws — one concept, one
/// resolver — so the two surfaces cannot disagree about how much the app knows.
@MainActor
public struct MenuPanelSource {
    private let model: AppModel
    private let version: String
    private let uptimeSeconds: () -> Int?

    public init(model: AppModel, version: String, uptimeSeconds: @escaping () -> Int?) {
        precondition(!version.isEmpty, "the panel shows the running version")

        self.model = model
        self.version = version
        self.uptimeSeconds = uptimeSeconds
    }

    public func panel() -> MenuPanelModel {
        MenuPanelModel(
            glyph: model.menuGlyph,
            uptimeSeconds: uptimeSeconds(),
            version: version,
            petShown: model.petShown,
            serviceEnabled: model.serviceEnabled
        )
    }
}

extension MenuBarGlyphState {
    /// The glyph follows the daemon: running is solid, starting pulses, and
    /// anything the operator must look at carries the badge.
    public init(daemon: DaemonCondition, hasAttention: Bool) {
        if hasAttention {
            self = .attention
            return
        }

        switch daemon {
        case .running: self = .running
        case .starting: self = .starting
        case .stopped: self = .attention
        }
    }
}
