import Foundation

@testable import FermixAppCore

/// The two sides of one update, and the record that joins them.
///
/// One fixture rather than a literal per case: every assertion about the
/// reconcile is about which side is installed and which engine answered, and
/// two hand-written builds per test would make those two facts easy to get
/// silently wrong.
enum UpdateFixture {
    static let sourceApp = AppBuild(marketingVersion: "0.1.0", buildNumber: 1)
    static let targetApp = AppBuild(marketingVersion: "0.2.0", buildNumber: 2)
    static let sourceEngine = EngineBuild(buildId: "engine-source", productVersion: "0.10.0")
    static let targetEngine = EngineBuild(buildId: "engine-target", productVersion: "0.11.0")
    /// A third engine that belongs to neither side, for the case where what is
    /// answering is not what either side of the record ships.
    static let foreignEngine = EngineBuild(buildId: "engine-foreign", productVersion: "0.9.0")

    static let source = UpdateRelease(app: sourceApp, engine: sourceEngine)
    static let target = UpdateRelease(app: targetApp, engine: targetEngine)

    static let migration = UpdateMigrationEdge(
        fromEngineVersion: "0.10.0",
        toEngineVersion: "0.11.0",
        declaredBridge: false
    )

    static let priorInstaller = UpdateInstaller(
        url: "https://example.invalid/Fermix-previous.dmg",
        version: "0.1.0",
        sha256: String(repeating: "a", count: 64),
        signingIdentity: "Developer ID Application: Example (TEAMID)"
    )

    /// - Parameter engineStopped: whether the drain was proven before the
    ///   bundle could be replaced. It defaults to what the phase implies and is
    ///   a parameter because the two are separate facts on disk: the barrier
    ///   holding the installer is bounded, so a transaction reaches `replacing`
    ///   either way, and a case about the swap that happened under a live
    ///   engine has to be able to say so.
    static func entry(
        phase: UpdatePhase,
        previousRegistration: ServiceRegistrationStatus = .enabled,
        originalPid: Int32? = 4242,
        rollbackSupported: Bool = true,
        engineStopped: Bool? = nil
    ) -> UpdateJournalEntry {
        UpdateJournalEntry(
            transactionId: UUID(uuidString: "6D6F8D7E-0F1B-4E2A-9C3D-0A1B2C3D4E5F") ?? UUID(),
            phase: phase,
            originalPid: originalPid,
            source: source,
            target: target,
            migration: migration,
            previousRegistration: previousRegistration,
            priorInstaller: priorInstaller,
            engineStopped: engineStopped ?? [.stopped, .replacing, .verifying].contains(phase),
            rollbackSupported: rollbackSupported,
            startedAt: Date(timeIntervalSince1970: 1_757_000_000)
        )
    }

    /// A record from a schema this build does not read, written in that
    /// schema's own shape rather than in this one's.
    ///
    /// A future document that kept the v1 fields would be refused on its
    /// version by luck: the reader has to reach the version before it reaches
    /// anything else, and only a differently shaped document proves that.
    static let futureSchemaJSON = """
    {
      "schema_version": 2,
      "transaction": {
        "id": "6D6F8D7E-0F1B-4E2A-9C3D-0A1B2C3D4E5F",
        "step": "recorded"
      }
    }
    """

    /// A hand-written document, for the shapes the model refuses to build.
    static func json(
        targetBuildNumber: Int = 2,
        targetEngineBuildId: String = "engine-target"
    ) -> String {
        """
        {
          "schema_version": 1,
          "transaction_id": "6D6F8D7E-0F1B-4E2A-9C3D-0A1B2C3D4E5F",
          "phase": "recorded",
          "original_pid": 4242,
          "source": {
            "app": {"marketing_version": "0.1.0", "build_number": 1},
            "engine": {"build_id": "engine-source", "product_version": "0.10.0"}
          },
          "target": {
            "app": {"marketing_version": "0.2.0", "build_number": \(targetBuildNumber)},
            "engine": {"build_id": "\(targetEngineBuildId)", "product_version": "0.11.0"}
          },
          "migration": {
            "from_engine_version": "0.10.0",
            "to_engine_version": "0.11.0",
            "declared_bridge": false
          },
          "previous_registration": "enabled",
          "prior_installer": {
            "url": "https://example.invalid/Fermix-previous.dmg",
            "version": "0.1.0",
            "sha256": "\(String(repeating: "a", count: 64))",
            "signing_identity": "Developer ID Application: Example (TEAMID)"
          },
          "rollback_supported": true,
          "engine_stopped": false,
          "started_at": "2025-09-04T15:33:20Z"
        }
        """
    }

    /// What the reconcile saw, with the aligned launch as the default: this
    /// copy of Fermix, its own engine answering, and the service registered.
    static func observation(
        installedApp: AppBuild = UpdateFixture.sourceApp,
        bundledEngine: EngineBuild? = UpdateFixture.sourceEngine,
        engines: EngineReconcileOutcome = .aligned,
        protocolMismatch: Bool = false,
        registration: ServiceRegistrationStatus = .enabled
    ) -> UpdateObservation {
        UpdateObservation(
            installedApp: installedApp,
            bundledEngine: bundledEngine,
            engines: engines,
            protocolMismatch: protocolMismatch,
            registration: registration
        )
    }
}

/// A throwaway Application Support directory with the update journal over it.
///
/// The real account is never touched: the root is created under the per-user
/// temporary directory with a fresh UUID and nothing else ever writes there.
final class UpdateJournalHarness {
    let root: URL
    let location: BootstrapLocation
    let journal: UpdateJournal

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-update-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        location = BootstrapLocation(homeDirectory: root)
        journal = UpdateJournal(location: location)
        try FileManager.default.createDirectory(
            at: location.directoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Writes a document the model would refuse to build, so the reader's own
    /// refusals can be driven.
    func write(rawJSON: String) throws {
        try Data(rawJSON.utf8).write(to: journal.url)
    }

    /// Every file in the journal directory, so a write that leaves a temporary
    /// behind is visible.
    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: location.directoryURL.path)
    }

    deinit {
        let path = root.path
        guard path.contains("fermix-update-tests"), path.split(separator: "/").count >= 4 else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// The one `hello` the reconcile reads, scripted.
///
/// Answers are consumed in order and the last one repeats, which is what lets a
/// case say "nothing answered until the registration came back" without
/// counting polls.
final class FakeUpdateEngineProbe: UpdateEngineProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [UpdateEngineAnswer]
    private var readCount = 0

    init(_ answers: [UpdateEngineAnswer]) {
        scripted = answers.isEmpty ? [.unreachable] : answers
    }

    var reads: Int { lock.withLock { readCount } }

    func read() async -> UpdateEngineAnswer {
        lock.withLock {
            let answer = scripted[min(readCount, scripted.count - 1)]
            readCount += 1
            return answer
        }
    }
}

/// The launch reconcile, scripted, for the surfaces that only call it.
final class FakeUpdateReconciler: UpdateReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    private var discards = 0

    var outcome: UpdateReconcileOutcome = .proceed
    var failure: (any Error)?
    var barrier: AsyncGate?
    /// What discarding the unreadable record refused with, where it refused.
    var discardFailure: (any Error)?

    var reconcileCount: Int { lock.withLock { runs } }
    /// How many times the unreadable record was thrown away, which is the one
    /// destructive step Recovery's Try again is allowed to take.
    var discardCount: Int { lock.withLock { discards } }

    func reconcile() async throws -> UpdateReconcileOutcome {
        await barrier?.wait()
        let (result, thrown) = lock.withLock { () -> (UpdateReconcileOutcome, (any Error)?) in
            runs += 1
            return (outcome, failure)
        }

        if let thrown { throw thrown }
        return result
    }

    func discardUnusableRecord() throws {
        let thrown = lock.withLock { () -> (any Error)? in
            discards += 1
            return discardFailure
        }

        if let thrown { throw thrown }
    }
}

/// The update seam every surface reads, scripted.
///
/// Home, the command router and the status item read one value and perform one
/// command; a double is what lets a case state the answer without a feed.
@MainActor
final class FakeUpdateChecker: UpdateChecking {
    var reported: UpdateAvailability = .unknown
    var accepts = false
    private(set) var checks = 0

    func availability() -> UpdateAvailability { reported }

    var canCheckForUpdates: Bool { accepts }

    func checkForUpdates() { checks += 1 }
}

/// The updater behind the coordinator, scripted.
@MainActor
final class FakeUpdater: UpdaterDriving {
    var accepts = true
    /// What starting the updater refused with, where it refused.
    var startRefusal: UpdateConfigurationRefusal?
    private(set) var started: UpdateCoordinator?
    private(set) var checks = 0

    var canCheckForUpdates: Bool { accepts }

    func start(_ coordinator: UpdateCoordinator) -> UpdateConfigurationRefusal? {
        started = coordinator
        return startRefusal
    }

    func checkForUpdates() { checks += 1 }
}

/// What the ownership probe answered, stated by the case rather than read off
/// this Mac.
final class FakeDaemonOwnership: DaemonOwnershipReading, @unchecked Sendable {
    var answer: DaemonOwnership = .thisAccount

    func ownership() -> DaemonOwnership { answer }
}

/// One appcast, as the transaction reads it.
///
/// Both sides of an update come from the same feed: the entry for the build
/// that is installed is where the prior artifact comes from, and the offered
/// entry is the target.
enum UpdateFeedFixture {
    static let installedURL = "https://example.invalid/Fermix-previous.dmg"
    static let offeredURL = "https://example.invalid/Fermix-next.dmg"

    static func entry(
        displayVersion: String = "0.2.0",
        versionString: String = "2",
        isCritical: Bool = false,
        isInformationOnly: Bool = false,
        enclosureURL: String? = UpdateFeedFixture.offeredURL,
        engineBuildId: String = "engine-target",
        engineVersion: String = "0.11.0",
        sha256: String = String(repeating: "b", count: 64),
        signingIdentity: String = "Developer ID Application: Example (TEAMID)",
        dropping: String? = nil
    ) -> UpdateFeedEntry {
        var elements = [
            UpdateFeedElement.engineBuildId: engineBuildId,
            UpdateFeedElement.engineVersion: engineVersion,
            UpdateFeedElement.sha256: sha256,
            UpdateFeedElement.signingIdentity: signingIdentity
        ]
        if let dropping { elements.removeValue(forKey: dropping) }

        return UpdateFeedEntry(
            displayVersion: displayVersion,
            versionString: versionString,
            isCritical: isCritical,
            isInformationOnly: isInformationOnly,
            enclosureURL: enclosureURL,
            elements: elements
        )
    }

    /// The entry for the build that is installed, which is the only place the
    /// prior installer can come from.
    static var installed: UpdateFeedEntry {
        entry(
            displayVersion: "0.1.0",
            versionString: "1",
            enclosureURL: installedURL,
            engineBuildId: "engine-source",
            engineVersion: "0.10.0",
            sha256: String(repeating: "a", count: 64)
        )
    }

    static var offered: UpdateFeedEntry { entry() }
}
