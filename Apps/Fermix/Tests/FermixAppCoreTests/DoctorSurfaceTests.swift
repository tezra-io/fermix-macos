import Foundation
import Testing

@testable import FermixAppCore

/// Doctor: typed check rows from `doctor.start` / `doctor.get` / `doctor.cancel`,
/// a local scope that runs on its own, and a network scope that runs only when
/// the user asks for it.
@Suite("Doctor surface")
@MainActor
struct DoctorSurfaceTests {
    @Test("opening Doctor runs the local scope and nothing else")
    func localRunsOnOpen() async throws {
        let harness = try DoctorHarness()

        await harness.model.runLocal()

        #expect(harness.gateway.calls.first == .doctorStart(.local))
        #expect(!harness.gateway.calls.contains(.doctorStart(.network)))
    }

    /// The network scope costs real requests against real endpoints, so it never
    /// starts by itself, and the button says what it will do.
    @Test("the network scope runs only on an explicit action, and its label says so")
    func networkIsExplicit() async throws {
        let harness = try DoctorHarness()

        await harness.model.runLocal()
        #expect(!harness.gateway.calls.contains(.doctorStart(.network)))

        await harness.model.runNetwork()
        #expect(harness.gateway.calls.contains(.doctorStart(.network)))
        #expect(harness.model.networkActionTitle == ProductStrings[.doctorNetworkRun])
        #expect(ProductStrings[.doctorNetworkBody].contains("30 seconds"))
    }

    @Test("a running session is polled until it reaches a terminal status")
    func pollsUntilTerminal() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [
            try ManagementValueFixture.doctorSession(status: "running", checks: []),
            try ManagementValueFixture.doctorSession(status: "running", checks: [("provider_auth", "passed")]),
            try ManagementValueFixture.doctorSession(status: "completed")
        ]

        await harness.model.runLocal()

        #expect(harness.gateway.calls == [
            .doctorStart(.local),
            .doctorGet("doctor:abc123"),
            .doctorGet("doctor:abc123")
        ])
        #expect(harness.model.phase == .finished)
    }

    @Test("cancelling a run stops the polling and reports the cancelled session")
    func cancelStopsTheRun() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [
            try ManagementValueFixture.doctorSession(status: "running", checks: []),
            try ManagementValueFixture.doctorSession(status: "cancelled", checks: [])
        ]

        await harness.model.start(scope: .local)
        await harness.model.cancel()

        #expect(harness.gateway.calls.contains(.doctorCancel("doctor:abc123")))
        #expect(harness.model.session?.status == .cancelled)
        #expect(harness.model.phase == .finished)
    }

    @Test("cancelling with nothing running asks the daemon nothing")
    func cancelWithNothingRunning() async throws {
        let harness = try DoctorHarness()

        await harness.model.cancel()

        #expect(harness.gateway.calls.isEmpty)
    }

    /// A run is declared before the daemon has issued its session id. Cancel
    /// inside that window must address no session at all: the finished run's id
    /// belongs to a session that is already terminal, and cancelling it would
    /// report the new run as over while it kept probing real endpoints.
    @Test("cancelling before the daemon issues a session id cancels nothing")
    func cancelInsideTheStartWindow() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [
            try ManagementValueFixture.doctorSession(id: "doctor:local", status: "completed"),
            try ManagementValueFixture.doctorSession(id: "doctor:network", status: "completed")
        ]
        await harness.model.runLocal()
        #expect(harness.model.session?.sessionId == "doctor:local")

        let gate = AsyncGate()
        harness.gateway.startGate = { await gate.wait() }
        let starting = Task { await harness.model.start(scope: .network) }
        while !harness.model.isRunning { await Task.yield() }

        await harness.model.cancel()

        #expect(!harness.gateway.calls.contains(.doctorCancel("doctor:local")))
        #expect(harness.model.isRunning, "the network run is still in flight")

        gate.release()
        await starting.value
    }

    /// Every one of the eight statuses renders. A status this build has never
    /// seen keeps its own wire value rather than being folded into a neighbour.
    @Test("all eight published statuses render as their own letter pill")
    func everyStatusRenders() {
        let expected: [(ManagementCheckStatus, ProductStringKey)] = [
            (.passed, .doctorPillPass),
            (.warning, .doctorPillWarn),
            (.failed, .doctorPillFail),
            (.unavailable, .doctorPillUnavailable),
            (.skipped, .doctorPillSkipped),
            (.cancelled, .doctorPillCancelled),
            (.timedOut, .doctorPillTimedOut),
            (.notApplicable, .doctorPillNotApplicable)
        ]

        for (status, key) in expected {
            #expect(CheckBadge.forStatus(status).letters == ProductStrings[key], "\(status.wireValue)")
        }
        #expect(CheckBadge.forStatus(.unrecognized("quarantined")).letters == "QUARANTINED")
    }

    /// `not_applicable` is its own class: an app-managed install has checks that
    /// simply do not apply, and folding them into pass would claim a result the
    /// daemon never produced.
    @Test("a not-applicable check renders N/A and counts as neither pass nor fail")
    func notApplicableIsItsOwnClass() throws {
        let session = try ManagementValueFixture.doctorSession(
            checks: [("binary_integrity", "not_applicable"), ("provider_auth", "passed")]
        )
        let rows = DoctorProjection.rows(for: session)

        #expect(rows.first { $0.id == "binary_integrity" }?.badge.letters == "N/A")
        #expect(DoctorProjection.banner(for: session).tone == .pass)
    }

    @Test("the banner states what the run found, and where the answers came from")
    func bannerWording() throws {
        let healthy = try ManagementValueFixture.doctorSession(checks: [("a", "passed"), ("b", "passed")])
        let oneWarning = try ManagementValueFixture.doctorSession(checks: [("a", "passed"), ("b", "warning")])
        let failing = try ManagementValueFixture.doctorSession(checks: [("a", "failed")])

        #expect(DoctorProjection.banner(for: healthy).title == ProductStrings[.doctorBannerHealthy])
        #expect(DoctorProjection.banner(for: oneWarning).title == ProductStrings[.doctorBannerHealthyWithWarning])
        #expect(DoctorProjection.banner(for: oneWarning).tone == .warn)
        #expect(DoctorProjection.banner(for: failing).tone == .fail)
        #expect(DoctorProjection.banner(for: healthy).explainer == ProductStrings[.doctorBannerExplainer])
    }

    @Test("a check's remediation reaches the row as its fix hint")
    func remediationBecomesTheFixHint() throws {
        let session = try ManagementValueFixture.doctorSession(checks: [("codex_login", "warning")])

        let row = DoctorProjection.rows(for: session).first

        #expect(row?.fixHint != nil)
        #expect(row?.fixHint?.isEmpty == false)
    }

    @Test("a refused start is reported rather than leaving an empty list")
    func startFailureIsReported() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorFailure = ManagementError.daemon(
            ManagementFailure(
                code: .busy,
                message: "another Doctor session is running",
                details: ManagementScalarMap(values: [:])
            )
        )

        await harness.model.runLocal()

        #expect(harness.model.phase == .failed("another Doctor session is running"))
    }

    /// The polling loop is bounded: a session that never reaches a terminal
    /// status stops being polled rather than looping forever.
    @Test("polling a session that never finishes is bounded")
    func pollingIsBounded() async throws {
        let harness = try DoctorHarness()
        harness.gateway.doctorScript = [try ManagementValueFixture.doctorSession(status: "running", checks: [])]

        await harness.model.runLocal()

        let polls = harness.gateway.calls.filter { $0 == .doctorGet("doctor:abc123") }.count
        #expect(polls == DoctorPolicy.maximumPolls)
        #expect(harness.model.phase == .failed(ProductStrings[.doctorRunStalled]))
    }
}

/// The SUPPORT card: the two accent actions §5.9 specifies, and the one §10.4
/// calls the floor.
@Suite("Doctor support")
@MainActor
struct DoctorSupportTests {
    @Test("open log folder reveals the daemon's own log directory")
    func openLogFolderRevealsTheLogDirectory() throws {
        let harness = try DoctorHarness()

        harness.model.openLogFolder()

        #expect(harness.revealer.revealed.map(\.path) == ["/tmp/fermix-home-fixture/logs"])
        #expect(harness.model.supportMessage == nil)
    }

    /// A home the app has not recorded yet has no log folder. Saying so is the
    /// point: a button that silently does nothing is worse than a sentence.
    @Test("with no recorded home the action says so instead of opening nothing")
    func openLogFolderWithoutAHome() throws {
        let harness = try DoctorHarness(logFolderFailure: BootstrapStoreError.absent(path: "/nowhere"))

        harness.model.openLogFolder()

        #expect(harness.revealer.revealed.isEmpty)
        #expect(harness.model.supportMessage == ProductStrings[.doctorSupportHomeUnavailable])
    }

    /// The bundle is the daemon's own bounded, field-allowlisted, scrubbed
    /// diagnostics object. Nothing here reads a file or adds a field.
    @Test("exporting the support bundle writes the daemon's diagnostics")
    func exportWritesDaemonDiagnostics() async throws {
        let harness = try DoctorHarness()

        let bundle = await harness.model.exportSupportBundle()

        #expect(harness.gateway.calls.contains(.diagnostics))
        let text = try #require(bundle.map { String(decoding: $0, as: UTF8.self) })
        #expect(text.contains("\"schema_version\""))
        #expect(text.contains("fermix_app_engine"))
        #expect(harness.model.supportMessage == nil)
    }

    @Test("a refused export reports the daemon's own sentence")
    func exportFailureIsReported() async throws {
        let harness = try DoctorHarness(diagnostics: nil)

        let bundle = await harness.model.exportSupportBundle()

        #expect(bundle == nil)
        #expect(harness.model.supportMessage?.isEmpty == false)
    }

    @Test("both accent actions carry the copy the redline publishes")
    func supportCopy() {
        #expect(ProductStrings[.doctorSupportExport] == "Export support bundle")
        #expect(ProductStrings[.doctorSupportOpenLogFolder] == "Open log folder")
    }
}

@MainActor
final class DoctorHarness {
    let gateway = FakeDaemonGateway()
    let revealer = RecordingFolderRevealer()
    let model: DoctorModel

    init(
        logFolderFailure: (any Error)? = nil,
        diagnostics: ManagementDiagnostics? = try? ManagementValueFixture.diagnostics()
    ) throws {
        gateway.doctorScript = [try ManagementValueFixture.doctorSession()]
        gateway.diagnostics = diagnostics
        model = DoctorModel(
            gateway: gateway,
            logFolder: {
                if let logFolderFailure { throw logFolderFailure }
                return URL(fileURLWithPath: "/tmp/fermix-home-fixture/logs", isDirectory: true)
            },
            revealer: revealer,
            sleeper: NoWaitSleeper()
        )
    }
}

/// Records the folders Doctor asked the Finder to reveal.
final class RecordingFolderRevealer: FolderRevealing, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [URL] = []

    var revealed: [URL] { lock.withLock { folders } }

    func reveal(_ url: URL) {
        lock.withLock { folders.append(url) }
    }
}

/// Consumes the poll interval instantly, so a bounded poll is provable without
/// spending its wall-clock time.
struct NoWaitSleeper: Sleeping {
    func sleep(seconds: TimeInterval) async throws {}
}
