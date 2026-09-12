import Foundation
import Testing

@testable import FermixAppCore

/// The durable update journal (M34 §6, R4).
///
/// It lives beside the bootstrap record rather than inside the bundle, because
/// an update replaces the bundle wholesale: a record kept in there would be
/// destroyed by the very step it exists to recover from. Every assertion here
/// is about the record surviving a process that stopped mid-transaction.
@Suite("Update journal")
struct UpdateJournalTests {
    @Test("the record lives beside the bootstrap record, outside the bundle")
    func recordLocation() throws {
        let harness = try UpdateJournalHarness()

        #expect(harness.journal.url.lastPathComponent == "update-journal.json")
        #expect(
            harness.journal.url.deletingLastPathComponent().path
                == harness.location.directoryURL.path
        )
        #expect(harness.journal.url.path.contains("/Library/Application Support/Fermix/"))
        #expect(harness.journal.url.path != harness.location.recordURL.path)
        #expect(harness.journal.url.lastPathComponent != LifecycleJournal.fileName)
    }

    @Test("an empty journal reads as no transaction")
    func emptyJournal() throws {
        let harness = try UpdateJournalHarness()

        #expect(harness.journal.isEmpty)
        #expect(try harness.journal.load() == nil)
    }

    /// Every fact R4 requires, round-tripped. A field that survives the write
    /// and not the read is a field Recovery cannot state.
    @Test("the record carries every fact recovery reads, through a write and a read")
    func roundTrip() throws {
        let harness = try UpdateJournalHarness()
        let entry = UpdateFixture.entry(phase: .draining)

        try harness.journal.write(entry)
        let read = try #require(try harness.journal.load())

        #expect(read == entry)
        #expect(read.schemaVersion == UpdateJournalEntry.supportedSchemaVersion)
        #expect(read.transactionId == entry.transactionId)
        #expect(read.phase == .draining)
        #expect(read.originalPid == 4242)
        #expect(read.source == UpdateFixture.source)
        #expect(read.target == UpdateFixture.target)
        #expect(read.migration == UpdateFixture.migration)
        #expect(read.previousRegistration == .enabled)
        #expect(read.priorInstaller == UpdateFixture.priorInstaller)
        #expect(read.rollbackSupported)
        #expect(!harness.journal.isEmpty)
    }

    /// The on-disk names are the contract R3 writes and a later build reads, so
    /// they are asserted rather than left to whatever the encoder synthesized.
    @Test("the record is written under the published key names")
    func onDiskShape() throws {
        let harness = try UpdateJournalHarness()

        try harness.journal.write(UpdateFixture.entry(phase: .replacing))
        let document = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: harness.journal.url)
            ) as? [String: Any]
        )

        #expect(Set(document.keys) == [
            "schema_version", "transaction_id", "phase", "original_pid",
            "source", "target", "migration", "previous_registration",
            "prior_installer", "engine_stopped", "rollback_supported", "started_at"
        ])
        let source = try #require(document["source"] as? [String: Any])
        #expect(Set(source.keys) == ["app", "engine"])
        let engine = try #require(source["engine"] as? [String: Any])
        #expect(Set(engine.keys) == ["build_id", "product_version"])
        let installer = try #require(document["prior_installer"] as? [String: Any])
        #expect(Set(installer.keys) == ["url", "version", "sha256", "signing_identity"])
    }

    /// A transaction boundary is a rewrite of the same file. A reader sees the
    /// previous entry or the new one, and the temporary the write goes through
    /// is never left behind.
    @Test("a later boundary rewrites the record and leaves no temporary behind")
    func rewritingABoundary() throws {
        let harness = try UpdateJournalHarness()
        var entry = UpdateFixture.entry(phase: .recorded)
        try harness.journal.write(entry)

        entry.phase = .draining
        try harness.journal.write(entry)

        let read = try #require(try harness.journal.load())
        #expect(read.phase == .draining)
        #expect(read.transactionId == entry.transactionId)
        #expect(try harness.leftovers() == ["update-journal.json"])
    }

    @Test("clearing a journal that was never written is not an error")
    func clearEmpty() throws {
        let harness = try UpdateJournalHarness()

        try harness.journal.clear()

        #expect(harness.journal.isEmpty)
    }

    @Test("clearing removes the record")
    func clear() throws {
        let harness = try UpdateJournalHarness()
        try harness.journal.write(UpdateFixture.entry(phase: .verifying))

        try harness.journal.clear()

        #expect(harness.journal.isEmpty)
        #expect(try harness.journal.load() == nil)
    }

    /// A record from a schema this build does not read is refused rather than
    /// decoded into whatever fields happen to line up: recovery acts on it.
    /// The document is written in the later schema's own shape, which is what a
    /// real one would be: the version has to be read before anything else, or
    /// the record is refused as malformed and the reason nobody can act on is
    /// the one that would have explained it.
    @Test("a record from another schema is refused on its version")
    func unsupportedSchema() throws {
        let harness = try UpdateJournalHarness()
        try harness.write(rawJSON: UpdateFixture.futureSchemaJSON)

        #expect(throws: UpdateJournalError.unsupportedSchemaVersion(2)) {
            try harness.journal.load()
        }
    }

    /// A record that is there and cannot be read is not "no record": every
    /// caller treats absence as nothing to do, and this one file is what says
    /// an update was interrupted. A directory at the path is the cheapest
    /// unreadable file there is, and it touches nothing outside the harness.
    @Test("a record that is present and unreadable throws rather than reading as absent")
    func presentAndUnreadable() throws {
        let harness = try UpdateJournalHarness()
        try FileManager.default.createDirectory(at: harness.journal.url, withIntermediateDirectories: false)

        #expect(throws: UpdateJournalError.malformed(path: harness.journal.url.path)) {
            try harness.journal.load()
        }
        #expect(!harness.journal.isEmpty, "the record is there, so the journal is not empty")
    }

    @Test("a record that is not the published shape is refused")
    func malformed() throws {
        let harness = try UpdateJournalHarness()
        try harness.write(rawJSON: "{\"schema_version\": 1}")

        #expect(throws: UpdateJournalError.self) {
            try harness.journal.load()
        }
    }

    /// The two sides of an update are two different app builds. A record whose
    /// sides are the same build describes no update at all, and the reconcile
    /// would be unable to tell which side is installed.
    @Test("a record whose two sides are the same app build is refused")
    func sameBuildOnBothSides() throws {
        let harness = try UpdateJournalHarness()
        try harness.write(rawJSON: UpdateFixture.json(targetBuildNumber: 1))

        #expect(throws: UpdateJournalError.notAnUpdate(build: 1)) {
            try harness.journal.load()
        }
    }

    /// An engine with no build id names no engine, and the journal is read
    /// after a crash, when nothing else can vouch for it.
    @Test("a record naming an engine with no build id is refused")
    func emptyEngineBuildId() throws {
        let harness = try UpdateJournalHarness()
        try harness.write(rawJSON: UpdateFixture.json(targetEngineBuildId: ""))

        #expect(throws: UpdateJournalError.self) {
            try harness.journal.load()
        }
    }

    /// The lifecycle journal and the update journal are two records, because
    /// the lifecycle record's shape carries none of the artifact facts an
    /// update recovery needs.
    @Test("the update record and the lifecycle record are separate files")
    func separateFromTheLifecycleJournal() throws {
        let harness = try UpdateJournalHarness()
        let lifecycle = LifecycleJournal(location: harness.location)
        try lifecycle.write(
            LifecycleJournalEntry(
                transactionId: UUID(),
                kind: .restart,
                phase: .mutate,
                originalPid: 99,
                previousRegistration: .enabled,
                startedAt: Date()
            )
        )

        try harness.journal.write(UpdateFixture.entry(phase: .draining))

        #expect(try lifecycle.load()?.kind == .restart)
        #expect(try harness.journal.load()?.phase == .draining)
        #expect(try harness.leftovers().sorted() == ["lifecycle-journal.json", "update-journal.json"])
    }

    /// The app build the journal compares against is the one the shipped
    /// configuration names, so nothing restates a version.
    @Test("the running app build comes from the product configuration")
    func appBuildFromConfiguration() throws {
        let configuration = try ProductConfiguration.decode(
            from: ProductFixture.json(buildNumber: "12")
        )

        #expect(
            AppBuild(configuration: configuration)
                == AppBuild(marketingVersion: "0.1.0", buildNumber: 12)
        )
    }
}
