import Foundation
import UniformTypeIdentifiers

/// A file on this Mac a link names, read as the person opens it (plan §8.2,
/// M66 §3.5): where it really is, and what opening it comes to.
///
/// Everything is decided on the file the link lands on, every symbolic link
/// resolved, never on the link's own name: a `notes.txt` that points at an
/// app is an app. The rule is an allowlist: what the pane shows it shows,
/// and everything else, from a folder to an app to a type nobody declared,
/// is only ever shown in Finder, which runs nothing. A document of a named
/// family also has an app it may go to, which its tab offers by name and
/// which takes a sound or a film the app's player cannot play; that app is
/// never one that opens web pages.
///
/// The rule itself is pure (`kind(of:as:readsAsText:)`), over what the file
/// system says of a file, so the chat's tiles decide by it too
/// (`ChatPreviewPolicy`): one owner for what a file opens as.
struct BrowserLocalFile {
    /// What opening the file comes to.
    enum Opening: Equatable {
        /// A file tab, showing it as this kind.
        case show(BrowserFileKind)
        /// Selected in Finder, and nothing opened.
        case reveal
    }

    /// What a path is on the disk, as the rule reads it.
    enum Entry: Equatable, Sendable {
        /// A regular file: its size, and whether its executable bit is set.
        case file(size: Int, isExecutable: Bool)
        /// A folder, or a package, which is a folder its type names.
        case folder
        /// Anything else: a pipe, a socket, a device.
        case other
    }

    /// What runs when it is opened: an app, an executable and a script, and
    /// anything that conforms to one. Never handed to an app nor drawn by a
    /// viewer, though a script is shown as the text it is.
    static let runnableTypes: [UTType] = [
        .applicationBundle, .application, .executable, .unixExecutable, .script, .shellScript
    ]

    /// The families of document the pane's own viewers draw and a file may
    /// be handed to an app as: pictures WebKit does not draw, sound and film,
    /// PDF, rich text, spreadsheets, presentations and word processing. Named
    /// rather than all content, which any app may declare more of: a web
    /// archive opens in a browser with its scripts on, and a shortcut opens
    /// an install sheet. Word processing has no family of its own, so its
    /// types are named one by one, a Pages document both as the package it
    /// is saved as and as the single file it can be.
    static let documentTypes: [UTType] = [
        .image, .audiovisualContent, .pdf, .rtf, .rtfd, .flatRTFD, .spreadsheet, .presentation
    ] + [
        "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
        "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages", "org.oasis-open.opendocument.text"
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

    /// The rule: shown where the pane shows it, and only in Finder otherwise.
    func opening() -> Opening {
        shownKind().map(Opening.show) ?? .reveal
    }

    /// What the pane shows the file as, if anything, by the rule, its bytes
    /// read only where its type leaves the rule to them.
    func shownKind() -> BrowserFileKind? {
        guard let facts else { return nil }

        return Self.kind(of: facts.type, as: facts.entry) { Self.readsAsText(url) }
    }

    /// What the pane shows a file of `type` as, or nil where it shows none,
    /// which leaves only Finder. A folder is shown only where it is a
    /// document family's package (a Pages document, an RTFD), as a document;
    /// a plain folder is not. A regular file is shown by its type or, for a
    /// type the Mac does not know as content, by its bytes reading as text,
    /// which `readsAsText` answers and is asked of then alone: a tile, which
    /// reads no bytes, answers for itself. The pane's own viewers never take
    /// a file with its executable bit set, which Launch Services would run
    /// rather than open, and a file read whole is not shown past the size
    /// cap.
    static func kind(of type: UTType, as entry: Entry, readsAsText: () -> Bool) -> BrowserFileKind? {
        switch entry {
        case .folder:
            return isDocument(type) ? .document : nil
        case .other:
            return nil
        case .file(let size, let isExecutable):
            let kind = BrowserFileKind(type) ?? (isUntyped(type) && readsAsText() ? .text : nil)
            guard let kind, kind.drawnByWebKit || !isExecutable else { return nil }
            guard !kind.readsWhole(type) || size <= BrowserFileKind.textSizeCap else { return nil }

            return kind
        }
    }

    /// The app a document goes to, named now from its type, where it may go
    /// to one (`mayGoToAnApp`), and never to an app that opens web pages,
    /// which would run what a file tab keeps inert.
    @MainActor
    func documentApplication(_ workspace: any WorkspaceLinkOpening) -> WorkspaceApplication? {
        guard let facts, Self.mayGoToAnApp(facts.type, as: facts.entry) else { return nil }
        guard let app = workspace.application(toOpen: facts.type), !workspace.opensWebPages(app) else { return nil }

        return app
    }

    /// Whether a file may be handed to an app at all: only a document of a
    /// family, never anything that runs or a file with its executable bit
    /// set, which Launch Services would run rather than open.
    static func mayGoToAnApp(_ type: UTType, as entry: Entry) -> Bool {
        guard isDocument(type) else { return false }
        guard case .file(_, true) = entry else { return true }

        return false
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
    static func isUntyped(_ type: UTType) -> Bool {
        type.isDynamic || !type.conforms(to: .content)
    }

    /// Text where its first 64 KB is UTF-8 with no NUL byte. A read cut short
    /// may end inside a character, so up to three trailing bytes are let go
    /// there.
    private static func readsAsText(_ file: URL) -> Bool {
        guard let bytes = FilePlace.contents(ofRegularFile: file.path, upTo: sniffLength), !bytes.contains(0) else { return false }

        let cut = bytes.count == sniffLength ? 3 : 0
        return (0...cut).contains { String(validating: bytes.dropLast($0), as: UTF8.self) != nil }
    }

    /// What the rule reads of a file. A regular file whose size cannot be
    /// read gives no facts at all.
    private struct Facts {
        let type: UTType
        let entry: Entry

        init?(of file: URL) {
            let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey, .isDirectoryKey, .isExecutableKey, .fileSizeKey]
            guard let values = try? file.resourceValues(forKeys: keys), let type = values.contentType else { return nil }

            self.type = type
            if values.isDirectory == true {
                entry = .folder
            } else if values.isRegularFile == true {
                guard let size = values.fileSize else { return nil }

                entry = .file(size: size, isExecutable: values.isExecutable == true)
            } else {
                entry = .other
            }
        }
    }
}
