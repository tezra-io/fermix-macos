import Foundation
import Testing

@testable import FermixAppCore

/// The pane's own two viewers (M66 §3.5): a media tab on the app's one
/// player, and a document tab as Quick Look draws it. The pages are the
/// product's own; only AVKit's and Quick Look's views are fakes.
@Suite("Browser viewer tabs")
@MainActor
struct BrowserViewerTabTests {
    @Test("a film inside the home that can play opens at once in a media tab, cued and not playing")
    func mediaInsideTheHomeOpensAtOnce() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write("clip.mp4", in: place.home))
        let harness = place.harness()
        harness.facts.playable = [file]

        harness.coordinator.openFile(file)
        await harness.settle()

        let tab = try #require(harness.model.tabs.first)
        #expect(harness.model.tabs.map(\.profile) == [.file])
        #expect(harness.model.host.owner(of: tab.id) == .person)
        #expect(harness.model.selectedTabID == tab.id)
        #expect(harness.model.isOpen)
        #expect(harness.model.dialog == nil)
        #expect(tab.file == file)
        #expect(tab.fileKind == .media)
        #expect(tab.fileApp == RecordingWorkspaceOpener.preview)
        #expect(harness.playback.requests == ["hold clip.mp4"], "the tab played, or never cued its file")
        #expect(harness.player.item?.url == file)
        #expect(try #require(harness.viewers.surfaces.first).holding)
        #expect(harness.engine.pages.isEmpty, "a web page was made for a film")
        #expect(harness.record.enginesBuilt.isEmpty, "a media tab needed the website profile")
    }

    @Test("a document inside the home opens at once in a document tab Quick Look draws, offered to its app", arguments: [
        "letter.docx", "sheet.xlsx", "deck.pptx", "notes.rtf", "photo.psd", "table.csv"
    ])
    func documentInsideTheHomeOpensAtOnce(_ name: String) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(name, in: place.home))
        let harness = place.harness()

        harness.coordinator.openFile(file)

        let tab = try #require(harness.model.tabs.first)
        #expect(tab.profile == .file)
        #expect(tab.fileKind == .document)
        #expect(harness.viewers.previews.map(\.shown) == [[file]])
        #expect(harness.engine.pages.isEmpty)
        #expect(harness.workspace.openedWith.isEmpty, "a document went to its app rather than the pane")
    }

    @Test("a Pages document, a package, opens in a document tab")
    func packageOpensInADocumentTab() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let package = try place.folder("Report.pages", in: place.home)
        _ = try place.folder("Data", in: package)
        let harness = place.harness()

        harness.coordinator.openFile(package)

        #expect(harness.model.tabs.first?.fileKind == .document)
        #expect(harness.viewers.previews.map(\.shown) == [[FilePlaceFixture.real(package)]])
        #expect(harness.workspace.revealed.isEmpty)
    }

    /// Asking was a file tab's alone; a film or a document outside the home
    /// went to its app without a word. Now every file tab asks.
    @Test("a film outside the home asks first, and is cued only on Open")
    func mediaOutsideTheHomeAsks() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write("talk.mov", in: place.outside))
        let harness = place.harness()
        harness.facts.playable = [file]

        harness.coordinator.openFile(file)
        await harness.settle()

        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "talk.mov"))
        #expect(harness.model.tabs.first?.file == file)
        #expect(harness.playback.requests.isEmpty, "the film was held before the person answered")
        #expect(try #require(harness.viewers.surfaces.first).playable == false)

        harness.coordinator.answer(.confirmed)

        #expect(harness.playback.requests == ["hold talk.mov"])
        #expect(harness.model.dialog == nil)
    }

    @Test("a document outside the home asks first, and Cancel closes its tab and its preview")
    func documentOutsideTheHomeAsks() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write("letter.docx", in: place.outside))
        let harness = place.harness()

        harness.coordinator.openFile(file)

        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "letter.docx"))
        let preview = try #require(harness.viewers.previews.first)
        #expect(preview.shown.isEmpty, "the document was shown before the person answered")

        harness.coordinator.answer(.dismissed)

        #expect(harness.model.tabs.isEmpty)
        #expect(preview.shown.isEmpty)
        #expect(preview.closes == 1)
        #expect(!harness.model.isOpen)
    }

    @Test("Open shows the document outside the home, and grants it nothing beyond the file")
    func documentOutsideTheHomeOpens() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write("sheet.xlsx", in: place.outside))
        let harness = place.harness()

        harness.coordinator.openFile(file)
        harness.coordinator.answer(.confirmed)

        #expect(harness.viewers.previews.map(\.shown) == [[file]])
        #expect(harness.engine.pages.isEmpty, "a web view was handed the document")
    }

    /// The pane's window outlives every tab, so Quick Look is told.
    @Test("closing a document tab closes its preview, once")
    func documentTabCloseClosesThePreview() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.openFile(try place.write("letter.docx", in: place.home))
        let preview = try #require(harness.viewers.previews.first)

        harness.coordinator.close(try #require(harness.model.tabs.first))

        #expect(preview.closes == 1)
        #expect(harness.model.tabs.isEmpty)
    }

    @Test("closing a media tab stops the player that holds its film")
    func mediaTabCloseStopsThePlayer() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write("clip.mp4", in: place.home))
        let harness = place.harness()
        harness.facts.playable = [file]
        harness.coordinator.openFile(file)
        await harness.settle()
        try #require(harness.viewers.surfaces.first).pressPlay()
        harness.playback.events?.playbackPlayingChanged(true)

        harness.coordinator.close(try #require(harness.model.tabs.first))

        #expect(harness.player.item == nil)
        #expect(harness.playback.requests == ["hold clip.mp4", "play", "hold nothing"])
    }

    /// The tab only takes the player when the person plays it, and a sound
    /// in the chat is the chat's own.
    @Test("a media tab opened while a sound plays leaves it playing, offers its own Play, and takes the player on it")
    func mediaTabOverAPlayingSound() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let sound = FilePlaceFixture.real(try place.write("voice.m4a", in: place.home))
        let film = FilePlaceFixture.real(try place.write("clip.mp4", in: place.home))
        let harness = place.harness()
        harness.facts.playable = [film]
        harness.player.play(sound, from: .chat)
        harness.playback.events?.playbackPlayingChanged(true)

        harness.coordinator.openFile(film)
        await harness.settle()

        let surface = try #require(harness.viewers.surfaces.first)
        #expect(harness.player.item == AppPlayerItem(url: sound, place: .chat))
        #expect(!surface.holding)
        #expect(surface.playable)

        surface.pressPlay()

        #expect(harness.player.item?.url == film)
        #expect(surface.holding)
        #expect(harness.playback.requests == ["hold voice.m4a", "play", "hold clip.mp4", "play"])

        harness.coordinator.close(try #require(harness.model.tabs.first))
        #expect(harness.player.item == nil)
    }

    @Test("closing a media tab that does not hold the player leaves the chat's sound alone")
    func mediaTabCloseLeavesOthers() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let sound = FilePlaceFixture.real(try place.write("voice.m4a", in: place.home))
        let film = FilePlaceFixture.real(try place.write("clip.mp4", in: place.home))
        let harness = place.harness()
        harness.facts.playable = [film]
        harness.coordinator.openFile(film)
        await harness.settle()
        harness.player.play(sound, from: .chat)

        harness.coordinator.close(try #require(harness.model.tabs.first))

        #expect(harness.player.item == AppPlayerItem(url: sound, place: .chat))
        #expect(!harness.viewers.surfaces[0].holding)
    }

    @Test("while a call is up a media tab's Play cannot be pressed, and nothing is cued")
    func mediaTabDuringACall() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let film = FilePlaceFixture.real(try place.write("clip.mp4", in: place.home))
        let harness = place.harness()
        let calls = AppPlayerSignals()
        harness.player.follow(calls: calls.calls, chatShown: calls.chat)
        harness.facts.playable = [film]
        calls.callUp(true)

        harness.coordinator.openFile(film)
        await harness.settle()

        let surface = try #require(harness.viewers.surfaces.first)
        #expect(!surface.holding)
        #expect(!surface.playable)
        #expect(harness.playback.requests.isEmpty)

        calls.callUp(false)
        #expect(surface.playable)
    }

    // MARK: - The one-deep kept click

    /// A click while a question is up is kept and asked next; a later click
    /// replaces it, and the replaced one is never asked.
    @Test("a click while a question is up is kept one deep, and a later click replaces it")
    func keptClickIsOneDeep() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let first = FilePlaceFixture.real(try place.write("first.md", in: place.outside))
        let harness = place.harness()
        harness.coordinator.openFile(first)

        harness.coordinator.openFile(try place.write("second.docx", in: place.outside))
        harness.coordinator.openFile(try place.write("third.md", in: place.outside))

        #expect(harness.model.tabs.count == 1)
        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "first.md"))

        harness.coordinator.answer(.confirmed)

        #expect(harness.model.tabs.map(\.file?.lastPathComponent) == ["first.md", "third.md"])
        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "third.md"))
        #expect(harness.model.selectedTabID == harness.model.tabs.last?.id)
        #expect(harness.page(0).files == [FileLoad(url: first, kind: .text)])
        #expect(harness.viewers.previews.isEmpty, "the replaced click was asked")

        harness.coordinator.answer(.confirmed)

        #expect(harness.model.dialog == nil)
        #expect(harness.model.tabs.count == 2)
    }

    /// Cancel closes the only tab, and the next question is already up in
    /// its place: the pane does not close only to open again.
    @Test("Cancel on the only tab asks the kept click without closing the pane")
    func cancelAsksTheKeptClick() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.openFile(try place.write("first.md", in: place.outside))
        harness.coordinator.openFile(try place.write("letter.docx", in: place.outside))

        harness.coordinator.answer(.dismissed)

        #expect(harness.model.tabs.map(\.file?.lastPathComponent) == ["letter.docx"])
        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "letter.docx"))
        #expect(harness.model.isOpen)
        #expect(harness.record.paneShown == [true])
    }

    @Test("closing the tab whose question is up asks the kept click")
    func closingTheAskingTabAsksTheKeptClick() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.open(BrowserFileTabTests.fermix)
        harness.coordinator.openFile(try place.write("first.md", in: place.outside))
        harness.coordinator.openFile(try place.write("second.md", in: place.outside))

        harness.coordinator.close(try #require(harness.model.tabs.last))

        #expect(harness.model.tabs.map(\.file?.lastPathComponent) == [nil, "second.md"])
        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "second.md"))
        #expect(harness.model.selectedTabID == harness.model.tabs.last?.id)
    }

    /// Hiding the pane is the person's own word on the question and on what
    /// waited behind it.
    @Test("hiding the pane lets the kept click go with the question")
    func hidingThePaneLetsTheKeptClickGo() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.openFile(try place.write("first.md", in: place.outside))
        harness.coordinator.openFile(try place.write("second.md", in: place.outside))

        harness.coordinator.closePane()

        #expect(harness.model.tabs.isEmpty)
        #expect(harness.model.dialog == nil)
        #expect(!harness.model.isOpen)
        #expect(harness.record.paneShown == [true, false])

        harness.coordinator.showPane()
        #expect(harness.model.tabs.isEmpty, "the kept click came back after the pane was hidden")
    }

    // MARK: - Phone-side files (M66 §3.5, decision 1)

    private static let ref = FakeMediaGrants.ref("a")
    /// What its row calls the file, which its granted copy, named by the
    /// ref, cannot say.
    private static let name = "garden.png"

    /// The engine's grant of `file` for the ref, as a harness's grants
    /// answer it.
    private static func grant(_ file: URL) -> MediaGrantOutcome {
        .granted(MediaGrant(ref: ref, url: file))
    }

    /// The engine grants a phone-side file inside the Fermix home, named
    /// with its type's extension, so it opens as a file at that path does,
    /// with no question, and its tab holds the grant until it closes.
    @Test("a phone-side file opens in the tab its granted file's kind takes, holding the grant until it closes", arguments: [
        ("png", BrowserFileKind.image), ("pdf", .pdf), ("docx", .document), ("csv", .document),
    ])
    func refOpensAsItsFile(_ ext: String, _ kind: BrowserFileKind) async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(Self.ref + "." + ext, in: place.home))
        let harness = place.harness()
        harness.grants.answers[Self.ref] = Self.grant(file)

        #expect(await harness.coordinator.openRef(Self.ref, named: Self.name) == Self.grant(file))

        let tab = try #require(harness.model.tabs.first)
        #expect(tab.fileKind == kind)
        #expect(tab.file == file)
        #expect(BrowserText.tabTitle(title: tab.title, url: tab.url, file: tab.file, fileName: tab.fileName) == "garden." + ext)
        #expect(harness.model.dialog == nil)
        #expect(harness.grants.counts == [Self.ref: 1])

        harness.coordinator.close(tab)
        #expect(harness.grants.held == 0)
        #expect(harness.grants.log == ["hold " + Self.ref, "release " + Self.ref])
    }

    /// The engine copied it into the home, but the phone's HTML is not
    /// Fermix's: WebKit would draw it as a page, so it is asked about as a
    /// file outside the home is, and reads nothing beside itself, not the
    /// other phone-side files granted beside it.
    @Test("a phone-side HTML file asks first under its true extension, and on Open reads only itself")
    func refHTMLAsksFirst() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(Self.ref + ".html", in: place.home))
        let harness = place.harness()
        harness.grants.answers[Self.ref] = Self.grant(file)

        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)
        // Its row calls it garden.png; the question says what it is.
        #expect(harness.model.dialog?.dialog.kind == .openFile(name: "garden.html"))
        #expect(harness.page(0).files.isEmpty)

        harness.coordinator.answer(.confirmed)
        #expect(harness.page(0).files == [FileLoad(url: file, kind: .html, readAccess: file)])
        #expect(harness.grants.counts == [Self.ref: 1])
    }

    /// Whoever sent the file chose its name: what the pane shows keeps the
    /// name but takes the extension from the file it really is, and drops
    /// the invisible characters that could reorder or hide one.
    @Test("a phone-side file goes by its row's name with its own extension and nothing invisible", arguments: [
        ("garden.png", "png", "garden.png"),
        ("report.pdf", "html", "report.html"),
        ("Picture", "png", "Picture.png"),
        ("invoice\u{202E}fdp.html", "html", "invoicefdp.html"),
        ("notes\u{200B}.txt", "md", "notes.md"),
    ])
    func refShownName(_ name: String, _ ext: String, _ shown: String) {
        let file = URL(fileURLWithPath: "/fermix/companion/media/" + Self.ref + "." + ext)

        #expect(BrowserCoordinator.shownName(name, of: file) == shown)
    }

    @Test("a phone-side film opens in a media tab, and closing it stops the player and lets the grant go")
    func refFilmOpensInAMediaTab() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(Self.ref + ".mp4", in: place.home))
        let harness = place.harness()
        harness.grants.answers[Self.ref] = Self.grant(file)
        harness.facts.playable = [file]

        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)
        await harness.settle()

        let tab = try #require(harness.model.tabs.first)
        #expect(tab.fileKind == .media)
        #expect(harness.player.item?.url == file)
        #expect(harness.grants.counts == [Self.ref: 1])

        harness.coordinator.close(tab)
        #expect(harness.player.item == nil)
        #expect(harness.grants.held == 0)
    }

    @Test("a phone-side file that does not open inside Fermix goes out and holds nothing", arguments: ["mp4", "epub"])
    func refOutsideHoldsNothing(_ ext: String) async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(Self.ref + "." + ext, in: place.home))
        let harness = place.harness()
        harness.grants.answers[Self.ref] = Self.grant(file)

        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)
        await harness.settle()

        #expect(harness.model.tabs.isEmpty)
        #expect(harness.workspace.openedWith.map(\.file) + harness.workspace.revealed == [file], "\(ext)")
        #expect(harness.grants.log == ["hold " + Self.ref, "release " + Self.ref])
    }

    /// The tile says Not available; the pane says nothing and opens nothing.
    @Test("a phone-side file whose bytes are gone opens nothing and says so to its tile")
    func refMissing() async {
        let harness = BrowserHarness()
        harness.grants.answers[Self.ref] = .missing

        #expect(await harness.coordinator.openRef(Self.ref, named: Self.name) == .missing)
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
        #expect(harness.grants.held == 0)
    }

    @Test("a phone-side file the engine could not get ready opens the pane on the sentence that says so, and holds nothing")
    func refFailed() async {
        let harness = BrowserHarness()
        harness.grants.answers[Self.ref] = .failed

        #expect(await harness.coordinator.openRef(Self.ref, named: Self.name) == .failed)
        #expect(harness.model.notice == ProductStrings[.browserNoticeFileNotReady])
        #expect(harness.model.isOpen)
        #expect(harness.model.tabs.isEmpty)
        #expect(harness.grants.held == 0)
    }

    @Test("a granted file that is not there opens the pane on the sentence that says so, and holds nothing")
    func refGrantedButGone() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.grants.answers[Self.ref] = Self.grant(place.home.appendingPathComponent(Self.ref + ".png"))

        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)

        #expect(harness.model.notice == ProductStrings[.browserNoticeFileMissing])
        #expect(harness.model.tabs.isEmpty)
        #expect(harness.grants.held == 0)
    }

    /// A granted file the pane reads as outside the home waits behind the
    /// question up, as any file does, and keeps its grant only while it
    /// waits.
    @Test("a phone-side file kept behind a question keeps its grant until a later click or hiding the pane lets it go")
    func refKeptBehindAQuestion() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(Self.ref + ".md", in: place.outside))
        let harness = place.harness()
        harness.grants.answers[Self.ref] = Self.grant(file)
        harness.coordinator.openFile(try place.write("first.md", in: place.outside))

        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)
        #expect(harness.grants.counts == [Self.ref: 1])

        harness.coordinator.openFile(try place.write("third.md", in: place.outside))
        #expect(harness.grants.held == 0, "a replaced click kept its grant")

        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)
        harness.coordinator.closePane()
        #expect(harness.grants.held == 0, "hiding the pane kept the grant")
        #expect(harness.grants.holds == 2)
    }

    @Test("a phone-side file opened twice is two tabs, each holding its own use of the grant")
    func refInTwoTabs() async throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let file = FilePlaceFixture.real(try place.write(Self.ref + ".pdf", in: place.home))
        let harness = place.harness()
        harness.grants.answers[Self.ref] = Self.grant(file)

        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)
        _ = await harness.coordinator.openRef(Self.ref, named: Self.name)
        #expect(harness.model.tabs.count == 2)
        #expect(harness.grants.counts == [Self.ref: 2])

        harness.coordinator.close(try #require(harness.model.tabs.first))
        #expect(harness.grants.counts == [Self.ref: 1])
    }

    // MARK: - Picture zoom

    @Test("a picture tab knows it is one, and the pane's zoom reaches the page in front")
    func pictureTabZoom() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        harness.coordinator.openFile(try place.write("shot.png", in: place.home))
        let tab = try #require(harness.model.tabs.first)

        harness.coordinator.zoom(.actualSize)
        harness.coordinator.zoom(.fit)
        harness.page(0).events?.pageChanged(BrowserPageState(isMagnified: true))

        #expect(tab.fileKind == .image)
        #expect(harness.page(0).actions == ["zoom actualSize", "zoom fit"])
        #expect(tab.isMagnified)
    }
}

/// The viewers are the GUI's and nobody else's (M66 §3.5, §3.7).
///
/// Both executables link `FermixAppCore`, so an AVKit or Quick Look import
/// there would put a viewer into `FermixAgent`, which shows nothing. The core
/// declares the seams and imports neither; `FermixViewers`, linked by the GUI
/// executable alone, is the one place a film, a document or a tile's
/// thumbnail is drawn.
@Suite("Viewer boundary")
struct ViewerBoundaryTests {
    @Test("only the viewers target imports AVKit, QuickLookUI and QuickLookThumbnailing", arguments: [
        "import AVKit", "import QuickLookUI", "import QuickLookThumbnailing", "import Quartz"
    ])
    func onlyTheViewersImportThem(_ statement: String) throws {
        let importers = try SparkleAdapterSource.everySwiftFileUnderSources()
            .filter { $0.text.contains(statement) }
        let offenders = importers.filter { !$0.path.contains("/FermixViewers/") }

        #expect(offenders.isEmpty, "\(statement) outside the viewers target in: \(offenders.map(\.path))")
    }

    /// A scan that finds nothing passes every assertion it was written to
    /// make, so the viewers themselves have to show up in it.
    @Test("the scan finds the viewers target and each framework in it")
    func theScanFindsTheViewers() throws {
        let viewers = try SparkleAdapterSource.everySwiftFileUnderSources()
            .filter { $0.path.contains("/FermixViewers/") }

        for statement in ["import AVKit", "import QuickLookUI", "import QuickLookThumbnailing"] {
            #expect(viewers.contains { $0.text.contains(statement) }, "the viewers target no longer imports \(statement)")
        }
    }
}
