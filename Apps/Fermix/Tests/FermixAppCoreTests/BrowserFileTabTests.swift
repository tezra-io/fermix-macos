import Foundation
import Testing
import UniformTypeIdentifiers

@testable import FermixAppCore

/// What the pane shows a file as (plan §8.2), by the type its extension
/// names.
@Suite("Browser file kinds")
struct BrowserFileKindTests {
    @Test("an image, a PDF, an HTML file and text are shown", arguments: [
        ("png", BrowserFileKind.image), ("jpg", .image), ("gif", .image), ("heic", .image), ("tiff", .image),
        ("svg", .image),
        ("pdf", .pdf),
        ("html", .html), ("htm", .html),
        ("txt", .text), ("md", .text), ("swift", .text), ("c", .text), ("csv", .text),
        ("json", .text), ("xml", .text), ("yaml", .text), ("yml", .text)
    ])
    func shownKinds(_ pathExtension: String, _ kind: BrowserFileKind) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserFileKind(type) == kind)
    }

    /// The reason the three are named beside plain text: none of them
    /// conforms to it, so plain text alone would send them to an app.
    @Test("JSON, XML and YAML are text the pane names, since none conforms to plain text")
    func structuredTextIsNamed() {
        for type in [UTType.json, .xml, .yaml] {
            #expect(!type.conforms(to: .plainText), "\(type.identifier)")
            #expect(BrowserFileKind.textTypes.contains(type), "\(type.identifier)")
        }
        #expect(BrowserFileKind.textTypes.contains(.plainText))
    }

    /// A script is text too, and an SVG is XML too: the order of the rule is
    /// what keeps each where it belongs.
    @Test("an SVG is drawn as a picture, not read as XML")
    func svgIsAnImage() throws {
        let svg = try #require(UTType(filenameExtension: "svg"))

        #expect(svg.conforms(to: .xml))
        #expect(BrowserFileKind(svg) == .image)
    }

    @Test("anything that runs is never shown, though a script is text", arguments: [
        "sh", "command", "zsh", "bash", "py", "rb", "pl", "php", "js", "applescript", "jar", "exe", "dylib"
    ])
    func runnablesAreNeverShown(_ pathExtension: String) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserFileKind.runs(type))
        #expect(BrowserFileKind(type) == nil)
    }

    @Test("an app, an executable and a script, by their own types, are what runs")
    func runnableTypes() {
        #expect(BrowserFileKind.runnableTypes == [.applicationBundle, .application, .executable, .unixExecutable, .script, .shellScript])
        for type in BrowserFileKind.runnableTypes {
            #expect(BrowserFileKind(type) == nil, "\(type.identifier)")
        }
        #expect(!BrowserFileKind.runs(.plainText))
        #expect(!BrowserFileKind.runs(.pdf))
    }

    @Test("anything else is not the pane's to show", arguments: ["zip", "docx", "mp4", "dmg", "fermixunknown"])
    func otherFilesAreNotShown(_ pathExtension: String) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))

        #expect(BrowserFileKind(type) == nil)
        #expect(!BrowserFileKind.runs(type))
    }

    @Test("the pane shows text up to 10 MB")
    func textCap() {
        #expect(BrowserFileKind.textSizeCap == 10_000_000)
    }
}

/// A file a link names, as it is on disk: decided on where the link really
/// lands, never on its name.
@Suite("Browser local files")
@MainActor
struct BrowserLocalFileTests {
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

    @Test("a folder is a folder")
    func folderIsAFolder() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let folder = try place.folder("reports", in: place.home)

        let file = try #require(BrowserLocalFile(folder))
        #expect(file.opening == .folder)
        #expect(file.url == FilePlaceFixture.real(folder))
    }

    /// A package is one file to the person and a directory to the disk, and
    /// a directory's executable bit is only leave to search it.
    @Test("an app is something that runs, not a folder")
    func appRuns() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let app = try place.folder("Thing.app", in: place.home)
        _ = try place.folder("Contents", in: app)

        #expect(BrowserLocalFile(app)?.opening == .reveal)
    }

    @Test("a file with its executable bit set runs, unless the pane shows it")
    func executableBit() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }

        let tool = try place.write("tool", in: place.home, executable: true)
        let archive = try place.write("archive.zip", in: place.home, executable: true)
        let notes = try place.write("notes.txt", in: place.home, executable: true)
        let plain = try place.write("plain.zip", in: place.home)

        #expect(BrowserLocalFile(tool)?.opening == .reveal)
        #expect(BrowserLocalFile(archive)?.opening == .reveal)
        #expect(BrowserLocalFile(notes)?.opening == .show(.text))
        #expect(BrowserLocalFile(plain)?.opening == .defaultApp)
    }

    @Test("text past the pane's size goes to its app")
    func largeTextGoesToItsApp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let large = try place.sparse("server.log", size: BrowserFileKind.textSizeCap + 1, in: place.home)
        let atCap = try place.sparse("exact.txt", size: BrowserFileKind.textSizeCap, in: place.home)
        let image = try place.sparse("huge.png", size: BrowserFileKind.textSizeCap + 1, in: place.home)

        #expect(BrowserLocalFile(large)?.opening == .defaultApp)
        #expect(BrowserLocalFile(atCap)?.opening == .show(.text))
        #expect(BrowserLocalFile(image)?.opening == .show(.image), "the cap is text's alone")
    }

    /// Handing the link to another app would run what it points at.
    @Test("a link is decided by the file it lands on")
    func linkIsItsTarget() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let script = try place.write("run.sh", in: place.outside)
        let link = place.home.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: script.path)

        let file = try #require(BrowserLocalFile(link))
        #expect(file.opening == .reveal)
        #expect(file.url == FilePlaceFixture.real(script))
    }

    @Test("a leading ~ is the person's home folder")
    func tildeIsTheHomeFolder() throws {
        let link = try #require(URL(string: "file:~"))
        let file = try #require(BrowserLocalFile(link))

        #expect(file.opening == .folder)
        #expect(file.url == FilePlaceFixture.real(URL(fileURLWithPath: NSHomeDirectory())))
    }
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
        ("notes.md", .text), ("config.yaml", .text), ("data.json", .text), ("main.swift", .text)
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
    /// dismissed, and the tab it was over goes with it, the pane once.
    @Test("hiding the pane while it asks closes the file tab")
    func hidingThePaneClosesTheTab() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()

        harness.coordinator.openFile(try place.write("notes.md", in: place.outside))
        harness.coordinator.closePane()

        #expect(harness.model.tabs.isEmpty)
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
        #expect(harness.workspace.revealed.isEmpty)
    }

    @Test("a folder goes to Finder")
    func folderGoesToFinder() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let folder = try place.folder("reports", in: place.home)
        let harness = place.harness()

        harness.coordinator.openFile(folder)

        #expect(harness.workspace.opened == [FilePlaceFixture.real(folder)])
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
    }

    /// The hole this closes: a script handed to the workspace opens in
    /// Terminal and runs, and an app launches.
    @Test("something that runs is only shown in Finder, never opened", arguments: [
        ("install.sh", false), ("run.command", false), ("tool.py", false), ("build", true), ("archive.zip", true)
    ])
    func runnablesAreRevealed(_ name: String, _ executable: Bool) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write(name, in: place.home, executable: executable)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file)])
        #expect(harness.workspace.opened.isEmpty)
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
    }

    @Test("a file the pane does not show goes to the app that opens it", arguments: ["archive.zip", "letter.docx", "clip.mp4"])
    func otherFilesGoToTheirApp(_ name: String) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write(name, in: place.outside)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.opened == [FilePlaceFixture.real(file)])
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
    }

    @Test("text past the pane's size goes to its app")
    func largeTextGoesToItsApp() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.sparse("server.log", size: BrowserFileKind.textSizeCap + 1, in: place.home)
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.workspace.opened == [FilePlaceFixture.real(file)])
        #expect(harness.model.tabs.isEmpty)
    }

    /// The link came from a reply, so the pane opens for the sentence rather
    /// than the click going nowhere.
    @Test("with no app for the file the pane opens on the sentence that says so")
    func noAppSaysSo() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.workspace.succeeds = false

        harness.coordinator.openFile(try place.write("archive.zip", in: place.home))

        #expect(harness.model.isOpen)
        #expect(harness.model.notice == ProductStrings[.browserNoticeNoApp])
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

    @Test("the file in front opens in its app and shows in Finder")
    func fileInFrontGoesOut() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = try place.write("report.pdf", in: place.home)
        let harness = place.harness()
        harness.coordinator.openFile(file)

        harness.coordinator.openFileInApp()
        harness.coordinator.showInFinder()

        #expect(harness.workspace.opened == [FilePlaceFixture.real(file)])
        #expect(harness.workspace.revealed == [FilePlaceFixture.real(file)])
        #expect(harness.coordinator.appName(toOpen: file) == "Mail")
    }

    @Test("a web tab in front has no file to open or show")
    func webTabHasNoFile() {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)

        harness.coordinator.openFileInApp()
        harness.coordinator.showInFinder()

        #expect(harness.workspace.opened.isEmpty)
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

    func write(_ name: String, in folder: URL, executable: Bool = false) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try Data("hello".utf8).write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }

        return file
    }

    func folder(_ name: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder
    }

    /// A file of `size` bytes that takes no room on disk.
    func sparse(_ name: String, size: Int, in folder: URL) throws -> URL {
        let file = try write(name, in: folder)
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
