import Foundation

/// Why a candidate Fermix home was refused.
public enum BootstrapHomeDefect: Error, Equatable, Sendable {
    case empty
    case notAbsolute(path: String)
    case relativeTraversal(path: String)
    case forbiddenLocation(path: String, reason: ForbiddenHomeReason)
    case notADirectory(path: String)
    case notOwnedByCurrentUser(path: String, owner: UInt32)
    case notWritable(path: String)
}

/// Locations a Fermix home may not be, each named so the refusal can say what
/// was inspected rather than "invalid path".
public enum ForbiddenHomeReason: String, CaseIterable, Equatable, Sendable {
    case filesystemRoot
    /// The account home itself, which would scatter the daemon's files across it.
    case accountHome
    case systemDirectory
    /// Inside an application bundle, which an update replaces wholesale.
    case applicationsDirectory
    /// Shared temporary storage, which is cleared out from under the daemon.
    case temporaryDirectory
    /// A synced container: file locking there corrupts the SQLite database.
    case cloudSyncedDirectory
    /// The bootstrap directory itself, which would nest the record in its own home.
    case bootstrapDirectory
}

public enum BootstrapStoreError: Error, Equatable, Sendable {
    case absent(path: String)
    case unreadable(path: String)
    case malformed(path: String)
    case unsupportedSchemaVersion(Int)
    case invalidHome(BootstrapHomeDefect)
    case writeFailed(path: String, errno: Int32)
    /// The bootstrap directory could not be created. Carries Foundation's own
    /// error code rather than a guessed errno.
    case directoryCreationFailed(path: String, code: Int)
}

/// The sole pre-daemon bootstrap record: a schema version, one normalized
/// absolute Fermix home, and one registration receipt. It is not a
/// configuration overlay, and nothing else is ever added to it.
public struct BootstrapRecord: Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let fermixHome: URL
    /// The sha256 of the agent plist that was actually registered with
    /// `SMAppService`.
    ///
    /// The one exception to the sentence above, and recorded as such (M34 §7.2
    /// step 5): `SMAppService` publishes a status and never the plist it
    /// registered, so without a receipt a changed `ProgramArguments` or label is
    /// applied silently to nothing. It is a registration receipt, not a
    /// configuration overlay. Absent on a record written before the field
    /// existed, which the reconciler treats as a difference.
    public let registeredAgentPlistSHA256: String?

    public init(
        schemaVersion: Int = BootstrapRecord.supportedSchemaVersion,
        fermixHome: URL,
        registeredAgentPlistSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.fermixHome = fermixHome
        self.registeredAgentPlistSHA256 = registeredAgentPlistSHA256
    }

    /// The management socket for this home.
    public var daemonSocketURL: URL {
        fermixHome.appendingPathComponent("daemon.sock", isDirectory: false)
    }

    /// The voice socket for this home. It is voice-only and keeps its own N/N-1
    /// contract; the management socket is a different wire entirely.
    public var realtimeSocketURL: URL {
        fermixHome.appendingPathComponent("realtime.sock", isDirectory: false)
    }
}

/// What this account's bootstrap record is.
public enum BootstrapCondition: Equatable, Sendable {
    case present
    /// No record: a fresh account, which onboarding is for.
    case absent
    /// A record that is there and unusable, which recovery is for.
    case unreadable(BootstrapStoreError)
}

/// The on-disk shape of `launcher.json`, kept separate from the value so the
/// file format and the model can never drift into each other by accident.
struct BootstrapDocument: Codable, Equatable {
    let schemaVersion: Int
    let fermixHome: String
    /// Absent on every record written before the receipt existed, which is a
    /// difference rather than a match (M34 §7.2).
    let registeredAgentPlistSHA256: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fermixHome = "fermix_home"
        case registeredAgentPlistSHA256 = "registered_agent_plist_sha256"
    }
}
