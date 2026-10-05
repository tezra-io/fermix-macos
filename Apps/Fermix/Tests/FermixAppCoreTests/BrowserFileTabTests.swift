import Foundation
import Testing
import UniformTypeIdentifiers

@testable import FermixAppCore

/// What the pane shows a file as (plan §8.2), by the type its extension
/// names.
@Suite("Browser file kinds")
struct BrowserFileKindTests {
    @Test("an image WebKit draws, a PDF, an HTML file and text are shown", arguments: [
        ("png", BrowserFileKind.image), ("jpg", .image), ("gif", .image), ("webp", .image), ("heic", .image),
        ("tiff", .image), ("bmp", .image), ("ico", .image), ("svg", .image),
        ("pdf", .pdf),
        ("html", .html), ("htm", .html),
        ("txt", .text), ("md", .text), ("swift", .text), ("c", .text), ("csv", .text), ("css", .text),
        ("json", .text), ("xml", .text), ("yaml", .text), ("yml", .text)
    ])
    func shownKinds(_ pathExtension: String, _ kind: BrowserFileKind) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserFileKind(type) == kind)
    }

    /// Reading a script runs nothing in a tab with no page scripts and no
    /// network, and the person wants to read what the agent wrote.
    @Test("a script is text the pane shows", arguments: ["sh", "command", "zsh", "py", "rb", "applescript"])
    func scriptsAreShownAsText(_ pathExtension: String) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserLocalFile.runs(type))
        #expect(BrowserFileKind(type) == .text)
    }

    /// A script is text too, and an SVG is XML too: the order of the rule is
    /// what keeps each where it belongs.
    @Test("an SVG is drawn as a picture, not read as XML")
    func svgIsAnImage() throws {
        let svg = try #require(UTType(filenameExtension: "svg"))

        #expect(svg.conforms(to: .xml))
        #expect(BrowserFileKind(svg) == .image)
    }

    @Test("an image WebKit does not draw is no image to the pane")
    func undrawableImagesAreNotImages() throws {
        let photoshop = try #require(UTType(filenameExtension: "psd"))

        for type in [photoshop, UTType.rawImage] {
            #expect(type.conforms(to: .image), "\(type.identifier)")
            #expect(BrowserFileKind(type) == nil, "\(type.identifier)")
        }
        #expect(BrowserFileKind.imageTypes.starts(with: [.png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp, .svg, .ico]))
    }

    /// What rich text holds is a word processor's markup, not the words.
    @Test("rich text is not text to the pane")
    func richTextIsNotText() throws {
        let rtf = try #require(UTType(filenameExtension: "rtf"))

        #expect(rtf.conforms(to: .text))
        #expect(BrowserFileKind(rtf) == nil)
    }

    @Test("anything else is not shown by its type", arguments: ["zip", "docx", "mp4", "dmg", "pkg", "fermixunknown"])
    func otherFilesAreNotShown(_ pathExtension: String) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserFileKind(type) == nil)
    }

    @Test("the pane shows text up to 10 MB")
    func textCap() {
        #expect(BrowserFileKind.textSizeCap == 10_000_000)
    }
}

/// A file a link names, as it is on disk: decided on where the link really
/// lands, never on its name, and by an allowlist: shown, a document to its
/// app, or only shown in Finder.
@Suite("Browser local files")
@MainActor
struct BrowserLocalFileTests {
    static let preview = RecordingWorkspaceOpener.preview

    @Test("nothing there, or a link to nothing, is no file")
    func missingIsNothing() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let relative = try #require(URL(string: "file:relative/notes.md"))
        let dangling = place.home.appendingPathComponent("gone.md")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: place.home.appendingPathComponent("never.md").path)

        #expect(BrowserLocalFile(place.home.appendingPathComponent("missing.md")) == nil)
        #expect(BrowserLocalFile(dangling) == nil)
        #expect(BrowserLocalFile(relative) == nil)
    }

    /// Finder shows a folder selected; opening one by its path would launch
    /// an app swapped in under the same name.
    @Test("a folder and an app are only shown in Finder")
    func foldersAndAppsAreRevealed() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        let folder = try place.folder("reports", in: place.home)
        let app = try place.folder("Thing.app", in: place.home)
        _ = try place.folder("Contents", in: app)

        let file = try #require(BrowserLocalFile(folder))
        #expect(file.opening(workspace) == .reveal)
        #expect(file.url == FilePlaceFixture.real(folder))
        #expect(BrowserLocalFile(app)?.opening(workspace) == .reveal)
        #expect(workspace.typesAsked.isEmpty, "an app was looked up for a folder or an app")
    }

    @Test("a script is shown as text and never offered to an app")
    func scriptsAreShownNeverOpened() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        let script = try #require(BrowserLocalFile(try place.write("install.sh", in: place.home)))

        #expect(script.opening(workspace) == .show(.text))
        #expect(script.documentApplication(workspace) == nil)
    }

    @Test("a file with its executable bit set is shown where it is text, and never offered to an app")
    func executableBit() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()

        let notes = try #require(BrowserLocalFile(try place.write("notes.txt", in: place.home, executable: true)))
        let script = try #require(BrowserLocalFile(try place.write("build", in: place.home, executable: true)))
        let binary = try #require(BrowserLocalFile(try place.write("tool", Self.binary, in: place.home, executable: true)))
        let letter = try #require(BrowserLocalFile(try place.write("letter.docx", in: place.home, executable: true)))

        #expect(notes.opening(workspace) == .show(.text))
        #expect(notes.documentApplication(workspace) == nil)
        #expect(script.opening(workspace) == .show(.text), "a script with no extension is text")
        #expect(binary.opening(workspace) == .reveal)
        #expect(letter.opening(workspace) == .reveal)
    }

    /// A type nobody declared, or one known only as data, is text when its
    /// bytes read as text, and never goes to an app either way.
    @Test("a file of no known type is shown where its bytes read as text, and otherwise only in Finder")
    func untypedFilesAreSniffed() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()

        let elixir = try #require(BrowserLocalFile(try place.write("lib.ex", Data("defmodule Fermix do\nend\n".utf8), in: place.home)))
        let toml = try #require(BrowserLocalFile(try place.write("config.toml", in: place.home)))
        let nul = try #require(BrowserLocalFile(try place.write("blob.ex", Self.binary, in: place.home)))
        let latin1 = try #require(BrowserLocalFile(try place.write("old.ex", Data([0x63, 0x61, 0x66, 0xE9]), in: place.home)))
        let installer = try #require(BrowserLocalFile(try place.write("setup.pkg", Self.binary, in: place.home)))
        let archive = try #require(BrowserLocalFile(try place.write("archive.zip", Self.binary, in: place.home)))

        #expect(elixir.opening(workspace) == .show(.text))
        #expect(toml.opening(workspace) == .show(.text))
        #expect(nul.opening(workspace) == .reveal)
        #expect(latin1.opening(workspace) == .reveal)
        #expect(installer.opening(workspace) == .reveal)
        #expect(archive.opening(workspace) == .reveal)
        #expect(elixir.documentApplication(workspace) == nil)
        #expect(workspace.typesAsked.isEmpty, "an app was looked up for a type that is not content")
    }

    /// The read stops at 64 KB, which can fall inside a character.
    @Test("a character cut by the end of the read is still text")
    func cutCharacterIsText() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        var bytes = Data(repeating: 0x61, count: BrowserLocalFile.sniffLength - 1)
        bytes.append(contentsOf: Array("\u{E9}tude".utf8))

        let file = try #require(BrowserLocalFile(try place.write("long.ex", bytes, in: place.home)))
        #expect(file.opening(RecordingWorkspaceOpener()) == .show(.text))
    }

    @Test("a document goes to the app named for its type, and with none only to Finder")
    func documentsGoToTheirApp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        let letter = try #require(BrowserLocalFile(try place.write("letter.docx", in: place.home)))
        let photo = try #require(BrowserLocalFile(try place.write("photo.psd", in: place.home)))

        #expect(letter.opening(workspace) == .open(Self.preview))
        #expect(photo.opening(workspace) == .open(Self.preview))
        #expect(workspace.typesAsked == [try #require(UTType(filenameExtension: "docx")), try #require(UTType(filenameExtension: "psd"))])

        workspace.documentApp = nil
        #expect(letter.opening(workspace) == .reveal)
    }

    @Test("text past the pane's size goes to its app where it is a document, and otherwise only to Finder")
    func largeText() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        let log = try #require(BrowserLocalFile(try place.sparse("server.log", size: BrowserFileKind.textSizeCap + 1, in: place.home)))
        let atCap = try #require(BrowserLocalFile(try place.sparse("exact.txt", size: BrowserFileKind.textSizeCap, in: place.home)))
        let image = try #require(BrowserLocalFile(try place.sparse("huge.png", size: BrowserFileKind.textSizeCap + 1, in: place.home)))
        let untyped = try #require(BrowserLocalFile(try place.sparse("huge.ex", size: BrowserFileKind.textSizeCap + 1, in: place.home)))

        #expect(log.opening(workspace) == .open(Self.preview))
        #expect(atCap.opening(workspace) == .show(.text))
        #expect(image.opening(workspace) == .show(.image), "the cap is text's alone")
        #expect(untyped.opening(workspace) == .reveal)

        workspace.documentApp = nil
        #expect(log.opening(workspace) == .reveal)
    }

    /// A link handed to another app would hand over what it points at.
    @Test("a link is decided by the file it lands on")
    func linkIsItsTarget() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        let app = try place.folder("Thing.app", in: place.outside)
        _ = try place.folder("Contents", in: app)
        let link = place.home.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: app.path)

        let file = try #require(BrowserLocalFile(link))
        #expect(file.opening(workspace) == .reveal)
        #expect(file.url == FilePlaceFixture.real(app))
    }

    @Test("a leading ~ is the person's home folder")
    func tildeIsTheHomeFolder() throws {
        let link = try #require(URL(string: "file:~"))
        let file = try #require(BrowserLocalFile(link))

        #expect(file.opening(RecordingWorkspaceOpener()) == .reveal)
        #expect(file.url == FilePlaceFixture.real(URL(fileURLWithPath: NSHomeDirectory())))
    }

    /// Bytes no text has: a NUL among them.
    static let binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x01, 0x00])
}

/// Where a navigation in a file tab goes: its own file, and nothing else.
@Suite("Browser file tab navigation")
struct BrowserFileTabNavigationTests {
    private static func inFile(
        _ scheme: String,
        targetsNewWindow: Bool = false,
        isDownload: Bool = false,
        isMainFrame: Bool = true,
        isUserInitiated: Bool = true
    ) -> BrowserNavigationDecision {
        BrowserNavigationPolicy.decide(BrowserNavigation(
            scheme: scheme,
            targetsNewWindow: targetsNewWindow,
            isDownload: isDownload,
            isMainFrame: isMainFrame,
            isUserInitiated: isUserInitiated,
            inFileTab: true
        ))
    }

    /// The load is the app's, never a click, and the text path's base is the
    /// file itself.
    @Test("the tab's own file, or a blank page, loads", arguments: ["file", "FILE", "about"])
    func ownLoadMovesTheTab(_ scheme: String) {
        #expect(Self.inFile(scheme, isUserInitiated: false) == .allow)
        #expect(Self.inFile(scheme) == .allow)
    }

    @Test("a person's click on a web link opens it in a tab of the shared profile", arguments: ["http", "https", "HTTPS"])
    func clickedWebLinksGoToASharedTab(_ scheme: String) {
        #expect(Self.inFile(scheme) == .sharedTab)
        #expect(Self.inFile(scheme, targetsNewWindow: true) == .sharedTab)
    }

    /// The network rule refuses these too; the policy refuses them first.
    @Test("the web nobody clicked, or a frame's, goes nowhere")
    func unclickedWebGoesNowhere() {
        #expect(Self.inFile("https", isUserInitiated: false) == .cancel)
        #expect(Self.inFile("https", isMainFrame: false) == .cancel)
        #expect(Self.inFile("http", targetsNewWindow: true, isUserInitiated: false) == .cancel)
    }

    @Test("a click on another app's link is the person's to answer, as in any tab of theirs")
    func otherAppsKeepThePersonsRule() {
        #expect(Self.inFile("mailto") == .external)
        #expect(Self.inFile("tel", targetsNewWindow: true) == .external)
        #expect(Self.inFile("mailto", isUserInitiated: false) == .cancel)
        #expect(Self.inFile("zoommtg", isMainFrame: false) == .cancel)
    }

    @Test("a file tab never saves anything", arguments: ["https", "http", "blob", "data", "file"])
    func nothingIsSaved(_ scheme: String) {
        #expect(Self.inFile(scheme, isDownload: true) == .cancel)
    }

    /// A frame of another file, a window of its own, or content a page built:
    /// none is the tab's file.
    @Test("anything else goes nowhere")
    func everythingElseGoesNowhere() {
        #expect(Self.inFile("file", isMainFrame: false) == .cancel)
        #expect(Self.inFile("about", isMainFrame: false) == .cancel)
        #expect(Self.inFile("file", targetsNewWindow: true) == .cancel)
        #expect(Self.inFile("data") == .cancel)
        #expect(Self.inFile("blob") == .cancel)
        #expect(Self.inFile("javascript") == .cancel)
    }

    @Test("a tab that shows no file keeps the web's rules")
    func otherTabsAreUnchanged() {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https")) == .allow)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https", targetsNewWindow: true)) == .newTab)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https", isDownload: true)) == .download)
    }
}

/// Opening a file on this Mac (plan §8.2): the one place a local file is
/// opened, and the file tab it opens in.
@Suite("Browser file tabs")
@MainActor
struct BrowserFileTabTests {
    static let fermix = URL(string: "https://fermix.ai")!

    @Test("a file the pane shows, inside the Fermix home, opens at once in a file tab of the person's, in front", arguments: [
        ("shot.png", BrowserFileKind.image), ("report.pdf", .pdf), ("page.html", .html),
        ("notes.md", .text), ("config.yaml", .text), ("data.json", .text), ("main.swift", .text),
        ("install.sh", .text), ("lib.ex", .text)
    ])
    func insideTheHomeOpensAtOnce(_ name: String, _ kind: BrowserFileKind) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write(name, in: place.home)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        let tab = try #require(harness.model.tabs.first)
        #expect(harness.model.tabs.map(\.profile) == [.file])
        #expect(harness.model.host.owner(of: tab.id) == .person)
        #expect(harness.model.selectedTabID == tab.id)
        #expect(harness.model.isOpen)
        #expect(harness.model.dialog == nil)
        #expect(tab.file == FilePlaceFixture.real(file))
        #expect(harness.page(0).files == [FileLoad(url: FilePlaceFixture.real(file), kind: kind)])
        #expect(harness.page(0).loaded.isEmpty, "a file tab loaded a web page")
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
        #expect(BrowserText.tabTitle(title: "", url: nil, file: tab.file) == name)
    }

    @Test("outside the home the pane asks first, naming the file, and loads only on Open")
    func outsideTheHomeAsksFirst() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("notes.md", in: place.outside)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        let question = try #require(harness.model.dialog?.dialog)
        #expect(question.kind == .openFile(name: "notes.md"))
        #expect(question.message == ProductStrings[.browserOpenFileMessage])
        #expect(harness.model.tabs.map(\.profile) == [.file])
        #expect(harness.model.tabs.first?.file == FilePlaceFixture.real(file), "the tab names its file before it loads")
        #expect(harness.page(0).files.isEmpty, "the file loaded before the person answered")

        harness.coordinator.answer(.confirmed)
        #expect(harness.page(0).files == [FileLoad(url: FilePlaceFixture.real(file), kind: .text)])
        #expect(harness.model.dialog == nil)
        #expect(harness.model.tabs.count == 1)
    }

    @Test("Cancel closes the file tab, which loaded nothing")
    func cancelClosesTheTab() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)

        harness.coordinator.openFile(try place.write("notes.md", in: place.outside))
        harness.coordinator.answer(.dismissed)

        #expect(harness.model.tabs.map(\.profile) == [.shared])
        #expect(harness.model.selectedTabID == harness.model.tabs.first?.id)
        #expect(harness.page(1).files.isEmpty)
        #expect(harness.model.isOpen)
    }

    /// Nobody can see the question once the pane is hidden, so it is
    /// dismissed, and the tab it was over goes with it. It is the last tab,
    /// and its close finds the pane already going: the pane closes once.
    @Test("hiding the pane while it asks closes the file tab, the last, and the pane once")
    func hidingThePaneClosesTheTab() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()

        harness.coordinator.openFile(try place.write("notes.md", in: place.outside))
        harness.coordinator.closePane()

        #expect(harness.model.tabs.isEmpty)
        #expect(harness.model.selectedTabID == nil)
        #expect(harness.model.dialog == nil)
        #expect(!harness.model.isOpen)
        #expect(harness.record.paneShown == [true, false])
        #expect(harness.page(0).files.isEmpty)
    }

    /// The tab's own close answers the question, and nothing closes twice.
    @Test("closing the file tab while it asks closes it once")
    func closingTheTabWhileItAsks() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)
        harness.coordinator.openFile(try place.write("notes.md", in: place.outside))

        harness.coordinator.close(try #require(harness.model.tabs.last))

        #expect(harness.model.tabs.map(\.profile) == [.shared])
        #expect(harness.model.dialog == nil)
        #expect(harness.model.isOpen)
        #expect(harness.record.paneShown == [true])
    }

    @Test("a home that cannot be resolved has nothing inside it")
    func unresolvedHomeAsks() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = BrowserHarness()

        harness.coordinator.openFile(try place.write("notes.md", in: place.home))

        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "notes.md"))
        #expect(harness.page(0).files.isEmpty)
    }

    @Test("a link inside the home that points out of it asks, and opens what it points at")
    func linkOutOfTheHomeAsks() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let target = try place.write("secret.md", in: place.outside)
        let link = place.home.appendingPathComponent("notes.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let harness = place.harness()

        harness.coordinator.openFile(link)

        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "secret.md"))
        harness.coordinator.answer(.confirmed)
        #expect(harness.page(0).files == [FileLoad(url: FilePlaceFixture.real(target), kind: .text)])
    }

    /// One popup at a time: the file's question is dismissed at once, which
    /// closes its tab, and the page's dialog stays where it was.
    @Test("a file outside the home never stacks its question on another")
    func questionNeverStacks() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)
        let alert = BrowserDialog(kind: .alert, message: "Hello", origin: "fermix.ai")
        harness.page(0).events?.pagePresented(alert) { _ in }

        harness.coordinator.openFile(try place.write("notes.md", in: place.outside))

        #expect(harness.model.dialog?.dialog == alert)
        #expect(harness.model.tabs.map(\.profile) == [.shared])
        #expect(harness.page(1).files.isEmpty)
    }

    @Test("nothing at the path opens the pane on the sentence that says so")
    func missingFileSaysSo() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()

        harness.coordinator.openFile(place.home.appendingPathComponent("gone.pdf"))

        #expect(harness.model.isOpen)
        #expect(harness.model.tabs.isEmpty)
        #expect(harness.model.notice == ProductStrings[.browserNoticeFileMissing])
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.workspace.revealed.isEmpty)
    }

    /// Opening a folder by its path would launch an app swapped in under
    /// its name; Finder shows it selected instead.
    @Test("a folder is shown in Finder, never opened")
    func folderGoesToFinder() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let folder = try place.folder("reports", in: place.home)
        let harness = place.harness()

        harness.coordinator.openFile(folder)

        #expect(harness.workspace.revealed == [FilePlaceFixture.real(folder)])
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
    }

    /// The hole this closes: a file handed to the workspace by its path is
    /// launched or run, whatever it was when the pane decided.
    @Test("anything that is neither shown nor a document is only shown in Finder", arguments: [
        ("build", true), ("tool.jar", false), ("setup.pkg", false), ("letter.docx", true), ("disk.dmg", false)
    ])
    func everythingElseIsRevealed(_ name: String, _ executable: Bool) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let contents = name == "letter.docx" ? Data("hello".utf8) : BrowserLocalFileTests.binary
        let file = try place.write(name, contents, in: place.home, executable: executable)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file)])
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
    }

    @Test("an app is only shown in Finder, never launched")
    func appIsRevealed() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let app = try place.folder("Thing.app", in: place.outside)
        _ = try place.folder("Contents", in: app)
        let harness = place.harness()

        harness.coordinator.openFile(app)

        #expect(harness.workspace.revealed == [FilePlaceFixture.real(app)])
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
    }

    /// The app is named before the open, so whatever is at the path by then
    /// is a document to it, never launched or run.
    @Test("a document goes to the app named for its type, never to the workspace by its path", arguments: [
        "letter.docx", "clip.mp4", "photo.psd"
    ])
    func documentsGoToTheirApp(_ name: String) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write(name, in: place.outside)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.openedWith == [AppOpen(file: FilePlaceFixture.real(file), app: RecordingWorkspaceOpener.preview.url)])
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.revealed.isEmpty)
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
    }

    @Test("a document with no app for it is only shown in Finder")
    func documentWithNoAppIsRevealed() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("letter.docx", in: place.home)
        let harness = place.harness()
        harness.workspace.documentApp = nil

        harness.coordinator.openFile(file)

        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file)])
        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.model.notice == nil)
    }

    /// The link came from a reply, so the pane opens for the sentence rather
    /// than the click going nowhere.
    @Test("an app that cannot take the file opens the pane on the system's sentence")
    func appRefusalSaysSo() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.workspace.appFailure = "The application can\u{2019}t be opened."

        harness.coordinator.openFile(try place.write("letter.docx", in: place.home))

        #expect(harness.model.isOpen)
        #expect(harness.model.notice == "The application can\u{2019}t be opened.")
        #expect(harness.model.tabs.isEmpty)
    }

    @Test("text past the pane's size goes to the app named for its type")
    func largeTextGoesToItsApp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.sparse("server.log", size: BrowserFileKind.textSizeCap + 1, in: place.home)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.openedWith == [AppOpen(file: FilePlaceFixture.real(file), app: RecordingWorkspaceOpener.preview.url)])
        #expect(harness.model.tabs.isEmpty)
    }

    @Test("an address typed into a file tab opens in a new tab of the shared profile")
    func addressFromAFileTabOpensASharedTab() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.openFile(try place.write("notes.md", in: place.home))

        harness.coordinator.load(address: "fermix.ai")

        #expect(harness.model.tabs.map(\.profile) == [.file, .shared])
        #expect(harness.page(0).loaded.isEmpty)
        #expect(harness.page(1).loaded == [Self.fermix])
        #expect(harness.model.selectedTabID == harness.model.tabs.last?.id)
    }

    @Test("a web link clicked in a file tab opens in a new tab of the shared profile, in front")
    func webLinkFromAFileTabOpensASharedTab() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.openFile(try place.write("page.html", in: place.home))

        harness.page(0).events?.pageRequestedWebPage(Self.fermix)

        #expect(harness.model.tabs.map(\.profile) == [.file, .shared])
        #expect(harness.page(1).loaded == [Self.fermix])
        #expect(harness.model.selectedTabID == harness.model.tabs.last?.id)
    }

    @Test("a document in front is offered to its app, which the label and the open both name, and shown in Finder")
    func documentInFrontGoesOut() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("notes.md", in: place.home)
        let harness = place.harness()
        harness.coordinator.openFile(file)

        #expect(harness.coordinator.documentApplication(for: FilePlaceFixture.real(file)) == RecordingWorkspaceOpener.preview)
        harness.coordinator.openFileInApp()
        harness.coordinator.showInFinder()

        #expect(harness.workspace.openedWith == [AppOpen(file: FilePlaceFixture.real(file), app: RecordingWorkspaceOpener.preview.url)])
        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file)])
        #expect(harness.workspace.opened.isEmpty)
    }

    /// Its app would be Terminal or an editor that runs it.
    @Test("a script in front is offered to no app, and the control only shows it in Finder")
    func scriptInFrontIsOfferedNoApp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("install.sh", in: place.home)
        let harness = place.harness()
        harness.coordinator.openFile(file)

        #expect(harness.coordinator.documentApplication(for: FilePlaceFixture.real(file)) == nil)
        harness.coordinator.openFileInApp()

        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file)])
    }

    /// The control decides again at the click, from what is at the path then.
    @Test("a file swapped for an app after it opened is only shown in Finder at the click")
    func swappedFileIsRevealedAtTheClick() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("notes.md", in: place.home)
        let harness = place.harness()
        harness.coordinator.openFile(file)
        let app = try place.folder("Thing.app", in: place.outside)
        _ = try place.folder("Contents", in: app)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: app.path)

        harness.coordinator.openFileInApp()

        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.revealed == [FilePlaceFixture.real(app)])
    }

    /// A page a person dropped a file on is at a file address: the person's
    /// browser is never handed it by its path.
    @Test("a page at a file address takes the file rules, never the workspace by its path")
    func fileAddressInAWebTabTakesTheFileRules() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let letter = FilePlaceFixture.real(try place.write("letter.docx", in: place.home))
        let script = FilePlaceFixture.real(try place.write("install.command", in: place.home))
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)

        harness.page(0).events?.pageChanged(BrowserPageState(url: letter))
        harness.coordinator.openInSystemBrowser()
        harness.page(0).events?.pageChanged(BrowserPageState(url: script))
        harness.coordinator.openInSystemBrowser()

        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith == [AppOpen(file: letter, app: RecordingWorkspaceOpener.preview.url)])
        #expect(harness.workspace.revealed == [script])
    }

    @Test("a web tab in front has no file to open or show")
    func webTabHasNoFile() {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)

        harness.coordinator.openFileInApp()
        harness.coordinator.showInFinder()

        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.workspace.revealed.isEmpty)
    }
}

/// A temporary Fermix home and a folder beside it, inside neither, made by
/// the test and removed after it.
@MainActor
struct FilePlaceFixture {
    let temporary: TemporaryDirectory
    let home: URL
    let outside: URL

    init() throws {
        temporary = try TemporaryDirectory()
        home = temporary.url.appendingPathComponent("home", isDirectory: true)
        outside = temporary.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func remove() {
        temporary.remove()
    }

    /// A coordinator whose Fermix home is this one.
    func harness() -> BrowserHarness {
        BrowserHarness(home: home)
    }

    func write(_ name: String, _ contents: Data = Data("hello".utf8), in folder: URL, executable: Bool = false) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try contents.write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }

        return file
    }

    func folder(_ name: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder
    }

    /// A file of `size` bytes, all zero, that takes no room on disk.
    func sparse(_ name: String, size: Int, in folder: URL) throws -> URL {
        let file = try write(name, Data(), in: folder)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))

        return file
    }

    /// Where a path really is, every link resolved, as the pane opens it:
    /// the temporary folder is itself under a link (`/var` is `/private/var`).
    nonisolated static func real(_ url: URL) -> URL {
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }

        return URL(fileURLWithPath: String(cString: real))
    }
}
