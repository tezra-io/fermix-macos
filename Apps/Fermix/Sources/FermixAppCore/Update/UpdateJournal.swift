import Foundation

/// Where an update transaction had got to (M34 §6, steps 1 to 9).
///
/// The phases are ordered by what has been mutated on this Mac, because that is
/// what recovery acts on: a record left at `recorded` changed nothing, and one
/// left at `draining` owes the account its background service back.
///
/// Every case is a boundary the transaction actually writes. A phase nothing
/// writes is a state no crash can land on, so it would be a recovery branch
/// with no way in.
public enum UpdatePhase: String, Codable, CaseIterable, Equatable, Sendable {
    /// The item is downloaded and verified and the user chose Install. Nothing
    /// on this Mac has been changed yet.
    case recorded
    /// A finite `lifecycle.prepare` lease is held and the background agent is
    /// unregistered, inside the postponed relaunch window.
    case draining
    /// The old daemon has exited and released the management socket.
    case stopped
    /// The postponement is released: the bundle is being replaced and the app
    /// relaunched.
    case replacing
    /// The target is installed and is being proven.
    case verifying
}

/// One app bundle's release identity.
///
/// The build number is the ordering fact and the marketing version is what a
/// person reads, so both are recorded: an update that changes only the build is
/// still an update, and one that changes only the marketing version is not.
public struct AppBuild: Codable, Equatable, Sendable {
    public let marketingVersion: String
    public let buildNumber: Int

    public init(marketingVersion: String, buildNumber: Int) {
        precondition(!marketingVersion.isEmpty, "an app build has a marketing version")
        precondition(buildNumber > 0, "an app build number is a positive integer")

        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    /// Read the installed identity that Sparkle compares, rather than source
    /// defaults that packaging may have overridden.
    public init(infoDictionary: [String: Any]) throws {
        guard let version = infoDictionary["CFBundleShortVersionString"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppBuildError.missingMarketingVersion
        }
        guard let raw = infoDictionary["CFBundleVersion"] as? String,
              let number = Int(raw), number > 0, String(number) == raw else {
            throw AppBuildError.invalidBuildNumber
        }

        self.init(marketingVersion: version, buildNumber: number)
    }

    /// The build this copy of Fermix is. `Product.json` is the one place those
    /// two values are written, and `ProductConfiguration` has already refused a
    /// build number that is not a positive integer.
    public init(configuration: ProductConfiguration) {
        guard let number = Int(configuration.buildNumber), number > 0 else {
            preconditionFailure("the product configuration validates build_number as a positive integer")
        }

        self.init(marketingVersion: configuration.marketingVersion, buildNumber: number)
    }

    private enum CodingKeys: String, CodingKey {
        case marketingVersion = "marketing_version"
        case buildNumber = "build_number"
    }
}

public enum AppBuildError: Error, Equatable {
    case missingMarketingVersion
    case invalidBuildNumber
}

/// One side of an update: the app bundle and the engine inside it.
public struct UpdateRelease: Codable, Equatable, Sendable {
    public let app: AppBuild
    public let engine: EngineBuild

    public init(app: AppBuild, engine: EngineBuild) {
        self.app = app
        self.engine = engine
    }
}

/// The source-to-target migration edge (M34 §6, direct-to-latest).
///
/// Engine data migrations are written any-supported-source to latest, so the
/// edge is what the target will migrate this home across. A declared bridge is
/// a named exception the feed steers, never an assumption this app makes.
public struct UpdateMigrationEdge: Codable, Equatable, Sendable {
    public let fromEngineVersion: String
    public let toEngineVersion: String
    public let declaredBridge: Bool

    public init(fromEngineVersion: String, toEngineVersion: String, declaredBridge: Bool) {
        self.fromEngineVersion = fromEngineVersion
        self.toEngineVersion = toEngineVersion
        self.declaredBridge = declaredBridge
    }

    private enum CodingKeys: String, CodingKey {
        case fromEngineVersion = "from_engine_version"
        case toEngineVersion = "to_engine_version"
        case declaredBridge = "declared_bridge"
    }
}

/// The exact installer the source came from.
///
/// Recovery offers it for an explicit reinstall, so all four facts are
/// recorded: a url alone provides no bytes and no way to tell whether the bytes
/// that arrive are the ones that were promised.
public struct UpdateInstaller: Codable, Equatable, Sendable {
    public let url: String
    public let version: String
    public let sha256: String
    public let signingIdentity: String

    public init(url: String, version: String, sha256: String, signingIdentity: String) {
        self.url = url
        self.version = version
        self.sha256 = sha256
        self.signingIdentity = signingIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case url, version, sha256
        case signingIdentity = "signing_identity"
    }
}

/// The record an update transaction leaves behind at every boundary.
///
/// It is written before the first mutation and cleared only once the intended
/// engine has been proven, so every interruption in between leaves a record
/// that names both sides of the update and the installer the source came from.
public struct UpdateJournalEntry: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let transactionId: UUID
    public var phase: UpdatePhase
    /// The daemon that was running when the transaction started, so the
    /// reconcile can tell "the engine came back" from "the old one never left".
    public let originalPid: Int32?
    public let source: UpdateRelease
    public let target: UpdateRelease
    public let migration: UpdateMigrationEdge
    public let previousRegistration: ServiceRegistrationStatus
    /// The installer that produced `source`, for an explicit reinstall.
    public let priorInstaller: UpdateInstaller
    /// Whether the engine was proven stopped before the bundle could be
    /// replaced.
    ///
    /// A separate fact from the phase, because a transaction reaches
    /// `replacing` either way: the barrier that holds the updater is bounded,
    /// and when its bound runs out the extraction happens regardless. It is
    /// written `false` before the first mutation and turned true only by a
    /// drain that succeeded, so a launch that finds the target installed with
    /// this still false knows the swap happened under a live engine and opens
    /// Recovery rather than claiming the update finished.
    public var engineStopped: Bool
    /// Whether returning to exactly `source` is data safe. Rollback is promised
    /// only to the recorded source, and only while this says so: once the
    /// target has migrated the home, going back is a data decision rather than
    /// an installation one.
    public var rollbackSupported: Bool
    public let startedAt: Date

    public init(
        schemaVersion: Int = UpdateJournalEntry.supportedSchemaVersion,
        transactionId: UUID,
        phase: UpdatePhase,
        originalPid: Int32?,
        source: UpdateRelease,
        target: UpdateRelease,
        migration: UpdateMigrationEdge,
        previousRegistration: ServiceRegistrationStatus,
        priorInstaller: UpdateInstaller,
        engineStopped: Bool,
        rollbackSupported: Bool,
        startedAt: Date
    ) {
        precondition(
            source.app.buildNumber != target.app.buildNumber,
            "the two sides of an update are two different app builds"
        )

        self.schemaVersion = schemaVersion
        self.transactionId = transactionId
        self.phase = phase
        self.originalPid = originalPid
        self.source = source
        self.target = target
        self.migration = migration
        self.previousRegistration = previousRegistration
        self.priorInstaller = priorInstaller
        self.engineStopped = engineStopped
        self.rollbackSupported = rollbackSupported
        self.startedAt = startedAt
    }

    /// Which side of the record an installed app bundle is.
    public func side(of installed: AppBuild) -> UpdateSide {
        if installed == source.app { return .source }
        if installed == target.app { return .target }

        return .neither
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionId = "transaction_id"
        case phase
        case originalPid = "original_pid"
        case source, target, migration
        case previousRegistration = "previous_registration"
        case priorInstaller = "prior_installer"
        case engineStopped = "engine_stopped"
        case rollbackSupported = "rollback_supported"
        case startedAt = "started_at"
    }
}

/// Which side of a recorded update an installed bundle is.
public enum UpdateSide: Equatable, Sendable {
    case source
    case target
    /// Neither: what is installed is not a bundle this transaction named.
    case neither
}

public enum UpdateJournalError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformed(path: String)
    /// The two sides name the same app build, so the record describes no update
    /// and the reconcile could not tell which side is installed.
    case notAnUpdate(build: Int)
    case writeFailed(path: String, errno: Int32)
    case directoryCreationFailed(path: String, code: Int)
}

/// The app-owned update record at
/// `~/Library/Application Support/Fermix/update-journal.json`.
///
/// It is a second file rather than a second kind of lifecycle record: an update
/// recovery reads the source and target artifacts and the installer the source
/// came from, and `LifecycleJournalEntry` carries none of those. Both write
/// through the same `JournalFile`, so there is one way to write a record
/// safely.
///
/// It lives outside the bundle because an update replaces the bundle wholesale:
/// a record kept in there would be destroyed by the step it exists to recover
/// from.
public struct UpdateJournal {
    public static let fileName = "update-journal.json"

    private let file: JournalFile

    public init(location: BootstrapLocation, fileManager: FileManager = .default) {
        self.file = JournalFile(
            directory: location.directoryURL,
            name: Self.fileName,
            fileManager: fileManager
        )
    }

    public var url: URL { file.url }

    public var isEmpty: Bool { !file.exists }

    /// The record an interrupted transaction left behind, if there is one.
    public func load() throws -> UpdateJournalEntry? {
        guard let data = try bytes() else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The version is read on its own, before the entry, because a record
        // from a later schema has a later schema's *shape*: decoding the whole
        // entry first refuses it as malformed and buries the one fact that
        // explains it, which is the version this build cannot read.
        try refuseAnUnsupportedSchema(in: data, decoder)
        let entry: UpdateJournalEntry
        do {
            entry = try decoder.decode(UpdateJournalEntry.self, from: data)
        } catch {
            throw UpdateJournalError.malformed(path: url.path)
        }

        // The memberwise initializer asserts this; decoding does not run it, and
        // a record read after a crash is exactly where an impossible one shows
        // up.
        guard entry.source.app.buildNumber != entry.target.app.buildNumber else {
            throw UpdateJournalError.notAnUpdate(build: entry.source.app.buildNumber)
        }

        return entry
    }

    /// The one field that decides whether the rest of the document is this
    /// build's business at all.
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }

    private func refuseAnUnsupportedSchema(in data: Data, _ decoder: JSONDecoder) throws {
        let probe: SchemaProbe
        do {
            probe = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            throw UpdateJournalError.malformed(path: url.path)
        }

        guard probe.schemaVersion != UpdateJournalEntry.supportedSchemaVersion else { return }

        throw UpdateJournalError.unsupportedSchemaVersion(probe.schemaVersion)
    }

    /// The record's bytes, in this journal's own error vocabulary. A record
    /// that is present and unreadable reaches the reconcile as `malformed`,
    /// which is the answer it already opens Recovery on.
    private func bytes() throws -> Data? {
        do {
            return try file.read()
        } catch let failure as JournalFileError {
            throw UpdateJournalError(failure)
        }
    }

    /// One transaction boundary: the whole record, flushed before the step it
    /// records is taken.
    public func write(_ entry: UpdateJournalEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        do {
            try file.write(try encoder.encode(entry))
        } catch let failure as JournalFileError {
            throw UpdateJournalError(failure)
        }
    }

    /// Clears a completed transaction. Clearing an empty journal is the normal
    /// end of a launch that found no record, so it is not an error.
    public func clear() throws {
        do {
            try file.remove()
        } catch let failure as JournalFileError {
            throw UpdateJournalError(failure)
        }
    }
}

private extension UpdateJournalError {
    /// The file layer's failure in this journal's own vocabulary, so one error
    /// type reaches the reconcile.
    init(_ failure: JournalFileError) {
        switch failure {
        case .readFailed(let path, _):
            self = .malformed(path: path)
        case .writeFailed(let path, let code):
            self = .writeFailed(path: path, errno: code)
        case .directoryCreationFailed(let path, let code):
            self = .directoryCreationFailed(path: path, code: code)
        }
    }
}
