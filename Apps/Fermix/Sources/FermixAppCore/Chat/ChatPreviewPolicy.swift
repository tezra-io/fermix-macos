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
    /// The file is gone, or the engine no longer has a phone-side file's
    /// bytes: icon, name and "Not available", and a click does nothing.
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
/// writes what it makes, and for a phone-side file, which the engine grants
/// there: a file outside it shows its icon until it is clicked, and the pane
/// asks before loading it. A phone-side file is judged by the type its row
/// names, through the same rules as a path. Text, code, HTML and SVG
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
        guard BrowserLocalFile.kind(of: facts.disk, readsAsText: { true }) != nil else { return .other }

        return facts.disk.entry == .folder ? .document : family(of: facts.type)
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

    /// The type a phone-side file is, read from the row before any file is
    /// granted for it: its mime's, and where the Mac knows no type by that
    /// mime, the broad one its kind names. A kind of no family is data.
    static func type(of ref: CompanionMediaRef) -> UTType {
        if let type = UTType(mimeType: ref.mime), !type.isDynamic { return type }

        switch ref.kind {
        case "image": return .image
        case "video": return .movie
        case CompanionProtocol.audioKind: return .audio
        default: return .data
        }
    }

    /// What a phone-side file's own file is on the disk, as the engine makes
    /// it: a regular file of its type, its size the row's, and nothing that
    /// runs. The pane's own rule reads the real one when it is opened.
    static func facts(of ref: CompanionMediaRef) -> FileFacts {
        FileFacts(type: type(of: ref), entry: .file(size: ref.sizeBytes, isExecutable: false))
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
    /// thumbnail. A path the strip reads as one, inside the Fermix home, and
    /// a phone-side file of one, are preview tiles, and keep that shape
    /// whatever their file turns out to be.
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
        case .found(let facts): return cardState(of: family(of: facts))
        }
    }

    /// The state of a phone-side file drawn as a card, which asks for nothing
    /// until it is clicked: Not available once a click has found its bytes
    /// gone, and otherwise as its type says.
    static func cardState(of ref: CompanionMediaRef, gone: Bool) -> ChatTileState {
        gone ? .notAvailable : cardState(of: family(of: type(of: ref)))
    }

    private static func cardState(of family: ChatFileFamily) -> ChatTileState {
        family == .other ? .opensOutside : .ready(nil)
    }

    /// The state a preview's answer puts its tile in, nil while it is being
    /// made: a phone-side file's tile has nothing else to learn.
    static func state(of outcome: ChatPreviewOutcome?) -> ChatTileState {
        switch outcome {
        case nil: return .loading
        case .made(.picture(let preview))?: return .ready(preview)
        // A sound's levels are its waveform's and a map its block's, never a
        // tile's: were one to reach a tile, it would show its icon.
        case .made(.levels)?, .made(.map)?, .iconOnly?: return .ready(nil)
        case .unplayable?: return .opensOutside
        case .failed?, .dropped?: return .previewUnavailable
        case .missing?: return .notAvailable
        }
    }

    /// Whether opening a file outside Fermix hands it to an app, as the
    /// pane's own rule decides (`BrowserLocalFile.mayGoToAnApp`), so its hint
    /// names that app; anything else is only ever shown in Finder.
    static func handsToApp(_ disk: FileFacts) -> Bool {
        BrowserLocalFile.mayGoToAnApp(disk)
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

    /// A phone-side file's name on its tile: its filename where its row
    /// gives one, and its kind's word where not.
    static func name(of ref: CompanionMediaRef) -> String {
        ref.filename ?? kindWord(family(of: type(of: ref)))
    }

    /// What VoiceOver reads for a phone-side file's tile: its name with its
    /// kind's word, or the word alone where that is all its name is.
    static func label(of ref: CompanionMediaRef) -> String {
        let kind = kindWord(family(of: type(of: ref)))
        return ref.filename.map { ProductStrings.commaPair($0, kind) } ?? kind
    }

    /// A PDF's page count, in words.
    static func pages(_ count: Int) -> String {
        count == 1 ? ProductStrings[.chatTilePagesOne] : String(format: ProductStrings[.chatTilePagesMany], count)
    }
}
