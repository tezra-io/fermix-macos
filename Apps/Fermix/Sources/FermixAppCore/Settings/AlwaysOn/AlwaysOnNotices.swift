import Foundation

/// The system notifications of Always On (M75 lean v1 §7, L18): the server is
/// ready, the move is done, the server has not answered for 10 minutes, a
/// waiting server must be set up again, and the last backup is 7 days old.
///
/// Each is raised from a change the app saw between two reads of
/// `home.status`, never from a state it read once, so each is raised at most
/// once per occurrence: a launch reads its first summary and raises nothing
/// for it. The body is the engine's own sentence for the state it changed to.

/// Which notification a change raised.
public enum AlwaysOnNoticeKind: String, CaseIterable, Sendable {
    case serverReady
    case moveDone
    case cannotReach
    case setUpAgain
    case backupOld
}

/// One notification to raise: its kind and the engine's sentence.
public struct AlwaysOnNotice: Equatable, Sendable {
    public let kind: AlwaysOnNoticeKind
    public let body: String
}

/// One read of `home.status`, and when it answered.
public struct AlwaysOnReading: Equatable, Sendable {
    public let status: ManagementHomeStatus
    public let at: Date

    public init(status: ManagementHomeStatus, at: Date) {
        self.status = status
        self.at = at
    }
}

public enum AlwaysOnNotices {
    /// How old the newest backup is before the Mac says so, as the server
    /// tells the phones.
    public static let backupAge: TimeInterval = 7 * 86_400

    /// The notification the change from `last` to `current` raises, if any.
    ///
    /// - Parameter ownMove: this app started the move that `current` may
    ///   finish, across the engine's restart, where no read may have seen
    ///   `moving`.
    public static func notice(after last: AlwaysOnReading?, _ current: AlwaysOnReading, ownMove: Bool) -> AlwaysOnNotice? {
        guard let last, let now = current.status.summary, let before = last.status.summary else { return nil }

        let kind: AlwaysOnNoticeKind?
        switch now.state {
        case .ready:
            kind = before.state == .ready ? nil : .serverReady
        case .on:
            kind = before.state == .moving || ownMove ? .moveDone : nil
        case .problem:
            kind = problemNotice(now, before: before, last: last, current: current)
        default:
            kind = nil
        }

        return kind.map { AlwaysOnNotice(kind: $0, body: now.sentence) }
    }

    /// A problem raises a notification as it begins, and an old backup once
    /// its age passes a week, once for that backup.
    private static func problemNotice(
        _ now: ManagementHomeSummary,
        before: ManagementHomeSummary,
        last: AlwaysOnReading,
        current: AlwaysOnReading
    ) -> AlwaysOnNoticeKind? {
        switch now.problem {
        case .cannotReach?:
            return before.problem == .cannotReach ? nil : .cannotReach
        case .waitedTooLong?:
            return before.problem == .waitedTooLong ? nil : .setUpAgain
        case .backupOld?:
            return passedAWeek(last: last, current: current) ? .backupOld : nil
        default:
            return nil
        }
    }

    /// Whether the newest backup is a week old now and was not yet at the
    /// last read: the same backup, counted from when it was taken, or from
    /// the move where none has finished since.
    private static func passedAWeek(last: AlwaysOnReading, current: AlwaysOnReading) -> Bool {
        guard let since = backupSince(current.status), current.at.timeIntervalSince(since) >= backupAge else {
            return false
        }
        guard last.status.summary?.problem == .backupOld, backupSince(last.status) == since else { return true }

        return last.at.timeIntervalSince(since) < backupAge
    }

    /// When the backup an old-backup problem counts from was taken: the
    /// problem's own time, or the move's where no backup finished since.
    static func backupSince(_ status: ManagementHomeStatus) -> Date? {
        // The engine writes these times in the cue rows' shape, and
        // `ManagementCueTime` is the one reader of it.
        ManagementCueTime.date(status.summary?.detail.seenAt ?? status.moved?.movedAt)
    }
}

/// How long the app waits before it reads `home.status` again: briskly while
/// something moves by itself and the pane shows it, slowly while all is set
/// and nothing can change but the server's health, and rarely where Always On
/// is not set up.
public enum AlwaysOnCadence {
    /// While the pane shows a server being created or a move, and while the
    /// engine restarts for this app's own move.
    public static let watching: TimeInterval = 3
    /// While the pane is open on anything else.
    public static let open: TimeInterval = 10
    /// While a server is created or a move runs with the pane closed.
    public static let moving: TimeInterval = 15
    /// While Always On is set up: a server that stops answering, a server
    /// that waits too long, an old backup.
    public static let settled: TimeInterval = 60
    /// After a read that failed, or while Always On is not set up.
    public static let idle: TimeInterval = 300

    public static func wait(after status: ManagementHomeStatus?, failed: Bool, paneVisible: Bool, ownMove: Bool) -> TimeInterval {
        if ownMove { return watching }
        let state = status?.summary?.state
        let moves = state == .creating || state == .moving

        if moves { return paneVisible ? watching : moving }
        if paneVisible { return open }
        if failed { return idle }

        switch state {
        case .ready?, .on?, .problem?, .undone?: return settled
        default: return idle
        }
    }
}
