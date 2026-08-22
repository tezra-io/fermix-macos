import Foundation

/// The Logs surface's bounds. Every one of them is the daemon's published
/// number, restated here only so the surface can refuse an out-of-range request
/// before spending a round trip on it.
public enum LogsPolicy {
    /// M34 §5: an initial tail of 200 entries.
    public static let pageSize = 200
    /// Polled every two seconds, and only while visible and not paused.
    public static let pollInterval: TimeInterval = 2
}

/// What the surface is telling the operator about the page it is showing.
public enum LogsStatus: Equatable, Sendable {
    case idle
    /// The daemon dropped the oldest rows of an oversized page to fit its cap.
    case truncated(String)
    /// The cursor expired because the log rotated, so the tail was restarted.
    case reset(String)
    /// The surface refused to send something out of bounds.
    case refused(String)
    /// The daemon could not answer.
    case failed(String)
}

/// Logs, as bounded pages from the daemon.
///
/// Swift never opens a log file: `logs.query` returns re-redacted, bounded,
/// filtered pages and an opaque cursor, and this holds one page's worth at a
/// time. There is no streaming connection and no whole-file read anywhere.
@MainActor
public final class LogsModel: ObservableObject {
    @Published public private(set) var entries: [ManagementLogEntry] = []
    @Published public private(set) var paused = false
    @Published public private(set) var visible = false
    @Published public private(set) var status: LogsStatus = .idle
    @Published public private(set) var loading = false
    @Published public var minimumLevel: ManagementLogLevel?
    @Published public var search = ""

    /// The cursor for the next older page, as the daemon issued it. Nil means
    /// the history ends here.
    public private(set) var cursor: String?

    private let gateway: any DaemonQuerying
    private let log = AppLog.logger(.app)

    public init(gateway: any DaemonQuerying) {
        self.gateway = gateway
    }

    /// M34 §5: poll every two seconds only while Logs is visible and not
    /// paused. Both halves are state, so the invariant is one expression rather
    /// than a timer somebody has to remember to invalidate.
    public var pollingActive: Bool { visible && !paused }

    public var canLoadOlder: Bool { cursor != nil }

    public var emptyState: EmptyStateModel {
        EmptyStateModel(message: ProductStrings[.logsEmpty])
    }

    public var pauseActionTitle: String {
        ProductStrings[paused ? .logsResume : .logsPause]
    }

    public func setVisible(_ isVisible: Bool) {
        visible = isVisible
    }

    public func togglePause() {
        paused.toggle()
    }

    /// One poll tick. It answers for itself whether it may run, so a timer that
    /// outlives the surface cannot make a request the surface would not.
    ///
    /// A poll asks what is new, never to start again: it merges the refreshed
    /// tail into the head of the page and leaves the older cursor alone, so the
    /// pages `Load older` fetched and the read position both survive it.
    public func poll() async {
        guard pollingActive, !loading else { return }

        await load(cursor: nil, mode: .mergeNewest)
    }

    /// The first page: the published tail, newest first, with no cursor.
    public func refresh() async {
        await load(cursor: nil, mode: .replace)
    }

    /// A changed filter starts a new page: a cursor belongs to the query that
    /// produced it, and continuing an old one under a new filter would return
    /// rows from a window that no longer exists.
    public func applyFilters() async {
        guard let query = validatedQuery(cursor: nil) else { return }

        await run(query, mode: .replace)
    }

    public func loadOlder() async {
        guard let cursor else { return }

        await load(cursor: cursor, mode: .append)
    }

    /// The visible entries as text, in the order they are drawn.
    public func copyVisible() -> String {
        entries.map(Self.line).joined(separator: "\n")
    }

    /// Writes the visible entries, and only those. There is no path here that
    /// reads or copies a log file.
    public func exportVisible(to url: URL) throws {
        try Data(copyVisible().utf8).write(to: url, options: .atomic)
    }

    // MARK: - One query

    /// What a returned page does to the one on screen.
    private enum PageMode {
        /// A new page: the tail replaces whatever was shown, cursor and all.
        case replace
        /// `Load older`: the page extends the tail, and its cursor continues it.
        case append
        /// A poll: only the lines the page does not already hold are added, at
        /// the head. The cursor is untouched — it belongs to the oldest page
        /// loaded, not to the newest query.
        case mergeNewest
    }

    private func load(cursor: String?, mode: PageMode) async {
        guard let query = validatedQuery(cursor: cursor) else { return }

        await run(query, mode: mode)
    }

    private func run(_ query: ManagementLogsQuery, mode: PageMode) async {
        loading = true
        defer { loading = false }

        do {
            let page = try await gateway.queryLogs(query)
            apply(page, mode: mode)
        } catch {
            handle(error)
        }
    }

    private func apply(_ page: ManagementLogPage, mode: PageMode) {
        switch mode {
        case .replace:
            entries = page.entries
            cursor = page.cursor
        case .append:
            entries += page.entries
            cursor = page.cursor
        case .mergeNewest:
            entries = LogsPageMerge.merge(existing: entries, refreshed: page.entries)
        }

        status = page.truncated ? .truncated(ProductStrings[.logsTruncated]) : .idle
    }

    /// A rotated log invalidates the cursor. The daemon says so by name, and the
    /// surface restarts the tail rather than showing a page that can no longer
    /// grow.
    private func handle(_ error: any Error) {
        guard ManagementMessage.code(of: error) == .cursorExpired else {
            log.error("logs query failed: \(ManagementMessage.sentence(for: error), privacy: .public)")
            status = .failed(ManagementMessage.sentence(for: error))
            return
        }

        entries = []
        cursor = nil
        status = .reset(ProductStrings[.logsRotated])
    }

    /// Builds the query, refusing anything past a published bound before it is
    /// sent. The daemon would refuse it too; failing here names the field.
    private func validatedQuery(cursor: String?) -> ManagementLogsQuery? {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= ManagementLogsQuery.maximumSearchLength else {
            status = .refused(ProductStrings[.logsSearchTooLong])
            return nil
        }

        return ManagementLogsQuery(
            limit: LogsPolicy.pageSize,
            level: minimumLevel,
            search: trimmed.isEmpty ? nil : trimmed,
            direction: .backward,
            cursor: cursor
        )
    }

    private static func line(_ entry: ManagementLogEntry) -> String {
        let subsystem = entry.subsystem.map { "[\($0)] " } ?? ""

        return "\(entry.time) \(entry.level.wireValue) \(subsystem)\(entry.message)"
    }
}

/// Folding a refreshed tail into the page on screen.
///
/// The comparison is the whole entry, because that is all the daemon sends and
/// two identical rows are indistinguishable to a reader anyway. Only the newest
/// page's worth of what is held is compared: an entry older than that cannot be
/// in a newest-first tail, so the work stays bounded by one page.
public enum LogsPageMerge {
    public static func merge(
        existing: [ManagementLogEntry],
        refreshed: [ManagementLogEntry]
    ) -> [ManagementLogEntry] {
        guard !existing.isEmpty else { return refreshed }

        let held = Set(existing.prefix(LogsPolicy.pageSize).map(key))

        return refreshed.filter { !held.contains(key($0)) } + existing
    }

    private static func key(_ entry: ManagementLogEntry) -> String {
        "\(entry.time)|\(entry.level.wireValue)|\(entry.subsystem ?? "")|\(entry.message)"
    }
}
