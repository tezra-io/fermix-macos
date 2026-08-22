import Foundation
import Testing

@testable import FermixAppCore

/// Logs: bounded pages from `logs.query`, polled every two seconds and only
/// while the surface is visible and not paused. Swift never reads a log file.
@Suite("Logs surface")
@MainActor
struct LogsSurfaceTests {
    @Test("the first load asks for the published tail, backwards, with no cursor")
    func initialTail() async throws {
        let harness = try LogsHarness()

        await harness.model.refresh()

        guard case .logs(let query)? = harness.gateway.calls.first else {
            Issue.record("expected a logs query, got \(harness.gateway.calls)")
            return
        }
        #expect(query.limit == LogsPolicy.pageSize)
        #expect(query.direction == .backward)
        #expect(query.cursor == nil)
        #expect(LogsPolicy.pageSize == 200)
        #expect(ManagementLogsQuery.maximumLimit == 500)
    }

    @Test("polling runs only while the surface is visible and not paused")
    func pollingIsGated() async throws {
        let harness = try LogsHarness()

        // Hidden: nothing is asked.
        harness.model.setVisible(false)
        await harness.model.poll()
        #expect(harness.gateway.calls.isEmpty)
        #expect(!harness.model.pollingActive)

        // Visible: one poll, one query.
        harness.model.setVisible(true)
        #expect(harness.model.pollingActive)
        await harness.model.poll()
        #expect(harness.gateway.calls.count == 1)

        // Paused while visible: nothing more.
        harness.model.togglePause()
        #expect(!harness.model.pollingActive)
        await harness.model.poll()
        #expect(harness.gateway.calls.count == 1)
    }

    @Test("the poll interval is two seconds")
    func pollInterval() {
        #expect(LogsPolicy.pollInterval == 2)
    }

    /// A poll answers "what is new", never "start again". Reloading the tail
    /// over the top would throw away every page `Load older` fetched and reset
    /// the read position, every two seconds, with no pause and no message.
    @Test("a poll keeps the pages the operator loaded and adds only what is new")
    func pollKeepsLoadedHistory() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [
            try ManagementValueFixture.logPage(messages: ["newest", "second"], cursor: "older-1"),
            try ManagementValueFixture.logPage(messages: ["third", "fourth"], cursor: "older-2"),
            // The poll: the same newest page, plus one line that arrived since.
            try ManagementValueFixture.logPage(messages: ["fresh", "newest", "second"], cursor: "older-1")
        ]

        await harness.model.refresh()
        await harness.model.loadOlder()
        #expect(harness.model.entries.map(\.message) == ["newest", "second", "third", "fourth"])
        #expect(harness.model.cursor == "older-2")

        await harness.model.poll()

        #expect(harness.model.entries.map(\.message) == ["fresh", "newest", "second", "third", "fourth"])
        #expect(harness.model.cursor == "older-2", "the older cursor belongs to the tail already loaded")
    }

    /// The merge compares whole entries, so a line the page already holds is not
    /// mistaken for a new one and a poll that finds nothing changes nothing.
    @Test("a poll that finds no new lines leaves the page exactly as it was")
    func pollWithNothingNewIsInert() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [try ManagementValueFixture.logPage(messages: ["newest", "second"])]

        await harness.model.refresh()
        let before = harness.model.entries

        await harness.model.poll()

        #expect(harness.model.entries == before)
    }

    @Test("a filter and a search are sent as query parameters, not applied locally")
    func filtersReachTheDaemon() async throws {
        let harness = try LogsHarness()
        harness.model.minimumLevel = .warning
        harness.model.search = "provider"

        await harness.model.applyFilters()

        guard case .logs(let query)? = harness.gateway.calls.last else {
            Issue.record("expected a logs query, got \(harness.gateway.calls)")
            return
        }
        #expect(query.level == .warning)
        #expect(query.search == "provider")
        #expect(query.cursor == nil, "a new filter starts a new page rather than continuing the old one")
    }

    @Test("a search longer than the published bound is refused before it is sent")
    func oversizedSearchIsRefused() async throws {
        let harness = try LogsHarness()
        harness.model.search = String(repeating: "x", count: ManagementLogsQuery.maximumSearchLength + 1)

        await harness.model.applyFilters()

        #expect(harness.gateway.calls.isEmpty)
        #expect(harness.model.status == .refused(ProductStrings[.logsSearchTooLong]))
    }

    @Test("load older continues from the cursor the daemon returned")
    func loadOlderUsesTheCursor() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [
            try ManagementValueFixture.logPage(messages: ["newest"], cursor: "cursor-1"),
            try ManagementValueFixture.logPage(messages: ["older"], cursor: "cursor-2")
        ]

        await harness.model.refresh()
        await harness.model.loadOlder()

        guard case .logs(let query)? = harness.gateway.calls.last else {
            Issue.record("expected a logs query, got \(harness.gateway.calls)")
            return
        }
        #expect(query.cursor == "cursor-1")
        #expect(harness.model.entries.map(\.message) == ["newest", "older"])
    }

    @Test("a page with no cursor ends the history rather than asking again")
    func noCursorEndsTheHistory() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [try ManagementValueFixture.logPage(messages: ["only"], cursor: nil)]

        await harness.model.refresh()
        #expect(!harness.model.canLoadOlder)

        await harness.model.loadOlder()
        #expect(harness.gateway.calls.count == 1)
    }

    /// Rotation invalidates a cursor. The daemon says so explicitly, and the
    /// surface starts a fresh tail rather than showing a frozen page.
    @Test("an expired cursor resets to a fresh tail and says why")
    func cursorExpiredResets() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [try ManagementValueFixture.logPage(messages: ["newest"], cursor: "cursor-1")]
        await harness.model.refresh()

        harness.gateway.logsFailure = ManagementError.daemon(
            ManagementFailure(
                code: .cursorExpired,
                message: "the log file rotated",
                details: ManagementScalarMap(values: [:])
            )
        )
        await harness.model.loadOlder()

        #expect(harness.model.status == .reset(ProductStrings[.logsRotated]))
        #expect(harness.model.cursor == nil)
        #expect(harness.model.entries.isEmpty)
    }

    @Test("copying gives the visible entries as text, in the order they are drawn")
    func copyVisible() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [try ManagementValueFixture.logPage(messages: ["first", "second"])]

        await harness.model.refresh()
        let copied = harness.model.copyVisible()

        #expect(copied.contains("first"))
        #expect(copied.contains("second"))
        #expect(copied.split(separator: "\n").count == 2)
    }

    @Test("exporting writes only the visible entries, never a log file")
    func exportVisible() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [try ManagementValueFixture.logPage(messages: ["exported line"])]
        await harness.model.refresh()

        let destination = harness.root.appendingPathComponent("logs.txt")
        try harness.model.exportVisible(to: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written.contains("exported line"))
        #expect(written.split(separator: "\n").count == 1)
    }

    @Test("an empty result draws the empty state rather than a blank list")
    func emptyState() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [try ManagementValueFixture.logPage(messages: [], cursor: nil)]

        await harness.model.refresh()

        #expect(harness.model.entries.isEmpty)
        #expect(harness.model.emptyState.message == ProductStrings[.logsEmpty])
    }

    @Test("a truncated page is reported, because the daemon dropped rows to fit")
    func truncationIsReported() async throws {
        let harness = try LogsHarness()
        harness.gateway.logPages = [
            try ManagementValueFixture.logPage(messages: ["kept"], truncated: true)
        ]

        await harness.model.refresh()

        #expect(harness.model.status == .truncated(ProductStrings[.logsTruncated]))
    }
}

@MainActor
final class LogsHarness {
    let root: URL
    let gateway = FakeDaemonGateway()
    let model: LogsModel

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-logs-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        gateway.logPages = [try ManagementValueFixture.logPage(messages: ["a line"])]
        model = LogsModel(gateway: gateway)
        model.setVisible(true)
    }

    deinit {
        let path = root.path
        guard path.contains("fermix-logs-tests"), path.split(separator: "/").count >= 4 else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
