import Darwin
import Foundation

/// Why a journal file could not be read, written or removed. Every case names
/// the path, because a journal is read after a crash and "write failed" without
/// one says nothing about which record is missing.
enum JournalFileError: Error, Equatable, Sendable {
    /// The record is there and its bytes could not be read: no permission, an
    /// I/O failure, a directory where the file should be. It is deliberately
    /// not the same answer as "there is no record", because a caller told the
    /// record is absent proceeds over a transaction nothing has resolved.
    case readFailed(path: String, code: Int)
    case writeFailed(path: String, errno: Int32)
    case directoryCreationFailed(path: String, code: Int)
}

/// The bytes half of a recovery journal: create, fill, flush, rename, remove.
///
/// Two journals need exactly this and nothing more — the lifecycle record and
/// the update record — so the mechanics live here once rather than being
/// written twice. A reader sees the previous entry or the new one and never a
/// half-written file, and the `fsync` is what makes that true across a power
/// loss rather than only across a crash.
struct JournalFile {
    let url: URL
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, name: String, fileManager: FileManager) {
        precondition(!name.isEmpty, "a journal file has a name")

        self.directory = directory
        self.url = directory.appendingPathComponent(name, isDirectory: false)
        self.fileManager = fileManager
    }

    var exists: Bool { fileManager.fileExists(atPath: url.path) }

    /// The record's bytes, or nil where there is no record at all.
    ///
    /// A record that is present and cannot be read is thrown rather than
    /// answered as absent: it is the one file that says what the last
    /// transaction did, and reading "no record" off it is how an unresolved
    /// update comes to look like an ordinary launch.
    func read() throws -> Data? {
        guard exists else { return nil }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw JournalFileError.readFailed(path: url.path, code: (error as NSError).code)
        }
    }

    /// Create, fill, flush, rename.
    func write(_ data: Data) throws {
        try createDirectory()

        let finalPath = url.path
        let temporaryPath = finalPath + ".tmp-\(UUID().uuidString)"
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw JournalFileError.writeFailed(path: temporaryPath, errno: errno)
        }

        do {
            try writeAll(data, to: descriptor, path: temporaryPath)
            guard fsync(descriptor) == 0 else {
                throw JournalFileError.writeFailed(path: temporaryPath, errno: errno)
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
            throw JournalFileError.writeFailed(path: finalPath, errno: code)
        }

        try syncDirectory()
    }

    /// Removing a record that was never written is the normal end of a
    /// transaction that had nothing to record, so it is not an error.
    func remove() throws {
        guard exists else { return }
        guard unlink(url.path) == 0 else {
            throw JournalFileError.writeFailed(path: url.path, errno: errno)
        }

        try syncDirectory()
    }

    /// Flushes the directory entry, which is what makes the record's *name*
    /// durable.
    ///
    /// The `fsync` on the descriptor above flushes the bytes. A rename and an
    /// unlink change the directory instead, and a directory left unflushed can
    /// come back after a power loss to the entry it had before: a cleared
    /// record reappearing, or a record that was renamed into place missing
    /// entirely. Both are exactly the states the launch reconcile reads.
    private func syncDirectory() throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw JournalFileError.writeFailed(path: directory.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }

        guard fsync(descriptor) == 0 else {
            throw JournalFileError.writeFailed(path: directory.path, errno: errno)
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
                throw JournalFileError.writeFailed(path: path, errno: errno)
            }
            offset += written
        }
    }

    private func createDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw JournalFileError.directoryCreationFailed(
                path: directory.path,
                code: (error as NSError).code
            )
        }
    }
}
