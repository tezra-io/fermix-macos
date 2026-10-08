import Foundation
import Testing

@testable import FermixAppCore

/// The one containment test: the host's for a file it reads or writes for
/// the engine (an upload from the workspace, a screenshot or a PDF into the
/// browser directory), and the pane's for a file the person opens. It is
/// decided on where a path really lands, as the engine decides it on its
/// side, never on how the path is spelled.
@Suite("File place")
@MainActor
struct FilePlaceTests {
    /// The proven escape: `root/link` points at a directory outside the root,
    /// so `root/link/secret.txt` reads as inside and is not.
    @Test("a path through a link out of the root is refused")
    func linkOutOfTheRootIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = try Self.directory("root", in: temporary.url)
        let outside = try Self.directory("outside", in: temporary.url)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        try Self.link(root.appendingPathComponent("link"), to: outside)
        try Self.link(root.appendingPathComponent("secret.txt"), to: secret)

        #expect(!FilePlace.path(root.appendingPathComponent("link/secret.txt").path, liesUnder: root))
        #expect(!FilePlace.path(root.appendingPathComponent("secret.txt").path, liesUnder: root))
    }

    /// A file tab reads text, and the open decision sniffs an untyped file,
    /// through one descriptor: the cap is the read's own, and a path that is
    /// a link, a pipe or a folder by the time it is read gives nothing, never
    /// a read that runs forever or waits forever.
    @Test("a regular file is read up to the limit, and a link, a pipe or a folder gives nothing")
    func contentsOfRegularFile() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appendingPathComponent("notes.txt", isDirectory: false)
        try Data("0123456789".utf8).write(to: file)
        let link = temporary.url.appendingPathComponent("zero", isDirectory: false)
        try Self.link(link, to: URL(fileURLWithPath: "/dev/zero", isDirectory: false))
        let pipe = temporary.url.appendingPathComponent("pipe", isDirectory: false)
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let folder = try Self.directory("folder", in: temporary.url)

        #expect(FilePlace.contents(ofRegularFile: file.path, upTo: 4) == Data("0123".utf8))
        #expect(FilePlace.contents(ofRegularFile: file.path, upTo: 64) == Data("0123456789".utf8))
        #expect(FilePlace.contents(ofRegularFile: link.path, upTo: 64) == nil)
        #expect(FilePlace.contents(ofRegularFile: pipe.path, upTo: 64) == nil)
        #expect(FilePlace.contents(ofRegularFile: folder.path, upTo: 64) == nil)
        #expect(FilePlace.contents(ofRegularFile: temporary.url.appendingPathComponent("missing").path, upTo: 64) == nil)
    }

    @Test("a root reached through a link still holds its own files")
    func linkedRootHoldsItsOwnFiles() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let real = try Self.directory("real", in: temporary.url)
        let file = real.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: file)
        let linked = temporary.url.appendingPathComponent("linked")
        try Self.link(linked, to: real)

        #expect(FilePlace.path(linked.appendingPathComponent("report.pdf").path, liesUnder: linked))
        #expect(FilePlace.path(file.path, liesUnder: linked))
        #expect(FilePlace.path(linked.appendingPathComponent("report.pdf").path, liesUnder: real))
        #expect(FilePlace.path(linked.path, liesUnder: real), "the root itself is its own")
    }

    /// A screenshot's path names a file that does not exist yet, and often a
    /// directory or two that the write is about to make.
    @Test("a file about to be written under a real directory is accepted")
    func missingLeafIsAccepted() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = try Self.directory("browser", in: temporary.url)
        let shots = try Self.directory("artifacts", in: root)

        #expect(FilePlace.path(shots.appendingPathComponent("1.png").path, liesUnder: root))
        #expect(FilePlace.path(shots.appendingPathComponent("task-1/screenshots/1.png").path, liesUnder: root))
        #expect(FilePlace.path(temporary.url.appendingPathComponent("nowhere/browser/1.png").path, liesUnder: temporary.url.appendingPathComponent("nowhere/browser")))
    }

    /// Writing through a link writes where it points, and so does writing
    /// through a link whose target is not there yet: that creates the target.
    @Test("a file about to be written through a link out of the root is refused")
    func missingLeafThroughAnEscapingLinkIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = try Self.directory("browser", in: temporary.url)
        let outside = try Self.directory("outside", in: temporary.url)
        try Self.link(root.appendingPathComponent("link"), to: outside)
        try Self.link(root.appendingPathComponent("latest.png"), to: outside.appendingPathComponent("new.png"))
        try Self.link(root.appendingPathComponent("current.png"), to: root.appendingPathComponent("shots/new.png"))

        #expect(!FilePlace.path(root.appendingPathComponent("link/new.png").path, liesUnder: root))
        #expect(!FilePlace.path(root.appendingPathComponent("link/deeper/new.png").path, liesUnder: root))
        #expect(!FilePlace.path(root.appendingPathComponent("latest.png").path, liesUnder: root))
        #expect(FilePlace.path(root.appendingPathComponent("current.png").path, liesUnder: root), "a dangling link that lands inside")
    }

    /// `/tmp` is a link to `/private/tmp`: the engine names one spelling and
    /// the app's root may be the other.
    @Test("/tmp and /private/tmp name one place")
    func tmpAndPrivateTmpAgree() throws {
        let name = "fermix-host-paths-\(UUID().uuidString)"
        let spelled = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let resolved = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: spelled.appendingPathComponent("browser"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resolved) }

        let shot = "browser/artifacts/1.png"
        #expect(FilePlace.path(spelled.appendingPathComponent(shot).path, liesUnder: resolved.appendingPathComponent("browser")))
        #expect(FilePlace.path(resolved.appendingPathComponent(shot).path, liesUnder: spelled.appendingPathComponent("browser")))
        #expect(FilePlace.path(spelled.appendingPathComponent("missing/1.png").path, liesUnder: resolved.appendingPathComponent("missing")))
        #expect(!FilePlace.path(spelled.appendingPathComponent("elsewhere/1.png").path, liesUnder: resolved.appendingPathComponent("browser")))
    }

    @Test("a path that climbs out, a relative path and a loop of links are refused")
    func pathsThatNameNoPlaceAreRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = try Self.directory("workspace", in: temporary.url)
        let outside = try Self.directory("outside", in: temporary.url)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try Self.link(root.appendingPathComponent("a"), to: root.appendingPathComponent("b"))
        try Self.link(root.appendingPathComponent("b"), to: root.appendingPathComponent("a"))

        #expect(!FilePlace.path(root.path + "/../outside/secret.txt", liesUnder: root))
        #expect(!FilePlace.path(root.path + "/missing/../../outside/new.txt", liesUnder: root))
        #expect(!FilePlace.path("workspace/notes.txt", liesUnder: root))
        #expect(!FilePlace.path(root.appendingPathComponent("a/notes.txt").path, liesUnder: root))
    }

    private static func directory(_ name: String, in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory
    }

    private static func link(_ link: URL, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination.path)
    }
}
