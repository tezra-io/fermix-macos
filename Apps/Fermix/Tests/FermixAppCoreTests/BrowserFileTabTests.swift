import Foundation
import Testing
import UniformTypeIdentifiers

@testable import FermixAppCore

/// What the pane shows a file as (plan §8.2), by the type its extension
/// names. Only types macOS declares itself are asked by extension, so the
/// answers hold on any Mac whatever is installed.
@Suite("Browser file kinds")
struct BrowserFileKindTests {
    @Test("an image WebKit draws, a PDF, an HTML file and text are shown", arguments: [
        ("png", BrowserFileKind.image), ("jpg", .image), ("gif", .image),
        ("pdf", .pdf),
        ("html", .html),
        ("txt", .text), ("md", .text), ("json", .text), ("xml", .text), ("swift", .text)
    ])
    func shownKinds(_ pathExtension: String, _ kind: BrowserFileKind) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserFileKind(type) == kind)
    }

    /// Reading a script runs nothing in a tab with no page scripts and no
    /// network, and the person wants to read what the agent wrote.
    @Test("a script is text the pane shows", arguments: ["sh", "py"])
    func scriptsAreShownAsText(_ pathExtension: String) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserLocalFile.runs(type))
        #expect(BrowserFileKind(type) == .text)
    }

    /// An SVG is XML too: the order of the rule is what draws it.
    @Test("an SVG is drawn as a picture, not read as XML")
    func svgIsAnImage() {
        #expect(UTType.svg.conforms(to: .xml))
        #expect(BrowserFileKind(.svg) == .image)
    }

    @Test("an image WebKit does not draw is no image to the pane")
    func undrawableImagesAreNotImages() {
        #expect(UTType.rawImage.conforms(to: .image))
        #expect(BrowserFileKind(.rawImage) == nil)
        #expect(BrowserFileKind.imageTypes.starts(with: [.png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp, .svg, .ico]))
    }

    /// What rich text holds is a word processor's markup, not the words.
    @Test("rich text is not text to the pane")
    func richTextIsNotText() {
        #expect(UTType.rtf.conforms(to: .text))
        #expect(BrowserFileKind(.rtf) == nil)
    }

    @Test("anything else is not shown by its type", arguments: ["zip", "mp4", "fermixunknown"])
    func otherFilesAreNotShown(_ pathExtension: String) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserFileKind(type) == nil)
    }

    @Test("the pane shows text up to 10 MB")
    func textCap() {
        #expect(BrowserFileKind.textSizeCap == 10_000_000)
    }
}

/// The families of document a file may be handed to an app as, and nothing
/// else that calls itself content.
@Suite("Browser document families")
struct BrowserDocumentFamilyTests {
    @Test("pictures, sound and film, PDF, rich text, spreadsheets, presentations and word processing go to an app")
    func familiesGoToAnApp() throws {
        let word = try #require(UTType("org.openxmlformats.wordprocessingml.document"))

        for type in [UTType.rawImage, .png, .mpeg4Movie, .mp3, .pdf, .rtf, .rtfd, .flatRTFD, .spreadsheet, .presentation, word] {
            #expect(BrowserLocalFile.isDocument(type), "\(type.identifier)")
        }
    }

    /// An SVG is a picture written in XML, HTML is what a file tab exists to
    /// hold, and text goes to an editor that may run it.
    @Test("markup and text never go to an app, even inside a family")
    func markupNeverGoesToAnApp() {
        for type in [UTType.svg, .html, .plainText, .xml, .json, .sourceCode, .pythonScript, .shellScript] {
            #expect(!BrowserLocalFile.isDocument(type), "\(type.identifier)")
        }
    }

    /// Content any app may declare: a web archive opens in a browser with its
    /// scripts on, and an app's own type may open whatever that app does.
    @Test("content outside the families never goes to an app")
    func otherContentNeverGoesToAnApp() throws {
        let declaredByAnApp = try #require(UTType(filenameExtension: "fermixthing", conformingTo: .content))

        #expect(declaredByAnApp.conforms(to: .content))
        #expect(UTType.webArchive.conforms(to: .content))
        #expect(!BrowserLocalFile.isDocument(declaredByAnApp))
        #expect(!BrowserLocalFile.isDocument(.webArchive))
        #expect(!BrowserLocalFile.isDocument(.applicationBundle))
        #expect(!BrowserLocalFile.isDocument(.data))
    }
}

/// A file a link names, as it is on disk: decided on where the link really
/// lands, never on its name, and by an allowlist: shown, a document to its
/// app, or only shown in Finder.
@Suite("Browser local files")
@MainActor
struct BrowserLocalFileTests {
    static let preview = RecordingWorkspaceOpener.preview

    @Test("a link that is not to a file, nothing there, or a link to nothing is no file")
    func missingIsNothing() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let relative = try #require(URL(string: "file:relative/notes.md"))
        let web = try #require(URL(string: "https://fermix.ai/notes.md"))
        let dangling = place.home.appendingPathComponent("gone.md", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path,
            withDestinationPath: place.home.appendingPathComponent("never.md", isDirectory: false).path
        )

        #expect(BrowserLocalFile(place.home.appendingPathComponent("missing.md", isDirectory: false)) == nil)
        #expect(BrowserLocalFile(dangling) == nil)
        #expect(BrowserLocalFile(relative) == nil)
        #expect(BrowserLocalFile(web) == nil)
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
        let report = try #require(BrowserLocalFile(try place.write("report.pdf", in: place.home, executable: true)))

        #expect(notes.opening(workspace) == .show(.text))
        #expect(script.opening(workspace) == .show(.text), "a script with no extension is text")
        #expect(binary.opening(workspace) == .reveal)
        #expect(report.opening(workspace) == .show(.pdf))
        #expect(report.documentApplication(workspace) == nil, "an executable PDF was offered to an app")
    }

    /// A type nobody declared, or one known only as data, is text when its
    /// bytes read as text, and never goes to an app either way.
    @Test("a file of no known type is shown where its bytes read as text, and otherwise only in Finder")
    func untypedFilesAreSniffed() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()

        let elixir = try #require(BrowserLocalFile(try place.write("lib.ex", Data("defmodule Fermix do\nend\n".utf8), in: place.home)))
        let nul = try #require(BrowserLocalFile(try place.write("blob.ex", Self.binary, in: place.home)))
        let latin1 = try #require(BrowserLocalFile(try place.write("old.ex", Data([0x63, 0x61, 0x66, 0xE9]), in: place.home)))
        let archive = try #require(BrowserLocalFile(try place.write("archive.zip", Self.binary, in: place.home)))

        #expect(elixir.opening(workspace) == .show(.text))
        #expect(nul.opening(workspace) == .reveal)
        #expect(latin1.opening(workspace) == .reveal)
        #expect(archive.opening(workspace) == .reveal)
        #expect(elixir.documentApplication(workspace) == nil)
        #expect(workspace.typesAsked.isEmpty, "an app was looked up for a type that is not a document")
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
        let clip = try #require(BrowserLocalFile(try place.write("clip.mp4", in: place.home)))

        #expect(clip.opening(workspace) == .open(Self.preview))
        #expect(workspace.typesAsked == [try #require(UTType(filenameExtension: "mp4"))])

        workspace.documentApp = nil
        #expect(clip.opening(workspace) == .reveal)
    }

    /// A browser given a file runs its scripts and reaches the network.
    @Test("a document whose app opens web pages is only shown in Finder")
    func browsersAreNeverHandedAFile() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        workspace.webBrowsers = [Self.preview.url]
        let clip = try #require(BrowserLocalFile(try place.write("clip.mp4", in: place.home)))
        let report = try #require(BrowserLocalFile(try place.write("report.pdf", in: place.home)))

        #expect(clip.opening(workspace) == .reveal)
        #expect(report.documentApplication(workspace) == nil)
    }

    /// Text is never handed to an app, at any size.
    @Test("text past the pane's size is only shown in Finder")
    func largeText() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        let large = try #require(BrowserLocalFile(try place.sparse("server.txt", size: BrowserFileKind.textSizeCap + 1, in: place.home)))
        let atCap = try #require(BrowserLocalFile(try place.sparse("exact.txt", size: BrowserFileKind.textSizeCap, in: place.home)))
        let image = try #require(BrowserLocalFile(try place.sparse("huge.png", size: BrowserFileKind.textSizeCap + 1, in: place.home)))
        let untyped = try #require(BrowserLocalFile(try place.sparse("huge.ex", size: BrowserFileKind.textSizeCap + 1, in: place.home)))

        #expect(large.opening(workspace) == .reveal)
        #expect(atCap.opening(workspace) == .show(.text))
        #expect(image.opening(workspace) == .show(.image), "the cap is text's alone")
        #expect(untyped.opening(workspace) == .reveal)
    }

    /// A link handed to another app would hand over what it points at.
    @Test("a link is decided by the file it lands on")
    func linkIsItsTarget() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let workspace = RecordingWorkspaceOpener()
        let app = try place.folder("Thing.app", in: place.outside)
        _ = try place.folder("Contents", in: app)
        let link = place.home.appendingPathComponent("notes.txt", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: app.path)

        let file = try #require(BrowserLocalFile(link))
        #expect(file.opening(workspace) == .reveal)
        #expect(file.url == FilePlaceFixture.real(app))
    }

    /// Bytes no text has: a NUL among them.
    static let binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x01, 0x00])
}

/// Where a navigation goes when it is to a file on this Mac, or made in a
/// file tab: the tab's own file, and nothing else.
@Suite("Browser file tab navigation")
struct BrowserFileTabNavigationTests {
    private static func inFile(
        _ scheme: String,
        targetsNewWindow: Bool = false,
        isDownload: Bool = false,
        isMainFrame: Bool = true,
        isUserInitiated: Bool = true,
        isTabsOwnFile: Bool = false
    ) -> BrowserNavigationDecision {
        BrowserNavigationPolicy.decide(BrowserNavigation(
            scheme: scheme,
            targetsNewWindow: targetsNewWindow,
            isDownload: isDownload,
            isMainFrame: isMainFrame,
            isUserInitiated: isUserInitiated,
            inFileTab: true,
            isTabsOwnFile: isTabsOwnFile
        ))
    }

    /// The load is the app's, never a click, and the text path's base is the
    /// file itself; a link to a place in it is the same file.
    @Test("the tab's own file, or a blank page, loads", arguments: ["file", "FILE"])
    func ownLoadMovesTheTab(_ scheme: String) {
        #expect(Self.inFile(scheme, isUserInitiated: false, isTabsOwnFile: true) == .allow)
        #expect(Self.inFile(scheme, isTabsOwnFile: true) == .allow)
        #expect(Self.inFile("about", isUserInitiated: false) == .allow)
    }

    @Test("a person's click on a web link or another file is handed off", arguments: ["http", "https", "HTTPS", "file"])
    func clicksAreHandedOff(_ scheme: String) {
        #expect(Self.inFile(scheme) == .handOff)
        #expect(Self.inFile(scheme, targetsNewWindow: true) == .handOff)
    }

    /// A redirect to another file or to the web is how a file would reach
    /// what the person never chose.
    @Test("another file or the web that nobody clicked, or a frame's, goes nowhere")
    func unclickedGoesNowhere() {
        #expect(Self.inFile("file", isUserInitiated: false) == .cancel)
        #expect(Self.inFile("file", isMainFrame: false) == .cancel)
        #expect(Self.inFile("file", isMainFrame: false, isTabsOwnFile: true) == .cancel)
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
        #expect(Self.inFile(scheme, isDownload: true, isTabsOwnFile: true) == .cancel)
    }

    @Test("content a page built, or a blank frame, goes nowhere")
    func everythingElseGoesNowhere() {
        #expect(Self.inFile("about", isMainFrame: false) == .cancel)
        #expect(Self.inFile("data") == .cancel)
        #expect(Self.inFile("blob") == .cancel)
        #expect(Self.inFile("javascript") == .cancel)
    }

    /// A website must never get a file on this Mac opened, shown or revealed:
    /// a click, a redirect, a frame or a file dropped on the page all go
    /// nowhere.
    @Test("a web tab goes to no file, clicked or not", arguments: ["file", "FILE"])
    func webTabsNeverReachAFile(_ scheme: String) {
        #expect(!BrowserNavigationPolicy.isWeb(scheme))
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme)) == .cancel)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, targetsNewWindow: true)) == .cancel)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, isUserInitiated: false)) == .cancel)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, isMainFrame: false)) == .cancel)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, isDownload: true)) == .cancel)
    }

    @Test("a tab that shows no file keeps the web's rules")
    func otherTabsAreUnchanged() {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https")) == .allow)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https", targetsNewWindow: true)) == .newTab)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https", isDownload: true)) == .download)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "mailto")) == .external)
    }
}

/// Opening a file on this Mac (plan §8.2), and the file tab it opens in.
@Suite("Browser file tabs")
@MainActor
struct BrowserFileTabTests {
    static let fermix = URL(string: "https://fermix.ai")!
    static let example = URL(string: "https://example.com")!
    static let preview = RecordingWorkspaceOpener.preview

    @Test("a file the pane shows, inside the Fermix home, opens at once in a file tab of the person's, in front", arguments: [
        ("shot.png", BrowserFileKind.image), ("report.pdf", .pdf),
        ("notes.md", .text), ("data.json", .text), ("main.swift", .text), ("install.sh", .text), ("lib.ex", .text)
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

    /// A report the agent wrote keeps its images and stylesheets beside it;
    /// scripts stay off and the network stays out all the same.
    @Test("an HTML file inside the home may read its own folder, and one outside only itself")
    func htmlReadsItsFolderInsideTheHome() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let inside = FilePlaceFixture.real(try place.write("report.html", in: place.home))
        let outside = FilePlaceFixture.real(try place.write("page.html", in: place.outside))
        let harness = place.harness()

        harness.coordinator.openFile(inside)
        harness.coordinator.openFile(outside)
        harness.coordinator.answer(.confirmed)

        #expect(harness.page(0).files == [FileLoad(url: inside, kind: .html, readAccess: inside.deletingLastPathComponent())])
        #expect(harness.page(1).files == [FileLoad(url: outside, kind: .html, readAccess: outside)])
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
        let link = place.home.appendingPathComponent("notes.md", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let harness = place.harness()

        harness.coordinator.openFile(link)

        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "secret.md"))
        harness.coordinator.answer(.confirmed)
        #expect(harness.page(0).files == [FileLoad(url: FilePlaceFixture.real(target), kind: .text)])
    }

    /// One popup at a time, and no tab for a question that could not be put:
    /// nothing flashes, and the tab in front stays in front.
    @Test("a file outside the home makes no tab while a page's dialog is up")
    func noTabWhileADialogIsUp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)
        let front = harness.model.selectedTabID
        let alert = BrowserDialog(kind: .alert, message: "Hello", origin: "fermix.ai")
        harness.page(0).events?.pagePresented(alert) { _ in }

        harness.coordinator.openFile(try place.write("notes.md", in: place.outside))

        #expect(harness.model.dialog?.dialog == alert)
        #expect(harness.model.tabs.map(\.profile) == [.shared])
        #expect(harness.engine.pages.count == 1, "a tab was made for a question that could not be put")
        #expect(harness.model.selectedTabID == front)
    }

    @Test("a file outside the home makes no tab while a system panel is up")
    func noTabWhileAPanelIsUp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)
        harness.page(0).events?.pageRequestedFiles(BrowserFileRequest(allowsMultipleSelection: false, allowsDirectories: false)) { _ in }
        #expect(harness.engine.fileRequests.count == 1)

        harness.coordinator.openFile(try place.write("notes.md", in: place.outside))

        #expect(harness.engine.pages.count == 1)
        #expect(harness.model.dialog == nil)
        #expect(harness.model.tabs.map(\.profile) == [.shared])
    }

    /// Inside the home nothing is asked, so another question does not stand
    /// in the way.
    @Test("a file inside the home opens while a page's dialog is up")
    func insideTheHomeOpensWhileADialogIsUp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)
        harness.page(0).events?.pagePresented(BrowserDialog(kind: .alert, message: "Hello", origin: "fermix.ai")) { _ in }
        let file = try place.write("notes.md", in: place.home)

        harness.coordinator.openFile(file)

        #expect(harness.model.tabs.map(\.profile) == [.shared, .file])
        #expect(harness.page(1).files == [FileLoad(url: FilePlaceFixture.real(file), kind: .text)])
    }

    @Test("nothing at the path opens the pane on the sentence that says so")
    func missingFileSaysSo() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()

        harness.coordinator.openFile(place.home.appendingPathComponent("gone.pdf", isDirectory: false))

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
    /// launched or run, whatever it was when the pane decided, and a web
    /// archive opens in a browser with its scripts on.
    @Test("anything that is neither shown nor a document is only shown in Finder", arguments: [
        ("build", true), ("tool.jar", false), ("archive.webarchive", false), ("clip.mp4", true), ("disk.dmg", false)
    ])
    func everythingElseIsRevealed(_ name: String, _ executable: Bool) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let contents = name == "build" || name == "tool.jar" || name == "disk.dmg" ? BrowserLocalFileTests.binary : Data("hello".utf8)
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
    @Test("a document goes to the app named for its type, never to the workspace by its path")
    func documentsGoToTheirApp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("clip.mp4", in: place.outside)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.openedWith == [AppOpen(file: FilePlaceFixture.real(file), app: Self.preview.url)])
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.revealed.isEmpty)
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
    }

    @Test("a document whose app opens web pages, or with no app, is only shown in Finder")
    func documentWithNoSafeAppIsRevealed() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("clip.mp4", in: place.home)
        let harness = place.harness()
        harness.workspace.webBrowsers = [Self.preview.url]

        harness.coordinator.openFile(file)
        harness.workspace.documentApp = nil
        harness.coordinator.openFile(file)

        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file), FilePlaceFixture.real(file)])
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

        harness.coordinator.openFile(try place.write("clip.mp4", in: place.home))

        #expect(harness.model.isOpen)
        #expect(harness.model.notice == "The application can\u{2019}t be opened.")
        #expect(harness.model.tabs.isEmpty)
    }

    @Test("text past the pane's size is only shown in Finder")
    func largeTextIsRevealed() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.sparse("server.txt", size: BrowserFileKind.textSizeCap + 1, in: place.home)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file)])
        #expect(harness.workspace.openedWith.isEmpty)
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

    /// As a popup lands beside its opener.
    @Test("a web link handed off by a file tab opens in a new shared tab beside it, in front")
    func webLinkFromAFileTabOpensBesideIt() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.openFile(try place.write("notes.md", in: place.home))
        harness.coordinator.open(Self.example)
        let fileTab = try #require(harness.model.tabs.first)
        harness.coordinator.select(fileTab)

        harness.page(0).events?.pageHandedOff(Self.fermix)

        #expect(harness.model.tabs.map(\.profile) == [.file, .shared, .shared])
        #expect(harness.page(2).loaded == [Self.fermix])
        #expect(harness.model.tabs[1].id == harness.model.selectedTabID)
    }

    /// A link to another file in a file tab is the same link a reply could
    /// hold, and takes the same rules.
    @Test("a file link handed off by a file tab takes the file rules")
    func fileLinkFromAFileTabTakesTheFileRules() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let report = try place.write("report.html", in: place.home)
        let notes = try place.write("notes.md", in: place.home)
        let app = try place.folder("Thing.app", in: place.home)
        let harness = place.harness()
        harness.coordinator.openFile(report)

        harness.page(0).events?.pageHandedOff(notes)
        harness.page(0).events?.pageHandedOff(app)

        #expect(harness.model.tabs.map(\.profile) == [.file, .file])
        #expect(harness.page(1).files == [FileLoad(url: FilePlaceFixture.real(notes), kind: .text)])
        #expect(harness.workspace.revealed == [FilePlaceFixture.real(app)])
    }

    /// The policy already cancels a web tab's click on a file; the
    /// coordinator refuses one all the same, so no page can get a file on
    /// this Mac opened, shown or revealed.
    @Test("a file link from a web tab opens, shows and reveals nothing", arguments: [BrowserProfile.shared, .private])
    func fileLinkFromAWebTabDoesNothing(_ profile: BrowserProfile) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.newTab(profile: profile)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "file")) == .cancel)

        harness.page(0).events?.pageHandedOff(try place.write("notes.md", in: place.home))
        harness.page(0).events?.pageHandedOff(try place.write("clip.mp4", in: place.home))
        harness.page(0).events?.pageHandedOff(try place.folder("Thing.app", in: place.home))

        #expect(harness.model.tabs.map(\.profile) == [profile])
        #expect(harness.model.dialog == nil)
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.workspace.revealed.isEmpty)
    }

    /// The agent's clicks are trusted events, so the policy alone would hand
    /// one off; ownership is what stops it.
    @Test("a task's tab hands nothing off")
    func taskTabHandsNothingOff() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        _ = try BrowserHostCoordinatorTests.attached(harness)
        _ = try BrowserHostCoordinatorTests.openTaskTab(harness)

        harness.page(0).events?.pageHandedOff(try place.write("notes.md", in: place.home))
        harness.page(0).events?.pageHandedOff(Self.fermix)

        #expect(harness.model.tabs.count == 1)
        #expect(harness.workspace.revealed.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
    }

    @Test("a document in front is offered to its app, which the label and the open both name, and shown in Finder")
    func documentInFrontGoesOut() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write("report.pdf", in: place.home))
        let harness = place.harness()
        harness.coordinator.openFile(file)

        #expect(harness.model.tabs.first?.fileApp == Self.preview)
        harness.coordinator.openFileInApp()
        harness.coordinator.showInFinder()

        #expect(harness.workspace.openedWith == [AppOpen(file: file, app: Self.preview.url)])
        #expect(harness.workspace.revealed == [file])
        #expect(harness.workspace.opened.isEmpty)
    }

    /// Text, markup and scripts go to an editor or a browser that may run
    /// them, so their tab offers Finder alone.
    @Test("a tab of text, markup or a script offers no app, and its control only shows it in Finder", arguments: [
        "install.sh", "notes.md", "report.html"
    ])
    func textInFrontIsOfferedNoApp(_ name: String) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(name, in: place.home))
        let harness = place.harness()
        harness.coordinator.openFile(file)

        #expect(harness.model.tabs.first?.fileApp == nil)
        harness.coordinator.openFileInApp()

        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.revealed == [file])
    }

    @Test("a document whose app opens web pages is offered to no app")
    func browserIsNeverOffered() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.workspace.webBrowsers = [Self.preview.url]

        harness.coordinator.openFile(try place.write("report.pdf", in: place.home))

        #expect(harness.model.tabs.first?.fileApp == nil)
    }

    /// The control decides again at the click, from what is at the path then.
    @Test("a file swapped for an app after it opened is only shown in Finder at the click")
    func swappedFileIsRevealedAtTheClick() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("report.pdf", in: place.home)
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

    /// No navigation takes a web tab to a file any more; should a page ever
    /// stand at a file address, the person's browser is still never handed
    /// it by its path.
    @Test("a page at a file address takes the file rules, never the workspace by its path")
    func fileAddressInAWebTabTakesTheFileRules() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let clip = FilePlaceFixture.real(try place.write("clip.mp4", in: place.home))
        let script = FilePlaceFixture.real(try place.write("install.command", in: place.home))
        let harness = place.harness()
        harness.coordinator.open(Self.fermix)

        harness.page(0).events?.pageChanged(BrowserPageState(url: clip))
        harness.coordinator.openInSystemBrowser()
        harness.page(0).events?.pageChanged(BrowserPageState(url: script))
        harness.coordinator.openInSystemBrowser()

        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith == [AppOpen(file: clip, app: Self.preview.url)])
        #expect(harness.workspace.revealed == [script])
    }

    /// A file tab's page stands at its file's address, and the browser
    /// control takes the same rule as the tab's own way out.
    @Test("a file tab's page sent to the browser takes the file rules")
    func fileTabToTheBrowserTakesTheFileRules() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let page = FilePlaceFixture.real(try place.write("report.html", in: place.home))
        let harness = place.harness()
        harness.coordinator.openFile(page)
        harness.page(0).events?.pageChanged(BrowserPageState(url: page))

        harness.coordinator.openInSystemBrowser()

        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty)
        #expect(harness.workspace.revealed == [page])
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
        let file = folder.appendingPathComponent(name, isDirectory: false)
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

        return URL(fileURLWithPath: String(cString: real), isDirectory: url.hasDirectoryPath)
    }
}
