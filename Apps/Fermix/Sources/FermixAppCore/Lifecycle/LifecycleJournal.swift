import Foundation

/// Which transaction a journal entry belongs to.
public enum LifecycleTransactionKind: String, Codable, Equatable, Sendable {
    case enable
    case disable
    case restart
}

/// Where a transaction had got to. Every transaction is preflight, prepare,
/// mutate, verify, then clear, so an interrupted one is recoverable from the
/// phase it stopped in.
public enum LifecyclePhase: String, Codable, Equatable, Sendable {
    case preflight
    case prepare
    case mutate
    case verify
}

/// The record an interrupted lifecycle transaction leaves behind.
public struct LifecycleJournalEntry: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let transactionId: UUID
    public let kind: LifecycleTransactionKind
    public var phase: LifecyclePhase
    /// The daemon that was running when the transaction started, so recovery
    /// can tell "it exited" from "a new one is running".
    public let originalPid: Int32?
    public let previousRegistration: ServiceRegistrationStatus
    public let startedAt: Date

    public init(
        schemaVersion: Int = LifecycleJournalEntry.supportedSchemaVersion,
        transactionId: UUID,
        kind: LifecycleTransactionKind,
        phase: LifecyclePhase,
        originalPid: Int32?,
        previousRegistration: ServiceRegistrationStatus,
        startedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.transactionId = transactionId
        self.kind = kind
        self.phase = phase
        self.originalPid = originalPid
        self.previousRegistration = previousRegistration
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionId = "transaction_id"
        case kind
        case phase
        case originalPid = "original_pid"
        case previousRegistration = "previous_registration"
        case startedAt = "started_at"
    }
}

public enum LifecycleJournalError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformed(path: String)
    case writeFailed(path: String, errno: Int32)
    case directoryCreationFailed(path: String, code: Int)
}

/// The app-owned recovery journal for enable, disable, and restart.
///
/// It lives beside the bootstrap record — outside the app bundle, which an
/// update replaces wholesale — and holds at most one transaction: they are
/// serialized, so a second one starting while another is journaled is a defect
/// rather than a queue.
///
/// The update transaction keeps its own record (`UpdateJournal`), because this
/// shape carries none of the source and target artifact facts an update
/// recovery reads. Both write through the same `JournalFile`.
public struct LifecycleJournal {
    public static let fileName = "lifecycle-journal.json"

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

    public func load() throws -> LifecycleJournalEntry? {
        guard let data = try bytes() else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry: LifecycleJournalEntry
        do {
            entry = try decoder.decode(LifecycleJournalEntry.self, from: data)
        } catch {
            throw LifecycleJournalError.malformed(path: url.path)
        }

        guard entry.schemaVersion == LifecycleJournalEntry.supportedSchemaVersion else {
            throw LifecycleJournalError.unsupportedSchemaVersion(entry.schemaVersion)
        }

        return entry
    }

    /// The record's bytes, in this journal's own error vocabulary. A record
    /// that is present and unreadable reaches the caller as `malformed`, which
    /// is the answer recovery already knows how to act on.
    private func bytes() throws -> Data? {
        do {
            return try file.read()
        } catch let failure as JournalFileError {
            throw LifecycleJournalError(failure)
        }
    }

    public func write(_ entry: LifecycleJournalEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        do {
            try file.write(try encoder.encode(entry))
        } catch let failure as JournalFileError {
            throw LifecycleJournalError(failure)
        }
    }

    /// Clears a completed transaction. Clearing an empty journal is the normal
    /// end of a transaction that never had to write one, so it is not an error.
    public func clear() throws {
        do {
            try file.remove()
        } catch let failure as JournalFileError {
            throw LifecycleJournalError(failure)
        }
    }
}

private extension LifecycleJournalError {
    /// The file layer's failure in this journal's own vocabulary, so the
    /// coordinator and Recovery keep reading one error type.
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
