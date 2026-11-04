import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// A file the composer holds for the next message.
public struct ChatAttachment: Equatable, Sendable, Identifiable {
    /// Where handing the file over stands.
    public enum Standing: Equatable, Sendable {
        /// Being copied into the engine's inbox.
        case copying
        /// Handed over, and the engine has not answered.
        case handing
        /// The engine holds it, so a message may name it.
        case held
        /// Not attached, in the engine's sentence or this app's.
        case refused(String)
    }

    /// The attach id: the copy's name in the inbox, and what a message names
    /// the file by.
    public let id: String
    /// The name the person knew it by.
    public let name: String
    public let kind: CompanionAttachKind
    /// The file it was copied from, which its chip draws.
    public let source: URL
    public internal(set) var standing: Standing
}

/// What copying a file into the inbox counted.
struct ChatAttachmentCopy: Equatable, Sendable {
    let size: Int
    /// Lowercase hex.
    let sha256: String
}

/// Why a file was not copied into the inbox.
enum ChatAttachmentFailure: Error, Equatable, Sendable {
    /// A folder, a package among them.
    case folder
    /// Larger than the engine takes.
    case tooLarge
    /// The file could not be read.
    case unreadable
    /// The inbox could not be written.
    case unwritable
}

/// The files the composer holds for the next message, each handed over to the
/// engine as soon as it is added (companion version 7), so it is held by the
/// time the message goes.
///
/// Handing one over copies it into the inbox the engine's hello named, at its
/// attach id and mode 0600, counting its size and SHA-256 as it copies, and
/// sends `attach_file`. The engine answers `attach_status` once it holds it,
/// or refuses it with its sentence, and removes the inbox copy either way.
/// The inbox is the engine's: this app writes a file there and never removes
/// one. A copy taken out of the composer while it was copied is still handed
/// over, so the engine clears it, and what a failed copy or a lost connection
/// leaves there goes when the engine next starts. A file larger than the
/// engine's own limit is refused here, in the engine's number, before a byte
/// moves.
///
/// A message goes only once every file is held (`sendable`) and takes them
/// all (`take`). A connection's end refuses each file the engine has not
/// answered for; a held one stays held, since the engine keeps it for the
/// message that follows.
///
/// The session owns the socket: it hands this its way of sending, which sends
/// only on a negotiated connection, and routes the handshake, the drop and
/// the engine's two answers here.
@MainActor
public final class ChatAttachments: ObservableObject {
    /// Puts an event on the negotiated connection, and says whether there was
    /// one.
    typealias Send = (CompanionClientEvent) -> Bool
    /// Copies a file into the inbox, off the main thread.
    typealias Copy = @Sendable (_ source: URL, _ destination: URL, _ maxBytes: Int) -> Result<ChatAttachmentCopy, ChatAttachmentFailure>

    @Published public private(set) var items: [ChatAttachment] = []
    /// The engine's inbox on this connection: nil while there is no
    /// connection or the engine takes no files, and the composer offers
    /// attaching only with one.
    @Published public private(set) var inbox: CompanionAttachmentInbox?

    private let send: Send
    private let ids: () -> String
    private let copy: Copy
    /// Where a pasted picture is written as a file of its own before it is
    /// handed over, which its chip draws; removed as it leaves the composer.
    private let scratch: URL
    private let log = AppLog.logger(.companion)

    init(
        send: @escaping Send,
        ids: @escaping () -> String,
        copy: @escaping Copy = { source, destination, maxBytes in ChatAttachments.copyIn(source, to: destination, maxBytes: maxBytes) },
        scratch: URL = FileManager.default.temporaryDirectory.appending(path: "FermixPasted", directoryHint: .isDirectory)
    ) {
        self.send = send
        self.ids = ids
        self.copy = copy
        self.scratch = scratch
    }

    /// Whether a message may go now: every file it would carry is held.
    public var sendable: Bool {
        items.allSatisfy { $0.standing == .held }
    }

    // MARK: - What the composer asks

    /// Hands over each file, in order. A link to something that is not a file
    /// on this Mac is no file to attach.
    public func add(_ files: [URL]) {
        guard let inbox else { return }

        for file in files where file.isFileURL {
            start(file, name: file.lastPathComponent, inbox: inbox)
        }
    }

    /// Hands over a pasted picture: written as a PNG of its own first, under
    /// the composer's own word for a pasted picture.
    public func addPicture(png: Data) {
        guard let inbox else { return }

        let id = ids()
        let name = ProductStrings[.chatAttachPastedName] + ".png"
        let file = scratch.appending(path: id, directoryHint: .isDirectory).appending(path: name)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
        } catch {
            log.error("could not write a pasted picture: \(String(describing: error), privacy: .public)")
            return
        }
        start(file, name: name, inbox: inbox, id: id)
    }

    /// Takes a file out of the composer. One being handed over still reaches
    /// the engine, which keeps it unnamed until it lets it go.
    public func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        forgetScratch(items.remove(at: index))
    }

    /// The files the message being sent carries, every one held; the
    /// composer is empty after.
    func take() -> [CompanionSentAttachment] {
        let taken = items
        items.removeAll()
        taken.forEach(forgetScratch)
        return taken.map { CompanionSentAttachment(attachId: $0.id, name: $0.name) }
    }

    // MARK: - What the session routes

    /// A handshake: the inbox its hello named, nil when it named none.
    func negotiated(inbox: CompanionAttachmentInbox?) {
        self.inbox = inbox
    }

    /// The connection ended: no file can be handed over until the next one,
    /// and none the engine has not answered for will be answered now.
    func disconnected() {
        inbox = nil
        for index in items.indices where items[index].standing == .handing {
            items[index].standing = .refused(ProductStrings[.chatAttachDisconnected])
        }
    }

    func answered(_ attachId: String, _ status: CompanionAttachStatus) {
        guard let index = items.firstIndex(where: { $0.id == attachId }) else { return }

        switch status {
        case .present:
            items[index].standing = .held
        case .unrecognized(let word):
            log.info("no handling for attach status \(word, privacy: .public)")
        }
    }

    /// Takes the engine's refusal of a file this app handed over, and says
    /// whether it was one: a refusal naming an attach id is always this
    /// app's, whether or not the file is still in the composer.
    func refused(_ refusal: CompanionServerError) -> Bool {
        guard let attachId = refusal.attachId else { return false }

        if let index = items.firstIndex(where: { $0.id == attachId }) {
            let sentence = refusal.message.flatMap { $0.isEmpty ? nil : $0 }
            items[index].standing = .refused(sentence ?? String(format: ProductStrings[.companionErrorRefusedFormat], refusal.reason))
        }
        return true
    }

    // MARK: - Handing over

    private func start(_ source: URL, name: String, inbox: CompanionAttachmentInbox, id: String? = nil) {
        let id = id ?? ids()
        let type = UTType(filenameExtension: source.pathExtension) ?? .data
        items.append(ChatAttachment(id: id, name: name, kind: Self.kind(of: type), source: source, standing: .copying))

        let destination = URL(fileURLWithPath: inbox.dir).appending(path: id)
        let copy = self.copy
        let maxBytes = inbox.maxBytes
        Task {
            let copied = await Task.detached(priority: .userInitiated) { copy(source, destination, maxBytes) }.value
            self.copied(id, name: name, type: type, maxBytes: maxBytes, copied)
        }
    }

    private func copied(
        _ id: String,
        name: String,
        type: UTType,
        maxBytes: Int,
        _ copied: Result<ChatAttachmentCopy, ChatAttachmentFailure>
    ) {
        let index = items.firstIndex(where: { $0.id == id })
        switch copied {
        case .failure(let failure):
            guard let index else { return }

            items[index].standing = .refused(Self.sentence(for: failure, maxBytes: maxBytes))
        case .success(let counted):
            // One taken out while it was copied is handed over all the same,
            // so the engine clears its copy; its answer finds no chip.
            let file = CompanionAttachFile(
                attachId: id,
                kind: Self.kind(of: type),
                mime: type.preferredMIMEType ?? "application/octet-stream",
                sizeBytes: counted.size,
                sha256: counted.sha256,
                name: name
            )
            let handed = send(.attachFile(file))
            guard let index else { return }

            items[index].standing = handed ? .handing : .refused(ProductStrings[.chatAttachDisconnected])
        }
    }

    private func forgetScratch(_ attachment: ChatAttachment) {
        guard attachment.source.path.hasPrefix(scratch.path + "/") else { return }

        try? FileManager.default.removeItem(at: attachment.source.deletingLastPathComponent())
    }

    // MARK: - Words and kinds

    static func sentence(for failure: ChatAttachmentFailure, maxBytes: Int) -> String {
        switch failure {
        case .folder: return ProductStrings[.chatAttachFolder]
        case .tooLarge:
            let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
            return String(format: ProductStrings[.chatAttachTooLargeFormat], limit)
        case .unreadable: return ProductStrings[.chatAttachUnreadable]
        case .unwritable: return ProductStrings[.chatAttachUnwritable]
        }
    }

    /// The kind `attach_file` hints, from the file's type.
    static func kind(of type: UTType) -> CompanionAttachKind {
        if type.conforms(to: .gif) { return .animation }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        let documents: [UTType] = [.pdf, .text, .compositeContent, .presentation, .spreadsheet, .rtf]
        if documents.contains(where: type.conforms) { return .document }
        return .file
    }

    // MARK: - Copying

    /// Copies `source` to `destination`, a new file at mode 0600, counting
    /// its size and SHA-256, and refuses a folder, a file larger than
    /// `maxBytes` before or while it is copied, and a file it cannot read or
    /// write. A copy refused part of the way through is left where it is: the
    /// inbox is the engine's to empty.
    nonisolated static func copyIn(_ source: URL, to destination: URL, maxBytes: Int) -> Result<ChatAttachmentCopy, ChatAttachmentFailure> {
        guard let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
            return .failure(.unreadable)
        }
        if values.isDirectory == true { return .failure(.folder) }
        guard values.isRegularFile == true else { return .failure(.unreadable) }
        if let size = values.fileSize, size > maxBytes { return .failure(.tooLarge) }
        guard let input = try? FileHandle(forReadingFrom: source) else { return .failure(.unreadable) }
        defer { try? input.close() }

        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failure(.unwritable) }

        return stream(input, into: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), maxBytes: maxBytes)
    }

    private nonisolated static func stream(
        _ input: FileHandle,
        into output: FileHandle,
        maxBytes: Int
    ) -> Result<ChatAttachmentCopy, ChatAttachmentFailure> {
        var hasher = SHA256()
        var size = 0
        defer { try? output.close() }

        while true {
            let chunk: Data
            do {
                guard let read = try input.read(upToCount: 1 << 20), !read.isEmpty else { break }
                chunk = read
            } catch {
                return .failure(.unreadable)
            }

            size += chunk.count
            guard size <= maxBytes else { return .failure(.tooLarge) }

            hasher.update(data: chunk)
            do {
                try output.write(contentsOf: chunk)
            } catch {
                return .failure(.unwritable)
            }
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success(ChatAttachmentCopy(size: size, sha256: digest))
    }
}
