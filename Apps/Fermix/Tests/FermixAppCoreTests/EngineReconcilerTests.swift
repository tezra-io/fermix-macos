import Foundation
import Testing

@testable import FermixAppCore

/// The launch reconcile (M34 §7.2).
///
/// Replacing the bundle does not stop the running FermixAgent, so after an
/// upgrade the app in `/Applications` and the daemon in memory are different
/// engines. The reconciler is what notices, and it notices by comparing build
/// ids rather than by asking the daemon whether it feels current.
@Suite("Engine reconciler")
struct EngineReconcilerTests {
    private let bundledDigest = "aa11bb22"

    private func reconciler(bundled: EngineBuild?, digest: String? = "aa11bb22") -> EngineReconciler {
        EngineReconciler(bundled: bundled, bundledPlistDigest: digest)
    }

    private func record(receipt: String?) -> BootstrapRecord {
        BootstrapRecord(
            fermixHome: URL(fileURLWithPath: "/tmp/fermix-reconciler-tests/home", isDirectory: true),
            registeredAgentPlistSHA256: receipt
        )
    }

    @Test("equal build ids do nothing")
    func alignedBuilds() throws {
        let hello = try ManagementValueFixture.hello()
        let bundled = EngineBuild(buildId: try #require(hello.engine.buildId), productVersion: "0.9.0")

        #expect(reconciler(bundled: bundled).reconcile(hello: hello) == .aligned)
    }

    /// The state carries both sides, because the sheet names the version the
    /// operator is leaving as well as the one they are getting.
    @Test("different build ids produce the pending state with both builds")
    func differentBuilds() throws {
        let hello = try ManagementValueFixture.hello(version: "0.9.0")
        let bundled = EngineBuild(buildId: "2", productVersion: "0.10.0")

        let outcome = reconciler(bundled: bundled).reconcile(hello: hello)

        #expect(
            outcome
                == .pendingEngineRestart(
                    running: EngineBuild(buildId: "1", productVersion: "0.9.0"),
                    bundled: bundled
                )
        )
        #expect(outcome.isPending)
    }

    /// Starting owns "nothing answered", not the reconciler: a daemon that never
    /// came up is not a daemon running a stale engine.
    @Test("a daemon that did not answer is unreachable rather than stale")
    func unreachableDaemon() {
        let bundled = EngineBuild(buildId: "2", productVersion: "0.10.0")

        #expect(reconciler(bundled: bundled).reconcile(hello: nil) == .daemonUnreachable)
        #expect(!EngineReconcileOutcome.daemonUnreachable.isPending)
    }

    /// A bundle whose manifest cannot be read has nothing to compare against,
    /// and the engine resolver's own validation is what refuses that bundle.
    @Test("a bundle with no readable manifest reports aligned rather than stale")
    func missingManifest() throws {
        #expect(reconciler(bundled: nil).reconcile(hello: try ManagementValueFixture.hello()) == .aligned)
    }

    // MARK: - The registration receipt

    /// `SMAppService` publishes a status and never the plist it registered, so
    /// the receipt is the only second operand there is (M34 §7.2 step 5).
    ///
    /// These four pin the verdict. What the restart then does with it — the
    /// unregister, the register and the new receipt — is pinned where it
    /// happens, in `LifecycleCoordinatorTests`.
    @Test("matching bytes answer that nothing has to be renewed")
    func matchingReceipt() {
        #expect(reconciler(bundled: nil).registration(recordedIn: record(receipt: bundledDigest)) == .unchanged)
    }

    @Test("bytes that differ from the receipt answer renew")
    func differingReceipt() {
        #expect(reconciler(bundled: nil).registration(recordedIn: record(receipt: "cc33dd44")) == .renew)
    }

    /// A record written before the field existed carries none, and an absent
    /// receipt is a difference rather than a match: treating it as a match would
    /// silently ignore a changed `ProgramArguments` forever.
    @Test("an absent recorded receipt is treated as a difference")
    func absentReceipt() {
        #expect(reconciler(bundled: nil).registration(recordedIn: record(receipt: nil)) == .renew)
    }

    /// A bundle that ships no plist has nothing to compare either, so it
    /// re-registers rather than skipping on a hash nobody has.
    @Test("a bundle with no readable plist answers renew rather than a match")
    func absentBundledDigest() {
        let reconciler = EngineReconciler(bundled: nil, bundledPlistDigest: nil)

        #expect(reconciler.registration(recordedIn: record(receipt: bundledDigest)) == .renew)
    }

    // MARK: - Reading the bundled manifest

    /// The two ways to have nothing to compare are not the same thing.
    ///
    /// A bundle staged before the engine slot is populated carries no manifest,
    /// which is a declared state. A manifest that is there and cannot be read is
    /// a packaging defect: the reconcile answers aligned for the life of the
    /// process, so the `Finish updating Fermix` row never appears again, and
    /// nothing in the GUI validates the bundle — `AgentLauncher.plan` does, and
    /// that runs in FermixAgent. It is logged rather than swallowed.
    @Test("a manifest that is present and unreadable compares nothing")
    func unreadableManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-reconciler-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Removed only when the path is the one this test made: a temporary
        // directory removal with an unchecked path is how a test suite once
        // wiped a home folder.
        defer {
            let path = root.path
            if path.contains("fermix-reconciler-tests"), path.split(separator: "/").count >= 4 {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let absent = EngineReconciler(
            manifestURL: root.appendingPathComponent(EngineManifest.fileName),
            plists: StubAgentPlistDigest(digest: nil)
        )
        #expect(absent.bundledVersion == nil)

        let manifest = root.appendingPathComponent(EngineManifest.fileName)
        try Data("{ not json".utf8).write(to: manifest)
        let unreadable = EngineReconciler(manifestURL: manifest, plists: StubAgentPlistDigest(digest: nil))
        #expect(unreadable.bundledVersion == nil)
        #expect(unreadable.reconcile(hello: try ManagementValueFixture.hello()) == .aligned)

        // The readable one is what a staged bundle carries, and it compares.
        try JSONSerialization
            .data(withJSONObject: EngineManifestFixture.document(), options: [.sortedKeys])
            .write(to: manifest)
        #expect(EngineReconciler(manifestURL: manifest, plists: StubAgentPlistDigest(digest: nil)).bundledVersion != nil)
    }

    // MARK: - What the pending state renders

    /// One Attention row with one action, and the same status line the menu bar
    /// already publishes for a pending restart (M34 §3.2, §3.3).
    @Test("the pending state renders one attention row and the status line")
    func pendingPresentation() {
        let outcome = EngineReconcileOutcome.pendingEngineRestart(
            running: EngineBuild(buildId: "1", productVersion: "0.9.0"),
            bundled: EngineBuild(buildId: "2", productVersion: "0.10.0")
        )

        let row = EngineReconcilePresentation.attentionRow(for: outcome)

        #expect(row?.title == ProductStrings[.settingsEngineSheetTitle])
        #expect(row?.body == "0.9.0 · 0.10.0")
        #expect(row?.action == .restartDaemon)
        #expect(EngineReconcilePresentation.statusLine(for: outcome) == ProductStrings[.statusMenuRestartPending])
    }

    @Test("an aligned reconcile renders nothing at all")
    func alignedPresentation() {
        #expect(EngineReconcilePresentation.attentionRow(for: .aligned) == nil)
        #expect(EngineReconcilePresentation.statusLine(for: .aligned) == nil)
        #expect(EngineReconcilePresentation.attentionRow(for: .daemonUnreachable) == nil)
    }

    /// A daemon released before `build_id` existed cannot be compared, and is
    /// left alone rather than declared stale.
    @Test("a daemon that reports no build id is left alone")
    func missingRunningBuildId() throws {
        let hello = try ManagementValueFixture.hello(buildId: nil)
        let bundled = EngineBuild(buildId: "2", productVersion: "0.10.0")

        #expect(EngineBuild(hello: hello) == nil)
        #expect(reconciler(bundled: bundled).reconcile(hello: hello) == .aligned)
    }
}

/// Home's own reading of the reconcile: the row leads the section, and the
/// status item says the same thing (M34 §3.2, §7.2).
@Suite("Engine reconcile on Home")
@MainActor
struct EngineReconcileHomeTests {
    @Test("a replaced bundle puts the finish-updating row at the top of Attention")
    func pendingRowLeadsAttention() async throws {
        let harness = try HomeHarness(reconciler: EngineReconcilerFixture.upgraded())

        await harness.model.refresh()

        #expect(harness.model.engineReconcile.isPending)
        #expect(harness.model.snapshot.attention.rows.first?.id == "engine_restart_pending")
    }

    @Test("an aligned pair adds no row of its own")
    func alignedAddsNoRow() async throws {
        let harness = try HomeHarness()

        await harness.model.refresh()

        #expect(harness.model.engineReconcile == .aligned)
        #expect(harness.model.snapshot.attention.rows.allSatisfy { $0.id != "engine_restart_pending" })
    }

    /// One owner, two inputs, one derived answer (M34 §7.1, §7.2).
    ///
    /// Both facts that make a restart "the one that finishes an update" live on
    /// the settings model's `engineReconcile`: Home writes the build comparison
    /// after every `hello`, and a refused v2 read writes the other half. They
    /// were two properties of two types on two models, both called
    /// `engineReconcile` and both carrying an `aligned` case, so the one restart
    /// sheet took its title from whichever one its caller happened to hold and a
    /// patch upgrade titled the two doors differently.
    @Test("the reconcile has one owner and the sheet title follows both facts")
    func oneOwnerForBothFacts() async throws {
        let harness = try HomeHarness(reconciler: EngineReconcilerFixture.upgraded())

        #expect(!harness.settings.engineReconcile.isFinishingUpdate, "nothing has been read yet")

        await harness.model.refresh()

        // Home wrote the build comparison into the one value.
        #expect(harness.settings.engineReconcile.builds.isPending)
        #expect(harness.model.engineReconcile == harness.settings.engineReconcile.builds)
        #expect(harness.settings.isFinishingUpdate)
        #expect(harness.model.isFinishingUpdate)
        // A build difference is not a refused method: the panes still serve.
        #expect(!harness.settings.requiresNewerEngine)

        // The other half, written by a v2 read that refused.
        harness.settings.noteRequiresNewerEngine()
        #expect(harness.settings.requiresNewerEngine)
        #expect(harness.settings.isFinishingUpdate)

        // And a served read clears only that half, never the comparison Home
        // owns: a settings read must not erase "the bundle ships a newer
        // engine".
        harness.settings.noteServed()
        #expect(!harness.settings.requiresNewerEngine)
        #expect(harness.settings.engineReconcile.builds.isPending)
        #expect(harness.settings.isFinishingUpdate)
    }

    /// The daemon reports no restart requirement of its own while running a
    /// stale engine, so the status line has to read the reconcile as well.
    @Test("the status line says restart to finish updating while the reconcile is pending")
    func statusLineFollowsTheReconcile() async throws {
        let harness = try HomeHarness(reconciler: EngineReconcilerFixture.upgraded())
        await harness.model.refresh()

        let source = StatusMenuSource(
            model: harness.appModel,
            snapshot: { harness.model.snapshot },
            reconcile: { harness.model.engineReconcile }
        )

        harness.appModel.daemon = .running
        #expect(source.line() == .restartPending)
        #expect(source.line().text == ProductStrings[.statusMenuRestartPending])
    }

    /// And it says it only while a restart would actually change the engine.
    /// The line reads the build comparison rather than the refusal, so a daemon
    /// that already is the bundled engine leaves it on the running state: the
    /// item must never offer to finish an update that no restart can finish
    /// (owner report of 2026-09-04).
    @Test("a refusal a restart cannot fix leaves the status line alone")
    func statusLineIgnoresARefusalARestartCannotFix() async throws {
        let harness = try HomeHarness()
        await harness.model.refresh()
        harness.settings.noteRequiresNewerEngine()

        #expect(harness.settings.requiresNewerEngine)
        #expect(!harness.settings.isFinishingUpdate)

        harness.appModel.daemon = .running
        #expect(harness.statusLine() != .restartPending)
    }
}
