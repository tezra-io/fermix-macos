import Foundation
import Testing
import UniformTypeIdentifiers

@testable import FermixAppCore

/// What a tile draws, by its file's type and place and what its preview came
/// to: content only inside the Fermix home and only for pictures, frames,
/// pages and documents; icons for markup, text and code anywhere; Opens
/// outside for what the pane does not show; and one state at a time, every
/// one but Loading an end.
@Suite("Chat preview policy")
struct ChatPreviewPolicyTests {
    private typealias F = ChatFactsFixture

    /// What the pane's own rule shows a file as, read as a tile reads it:
    /// with no bytes, so a type known only as data is taken for text.
    private static func paneKind(_ facts: ChatFileFacts) -> BrowserFileKind? {
        BrowserLocalFile.kind(of: facts.type, as: facts.entry, readsAsText: { true })
    }

    // MARK: - Content or icon

    @Test("inside the home a picture, a video, a PDF and a document draw their content")
    func contentInsideTheHome() {
        for path in ["/h/shot.png", "/h/raw.cr2", "/h/clip.mp4", "/h/report.pdf", "/h/q3.docx", "/h/sheet.xlsx", "/h/deck.pptx"] {
            #expect(ChatPreviewPolicy.drawsContent(F.facts(path)), "\(path)")
        }
        #expect(ChatPreviewPolicy.drawsContent(F.facts("/h/Notes.pages", isDirectory: true)))
        #expect(ChatPreviewPolicy.drawsContent(F.facts("/h/Story.rtfd", isDirectory: true)))
    }

    @Test("outside the home every one of them shows its icon")
    func iconsOutsideTheHome() {
        for path in ["/x/shot.png", "/x/clip.mp4", "/x/report.pdf", "/x/q3.docx"] {
            let facts = F.facts(path, insideHome: false)

            #expect(!ChatPreviewPolicy.drawsContent(facts), "\(path)")
            #expect(ChatPreviewPolicy.state(of: .found(facts), outcome: nil) == .ready(nil), "\(path) asks for nothing")
        }
    }

    /// A reply naming `~/.ssh/config` must not print its first lines, and
    /// Quick Look draws a page with WebKit, which could reach the network.
    @Test("HTML, SVG, a config file, CSV, Markdown and source code show their icon anywhere")
    func iconsAnywhere() {
        let facts = [
            F.facts("/h/page.html"), F.facts("/h/logo.svg"), F.facts("/h/.ssh/config", type: .data),
            F.facts("/h/table.csv"), F.facts("/h/notes.md"), F.facts("/h/app.swift"), F.facts("/h/run.sh"), F.facts("/h/song.mp3"),
        ]

        for file in facts {
            #expect(!ChatPreviewPolicy.drawsContent(file), "\(file.file.path)")
        }
    }

    // MARK: - Families and Opens outside

    @Test("each type has its family and its word")
    func families() {
        let words = [
            "/a.png": "Picture", "/a.psd": "Picture", "/a.svg": "Picture", "/a.mov": "Video", "/a.m4a": "Sound",
            "/a.pdf": "PDF", "/a.docx": "Document", "/a.key": "Document", "/a.numbers": "Document", "/a.rtf": "Document",
            "/a.html": "Page", "/a.csv": "File", "/a.md": "File", "/a.py": "File", "/a.zip": "File",
        ]

        for (path, word) in words {
            let type = ChatPreviewPolicy.type(ofPath: path) ?? .data
            #expect(ChatPreviewPolicy.kindWord(ChatPreviewPolicy.family(of: type)) == word, "\(path)")
        }
    }

    /// A package's extension names the package, since text cannot say
    /// whether a path is a folder.
    @Test("a package's extension names its package type")
    func packageExtensions() {
        #expect(ChatPreviewPolicy.type(ofPath: "/a/Story.rtfd") == .rtfd)
        #expect(ChatPreviewPolicy.type(ofPath: "/a/Notes.pages")?.conforms(to: .package) == true)
        #expect(ChatPreviewPolicy.type(ofPath: "/a/README") == nil)
    }

    @Test("a picture, video, sound, PDF or document is worth a tile anywhere, and text, markup and data are not")
    func worthSeeing() {
        for path in ["/a.png", "/a.mov", "/a.mp3", "/a.pdf", "/a.xlsx", "/a.pages"] {
            #expect(ChatPreviewPolicy.isWorthSeeing(ChatPreviewPolicy.type(ofPath: path) ?? .data), "\(path)")
        }
        for path in ["/a.txt", "/a.html", "/a.csv", "/a.json", "/a.zip", "/a.app"] {
            #expect(!ChatPreviewPolicy.isWorthSeeing(ChatPreviewPolicy.type(ofPath: path) ?? .data), "\(path)")
        }
    }

    /// Opens outside is decided by family, from the opening table: a folder
    /// that is no package, anything that runs, and content in no family the
    /// pane shows. A type known only as data claims nothing: the pane reads
    /// its bytes to tell whether it is text.
    @Test("a plain folder, an app and an ebook open outside; a document's package and data do not")
    func opensOutside() {
        let outside = [
            F.facts("/h/out", type: .folder, isDirectory: true),
            F.facts("/h/Tool.app", type: .applicationBundle, isDirectory: true),
            F.facts("/h/book.epub"),
            F.facts("/h/tool", type: .unixExecutable, isExecutable: true),
        ]
        for facts in outside {
            #expect(ChatPreviewPolicy.state(of: .found(facts), outcome: nil) == .opensOutside, "\(facts.file.path)")
        }

        let shown = [
            F.facts("/h/Notes.pages", isDirectory: true), F.facts("/h/Story.rtfd", isDirectory: true),
            F.facts("/h/archive.zip"), F.facts("/h/.ssh/config", type: .data), F.facts("/h/run.sh", isExecutable: true),
        ]
        for facts in shown {
            #expect(ChatPreviewPolicy.state(of: .found(facts), outcome: nil) != .opensOutside, "\(facts.file.path)")
        }
    }

    /// One owner for what a file opens as: a tile opens outside exactly
    /// where the pane's own rule shows the file as nothing, and draws the
    /// kind of thing the pane shows it as.
    @Test("a tile's family follows the pane's own rule, file by file")
    func familyFollowsThePanesRule() throws {
        let keynote = try #require(UTType("com.apple.iwork.keynote.key"))
        let cases: [(ChatFileFacts, BrowserFileKind?)] = [
            (F.facts("/h/Report.pages", isDirectory: true), .document),
            (F.facts("/h/Deck.key", type: keynote, isDirectory: true), .document),
            (F.facts("/h/Story.rtfd", isDirectory: true), .document),
            (F.facts("/h/out", type: .folder, isDirectory: true), nil),
            (F.facts("/h/shot.png"), .image),
            (F.facts("/h/shot.png", isExecutable: true), .image),
            (F.facts("/h/raw.cr2"), .document),
            (F.facts("/h/raw.cr2", isExecutable: true), nil),
            (F.facts("/h/clip.mov"), .media),
            (F.facts("/h/song.mp3", isExecutable: true), nil),
            (F.facts("/h/q3.docx"), .document),
            (F.facts("/h/q3.docx", isExecutable: true), nil),
            (F.facts("/h/table.csv"), .document),
            (F.facts("/h/table.csv", size: BrowserFileKind.textSizeCap + 1), nil),
            (F.facts("/h/log.txt", size: BrowserFileKind.textSizeCap + 1), nil),
            (F.facts("/h/page.html"), .html),
            (F.facts("/h/report.pdf"), .pdf),
            (F.facts("/h/book.epub"), nil),
        ]

        for (facts, kind) in cases {
            #expect(Self.paneKind(facts) == kind, "\(facts.file.path)")
            #expect((ChatPreviewPolicy.family(of: facts) == .other) == (kind == nil), "\(facts.file.path)")
        }
    }

    /// A Pages document is a package, a folder its type names, which the
    /// pane shows in a document tab and its tile draws as one.
    @Test("a Pages package is a document to the pane and to its tile, drawn inside the home and offered to its app")
    func pagesPackage() throws {
        let sffpages = try #require(UTType("com.apple.iwork.pages.sffpages"))
        let package = F.facts("/h/Report.pages", isDirectory: true)
        let single = F.facts("/h/Report.pages", type: sffpages)

        #expect(package.type.conforms(to: .package))
        #expect(Self.paneKind(package) == .document)
        #expect(ChatPreviewPolicy.family(of: package) == .document)
        #expect(ChatPreviewPolicy.drawsContent(package))
        #expect(ChatPreviewPolicy.handsToApp(package))
        #expect(ChatPreviewPolicy.kindWord(ChatPreviewPolicy.family(of: package)) == "Document")
        #expect(Self.paneKind(single) == .document)
        #expect(ChatPreviewPolicy.family(of: single) == .document)
    }

    /// Launch Services would run such a file rather than open it, so it never
    /// reaches a media or document tab, nor its app. A picture WebKit draws
    /// is shown as the picture it is.
    @Test("a document, a sound, a film or a raw picture with its executable bit set opens outside")
    func executableBit() {
        for path in ["/h/q3.docx", "/h/song.mp3", "/h/clip.mov", "/h/raw.cr2"] {
            let facts = F.facts(path, isExecutable: true)

            #expect(Self.paneKind(facts) == nil, "\(path)")
            #expect(ChatPreviewPolicy.family(of: facts) == .other, "\(path)")
        }
        #expect(Self.paneKind(F.facts("/h/shot.png", isExecutable: true)) == .image)
        #expect(ChatPreviewPolicy.family(of: F.facts("/h/shot.png", isExecutable: true)) == .picture)
    }

    @Test("text or CSV past the size the pane reads whole opens outside")
    func textPastTheCap() {
        #expect(Self.paneKind(F.facts("/h/log.txt", size: BrowserFileKind.textSizeCap)) == .text)
        #expect(ChatPreviewPolicy.family(of: F.facts("/h/log.txt", size: BrowserFileKind.textSizeCap)) == .text)
        #expect(ChatPreviewPolicy.family(of: F.facts("/h/log.txt", size: BrowserFileKind.textSizeCap + 1)) == .other)
        #expect(ChatPreviewPolicy.family(of: F.facts("/h/table.csv", size: BrowserFileKind.textSizeCap)) == .text)
        #expect(ChatPreviewPolicy.family(of: F.facts("/h/table.csv", size: BrowserFileKind.textSizeCap + 1)) == .other)
    }

    @Test("an Opens outside hint names the app only where opening hands the file to one, by the pane's own rule")
    func handsToApp() {
        let files = [
            F.facts("/h/clip.mov"), F.facts("/h/clip.mov", isExecutable: true), F.facts("/h/book.epub"),
            F.facts("/h/out", type: .folder, isDirectory: true), F.facts("/h/Report.pages", isDirectory: true),
        ]
        for facts in files {
            #expect(ChatPreviewPolicy.handsToApp(facts) == BrowserLocalFile.mayGoToAnApp(facts.type, as: facts.entry), "\(facts.file.path)")
        }

        #expect(ChatPreviewPolicy.handsToApp(F.facts("/h/clip.mov")))
        #expect(!ChatPreviewPolicy.handsToApp(F.facts("/h/clip.mov", isExecutable: true)))
        #expect(!ChatPreviewPolicy.handsToApp(F.facts("/h/book.epub")))
        #expect(!ChatPreviewPolicy.handsToApp(F.facts("/h/out", type: .folder, isDirectory: true)))
    }

    // MARK: - States

    @Test("a tile is Loading until its facts and its preview are in, and missing bytes are Not available")
    func loadingAndMissing() {
        let shot = F.facts("/h/shot.png")

        #expect(ChatPreviewPolicy.state(of: .reading, outcome: nil) == .loading)
        #expect(ChatPreviewPolicy.state(of: .found(shot), outcome: nil) == .loading)
        #expect(ChatPreviewPolicy.state(of: .missing, outcome: nil) == .notAvailable)
    }

    /// A failed preview never disables a readable file: it is Preview
    /// unavailable, which still opens, and a preview let go is too until the
    /// tile asks again.
    @Test("each preview outcome ends in its own state, and a failed one leaves the file clickable")
    func outcomes() {
        let shot = F.facts("/h/shot.png")
        let preview = ChatPreview(image: FakeMediaReader.image(), detail: nil)

        #expect(ChatPreviewPolicy.state(of: .found(shot), outcome: .made(preview)) == .ready(preview))
        #expect(ChatPreviewPolicy.state(of: .found(shot), outcome: .iconOnly) == .ready(nil))
        #expect(ChatPreviewPolicy.state(of: .found(shot), outcome: .failed) == .previewUnavailable)
        #expect(ChatPreviewPolicy.state(of: .found(shot), outcome: .dropped) == .previewUnavailable)
        #expect(ChatPreviewPolicy.state(of: .found(F.facts("/h/clip.mov")), outcome: .unplayable) == .opensOutside)
        #expect(ChatPreviewPolicy.state(of: .found(shot), outcome: .failed) != .notAvailable)
    }

    @Test("a PDF's page count reads in words, one key for one page and one for more")
    func pageCount() {
        #expect(ChatPreviewPolicy.pages(1) == "1 page")
        #expect(ChatPreviewPolicy.pages(12) == "12 pages")
    }
}
