import FermixAppCore
import Foundation
import Testing

@testable import FermixBrowser

/// `act` `kind=upload` on a real web view. The file an upload arms is the
/// answer to the one chooser its own scripted click raises and to no other:
/// an upload that fails, on a ref that is not a file input or on an input
/// whose chooser never opens, leaves nothing armed for the next chooser the
/// tab raises, which whatever page is in the tab by then could open.
@MainActor
@Suite("Browser page upload", .serialized)
struct BrowserPageUploadTests {
    private static let address = "https://jobs.example.com/apply"
    /// A text field, a file input, and a file input that is disabled, whose
    /// click opens no chooser.
    private static let page = """
        <!doctype html><html><head><title>Apply</title></head><body>
        <input type="text" aria-label="Full name">
        <input type="file" aria-label="Resume">
        <input type="file" aria-label="Portfolio" disabled>
        </body></html>
        """

    /// The order the disarm stands on: WebKit asks its delegate for the files
    /// while the page script's click is still running, so the grant is taken
    /// before `openChooser` answers, and disarming it as the upload ends
    /// never takes it from the upload's own chooser.
    @Test("the chooser a scripted click raises is answered before the click's own call returns")
    func chooserAnsweredBeforeTheClickReturns() async throws {
        try await Self.withUploadFile { file in
            let harness = BrowserPageHarness()
            try await harness.load(Self.page, at: Self.address)
            let resume = try await harness.uploadRef(named: "Resume")

            harness.page.pendingUploadPath = file.path
            let opened = try await harness.call("openChooser", [resume], as: BrowserScriptAnswer<EmptyAnswer>.self)
            _ = try opened.value(for: resume)

            #expect(harness.page.pendingUploadPath == nil, "the delegate took the grant before openChooser answered")
        }
    }

    @Test("an upload on a ref that is not a file input throws and leaves no file armed")
    func uploadOnATextFieldLeavesNothingArmed() async throws {
        try await Self.withUploadFile { file in
            let harness = BrowserPageHarness()
            try await harness.load(Self.page, at: Self.address)
            let name = try await harness.uploadRef(named: "Full name")

            await #expect(throws: BrowserPageDriveError.notFileInput(name)) {
                _ = try await harness.page.act(.upload(ref: name, path: file.path), observing: nil)
            }
            #expect(harness.page.pendingUploadPath == nil, "the grant is disarmed when the upload fails")
        }
    }

    @Test("an upload whose chooser never opens throws and leaves no file armed")
    func uploadWithNoChooserLeavesNothingArmed() async throws {
        try await Self.withUploadFile { file in
            let harness = BrowserPageHarness()
            try await harness.load(Self.page, at: Self.address)
            let portfolio = try await harness.uploadRef(named: "Portfolio")

            await #expect(throws: BrowserPageDriveError.uploadNotAccepted(portfolio)) {
                _ = try await harness.page.act(.upload(ref: portfolio, path: file.path), observing: nil)
            }
            #expect(harness.page.pendingUploadPath == nil, "the grant is disarmed when no chooser opened")
        }
    }
}

/// The page script's empty answer, `{}`.
private struct EmptyAnswer: Decodable {}

private extension BrowserPageUploadTests {
    /// Writes a small file to upload in a folder of its own for the length of
    /// `body`, and removes the folder on every path.
    static func withUploadFile(_ body: @MainActor (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "fermix-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { removeFolder(folder) }

        let file = folder.appending(path: "resume.txt", directoryHint: .notDirectory)
        try Data("Avery Quill, cartographer".utf8).write(to: file)
        try await body(file)
    }

    static func removeFolder(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Issue.record(error, "the upload file's folder stayed behind")
        }
    }
}

private extension BrowserPageHarness {
    /// The ref of the first node named `name`, from the page script's own snapshot.
    func uploadRef(named name: String) async throws -> Int {
        let snapshot = try await page.snapshot(BrowserSnapshotRequest(mode: .full, maxChars: 200_000, depth: 200))
        return try #require(snapshot.nodes.first { $0.name == name && $0.ref != nil }?.ref)
    }
}
