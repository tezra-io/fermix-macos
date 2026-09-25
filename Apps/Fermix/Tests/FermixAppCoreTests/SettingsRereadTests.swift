import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// Opening Settings and moving between its panes re-reads what the window
/// already shows (owner report of 2026-09-24: switching panes "takes a bit to
/// actually load the next page").
///
/// Three rules, each a value a test can read without a window: a re-read keeps
/// the answer on screen while it runs, an answer equal to the one held
/// publishes nothing, and a read whose answer cannot move until a restart is
/// not repeated.
@Suite("Settings re-reads")
@MainActor
struct SettingsRereadTests {

    // MARK: - What stays on screen

    /// The first read of a value has nothing to show and says so; a re-read has
    /// the last answer and keeps it. Publishing the spinner over it emptied
    /// every pane that draws the value until the reply.
    @Test("only a first read shows the spinner")
    func onlyAFirstReadLoads() async throws {
        let harness = try SettingsHarness()

        let first = await Self.published(harness.model.$inventory) { await harness.model.loadInventory() }
        let again = await Self.published(harness.model.$inventory) { await harness.model.loadInventory() }

        #expect(first.first == .loading, "nothing was on screen, so the read says so")
        #expect(!again.contains(.loading))
        #expect(!harness.model.sections(for: .voice).isEmpty, "the panes kept their sections")
    }

    /// Every Settings entry re-reads the setup state, and Home's refresh reads
    /// it again on the same click. Providers, Channels, Integrations and
    /// Permissions all draw from it.
    @Test("re-reading the setup state goes from one answer to the next with no spinner between")
    func setupStateStaysOnScreen() async throws {
        let harness = try SettingsHarness()
        await harness.model.refreshSetupState()
        let changed = try ManagementValueFixture.setupState(gating: false, failures: false)
        harness.gateway.setupStateResult = changed

        let seen = await Self.published(harness.model.$setupState) { await harness.model.refreshSetupState() }

        #expect(seen == [.loaded(changed)])
    }

    @Test("re-reading the plugin catalogue goes from one answer to the next with no spinner between")
    func pluginsStayOnScreen() async throws {
        let harness = try SettingsHarness()
        await harness.model.refreshPlugins()
        let changed = try ManagementValueFixture.pluginCatalog(
            named: "google_calendar",
            status: "needs_auth",
            sentence: "Turned on and waiting for a sign-in.",
            primaryVerb: "Sign in",
            primaryAction: "sign_in"
        )
        harness.gateway.pluginsResult = changed

        let seen = await Self.published(harness.model.$plugins) { await harness.model.refreshPlugins() }

        #expect(seen == [.loaded(changed)])
    }

    @Test("re-reading the helper's rights keeps them on screen")
    func computerUseStaysOnScreen() async throws {
        let model = SettingsFixture.model(gateway: try SettingsFixture.gateway())
        await model.permissions.refresh()

        let seen = await Self.published(model.permissions.$computerUse) { await model.permissions.refresh() }

        #expect(!seen.contains(.loading))
        #expect(model.permissions.computerUse.value != nil)
    }

    /// Providers, Coding agents and Meetings probe different targets through
    /// the one value. Replaced whole, each switch between them left the next
    /// pane with nothing to draw until a probe that runs subprocesses in the
    /// daemon answered.
    @Test("each pane's probe keeps the other panes' answers and never blanks its own")
    func detectionsMergeByTarget() async throws {
        let harness = try SettingsHarness()
        let providers: [ManagementDetectTarget] = [.claudeCode, .codexCLI, .existingPrimary]
        await harness.model.refreshDetections(providers)

        let coding = await Self.published(harness.model.$detections) {
            await harness.model.refreshDetections([.harnessVendors])
        }

        #expect(!coding.contains(.loading))
        let held = try #require(harness.model.detections.value)
        #expect(held.result(for: .claudeCode) != nil, "Providers' answer survived a visit to Coding agents")
        #expect(held.result(for: .harnessVendors) != nil)
        #expect(held.result(for: .meetbot) == nil, "nothing was probed that no pane asked for")

        // Back on Providers the probe runs again, and an answer equal to the
        // one held leaves the value as it was.
        let back = await Self.published(harness.model.$detections) {
            await harness.model.refreshDetections(providers)
        }

        #expect(back.isEmpty)
        #expect(harness.gateway.detectedTargets == [providers, [.harnessVendors], providers])
    }

    // MARK: - What is not asked again

    /// The section index changes only across a restart, which reads it again.
    @Test("the section index is read once per engine, not on every entry")
    func inventoryIsReadOncePerEngine() async throws {
        let harness = try SettingsHarness()

        await harness.model.windowAppeared()
        await harness.model.windowAppeared()
        #expect(Self.reads(of: .settingsSections, in: harness.gateway) == 1)
        #expect(Self.reads(of: .setupStateGet, in: harness.gateway) == 2, "the shared state is still re-read")

        await harness.model.restartCompleted()
        #expect(Self.reads(of: .settingsSections, in: harness.gateway) == 2, "a restart brings the engine back")
    }

    /// Each provider's section was re-read in turn on every visit to
    /// Providers. A write re-reads the section it changed, and a restart drops
    /// them all, so a return reads nothing.
    @Test("a return to Providers reads no provider section it already has")
    func providerSectionsAreReadOnce() async throws {
        let harness = try SettingsHarness()
        await harness.model.refreshSetupState()
        let providers = try #require(harness.model.setupState.value?.providers)

        await harness.model.loadProviderSections(for: providers)
        let first = harness.gateway.readSections

        await harness.model.loadProviderSections(for: providers)

        #expect(first.count == providers.count)
        #expect(harness.gateway.readSections == first)
    }

    // MARK: - What is not published again

    /// Every pane observes the one model, so a write of an equal value redrew
    /// the whole window: a Settings entry, a pane's own read and Home's
    /// refresh each made one for nothing.
    @Test("a re-read that finds what is held redraws nothing")
    func unchangedAnswersPublishNothing() async throws {
        let harness = try SettingsHarness()
        let model = harness.model
        await Self.readEverything(model)

        var redraws = 0
        let watch = model.objectWillChange.sink { _ in redraws += 1 }
        defer { watch.cancel() }

        await Self.readEverything(model)
        model.apply(restart: model.restart)

        #expect(redraws == 0)
        #expect(Self.reads(of: .setupStateGet, in: harness.gateway) == 2, "the daemon was asked again")
    }

    // MARK: - The permission ledger

    /// Each `SMAppService` status read is a synchronous XPC round trip of about
    /// 70 ms, and the projection made two. The Voice pane re-projects as it
    /// appears, so opening it froze the window for both.
    @Test("drawing the permission ledger asks macOS nothing, and a refresh reads the registration again")
    func ledgerHoldsTheAgentRegistration() async throws {
        let loginItems = FakeLoginItemService()
        loginItems.preregister(.agent, as: .requiresApproval)
        let ledger = SettingsFixture.model(gateway: try SettingsFixture.gateway(), loginItems: loginItems).permissions

        #expect(loginItems.statusReads == 1, "read once, before the first draw")
        #expect(ledger.row(.backgroundService)?.state == .requiresApproval)
        #expect(ledger.row(.backgroundService)?.action == .openLoginItems)

        var redraws = 0
        let watch = ledger.objectWillChange.sink { _ in redraws += 1 }
        defer { watch.cancel() }
        for _ in 0..<5 { ledger.refreshLocalRights() }

        #expect(loginItems.statusReads == 1, "the Voice pane appearing asks macOS nothing")
        #expect(redraws == 0, "and an unchanged ledger publishes nothing")

        // Approved in Login Items; the Permissions pane's own read sees it.
        loginItems.preregister(.agent)
        await ledger.refresh()

        #expect(ledger.row(.backgroundService)?.state == .granted)
        #expect(ledger.row(.backgroundService)?.action == nil)
    }

    // MARK: - Work that left the main thread or the redraw

    /// The picker reads every bundle's `Info.plist` in three folders.
    @Test("the installed application scan runs off the main thread")
    func applicationScanLeavesTheMainThread() async {
        let source = ThreadRecordingApps()

        let apps = await source.scanned()

        #expect(apps.map(\.id) == ["com.apple.Safari"])
        #expect(source.ranOnMainThread == false)
    }

    /// Built once rather than per call, and still in the Mac's own conventions.
    @Test("the shared formatters write what a fresh formatter writes")
    func sharedFormattersMatchFreshOnes() {
        let money = NumberFormatter()
        money.numberStyle = .currency
        money.maximumFractionDigits = 2
        #expect(CurrencyFormat.wholeCents(1_234) == money.string(from: NSNumber(value: 12.34)))

        let moment = Date(timeIntervalSince1970: 1_790_000_000)
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        #expect(HumaneTime.moment(moment) == dates.string(from: moment))
    }

    /// A time zone's title is composed when the choice is made, so the sheet's
    /// search filters words it already has.
    @Test("a time zone choice carries its title and its search text")
    func timeZoneTitlesAreComposedOnce() {
        let choice = TimeZoneChoice(identifier: "America/New_York")

        #expect(choice.title.hasPrefix("New York"))
        #expect(choice.title.contains("GMT"))
        #expect(choice.searchable == "america/new_york \(choice.title.lowercased())")
    }

    // MARK: - Support

    /// Every value a published property takes while `body` runs, after the
    /// one it held when the watch began.
    private static func published<Value>(
        _ publisher: Published<Value>.Publisher,
        during body: () async -> Void
    ) async -> [Value] {
        var seen: [Value] = []
        let watch = publisher.dropFirst().sink { seen.append($0) }
        await body()
        watch.cancel()

        return seen
    }

    /// Everything a visit to Settings and Home's refresh read.
    private static func readEverything(_ model: SettingsModel) async {
        await model.windowAppeared()
        await model.refreshPlugins()
        await model.refreshDetections([.harnessVendors])
        await model.refreshPermissions()
        model.noteEngineBuilds(.aligned)
    }

    private static func reads(of method: ManagementMethod, in gateway: FakeDaemonGateway) -> Int {
        gateway.calls.filter { $0 == .v2(method) }.count
    }
}

/// An application list that records which thread was asked for it.
final class ThreadRecordingApps: InstalledAppsEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: Bool?

    var ranOnMainThread: Bool? { lock.withLock { onMain } }

    func installedApps() -> [InstalledApp] {
        lock.withLock { onMain = Thread.isMainThread }

        return [InstalledApp(bundleIdentifier: "com.apple.Safari", name: "Safari")]
    }
}
