import Foundation
import UniformTypeIdentifiers

/// What a file is to a tile, by its type: the word VoiceOver reads after its
/// name, whether the tile may draw what is in it, and whether the pane shows
/// it at all (M66 §3.3, §3.5).
enum ChatFileFamily: Equatable, Sendable {
    /// Any picture, those WebKit does not draw (a Photoshop or camera raw
    /// file) among them, and an SVG, which is drawn as its icon.
    case picture
    case video
    case sound
    case pdf
    /// Word processing, spreadsheets, presentations and rich text, packages
    /// among them (Pages, Numbers, Keynote, RTFD).
    case document
    /// HTML, drawn as its icon wherever it is.
    case page
    /// Text, Markdown, CSV, code and scripts: read in the pane, never printed
    /// into the window.
    case text
    /// A type the Mac knows only as data, or not at all (`~/.ssh/config`):
    /// the pane reads its bytes to tell whether it is text, which a tile does
    /// not, so the tile claims nothing about where it opens.
    case data
    /// Content in no family the pane shows, a folder, or anything that runs.
    /// It opens outside Fermix.
    case other
}

/// The facts a tile reads of the file a path names, off the main thread
/// (`ChatFileFacts.read`): enough to choose its look and to key its preview.
struct ChatFileFacts: Equatable, Sendable {
    /// Where the path really lands, every symbolic link resolved.
    let file: URL
    let type: UTType
    /// A folder or a package.
    let isDirectory: Bool
    /// A regular file with its executable bit set, which Launch Services
    /// would run rather than open.
    let isExecutable: Bool
    /// What the preview cache keys on: the file's volume and number, which a
    /// rename keeps and a new file under the old name does not, and its
    /// modification date and size, which an edit changes.
    let identity: ChatFileIdentity
    let modified: Date
    /// Its size in bytes. A folder, a package among them, has none of its
    /// own and counts zero.
    let size: Int
    /// Whether it lies inside the Fermix home, decided where both really are.
    let insideHome: Bool

    /// What it is on the disk, as the pane's own rule reads it.
    var entry: BrowserLocalFile.Entry {
        isDirectory ? .folder : .file(size: size, isExecutable: isExecutable)
    }
}

/// A file's identity on this Mac: its volume and its number there.
struct ChatFileIdentity: Hashable, Sendable {
    let volume: UInt64
    let number: UInt64
}

/// What a tile has learnt of its file so far.
enum ChatFileLookup: Equatable, Sendable {
    /// Its facts are being read.
    case reading
    /// Nothing is there now.
    case missing
    case found(ChatFileFacts)
}

/// The one state a tile is in, each with its own look (M66 §3.3). Every one
/// but Loading is where a tile ends, and Loading ends in one of the others,
/// since a preview that takes too long counts as failed.
enum ChatTileState: Equatable {
    /// Its facts or its preview are being read: icon and name.
    case loading
    /// What the tile draws: the preview made of its content, or nil where
    /// its icon is its picture, by its type or its place.
    case ready(ChatPreview?)
    /// The preview failed or took too long, and the file is there: icon and
    /// name, and a click still opens it.
    case previewUnavailable
    /// The pane does not show it: icon, name and the pane's open-in-app
    /// glyph, and a click hands it to its app or shows it in Finder.
    case opensOutside
    /// The file is gone, or its bytes are not in the app's hands: icon, name
    /// and "Not available", and a click does nothing.
    case notAvailable
}

/// Where an Opens outside tile goes, as VoiceOver's hint says it: the app
/// its type opens in, found by Launch Services, or Finder where none takes it.
enum ChatTileHint: Equatable, Sendable {
    case openIn(String)
    case showInFinder
}

/// The rules a tile is drawn by, over a file's type, its place and what its
/// preview came to. Pure, so every rule is provable without a file.
///
/// What a file opens as is not decided here: the pane's own rule decides it
/// (`BrowserFileKind` by type, `BrowserLocalFile.kind` on the disk), so a
/// tile and a click on its link can never disagree. What is here is the
/// tile's: its word, whether it draws content, and where it goes outside.
///
/// Content is drawn only for a file inside the Fermix home, where Fermix
/// writes what it makes: a file outside it shows its icon until it is
/// clicked, and the pane asks before loading it. Text, code, HTML and SVG
/// show their icon wherever they are: a reply that names `~/.ssh/config` must
/// not print its first lines into the window, and Quick Look draws a page
/// with WebKit, which could load a remote picture the moment it is drawn.
enum ChatPreviewPolicy {
    /// The family a type belongs to, from the kind the pane shows it as, in
    /// the words a tile has for it: a picture WebKit does not draw is still a
    /// picture, CSV is text, and a sound and a film are told apart. A type the
    /// pane shows as no kind is data where the pane would read its bytes, and
    /// otherwise opens outside: content in no family, and what runs, which
    /// the pane shows only as the text a script is.
    static func family(of type: UTType) -> ChatFileFamily {
        switch BrowserFileKind(type) {
        case .image?: return .picture
        case .pdf?: return .pdf
        case .html?: return .page
        case .text?: return .text
        case .media?: return type.conforms(to: .audio) ? .sound : .video
        case .document?: return documentFamily(of: type)
        case nil: return BrowserLocalFile.isUntyped(type) && !BrowserLocalFile.runs(type) ? .data : .other
        }
    }

    /// The family of a file as it is on the disk: what the pane shows of it
    /// is the pane's own rule, so a file it shows only in Finder (a plain
    /// folder, a viewer's file with its executable bit set, text or CSV past
    /// the size cap) opens outside, and a package it shows is a document. A
    /// tile reads no bytes, so a type the Mac knows only as data is taken for
    /// the text the pane may find it is, and claims nothing more.
    static func family(of facts: ChatFileFacts) -> ChatFileFamily {
        guard BrowserLocalFile.kind(of: facts.type, as: facts.entry, readsAsText: { true }) != nil else { return .other }

        return facts.isDirectory ? .document : family(of: facts.type)
    }

    /// A document tab's family in a tile's words: a picture WebKit does not
    /// draw, CSV, which Quick Look draws as a table and a tile as text, or a
    /// document.
    private static func documentFamily(of type: UTType) -> ChatFileFamily {
        if type.conforms(to: .image) { return .picture }
        if type.conforms(to: .commaSeparatedText) { return .text }

        return .document
    }

    /// The type a path's extension names, read without the disk. An
    /// extension a package declares (`.rtfd`, `.pages`) is that package's
    /// type, since text cannot say whether the path is a folder.
    static func type(ofPath path: String) -> UTType? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }

        return UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil).first { !$0.isDynamic }
    }

    /// Whether a path in a reply is worth a tile wherever it is: a picture,
    /// a video, a sound, a PDF or a document. Inside the Fermix home every
    /// path is (`ChatStrip`).
    static func isWorthSeeing(_ type: UTType) -> Bool {
        switch family(of: type) {
        case .picture, .video, .sound, .pdf, .document: return true
        case .page, .text, .data, .other: return false
        }
    }

    /// Whether a type is one a tile draws by its content: a picture other
    /// than an SVG, a video's frame, a PDF's first page or a document's
    /// thumbnail. A path the strip reads as one, inside the Fermix home, is a
    /// preview tile, and keeps that shape whatever its file turns out to be.
    static func showsContent(_ type: UTType) -> Bool {
        showsContent(family(of: type), type)
    }

    /// Whether a tile draws the file's content rather than its icon: a type
    /// drawn by its content, as the disk finds it, and only for a file
    /// inside the Fermix home where it really lands.
    static func drawsContent(_ facts: ChatFileFacts) -> Bool {
        facts.insideHome && showsContent(family(of: facts), facts.type)
    }

    private static func showsContent(_ family: ChatFileFamily, _ type: UTType) -> Bool {
        switch family {
        case .picture: return !type.conforms(to: .svg)
        case .video, .pdf, .document: return true
        case .sound, .page, .text, .data, .other: return false
        }
    }

    /// The state a file's tile is in, from what it has learnt of the file and
    /// what its preview came to, nil while none was asked for or it is still
    /// being made.
    static func state(of lookup: ChatFileLookup, outcome: ChatPreviewOutcome?) -> ChatTileState {
        let card = cardState(of: lookup)
        guard card == .ready(nil), case .found(let facts) = lookup, drawsContent(facts) else { return card }

        return state(of: outcome)
    }

    /// The state of a file drawn as a card, which asks for no preview: its
    /// icon is its picture once it is found.
    static func cardState(of lookup: ChatFileLookup) -> ChatTileState {
        switch lookup {
        case .reading: return .loading
        case .missing: return .notAvailable
        case .found(let facts): return family(of: facts) == .other ? .opensOutside : .ready(nil)
        }
    }

    private static func state(of outcome: ChatPreviewOutcome?) -> ChatTileState {
        switch outcome {
        case nil: return .loading
        case .made(let preview)?: return .ready(preview)
        case .iconOnly?: return .ready(nil)
        case .unplayable?: return .opensOutside
        case .failed?, .dropped?: return .previewUnavailable
        }
    }

    /// Whether opening a file outside Fermix hands it to an app, as the
    /// pane's own rule decides (`BrowserLocalFile.mayGoToAnApp`), so its hint
    /// names that app; anything else is only ever shown in Finder.
    static func handsToApp(_ facts: ChatFileFacts) -> Bool {
        BrowserLocalFile.mayGoToAnApp(facts.type, as: facts.entry)
    }

    /// The word VoiceOver reads after a tile's name.
    static func kindWord(_ family: ChatFileFamily) -> String {
        switch family {
        case .picture: return ProductStrings[.chatKindPicture]
        case .video: return ProductStrings[.chatKindVideo]
        case .sound: return ProductStrings[.chatKindSound]
        case .pdf: return ProductStrings[.chatKindPDF]
        case .document: return ProductStrings[.chatKindDocument]
        case .page: return ProductStrings[.chatKindPage]
        case .text, .data, .other: return ProductStrings[.chatKindFile]
        }
    }

    /// A PDF's page count, in words.
    static func pages(_ count: Int) -> String {
        count == 1 ? ProductStrings[.chatTilePagesOne] : String(format: ProductStrings[.chatTilePagesMany], count)
    }
}
