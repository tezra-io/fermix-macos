import Foundation

/// A ladder row's state. Each has a word, so the spinner and the sheen can be
/// hidden from VoiceOver without losing the state they draw.
public enum LadderRowState: String, CaseIterable, Sendable {
    case done
    case active
    case pending

    public var accessibilityValue: String {
        switch self {
        case .done: return ProductStrings[.ladderStateDone]
        case .active: return ProductStrings[.ladderStateActive]
        case .pending: return ProductStrings[.ladderStatePending]
        }
    }
}

/// One row of the activation ladder.
public struct LadderRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: LadderRowState

    public init(id: String, title: String, state: LadderRowState) {
        precondition(!id.isEmpty, "a ladder row needs an identifier")
        precondition(!title.isEmpty, "a ladder row needs a title")

        self.id = id
        self.title = title
        self.state = state
    }

    public var accessibilityLabel: String { title }
    public var accessibilityValue: String { state.accessibilityValue }
}

/// A provable ladder: the rows a mechanical stage can actually prove happened,
/// and the headline of the screen they run inside.
public struct ProgressLadderModel: Equatable, Sendable {
    public let rows: [LadderRowModel]
    public let headline: String

    public init(rows: [LadderRowModel], headline: String) {
        precondition(!rows.isEmpty, "a ladder needs rows")
        precondition(!headline.isEmpty, "a ladder needs a headline")

        self.rows = rows
        self.headline = headline
    }

    /// Starting's rows (M34 §4). The last is what makes an upgrade land on
    /// Ready instead of re-asking a configured home.
    ///
    /// The registration row is drawn from the activation plan rather than
    /// always, for the reason the restart row below is: a launch whose engine
    /// the developer started registers nothing with launchd, and a row
    /// promising a background item that never arrives is a step the app does
    /// not take being shown as one it has not finished.
    public static func starting(activeIndex: Int, includesRegistration: Bool) -> ProgressLadderModel {
        var titles: [(String, ProductStringKey)] = []
        if includesRegistration { titles.append(("service", .startingRowService)) }
        titles += [
            ("daemon", .startingRowDaemon),
            ("answering", .startingRowAnswering),
            ("reading", .startingRowReading)
        ]

        return ladder(titles: titles, headline: .startingTitle, activeIndex: activeIndex)
    }

    /// Applying's rows (M34 §4): the save, and the restart where one is going
    /// to happen.
    ///
    /// The restart row is drawn from the daemon's own `restart.required`
    /// rather than always: a home that needs no restart used to watch
    /// `Restarting Fermix so your provider takes effect` sit pending until the
    /// screen left, which is a step the app never took being shown as a step
    /// it had not finished.
    public static func applying(activeIndex: Int, includesRestart: Bool) -> ProgressLadderModel {
        var titles: [(String, ProductStringKey)] = [("saving", .applyingRowSaving)]
        if includesRestart { titles.append(("restarting", .applyingRowRestarting)) }

        return ladder(titles: titles, headline: .applyingTitle, activeIndex: activeIndex)
    }

    private static func ladder(
        titles: [(String, ProductStringKey)],
        headline: ProductStringKey,
        activeIndex: Int
    ) -> ProgressLadderModel {
        precondition(titles.indices.contains(activeIndex), "ladder step out of range: \(activeIndex)")

        let rows = titles.enumerated().map { index, entry in
            LadderRowModel(id: entry.0, title: ProductStrings[entry.1], state: state(of: index, active: activeIndex))
        }

        return ProgressLadderModel(rows: rows, headline: ProductStrings[headline])
    }

    private static func state(of index: Int, active: Int) -> LadderRowState {
        if index < active { return .done }
        if index == active { return .active }

        return .pending
    }
}

/// The progress-dot zone at the foot of an onboarding screen.
public struct ProgressDotsModel: Equatable, Sendable {
    public enum DotState: String, Equatable, Sendable {
        case done
        case active
        case pending
    }

    public let total: Int
    public let activeIndex: Int

    public init(total: Int, activeIndex: Int) {
        precondition(total > 0, "a progress ladder needs at least one step")
        precondition((0..<total).contains(activeIndex), "active step out of range: \(activeIndex)")

        self.total = total
        self.activeIndex = activeIndex
    }

    public var states: [DotState] {
        (0..<total).map { index in
            if index < activeIndex { return .done }
            if index == activeIndex { return .active }

            return .pending
        }
    }

    public var accessibilityLabel: String {
        String(format: ProductStrings[.progressStepFormat], activeIndex + 1, total)
    }
}

/// The menu-bar glyph's three states.
///
/// Each is a template raster of its own (`MenuBarGlyphImage`), so none of them
/// is carried by animation or by colour: running is the mark, starting is the
/// mark in a lighter ink, and attention is the mark with a badge shape cut into
/// it. Nothing about the status item moves, so Reduce Motion changes none of it.
public enum MenuBarGlyphState: String, CaseIterable, Sendable {
    case running
    case starting
    case attention

    public var accessibilityLabel: String {
        switch self {
        case .running: return ProductStrings[.menuGlyphRunning]
        case .starting: return ProductStrings[.menuGlyphStarting]
        case .attention: return ProductStrings[.menuGlyphAttention]
        }
    }
}

/// How a status reads in the low-chroma palette.
public enum StatusTone: String, CaseIterable, Sendable {
    case pass
    case warn
    case fail
    case neutral

    public var textColor: ThemedColor {
        switch self {
        case .pass: return Palette.pillPass
        case .warn: return Palette.pillWarn
        case .fail: return Palette.error
        case .neutral: return Palette.faint
        }
    }

    /// The disc behind a status glyph.
    public var pillFill: ThemedColor {
        switch self {
        case .pass: return Palette.successPillFill
        case .warn: return Palette.warnIconFill
        case .fail: return Palette.errorDiscFill
        case .neutral: return Palette.base300
        }
    }

    /// The one glyph that names this tone. A failure draws an x, never the
    /// warning's exclamation: eight statuses collapsing onto two glyphs is how a
    /// failed check came to be drawn like a warning (redlines §5.9).
    public var symbol: String {
        switch self {
        case .pass: return "checkmark"
        case .warn: return "exclamationmark"
        case .fail: return "xmark"
        case .neutral: return "minus"
        }
    }
}

/// A Doctor check's status vocabulary: the letters VoiceOver reads in the
/// row's accessibility value, and the tone that tints its one status disc.
public struct CheckBadge: Equatable, Sendable {
    public let letters: String
    public let tone: StatusTone

    public init(letters: String, tone: StatusTone) {
        precondition(!letters.isEmpty, "a badge needs letters")

        self.letters = letters
        self.tone = tone
    }

    /// A status this build has never seen keeps its wire value rather than
    /// being folded into a neighbouring status.
    public static func forStatus(_ status: ManagementCheckStatus) -> CheckBadge {
        switch status {
        case .passed: return CheckBadge(letters: ProductStrings[.doctorPillPass], tone: .pass)
        case .warning: return CheckBadge(letters: ProductStrings[.doctorPillWarn], tone: .warn)
        case .failed: return CheckBadge(letters: ProductStrings[.doctorPillFail], tone: .fail)
        case .unavailable: return CheckBadge(letters: ProductStrings[.doctorPillUnavailable], tone: .neutral)
        case .skipped: return CheckBadge(letters: ProductStrings[.doctorPillSkipped], tone: .neutral)
        case .cancelled: return CheckBadge(letters: ProductStrings[.doctorPillCancelled], tone: .neutral)
        case .timedOut: return CheckBadge(letters: ProductStrings[.doctorPillTimedOut], tone: .neutral)
        case .notApplicable: return CheckBadge(letters: ProductStrings[.doctorPillNotApplicable], tone: .neutral)
        case .unrecognized(let value): return CheckBadge(letters: value.uppercased(), tone: .neutral)
        }
    }
}

/// One sidebar destination, drawn as a system `Label`. The list is the
/// chat-ready shell: a future Chat row is one more entry here.
///
/// There is no Setup row: M34 §5 makes setup a task rather than a destination.
public struct SidebarItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// The route this row selects, so the sidebar and the `fermix://` verbs
    /// cannot disagree about what a row means.
    public let route: AppRoute

    public init(route: AppRoute, title: String, systemImage: String) {
        guard let identifier = route.sidebarItemIdentifier else {
            preconditionFailure("\(route.rawValue) is not a sidebar destination")
        }
        precondition(!title.isEmpty, "a sidebar item needs a title")
        precondition(!systemImage.isEmpty, "a sidebar item needs a symbol")

        self.id = identifier
        self.title = title
        self.systemImage = systemImage
        self.route = route
    }

    public static let mainWindow: [SidebarItem] = [
        SidebarItem(route: .home, title: ProductStrings[.sidebarHome], systemImage: "house"),
        SidebarItem(route: .doctor, title: ProductStrings[.sidebarDoctor], systemImage: "stethoscope"),
        SidebarItem(route: .logs, title: ProductStrings[.sidebarLogs], systemImage: "list.bullet.rectangle"),
        SidebarItem(route: .pet, title: ProductStrings[.sidebarPet], systemImage: "pawprint")
    ]

    /// The row a route selects, where it is one. A route with no row (the update
    /// and uninstall surfaces) has no answer here, and the sidebar draws an
    /// empty selection rather than lighting a row that does not describe what is
    /// showing.
    public static func item(for route: AppRoute) -> SidebarItem? {
        mainWindow.first { $0.route == route }
    }

    /// The pinned footer row (decision D2, owner directive of 2026-09-03). It
    /// is not a `SidebarItem`: it selects a presentation of this window rather
    /// than a route, so it has no `AppRoute` to carry and cannot be built by
    /// the initialiser above. The identifier is written once, here, so the row
    /// and the selection cannot spell it differently.
    public static let settingsIdentifier = "settings"

    /// Which row is lit: the row for the current route.
    ///
    /// There is no settings answer here. Entering settings replaces the whole
    /// app sidebar with the pane column (decision D1), so while the
    /// presentation shows there is no drawn row to carry a highlight, and a
    /// branch for it would publish a value no surface can display.
    public static func selection(route: AppRoute) -> String? {
        route.sidebarItemIdentifier
    }
}

/// One labelled fact: a title and the value beside it, with an optional
/// trailing fact and an optional icon.
///
/// The icon is optional because M34 §6 leaves the primary window's rows to the
/// system: a fact inside a grouped `Form` is a `LabeledContent` with no tile of
/// its own, while the decorated rows keep theirs.
public struct StatusRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let meta: String?
    public let systemImage: String?
    public let tone: StatusTone

    public init(
        id: String,
        title: String,
        detail: String,
        meta: String? = nil,
        systemImage: String? = nil,
        tone: StatusTone = .neutral
    ) {
        precondition(!id.isEmpty, "a status row needs an identifier")
        precondition(!title.isEmpty, "a status row needs a title")
        precondition(systemImage?.isEmpty != true, "a status row's symbol is absent or named")

        self.id = id
        self.title = title
        self.detail = detail
        self.meta = meta
        self.systemImage = systemImage
        self.tone = tone
    }

    public var accessibilityLabel: String { title }

    /// The detail and the trailing fact read as one value, so VoiceOver does
    /// not leave the trailing column unspoken.
    public var accessibilityValue: String {
        guard let meta, !meta.isEmpty else { return detail }

        return ProductStrings.commaPair(detail, meta)
    }
}

/// The empty state: one caption line inside the same card, no illustration.
public struct EmptyStateModel: Equatable, Sendable {
    public let message: String

    public init(message: String) {
        precondition(!message.isEmpty, "an empty state needs a message")

        self.message = message
    }

    public var accessibilityLabel: String { message }
}

/// What a boot-failure card can be asked to do. Named rather than positional,
/// because which of them leads depends on the cause (M34 §15.2).
public enum ErrorPanelIntent: String, CaseIterable, Equatable, Sendable {
    case runDoctor
    case viewLog
    case tryAgain

    public var title: String {
        switch self {
        case .runDoctor: return ProductStrings[.bootFailedRunDoctor]
        case .viewLog: return ProductStrings[.bootFailedViewLog]
        case .tryAgain: return ProductStrings[.bootFailedTryAgain]
        }
    }
}

/// The recovery panel: what happened, what is untouched, and one next action.
public struct ErrorPanelModel: Equatable, Sendable {
    /// §5.6 draws three log lines. A longer tail keeps its most recent three
    /// rather than growing the card.
    public static let logLineCount = 3

    public let title: String
    public let body: String
    public let logHeader: String
    public let logLines: [String]
    /// The Terminal lines this cause's own sentence names, in order. The card
    /// puts each on the pasteboard: a cause whose only next step is a command
    /// the operator cannot select is the dead end M34 §15.2 names.
    public let commands: [String]
    /// What the refusal found on this Mac: the copies it counted, the journal it
    /// could not use. Rendered under the sentence, because a sentence naming a
    /// condition and no path is not diagnosable (M34 §15.2).
    public let evidence: [String]
    public let primary: ErrorPanelIntent
    public let secondary: ErrorPanelIntent
    public let ghost: ErrorPanelIntent

    public static func bootFailure(
        _ cause: BootFailureCause,
        logLines: [String],
        evidence: [String] = []
    ) -> ErrorPanelModel {
        let commands = cause.commands
        // Where the copy names commands, running them is the next step and
        // trying again is what follows: Doctor would answer from a daemon this
        // app never started, so it must not be the tinted action.
        let leading: ErrorPanelIntent = commands.isEmpty ? .runDoctor : .tryAgain
        let following: ErrorPanelIntent = commands.isEmpty ? .viewLog : .runDoctor

        return ErrorPanelModel(
            title: ProductStrings[.bootFailedTitle],
            body: ProductStrings.bootFailure(cause),
            logHeader: ProductStrings[.bootFailedLogHeader],
            logLines: Array(logLines.suffix(logLineCount)),
            commands: commands,
            evidence: evidence,
            primary: leading,
            secondary: following,
            ghost: commands.isEmpty ? .tryAgain : .viewLog
        )
    }
}

/// The Terminal lines each boot-failure sentence names.
///
/// A closed switch with no default, so a cause added later has to decide
/// whether its copy names a command rather than silently answering none.
extension BootFailureCause {
    public var commands: [String] {
        switch self {
        case .preManagementDaemonRunning, .legacyInstallPresent:
            return ["brew upgrade fermix", "fermix restart", "fermix migrate-to-app"]
        case .legacySystemInstallPresent:
            return ["sudo fermix service uninstall --system"]
        case .timedOut, .approvalPending, .backgroundItemDisabled, .incompatibleVersion, .crashLoop,
             .bindFailure, .webUnavailable, .invalidPackage, .bootstrapRecordUnusable,
             .registrationFailed, .notInApplications, .foreignDaemonRunning, .daemonUnresponsive,
             .duplicateCopyPresent, .migrationHandoffInvalid, .daemonRefusedIdentity:
            return []
        }
    }
}

/// Durations read as words, never as a duration format.
public enum HumaneTime {
    private static let minute = 60
    private static let hour = 3_600
    private static let day = 86_400

    /// The two largest units, e.g. "3 days 4 hours". Anything under a minute
    /// is "just now" rather than a count of seconds.
    public static func uptime(seconds: Int) -> String {
        guard seconds >= minute else { return ProductStrings[.timeJustNow] }

        if seconds >= day {
            return join(count: seconds / day, unit: .day, remainder: (seconds % day) / hour, remainderUnit: .hour)
        }

        if seconds >= hour {
            return join(
                count: seconds / hour,
                unit: .hour,
                remainder: (seconds % hour) / minute,
                remainderUnit: .minute
            )
        }

        return phrase(count: seconds / minute, unit: .minute)
    }

    /// The largest unit only, for the menu-bar status line.
    public static func coarseUptime(seconds: Int) -> String {
        guard seconds >= minute else { return ProductStrings[.timeJustNow] }
        if seconds >= day { return phrase(count: seconds / day, unit: .day) }
        if seconds >= hour { return phrase(count: seconds / hour, unit: .hour) }

        return phrase(count: seconds / minute, unit: .minute)
    }

    private enum Unit {
        case day
        case hour
        case minute

        func word(count: Int) -> String {
            switch self {
            case .day: return ProductStrings[count == 1 ? .timeDay : .timeDays]
            case .hour: return ProductStrings[count == 1 ? .timeHour : .timeHours]
            case .minute: return ProductStrings[count == 1 ? .timeMinute : .timeMinutes]
            }
        }
    }

    private static func phrase(count: Int, unit: Unit) -> String {
        "\(count) \(unit.word(count: count))"
    }

    private static func join(count: Int, unit: Unit, remainder: Int, remainderUnit: Unit) -> String {
        guard remainder > 0 else { return phrase(count: count, unit: unit) }

        return phrase(count: count, unit: unit) + " " + phrase(count: remainder, unit: remainderUnit)
    }
}
