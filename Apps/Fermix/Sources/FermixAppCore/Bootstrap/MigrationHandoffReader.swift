import Darwin
import Foundation

/// What `fermix migrate-to-app` left behind for this app to adopt.
///
/// The verb knows the home the operator was actually using — which may be a
/// custom `FERMIX_HOME` known only to the exporting shell or to the launchd unit
/// it just removed — and the app cannot rediscover it. The journal is that one
/// fact, handed over once (M34 §15.0 step 5, §15.2).
public struct MigrationHandoff: Equatable, Sendable {
    public static let supportedSchemaVersion = MigrationHandoffContract.schemaVersion

    public let schemaVersion: Int
    public let fermixHome: URL

    public init(schemaVersion: Int = MigrationHandoff.supportedSchemaVersion, fermixHome: URL) {
        self.schemaVersion = schemaVersion
        self.fermixHome = fermixHome
    }
}

/// Why a handoff journal could not be adopted. Each case names what was
/// inspected, so the refusal is diagnosable without opening the file.
public enum MigrationHandoffDefect: Error, Equatable, Sendable {
    case unreadable(path: String)
    case malformed(path: String)
    case unsupportedSchemaVersion(Int)
    case invalidHome(BootstrapHomeDefect)
}

/// The one place the cross-repo handoff is named and versioned.
///
/// Both halves of the handoff are in different repositories, so the file name
/// and the schema version are stated once here and pinned by a golden copied
/// from the engine's own record. A rename on either side fails that test rather
/// than silently producing a handoff nobody reads.
public enum MigrationHandoffContract {
    /// `Fermix.CLI.Migrate.Journal`'s `@filename`.
    public static let fileName = "migration-journal.json"
    /// Its `@schema_version`.
    public static let schemaVersion = 1
    /// The two keys this app reads out of the record. The engine writes more —
    /// the transaction id, the phase, the inspected source facts — and they are
    /// deliberately ignored: the app's half of the handoff is the home.
    public static let readKeys = ["schema_version", "fermix_home"]
}

/// The on-disk shape, kept separate from the value so the file format and the
/// model cannot drift into each other by accident.
private struct MigrationHandoffDocument: Decodable {
    let schemaVersion: Int
    let fermixHome: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fermixHome = "fermix_home"
    }
}

/// Reads and clears the migration handoff journal.
///
/// It parses nothing else out of the file and writes nothing into it: the app's
/// half of the handoff is to adopt the home, record it through `BootstrapStore`,
/// and clear the journal once a daemon on that home has answered `hello`.
public struct MigrationHandoffReader {
    /// The journal sits beside `launcher.json`, which is the one pre-daemon
    /// directory both sides of the handoff already agree on.
    ///
    /// The name is the **engine's**, not this app's: `Fermix.CLI.Migrate.Journal`
    /// writes `migration-journal.json`, and this reader looked for
    /// `migration-handoff.json`. The two never met, so a custom `FERMIX_HOME`
    /// migrator got a fresh empty `~/.fermix` while their data sat untouched
    /// elsewhere, the engine's journal lingered, and the verb's closing line
    /// about the app reading the handoff was false. `MigrationHandoffContract`
    /// is the one place the name is written, and the golden it is pinned
    /// against fails on a rename from either side (M34 §15.2).
    public static let fileName = MigrationHandoffContract.fileName

    private let location: BootstrapLocation
    private let fileManager: FileManager
    private let validator: BootstrapHomeValidator

    public init(location: BootstrapLocation, fileManager: FileManager = .default) {
        self.location = location
        self.fileManager = fileManager
        self.validator = BootstrapHomeValidator(location: location, fileManager: fileManager)
    }

    public var journalURL: URL {
        location.directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Whether a journal is waiting. Welcome's `Use an existing Fermix home…`
    /// link is offered only when this is false: the journal already answers the
    /// question the picker would ask (M34 §15.2).
    public func exists() -> Bool {
        fileManager.fileExists(atPath: journalURL.path)
    }

    /// The journal, or nil where there is none. A journal that is there and
    /// unusable is raised rather than treated as absent: adopting the default
    /// home instead would silently strand the operator's real one.
    public func read() throws -> MigrationHandoff? {
        let path = journalURL.path
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let data = fileManager.contents(atPath: path) else {
            throw MigrationHandoffDefect.unreadable(path: path)
        }

        let document: MigrationHandoffDocument
        do {
            document = try JSONDecoder().decode(MigrationHandoffDocument.self, from: data)
        } catch {
            throw MigrationHandoffDefect.malformed(path: path)
        }
        guard document.schemaVersion == MigrationHandoff.supportedSchemaVersion else {
            throw MigrationHandoffDefect.unsupportedSchemaVersion(document.schemaVersion)
        }

        let home = try normalized(document.fermixHome)
        return MigrationHandoff(
            schemaVersion: document.schemaVersion,
            fermixHome: URL(fileURLWithPath: home, isDirectory: true)
        )
    }

    /// Consumes the journal. It is cleared only after a daemon on the adopted
    /// home has answered, so a boot that failed part-way leaves it for the next
    /// attempt (M34 §15.2).
    public func clear() throws {
        let path = journalURL.path
        guard fileManager.fileExists(atPath: path) else { return }
        guard unlink(path) == 0 else {
            throw MigrationHandoffDefect.unreadable(path: path)
        }
    }

    private func normalized(_ path: String) throws -> String {
        do {
            return try validator.normalize(path)
        } catch let defect as BootstrapHomeDefect {
            throw MigrationHandoffDefect.invalidHome(defect)
        }
    }
}
