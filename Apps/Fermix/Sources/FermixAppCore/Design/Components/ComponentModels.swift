import Foundation

/// A ladder row's state. Each has a word, so the spinner and the sheen can be
/// hidden from VoiceOver without losing the state they draw.
public enum LadderRowState: String, CaseIterable, Sendable {
    case done
    case active
    case pending

    public var accessibilityValue: String {
        switch self {
        case .done: return ProductStrings[.activateStateDone]
        case .active: return ProductStrings[.activateStateActive]
        case .pending: return ProductStrings[.activateStatePending]
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

/// The activation ladder: exactly the three provable states, and the headline
/// that tracks the active one.
public struct ProgressLadderModel: Equatable, Sendable {
    public let rows: [LadderRowModel]
    public let headline: String

    public init(rows: [LadderRowModel], headline: String) {
        precondition(!rows.isEmpty, "a ladder needs rows")
        precondition(!headline.isEmpty, "a ladder needs a headline")

        self.rows = rows
        self.headline = headline
    }

    public static func activation(activeIndex: Int) -> ProgressLadderModel {
        let titles: [(String, ProductStringKey)] = [
            ("service", .activateRowService),
            ("daemon", .activateRowDaemon),
            ("setup", .activateRowSetup)
        ]
        let headlines: [ProductStringKey] = [
            .activateHeadlineRegistering,
            .activateHeadlineStarting,
            .activateHeadlineAlmostReady
        ]

        precondition(titles.indices.contains(activeIndex), "activation stage out of range: \(activeIndex)")

        let rows = titles.enumerated().map { index, entry in
            LadderRowModel(id: entry.0, title: ProductStrings[entry.1], state: state(of: index, active: activeIndex))
        }

        return ProgressLadderModel(rows: rows, headline: ProductStrings[headlines[activeIndex]])
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

/// The menu-bar glyph's three states. None of them is carried by animation
/// alone: running is solid, starting also pulses but is still a solid glyph
/// under Reduce Motion, and attention adds a badge shape.
public enum MenuBarGlyphState: String, CaseIterable, Sendable {
    case running
    case starting
    case attention

    public var pulses: Bool { self == .starting }
    public var showsBadge: Bool { self == .attention }

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
}

/// A Doctor letter-pill: text only, no flood fill.
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

/// One sidebar destination. The list is the chat-ready shell: a future Chat
/// row is one more entry here.
public struct SidebarItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        precondition(!id.isEmpty, "a sidebar item needs an identifier")
        precondition(!title.isEmpty, "a sidebar item needs a title")
        precondition(!systemImage.isEmpty, "a sidebar item needs a symbol")

        self.id = id
        self.title = title
        self.systemImage = systemImage
    }

    public static let mainWindow: [SidebarItem] = [
        SidebarItem(id: "home", title: ProductStrings[.sidebarHome], systemImage: "house"),
        SidebarItem(id: "setup", title: ProductStrings[.sidebarSetup], systemImage: "slider.horizontal.3"),
        SidebarItem(id: "doctor", title: ProductStrings[.sidebarDoctor], systemImage: "stethoscope"),
        SidebarItem(id: "pet", title: ProductStrings[.sidebarPet], systemImage: "pawprint"),
        SidebarItem(id: "logs", title: ProductStrings[.sidebarLogs], systemImage: "list.bullet.rectangle")
    ]
}

/// One Runtime or Attention row: an authoritative fact, or a warning with its
/// one next action.
public struct StatusRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let meta: String?
    public let systemImage: String
    public let tone: StatusTone

    public init(
        id: String,
        title: String,
        detail: String,
        meta: String?,
        systemImage: String,
        tone: StatusTone
    ) {
        precondition(!id.isEmpty, "a status row needs an identifier")
        precondition(!title.isEmpty, "a status row needs a title")
        precondition(!systemImage.isEmpty, "a status row needs a symbol")

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

/// The recovery panel: what happened, what is untouched, and one next action.
public struct ErrorPanelModel: Equatable, Sendable {
    /// §5.6 draws three log lines. A longer tail keeps its most recent three
    /// rather than growing the card.
    public static let logLineCount = 3

    public let title: String
    public let body: String
    public let logHeader: String
    public let logLines: [String]
    public let primaryAction: String
    public let secondaryAction: String
    public let ghostAction: String

    public static func bootFailure(_ cause: BootFailureCause, logLines: [String]) -> ErrorPanelModel {
        ErrorPanelModel(
            title: ProductStrings[.bootFailedTitle],
            body: ProductStrings.bootFailure(cause),
            logHeader: ProductStrings[.bootFailedLogHeader],
            logLines: Array(logLines.suffix(logLineCount)),
            primaryAction: ProductStrings[.bootFailedRunDoctor],
            secondaryAction: ProductStrings[.bootFailedViewLog],
            ghostAction: ProductStrings[.bootFailedTryAgain]
        )
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
