import CryptoKit
import Foundation
import Testing

@testable import FermixAppCore

/// The composer's files (companion version 7): copied into the engine's
/// inbox, handed over by `attach_file`, held or refused on the engine's word,
/// and taken by the message that carries them; and the palette's reading of
/// a draft.
/// What a copy off the main thread saw, read back on it.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    var all: [URL] {
        lock.withLock { urls }
    }
}

@Suite("Chat attachments")
@MainActor
struct ChatAttachmentsTests {
    private static let inbox = CompanionAttachmentInbox(dir: "/inbox", maxBytes: 1_000)

    /// The attachments over a copy a case decides, recording every event sent.
    @MainActor
    private final class Harness {
        var sent: [CompanionClientEvent] = []
        var connected = true
        let attachments: ChatAttachments

        init(copy: @escaping ChatAttachments.Copy = { _, _, _ in .success(ChatAttachmentCopy(size: 12, sha256: String(repeating: "a", count: 64))) }) {
            var issued = 0
            var box: Harness?
            attachments = ChatAttachments(
                send: { event in
                    guard box?.connected == true else { return false }

                    box?.sent.append(event)
                    return true
                },
                ids: {
                    issued += 1
                    return "att-\(issued)"
                },
                copy: copy,
                scratch: FileManager.default.temporaryDirectory.appending(path: "fermix-attach-tests-\(UUID().uuidString)")
            )
            box = self
        }
    }

    /// Waits on the wall clock, so a busy main actor cannot run the bound out.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "the attachments did not reach the expected point")
    }

    // MARK: - Handing over

    @Test("a file is copied in at its attach id, handed over with its size, digest, kind and name, and held on present")
    func handsOverAndHolds() async throws {
        let destinations = Seen()
        let harness = Harness(copy: { _, destination, maxBytes in
            #expect(maxBytes == 1_000)
            destinations.add(destination)
            return .success(ChatAttachmentCopy(size: 12, sha256: String(repeating: "b", count: 64)))
        })
        harness.attachments.negotiated(inbox: Self.inbox)

        harness.attachments.add([URL(fileURLWithPath: "/Users/someone/Desktop/Plan.pdf")])
        #expect(harness.attachments.items.map(\.standing) == [.copying])
        #expect(!harness.attachments.sendable)

        try await Self.waitUntil { harness.attachments.items.first?.standing == .handing }
        #expect(destinations.all == [URL(fileURLWithPath: "/inbox/att-1")])
        #expect(harness.sent == [.attachFile(CompanionAttachFile(
            attachId: "att-1",
            kind: .document,
            mime: "application/pdf",
            sizeBytes: 12,
            sha256: String(repeating: "b", count: 64),
            name: "Plan.pdf"
        ))])

        harness.attachments.answered("att-1", .present)
        #expect(harness.attachments.items.map(\.standing) == [.held])
        #expect(harness.attachments.sendable)
        #expect(harness.attachments.take() == [CompanionSentAttachment(attachId: "att-1", name: "Plan.pdf")])
        #expect(harness.attachments.items.isEmpty)
    }

    @Test("without an inbox nothing is added, and a link that is no file is no file to attach")
    func offersNothingWithoutAnInbox() {
        let harness = Harness()

        harness.attachments.add([URL(fileURLWithPath: "/Users/someone/a.png")])
        #expect(harness.attachments.items.isEmpty)

        harness.attachments.negotiated(inbox: Self.inbox)
        harness.attachments.add([URL(string: "https://example.com/a.png")!])
        #expect(harness.attachments.items.isEmpty)
    }

    @Test("the engine's refusal shows its sentence, keeps the message from going, and is taken whatever the composer holds")
    func showsTheEnginesRefusal() async throws {
        let harness = Harness()
        harness.attachments.negotiated(inbox: Self.inbox)
        harness.attachments.add([URL(fileURLWithPath: "/a/b.zip")])
        try await Self.waitUntil { harness.attachments.items.first?.standing == .handing }

        var refusal = CompanionServerError(
            reason: "request_failed", message: "That file is too large.", field: nil, event: nil, clientMsgId: nil,
            direction: nil, clientVersion: nil, minVersion: nil, maxVersion: nil, ref: nil
        )
        refusal.attachId = "att-1"
        #expect(harness.attachments.refused(refusal))
        #expect(harness.attachments.items.map(\.standing) == [.refused("That file is too large.")])
        #expect(!harness.attachments.sendable)

        refusal.attachId = "att-gone"
        #expect(harness.attachments.refused(refusal))
        refusal.attachId = nil
        #expect(!harness.attachments.refused(refusal))

        harness.attachments.remove("att-1")
        #expect(harness.attachments.items.isEmpty)
        #expect(harness.attachments.sendable)
    }

    @Test("a copy this app refused shows its own sentence, in the engine's limit")
    func refusesWhatCannotBeCopied() async throws {
        let harness = Harness(copy: { _, _, _ in .failure(.tooLarge) })
        harness.attachments.negotiated(inbox: Self.inbox)

        harness.attachments.add([URL(fileURLWithPath: "/a/movie.mov")])

        try await Self.waitUntil { harness.attachments.items.first?.standing != .copying }
        let limit = ByteCountFormatter.string(fromByteCount: 1_000, countStyle: .file)
        #expect(harness.attachments.items.map(\.standing) == [.refused(String(format: ProductStrings[.chatAttachTooLargeFormat], limit))])
        #expect(harness.sent.isEmpty)
    }

    @Test("a drop refuses each file the engine has not answered for, keeps the held ones, and takes the inbox away")
    func dropRefusesWhatWasNotAnswered() async throws {
        let harness = Harness()
        harness.attachments.negotiated(inbox: Self.inbox)
        harness.attachments.add([URL(fileURLWithPath: "/a/one.txt"), URL(fileURLWithPath: "/a/two.txt")])
        try await Self.waitUntil { harness.attachments.items.allSatisfy { $0.standing == .handing } }
        harness.attachments.answered("att-1", .present)

        harness.attachments.disconnected()

        #expect(harness.attachments.inbox == nil)
        #expect(harness.attachments.items.map(\.standing) == [.held, .refused(ProductStrings[.chatAttachDisconnected])])
    }

    @Test("a copy that finishes after the connection went is refused, and one taken out while copying is still handed over for the engine to clear")
    func copyOutlivingItsChipOrConnection() async throws {
        let harness = Harness()
        harness.attachments.negotiated(inbox: Self.inbox)
        harness.connected = false

        harness.attachments.add([URL(fileURLWithPath: "/a/one.txt")])
        try await Self.waitUntil { harness.attachments.items.first?.standing != .copying }
        #expect(harness.attachments.items.map(\.standing) == [.refused(ProductStrings[.chatAttachDisconnected])])

        harness.connected = true
        harness.attachments.add([URL(fileURLWithPath: "/a/two.txt")])
        harness.attachments.remove("att-2")
        try await Self.waitUntil { !harness.sent.isEmpty }
        guard case .attachFile(let file) = harness.sent.first else {
            Issue.record("no attach_file for the copy taken out")
            return
        }
        #expect(file.attachId == "att-2" && file.name == "two.txt")
        #expect(harness.attachments.items.map(\.id) == ["att-1"])
    }

    @Test("an unknown status word leaves the file waiting rather than held")
    func unknownStatusIsNotHeld() async throws {
        let harness = Harness()
        harness.attachments.negotiated(inbox: Self.inbox)
        harness.attachments.add([URL(fileURLWithPath: "/a/one.txt")])
        try await Self.waitUntil { harness.attachments.items.first?.standing == .handing }

        harness.attachments.answered("att-1", .unrecognized("uploading"))

        #expect(harness.attachments.items.map(\.standing) == [.handing])
    }

    @Test("a pasted picture is written as a PNG of its own under the composer's word, and goes with the message")
    func pastedPicture() async throws {
        let seen = Seen()
        let harness = Harness(copy: { source, _, _ in
            seen.add(source)
            return .success(ChatAttachmentCopy(size: 4, sha256: String(repeating: "c", count: 64)))
        })
        harness.attachments.negotiated(inbox: Self.inbox)

        harness.attachments.addPicture(png: Data([0x89, 0x50, 0x4E, 0x47]))

        try await Self.waitUntil { harness.attachments.items.first?.standing == .handing }
        let name = ProductStrings[.chatAttachPastedName] + ".png"
        #expect(harness.attachments.items.map(\.name) == [name])
        #expect(harness.attachments.items.map(\.kind) == [.image])
        let sources = seen.all
        #expect(sources.map(\.lastPathComponent) == [name])
        #expect(FileManager.default.fileExists(atPath: sources[0].path))

        harness.attachments.answered("att-1", .present)
        _ = harness.attachments.take()
        #expect(!FileManager.default.fileExists(atPath: sources[0].path))
    }

    @Test("the kind hinted follows the file's type")
    func kinds() {
        #expect(ChatAttachments.kind(of: .gif) == .animation)
        #expect(ChatAttachments.kind(of: .png) == .image)
        #expect(ChatAttachments.kind(of: .mpeg4Movie) == .video)
        #expect(ChatAttachments.kind(of: .mp3) == .audio)
        #expect(ChatAttachments.kind(of: .pdf) == .document)
        #expect(ChatAttachments.kind(of: .plainText) == .document)
        #expect(ChatAttachments.kind(of: .zip) == .file)
    }

    // MARK: - Copying, on a scratch disk of the case's own

    private static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fermix-copy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a copy counts the bytes and their SHA-256, at mode 0600, and never writes over a file")
    func copiesAndCounts() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "notes.txt")
        let bytes = Data("hello, fermix".utf8)
        try bytes.write(to: source)
        let destination = directory.appending(path: "att-1")

        let copied = ChatAttachments.copyIn(source, to: destination, maxBytes: 1_000)

        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(copied == .success(ChatAttachmentCopy(size: bytes.count, sha256: digest)))
        #expect(try Data(contentsOf: destination) == bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        #expect(ChatAttachments.copyIn(source, to: destination, maxBytes: 1_000) == .failure(.unwritable))
    }

    @Test("a folder, a file over the limit and a missing file are refused before a byte is written")
    func refusesBeforeWriting() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "big.bin")
        try Data(count: 2_000).write(to: source)
        let destination = directory.appending(path: "att-1")

        #expect(ChatAttachments.copyIn(directory, to: destination, maxBytes: 1_000) == .failure(.folder))
        #expect(ChatAttachments.copyIn(source, to: destination, maxBytes: 1_000) == .failure(.tooLarge))
        #expect(ChatAttachments.copyIn(directory.appending(path: "gone"), to: destination, maxBytes: 1_000) == .failure(.unreadable))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - The palette's reading of a draft

    private static let commands = [
        CompanionCommand(name: "new", aliases: ["reset"], description: "Start a new conversation"),
        CompanionCommand(name: "background", aliases: ["bg"], description: "Run a task in the background"),
        CompanionCommand(name: "skills", aliases: [], description: "Review skill proposals"),
    ]

    @Test("a slash alone asks for every command, in the engine's order")
    func slashAlone() {
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/") == Self.commands)
    }

    @Test("a name or alias that starts with the word comes first, then one that holds it")
    func ordering() {
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/b")?.map(\.name) == ["background"])
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/re")?.map(\.name) == ["new", "skills"])
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/S")?.map(\.name) == ["skills", "new", "background"])
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/zzz") == [])
    }

    @Test("a draft without a leading slash, or past its first word, asks for none")
    func notACommand() {
        #expect(ChatCommandFilter.matches(Self.commands, draft: "") == nil)
        #expect(ChatCommandFilter.matches(Self.commands, draft: "new") == nil)
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/new ") == nil)
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/skills review") == nil)
        #expect(ChatCommandFilter.matches(Self.commands, draft: "/new\n") == nil)
    }

    @Test("a chosen command writes its slash, its name and the space its arguments follow")
    func chosenDraft() {
        #expect(ChatCommandFilter.draft(for: Self.commands[1]) == "/background ")
    }
}
