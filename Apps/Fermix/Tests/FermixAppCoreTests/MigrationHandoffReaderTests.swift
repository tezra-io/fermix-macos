import Foundation
import Testing

@testable import FermixAppCore

/// The migration handoff journal (M34 §15.0 step 5, §15.2).
///
/// `fermix migrate-to-app` knows the home the operator was actually using —
/// which may be a custom `FERMIX_HOME` known only to a shell or to the launchd
/// unit it just removed — and the app cannot rediscover it. The journal is that
/// one fact, handed over once.
@Suite("Migration handoff reader")
struct MigrationHandoffReaderTests {
    private func write(_ json: String, to location: BootstrapLocation) throws {
        try FileManager.default.createDirectory(at: location.directoryURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(
            to: location.directoryURL.appendingPathComponent(MigrationHandoffReader.fileName)
        )
    }

    /// The cross-repo pin. Both halves of the handoff live in different
    /// repositories, and they never met: the engine writes
    /// `migration-journal.json` and this reader looked for
    /// `migration-handoff.json`, so a custom `FERMIX_HOME` migrator got a fresh
    /// empty home while their data sat untouched elsewhere (M34 §15.2).
    ///
    /// The golden is the engine's own record, byte for byte apart from the home
    /// path this case has to own. A rename or a schema bump on either side
    /// fails here rather than producing a handoff nobody reads.
    @Test("the engine's own journal is read at the name the engine writes")
    func readsTheEnginesGoldenRecord() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let home = temporary.url.appendingPathComponent("custom-home", isDirectory: true)

        let golden = try String(
            contentsOf: Self.goldenURL,
            encoding: .utf8
        ).replacingOccurrences(of: "__FERMIX_HOME__", with: home.path)
        try write(golden, to: location)

        let reader = MigrationHandoffReader(location: location)

        #expect(MigrationHandoffContract.fileName == "migration-journal.json")
        #expect(reader.journalURL.lastPathComponent == MigrationHandoffContract.fileName)
        #expect(reader.exists())
        #expect(try reader.read()?.fermixHome.path == home.path)
        #expect(try reader.read()?.schemaVersion == MigrationHandoffContract.schemaVersion)

        // The engine writes more than the app reads — the transaction id, the
        // phase, the inspected source facts — and the reader ignores them
        // rather than refusing a record it does not fully understand.
        let record = try #require(
            try JSONSerialization.jsonObject(with: Data(golden.utf8)) as? [String: Any]
        )
        for key in MigrationHandoffContract.readKeys {
            #expect(record[key] != nil, "the engine's record carries no \(key)")
        }
        #expect(record["phase"] as? String == "handoff_written")
        #expect(record["transaction_id"] != nil)
    }

    /// Beside the test that reads it, exactly as the source-scan gates read the
    /// tree. It is a test input and never ships in a bundle.
    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/migration-journal.json")
    }

    @Test("no journal is absent rather than an error")
    func absentJournal() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let reader = MigrationHandoffReader(location: BootstrapLocation(homeDirectory: temporary.url))

        #expect(!reader.exists())
        #expect(try reader.read() == nil)
    }

    @Test("a journal names one normalized absolute home")
    func readsTheHome() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let home = temporary.url.appendingPathComponent("custom-home", isDirectory: true)
        try write("{\"schema_version\": 1, \"fermix_home\": \"\(home.path)\"}", to: location)

        let reader = MigrationHandoffReader(location: location)

        #expect(reader.exists())
        #expect(try reader.read()?.fermixHome.path == home.path)
    }

    /// A journal that is there and unusable is raised rather than treated as
    /// absent: adopting the default home instead would silently strand the
    /// operator's real one.
    @Test("an unusable journal is raised, never read as absent")
    func unusableJournalsAreRaised() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let reader = MigrationHandoffReader(location: location)

        try write("not json", to: location)
        #expect(throws: MigrationHandoffDefect.malformed(path: reader.journalURL.path)) {
            _ = try reader.read()
        }

        try write("{\"schema_version\": 9, \"fermix_home\": \"/tmp/x\"}", to: location)
        #expect(throws: MigrationHandoffDefect.unsupportedSchemaVersion(9)) {
            _ = try reader.read()
        }

        try write("{\"schema_version\": 1, \"fermix_home\": \"/\"}", to: location)
        #expect(throws: MigrationHandoffDefect.self) {
            _ = try reader.read()
        }
    }

    /// Clearing is what consumes the journal, and it is only ever called once a
    /// daemon on the adopted home has answered.
    @Test("clearing consumes the journal and clearing nothing is not an error")
    func clearing() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let reader = MigrationHandoffReader(location: location)
        try write("{\"schema_version\": 1, \"fermix_home\": \"\(temporary.url.path)/home\"}", to: location)

        try reader.clear()
        #expect(!reader.exists())

        try reader.clear()
    }
}
