import Foundation

/// Reads and writes `launcher.json` in this build's Application Support folder
/// (`BootstrapLocation`), the one pre-daemon bootstrap record on macOS.
///
/// The GUI, the agent, and the bundled CLI all take the Fermix home from here.
/// Production code reads no `FERMIX_HOME`, no shell startup file, and no
/// secret-bearing environment value: there is one source, and it is this file.
public struct BootstrapStore {
    private let location: BootstrapLocation
    private let fileManager: FileManager
    private let validator: BootstrapHomeValidator
    private let file: JournalFile

    public init(location: BootstrapLocation, fileManager: FileManager = .default) {
        self.location = location
        self.fileManager = fileManager
        self.validator = BootstrapHomeValidator(location: location, fileManager: fileManager)
        self.file = JournalFile(
            directory: location.directoryURL,
            name: BootstrapLocation.recordName,
            fileManager: fileManager
        )
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
            registeredAgentPlistSHA256: document.registeredAgentPlistSHA256,
            registeredAppBuild: document.registeredAppBuild
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

    /// The chat socket for this account's home, named on the record for the
    /// same reason.
    public func companionSocketPath() throws -> String {
        BootstrapRecord(fermixHome: try resolvedHome()).companionSocketURL.path
    }

    /// The browser host socket for this account's home, named on the record
    /// for the same reason.
    public func browserHostSocketPath() throws -> String {
        BootstrapRecord(fermixHome: try resolvedHome()).browserHostSocketURL.path
    }

    /// The native host socket for this account's home, named on the record
    /// for the same reason.
    public func nativeHostSocketPath() throws -> String {
        BootstrapRecord(fermixHome: try resolvedHome()).nativeHostSocketURL.path
    }

    /// The engine's workspace directory for this account's home, the root an
    /// upload path must fall under.
    public func workspaceDirectoryURL() throws -> URL {
        BootstrapRecord(fermixHome: try resolvedHome()).workspaceDirectoryURL
    }

    /// The engine's browser directory for this account's home, the root a
    /// screenshot or a PDF path must fall under.
    public func browserDirectoryURL() throws -> URL {
        BootstrapRecord(fermixHome: try resolvedHome()).browserDirectoryURL
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
    ///
    /// Both halves of the receipt move together. Carrying one forward and
    /// dropping the other would publish a registration some other build made as
    /// this build's own, which is the exact comparison the launch rebuild
    /// stands on.
    @discardableResult
    public func save(path: String, receipt: AgentRegistrationReceipt? = nil) throws -> BootstrapRecord {
        let home = try normalize(path)
        do {
            try validator.checkAccess(home)
        } catch let defect as BootstrapHomeDefect {
            throw BootstrapStoreError.invalidHome(defect)
        }

        let recorded = recordedReceipt(orWriting: receipt)
        let document = BootstrapDocument(
            schemaVersion: BootstrapRecord.supportedSchemaVersion,
            fermixHome: home,
            registeredAgentPlistSHA256: recorded?.plistSHA256,
            registeredAppBuild: recorded?.appBuild
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(document))

        return BootstrapRecord(
            fermixHome: URL(fileURLWithPath: home, isDirectory: true),
            registeredAgentPlistSHA256: recorded?.plistSHA256,
            registeredAppBuild: recorded?.appBuild
        )
    }

    /// The receipt this save writes: the caller's, or the one already on disk.
    private func recordedReceipt(orWriting receipt: AgentRegistrationReceipt?) -> AgentRegistrationReceipt? {
        if let receipt { return receipt }
        guard let existing = try? load(), let digest = existing.registeredAgentPlistSHA256 else { return nil }

        return AgentRegistrationReceipt(plistSHA256: digest, appBuild: existing.registeredAppBuild)
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

    /// Records the plist that was actually registered with `SMAppService`, and
    /// the build of the app bundle that registered it.
    ///
    /// Written by the one caller that performs the registration, so the receipt
    /// and the registration cannot disagree.
    @discardableResult
    public func recordAgentRegistration(plistSHA256: String, appBuild: String) throws -> BootstrapRecord {
        precondition(!plistSHA256.isEmpty, "a registration receipt is a digest")
        precondition(!appBuild.isEmpty, "a registration receipt names the build that made it")

        return try save(
            path: try resolvedHome().path,
            receipt: AgentRegistrationReceipt(plistSHA256: plistSHA256, appBuild: appBuild)
        )
    }

    /// Which bundle wrote the registration this account carries, compared with
    /// the build running now. An unreadable record is not a registration this
    /// build made, and it is not a fresh account either: recovery owns it, and
    /// nothing is rebuilt over it.
    public func registrationBuild(matching appBuild: String) -> AgentRegistrationBuild {
        guard let record = try? load() else { return .unregistered }

        return record.registrationBuild(matching: appBuild)
    }

    /// Clears the bootstrap, as in-app uninstall does. Removing a record that is
    /// not there is reported, not treated as success.
    public func remove() throws {
        guard file.exists else {
            throw BootstrapStoreError.absent(path: file.url.path)
        }

        do {
            try file.remove()
        } catch let failure as JournalFileError {
            throw BootstrapStoreError(failure)
        }
    }

    // MARK: - Writing

    /// Through the one file layer every record beside the bundle uses: a
    /// reader sees the previous record or the new one, never a half-written
    /// file, and the directory is flushed so the rename survives a power loss.
    private func write(_ data: Data) throws {
        do {
            try file.write(data)
        } catch let failure as JournalFileError {
            throw BootstrapStoreError(failure)
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

private extension BootstrapStoreError {
    /// The file layer's failure in the store's own vocabulary, so callers keep
    /// catching one error type.
    init(_ failure: JournalFileError) {
        switch failure {
        case .readFailed(let path, _):
            self = .unreadable(path: path)
        case .writeFailed(let path, let code):
            self = .writeFailed(path: path, errno: code)
        case .directoryCreationFailed(let path, let code):
            self = .directoryCreationFailed(path: path, code: code)
        }
    }
}
