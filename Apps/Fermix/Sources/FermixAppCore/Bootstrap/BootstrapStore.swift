import Darwin
import Foundation

/// Reads and writes `~/Library/Application Support/Fermix/launcher.json`, the
/// one pre-daemon bootstrap record on macOS.
///
/// The GUI, the agent, and the bundled CLI all take the Fermix home from here.
/// Production code reads no `FERMIX_HOME`, no shell startup file, and no
/// secret-bearing environment value: there is one source, and it is this file.
public struct BootstrapStore {
    private let location: BootstrapLocation
    private let fileManager: FileManager
    private let validator: BootstrapHomeValidator

    public init(location: BootstrapLocation, fileManager: FileManager = .default) {
        self.location = location
        self.fileManager = fileManager
        self.validator = BootstrapHomeValidator(location: location, fileManager: fileManager)
    }

    public var recordURL: URL { location.recordURL }

    /// The recorded bootstrap. A missing record is reported as absent — the
    /// caller decides whether that means a fresh account or a broken install.
    public func load() throws -> BootstrapRecord {
        let path = location.recordURL.path
        guard fileManager.fileExists(atPath: path) else {
            throw BootstrapStoreError.absent(path: path)
        }
        guard let data = fileManager.contents(atPath: path) else {
            throw BootstrapStoreError.unreadable(path: path)
        }

        let document: BootstrapDocument
        do {
            document = try JSONDecoder().decode(BootstrapDocument.self, from: data)
        } catch {
            throw BootstrapStoreError.malformed(path: path)
        }
        guard document.schemaVersion == BootstrapRecord.supportedSchemaVersion else {
            throw BootstrapStoreError.unsupportedSchemaVersion(document.schemaVersion)
        }

        let home = try normalize(document.fermixHome)
        return BootstrapRecord(
            schemaVersion: document.schemaVersion,
            fermixHome: URL(fileURLWithPath: home, isDirectory: true),
            registeredAgentPlistSHA256: document.registeredAgentPlistSHA256
        )
    }

    /// What this account's bootstrap record is, as one of three answers.
    ///
    /// A record that exists but cannot be read is not a fresh account, and
    /// treating it as one would send a broken install through onboarding as if
    /// nothing were wrong.
    public func condition() -> BootstrapCondition {
        do {
            _ = try load()
            return .present
        } catch BootstrapStoreError.absent {
            return .absent
        } catch let failure as BootstrapStoreError {
            return .unreadable(failure)
        } catch {
            preconditionFailure("BootstrapStore.load throws only BootstrapStoreError, got \(error)")
        }
    }

    /// The home this account uses: the recorded one, or the account default
    /// that activation will record on a fresh account. Both are properties of
    /// this machine, and neither is read from the environment — production GUI
    /// code never consults `FERMIX_HOME` or `FERMIX_REALTIME_SOCKET`.
    ///
    /// A record that exists but cannot be read is not a fresh account, so it is
    /// raised rather than replaced by the default.
    public func resolvedHome() throws -> URL {
        do {
            return try load().fermixHome
        } catch BootstrapStoreError.absent {
            return location.defaultFermixHome
        }
    }

    /// The voice socket for this account's home. One definition of the file
    /// name, on the record, so the two callers cannot drift.
    public func realtimeSocketPath() throws -> String {
        BootstrapRecord(fermixHome: try resolvedHome()).realtimeSocketURL.path
    }

    @discardableResult
    public func save(fermixHome: URL) throws -> BootstrapRecord {
        try save(path: fermixHome.path)
    }

    /// Records `path` as this account's Fermix home. The home itself is not
    /// created: the engine's first-boot path owns that, and a second creation
    /// path would drift from it.
    ///
    /// The registration receipt is carried forward from the record on disk
    /// unless the caller is writing a new one: recording a home is not a
    /// registration, and dropping the receipt here would make every launch
    /// re-register the agent (M34 §7.2).
    @discardableResult
    public func save(path: String, registeredAgentPlistSHA256: String? = nil) throws -> BootstrapRecord {
        let home = try normalize(path)
        do {
            try validator.checkAccess(home)
        } catch let defect as BootstrapHomeDefect {
            throw BootstrapStoreError.invalidHome(defect)
        }

        let receipt = registeredAgentPlistSHA256 ?? (try? load())?.registeredAgentPlistSHA256
        let document = BootstrapDocument(
            schemaVersion: BootstrapRecord.supportedSchemaVersion,
            fermixHome: home,
            registeredAgentPlistSHA256: receipt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(document))

        return BootstrapRecord(
            fermixHome: URL(fileURLWithPath: home, isDirectory: true),
            registeredAgentPlistSHA256: receipt
        )
    }

    /// Whether this account has ever completed an activation.
    ///
    /// The receipt is written only by a registration that reached `enabled`, so
    /// its presence is the one durable fact that says "this Mac has been through
    /// setup". A record that cannot be read answers false the way an absent one
    /// does: the activation that follows refuses on it anyway (M34 §7.2).
    public func hasRegistrationReceipt() -> Bool {
        (try? load())?.registeredAgentPlistSHA256 != nil
    }

    /// Records the plist that was actually registered with `SMAppService`.
    ///
    /// Written by the one caller that performs the registration, so the receipt
    /// and the registration cannot disagree.
    @discardableResult
    public func recordAgentRegistration(plistSHA256: String) throws -> BootstrapRecord {
        precondition(!plistSHA256.isEmpty, "a registration receipt is a digest")

        return try save(path: try resolvedHome().path, registeredAgentPlistSHA256: plistSHA256)
    }

    /// Clears the bootstrap, as in-app uninstall does. Removing a record that is
    /// not there is reported, not treated as success.
    public func remove() throws {
        let path = location.recordURL.path
        guard fileManager.fileExists(atPath: path) else {
            throw BootstrapStoreError.absent(path: path)
        }
        guard unlink(path) == 0 else {
            throw BootstrapStoreError.writeFailed(path: path, errno: errno)
        }
    }

    // MARK: - Writing

    /// Create, fill, flush, then rename over the record: a reader either sees
    /// the previous record or the new one, never a half-written file. The
    /// temporary file is created owner-only and carries that mode across the
    /// rename, and it is removed on every failure path.
    private func write(_ data: Data) throws {
        try createDirectory()

        let finalPath = location.recordURL.path
        let temporaryPath = finalPath + ".tmp-\(UUID().uuidString)"
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw BootstrapStoreError.writeFailed(path: temporaryPath, errno: errno)
        }

        do {
            try writeAll(data, to: descriptor, path: temporaryPath)
            guard fsync(descriptor) == 0 else {
                throw BootstrapStoreError.writeFailed(path: temporaryPath, errno: errno)
            }
            Darwin.close(descriptor)
        } catch {
            Darwin.close(descriptor)
            unlink(temporaryPath)
            throw error
        }

        guard rename(temporaryPath, finalPath) == 0 else {
            let code = errno
            unlink(temporaryPath)
            throw BootstrapStoreError.writeFailed(path: finalPath, errno: code)
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else {
                throw BootstrapStoreError.writeFailed(path: path, errno: errno)
            }
            offset += written
        }
    }

    private func createDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: location.directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw BootstrapStoreError.directoryCreationFailed(
                path: location.directoryURL.path,
                code: (error as NSError).code
            )
        }
    }

    private func normalize(_ path: String) throws -> String {
        do {
            return try validator.normalize(path)
        } catch let defect as BootstrapHomeDefect {
            throw BootstrapStoreError.invalidHome(defect)
        }
    }
}
