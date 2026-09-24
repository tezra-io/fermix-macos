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

/// Which bundle wrote the agent registration this account carries.
///
/// `SMAppService` keys the job on the bundle at a path, and a cask upgrade
/// replaces that bundle without telling the app: the plist is byte-identical
/// across two releases, so its digest cannot tell the two apart and the build
/// number is the only thing that can.
public enum AgentRegistrationBuild: Equatable, Sendable {
    /// No registration receipt at all, which is a fresh account. Onboarding
    /// owns it, and registering an agent there would be a mutation nobody has
    /// asked for yet.
    case unregistered
    /// The receipt was written by the bundle running now.
    case thisBuild
    /// The receipt was written by another build, or before the build was
    /// recorded at all. Both are the same fact: the job launchd holds was made
    /// by a copy of the app that is no longer the one on disk.
    case anotherBuild
}

/// What one completed registration records.
///
/// The two halves travel together: the plist answers "is this the launchd job
/// this bundle describes" and the build answers "is this the bundle that made
/// it". A save that moved one without the other would publish another build's
/// registration as this build's own.
public struct AgentRegistrationReceipt: Equatable, Sendable {
    public let plistSHA256: String
    /// Absent only on a receipt written before the build was recorded beside
    /// the digest, which is every install made before this version.
    public let appBuild: String?

    public init(plistSHA256: String, appBuild: String?) {
        self.plistSHA256 = plistSHA256
        self.appBuild = appBuild
    }
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
    /// The `build_number` of the app bundle that performed that registration.
    ///
    /// The other half of the same receipt, and the half a bundle replacement
    /// moves: `brew upgrade --cask fermix` swaps the app under a registered
    /// agent, leaves the launchd job behind, and ships the same plist bytes, so
    /// the digest matches while the job belongs to a copy that is gone. Absent
    /// on a record written before this field existed, which is another build.
    public let registeredAppBuild: String?

    public init(
        schemaVersion: Int = BootstrapRecord.supportedSchemaVersion,
        fermixHome: URL,
        registeredAgentPlistSHA256: String? = nil,
        registeredAppBuild: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.fermixHome = fermixHome
        self.registeredAgentPlistSHA256 = registeredAgentPlistSHA256
        self.registeredAppBuild = registeredAppBuild
    }

    /// Which bundle wrote this record's registration, compared with the build
    /// running now.
    public func registrationBuild(matching appBuild: String) -> AgentRegistrationBuild {
        guard registeredAgentPlistSHA256 != nil else { return .unregistered }
        guard let registeredAppBuild, registeredAppBuild == appBuild else { return .anotherBuild }

        return .thisBuild
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
    /// Absent for the same reason, and on every record written before the
    /// build was recorded beside the digest.
    let registeredAppBuild: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fermixHome = "fermix_home"
        case registeredAgentPlistSHA256 = "registered_agent_plist_sha256"
        case registeredAppBuild = "registered_app_build"
    }
}
