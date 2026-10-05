import Foundation
import UniformTypeIdentifiers

/// A file on this Mac a link names, read as the person opens it (plan §8.2):
/// where it really is, and what opening it comes to.
///
/// Everything is decided on the file the link lands on, every symbolic link
/// resolved, never on the link's own name: a `notes.txt` that points at an
/// app is an app. The rules are an allowlist, in order: what the pane shows
/// it shows; a document of a named family goes to the app that opens its
/// type, where that app is no browser; and everything else, from a folder to
/// an app to a type nobody declared, is only ever shown in Finder, which runs
/// nothing.
struct BrowserLocalFile {
    /// What opening the file comes to.
    enum Opening: Equatable {
        /// A file tab, showing it as this kind.
        case show(BrowserFileKind)
        /// Handed to this app as a document, the app named now.
        case open(WorkspaceApplication)
        /// Selected in Finder, and nothing opened.
        case reveal
    }

    /// What runs when it is opened: an app, an executable and a script, and
    /// anything that conforms to one. Never handed to an app, though a script
    /// is shown as the text it is.
    static let runnableTypes: [UTType] = [
        .applicationBundle, .application, .executable, .unixExecutable, .script, .shellScript
    ]

    /// The families of document a file may be handed to an app as: pictures
    /// WebKit does not draw, sound and film, PDF, rich text, spreadsheets,
    /// presentations and word processing. Named rather than all content, which
    /// any app may declare more of: a web archive opens in a browser with its
    /// scripts on, and a shortcut opens an install sheet. Word processing has
    /// no family of its own, so its types are named one by one.
    static let documentTypes: [UTType] = [
        .image, .audiovisualContent, .pdf, .rtf, .rtfd, .flatRTFD, .spreadsheet, .presentation
    ] + [
        "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
        "com.apple.iwork.pages.sffpages", "org.oasis-open.opendocument.text"
    ].compactMap { UTType($0) }

    /// What an app takes as code or as a page, even inside a document family:
    /// text and markup, an SVG among them, which is a picture written in XML.
    /// Rich text is the one text handed over, being a word processor's own.
    static let markupTypes: [UTType] = [.text, .xml, .html, .svg]

    /// How much of a file of no known type is read to tell whether it is
    /// text.
    static let sniffLength = 65_536

    /// Where the link really lands.
    let url: URL
    /// What the file system says of it, read once; nil where it could not
    /// say, which leaves only Finder.
    private let facts: Facts?

    /// Nil for a link that is not to a file, or where nothing is there.
    init?(_ link: URL) {
        guard link.isFileURL else { return nil }
        guard let real = FilePlace.resolved(link.path), FileManager.default.fileExists(atPath: real) else { return nil }

        url = URL(fileURLWithPath: real)
        facts = Facts(of: url)
    }

    /// The three rules, in order.
    @MainActor
    func opening(_ workspace: any WorkspaceLinkOpening) -> Opening {
        if let kind = shownKind() { return .show(kind) }
        if let app = documentApplication(workspace) { return .open(app) }

        return .reveal
    }

    /// Rule one: a regular file the pane shows, by its type, or, for a type
    /// the Mac does not know as content, by its bytes reading as text. Text
    /// past the pane's size is not shown.
    func shownKind() -> BrowserFileKind? {
        guard let facts, let size = facts.size else { return nil }

        let kind = BrowserFileKind(facts.type) ?? (Self.isUntyped(facts.type) && Self.readsAsText(url) ? .text : nil)
        guard kind != .text || size <= BrowserFileKind.textSizeCap else { return nil }

        return kind
    }

    /// Rule two: the app a document goes to, named now from its type. Only a
    /// document family goes to one, never anything that runs or a file with
    /// its executable bit set, which Launch Services would run rather than
    /// open, and never to an app that opens web pages, which would run what a
    /// file tab keeps inert.
    @MainActor
    func documentApplication(_ workspace: any WorkspaceLinkOpening) -> WorkspaceApplication? {
        guard let facts, Self.isDocument(facts.type), !(facts.isRegularFile && facts.isExecutable) else { return nil }
        guard let app = workspace.application(toOpen: facts.type), !workspace.opensWebPages(app) else { return nil }

        return app
    }

    static func runs(_ type: UTType) -> Bool {
        runnableTypes.contains(where: type.conforms)
    }

    /// A type of a document family, and neither markup nor anything that
    /// runs.
    static func isDocument(_ type: UTType) -> Bool {
        guard documentTypes.contains(where: type.conforms), !runs(type) else { return false }

        return type.conforms(to: .rtf) || !markupTypes.contains(where: type.conforms)
    }

    /// A type the Mac made up for an extension nobody declared (`dyn.*`), or
    /// one it knows only as data: an archive, an installer, a plug-in, a
    /// shortcut to somewhere else, or source code in a language it was never
    /// told of.
    private static func isUntyped(_ type: UTType) -> Bool {
        type.isDynamic || !type.conforms(to: .content)
    }

    /// Text where its first 64 KB is UTF-8 with no NUL byte. A read cut short
    /// may end inside a character, so up to three trailing bytes are let go
    /// there.
    private static func readsAsText(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: sniffLength) ?? Data() else { return false }
        guard !bytes.contains(0) else { return false }

        let cut = bytes.count == sniffLength ? 3 : 0
        return (0...cut).contains { String(validating: bytes.dropLast($0), as: UTF8.self) != nil }
    }

    /// What the rules read of a file. A regular file whose size cannot be
    /// read gives no facts at all.
    private struct Facts {
        let type: UTType
        let isRegularFile: Bool
        let isExecutable: Bool
        /// A regular file's size; a directory, a package among them, has none.
        let size: Int?

        init?(of file: URL) {
            let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey, .isExecutableKey, .fileSizeKey]
            guard let values = try? file.resourceValues(forKeys: keys), let type = values.contentType else { return nil }

            self.type = type
            isRegularFile = values.isRegularFile == true
            isExecutable = values.isExecutable == true
            size = isRegularFile ? values.fileSize : nil
            guard !isRegularFile || size != nil else { return nil }
        }
    }
}
