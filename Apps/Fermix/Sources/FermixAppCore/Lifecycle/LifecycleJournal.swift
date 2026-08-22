import Darwin
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
public struct LifecycleJournal {
    public static let fileName = "lifecycle-journal.json"

    private let location: BootstrapLocation
    private let fileManager: FileManager

    public init(location: BootstrapLocation, fileManager: FileManager = .default) {
        self.location = location
        self.fileManager = fileManager
    }

    public var url: URL {
        location.directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public var isEmpty: Bool {
        !fileManager.fileExists(atPath: url.path)
    }

    public func load() throws -> LifecycleJournalEntry? {
        guard let data = fileManager.contents(atPath: url.path) else { return nil }

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

    public func write(_ entry: LifecycleJournalEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try writeAtomically(try encoder.encode(entry))
    }

    /// Clears a completed transaction. Clearing an empty journal is the normal
    /// end of a transaction that never had to write one, so it is not an error.
    public func clear() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard unlink(url.path) == 0 else {
            throw LifecycleJournalError.writeFailed(path: url.path, errno: errno)
        }
    }

    /// Create, fill, flush, rename: a reader sees the previous entry or the new
    /// one, never a half-written file.
    private func writeAtomically(_ data: Data) throws {
        try createDirectory()

        let finalPath = url.path
        let temporaryPath = finalPath + ".tmp-\(UUID().uuidString)"
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw LifecycleJournalError.writeFailed(path: temporaryPath, errno: errno)
        }

        do {
            try writeAll(data, to: descriptor, path: temporaryPath)
            guard fsync(descriptor) == 0 else {
                throw LifecycleJournalError.writeFailed(path: temporaryPath, errno: errno)
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
            throw LifecycleJournalError.writeFailed(path: finalPath, errno: code)
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
                throw LifecycleJournalError.writeFailed(path: path, errno: errno)
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
            throw LifecycleJournalError.directoryCreationFailed(
                path: location.directoryURL.path,
                code: (error as NSError).code
            )
        }
    }
}
