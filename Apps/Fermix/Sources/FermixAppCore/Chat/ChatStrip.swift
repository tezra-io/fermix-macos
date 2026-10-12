import CoreGraphics
import Foundation

/// What a finished row shows under its text (M66 §3.1): its tiles, in order,
/// each destination once, and the two things a row draws that are not tiles,
/// its voice note and the sound files Fermix made, which play where they are
/// (§3.4).
///
/// It is worked out from the row's content alone and never looks at the disk:
/// whether a file is there, and what it looks like, is each tile's to find out
/// once it is on screen. The tiles come in this order:
///
/// 1. The row's media refs, in their order.
/// 2. The stored link previews whose address is not one the text links to.
/// 3. The paths the text links to that are worth seeing: anything inside the
///    Fermix home, and a picture, video, sound, PDF or document anywhere. A
///    path that is only talked about (`/etc/hosts`) stays a link in the text.
/// 4. The web addresses the text links to, each with its stored preview where
///    it has one.
struct ChatStrip: Equatable {
    /// The `kind` the engine gives a phone's recorded voice.
    static let voiceKind = "audio"

    /// The row's voice note, its first `audio` ref, drawn as its chip with
    /// the row's text as its transcript.
    let voiceNote: CompanionMediaRef?
    let items: [ChatStripItem]
    /// The sound files inside the Fermix home the text names, in reading
    /// order: each plays in the row rather than showing as a tile.
    let sounds: [URL]

    /// The strip of a row's content. `userHome` is what `~` reads as, and
    /// `home` the Fermix home, nil where it could not be read, which leaves
    /// nothing inside it.
    init(text: String, mediaRefs: [CompanionMediaRef], linkPreviews: [CompanionLinkPreview], userHome: String, home: ChatHome?) {
        let reply = ChatText.reply(text, home: userHome)
        let paths = ReplyPaths.files(in: reply)
        let addresses = ReplyLinks.addresses(in: reply)
        let previews = Self.paired(linkPreviews, in: text, with: addresses)

        voiceNote = mediaRefs.first { $0.kind == Self.voiceKind }
        sounds = Self.unique(paths.filter { Self.isSound($0, home: home) })

        let refs = mediaRefs.filter { $0.kind != Self.voiceKind }.map(ChatStripItem.media)
        let loose = previews.filter { $0.written == nil }.map { ChatStripItem.link(ChatStripLink(address: $0.opens, preview: $0.preview)) }
        let files = paths.filter { Self.isTile($0, home: home) }.map(ChatStripItem.file)
        let links = addresses.map { address in
            ChatStripItem.link(ChatStripLink(address: address, preview: previews.first { $0.written == address }?.preview))
        }
        items = Self.unique(refs + loose + files + links)
    }

    /// A path is a tile when it names something inside the Fermix home or a
    /// file worth seeing anywhere, and is not a sound Fermix made.
    private static func isTile(_ file: URL, home: ChatHome?) -> Bool {
        guard !isSound(file, home: home) else { return false }
        if home?.contains(file) == true { return true }

        return ChatPreviewPolicy.type(ofPath: file.path).map(ChatPreviewPolicy.isWorthSeeing) ?? false
    }

    private static func isSound(_ file: URL, home: ChatHome?) -> Bool {
        guard home?.contains(file) == true, let type = ChatPreviewPolicy.type(ofPath: file.path) else { return false }

        return ChatPreviewPolicy.family(of: type) == .sound
    }

    private static func unique<Item: Hashable>(_ items: [Item]) -> [Item] {
        var seen: Set<Item> = []
        return items.filter { seen.insert($0).inserted }
    }

    private static func unique(_ items: [ChatStripItem]) -> [ChatStripItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Stored previews

    /// A stored preview with the address it was made from: one the text
    /// links to, where it is one, and what a click on it opens.
    private struct Paired {
        let preview: CompanionLinkPreview
        let written: URL?
        let opens: URL
    }

    /// Each stored preview with the address in the text it was made from.
    ///
    /// The engine stores a preview under the address it reached after
    /// redirects, not the one written, so the two are paired by the engine's
    /// own rule: with as many previews as the addresses it read, the first
    /// preview is the first address's and the second the second's; with
    /// fewer, because a page failed, a preview is an address's only when the
    /// two are the same destination. The address the engine read is then
    /// found among the ones the text links to, which end where the sentence
    /// does rather than where the engine's rule stops. A click opens the
    /// address as the text wrote it, or the preview's own where it has none;
    /// a preview with neither, an address that is no URL, is left out.
    private static func paired(_ previews: [CompanionLinkPreview], in text: String, with addresses: [URL]) -> [Paired] {
        let read = engineAddresses(in: text)
        let byOrder = previews.count == read.count

        return previews.enumerated().compactMap { index, preview in
            let own = URL(string: preview.url)
            let partner = byOrder ? read[index] : read.first { address in
                guard let own, let address = URL(string: address) else { return false }

                return ChatDestination(own) == ChatDestination(address)
            }
            let written = partner.flatMap { partner in addresses.first { isReading(partner, of: $0) } }
            guard let opens = written ?? partner.flatMap(asWritten) ?? own else { return nil }

            return Paired(preview: preview, written: written, opens: opens)
        }
    }

    /// Whether the engine's reading of an address is an address the text
    /// links to: the same destination once the closing marks either rule
    /// leaves at the end are set aside (`Foo_(bar` read, `Foo_(bar)` linked).
    private static func isReading(_ read: String, of written: URL) -> Bool {
        guard let read = bare(read) else { return false }

        return read == bare(written.absoluteString)
    }

    /// An address's destination with the closing marks either rule may leave
    /// at its end set aside.
    private static func bare(_ address: String) -> ChatDestination? {
        var trimmed = Substring(address)
        while let last = trimmed.last, readingMarks.contains(last) {
            trimmed = trimmed.dropLast()
        }

        return URL(string: String(trimmed)).map(ChatDestination.init)
    }

    /// An address as the engine read it, less what closes the sentence.
    private static func asWritten(_ read: String) -> URL? {
        URL(string: String(ReplyLinks.trimmed(Substring(read))))
    }

    /// Every mark either rule may leave at an address's end.
    private static let readingMarks: Set<Character> = engineClosing.union([":", "'", "\"", "\u{201D}", "\u{2019}", "`", ">"])

    /// The addresses the engine reads a preview from (`unfurl.ex`): the first
    /// two different `http` or `https` addresses in the raw text, code and
    /// markdown included, each less a run of `),.;!?]}` at its end.
    static func engineAddresses(in text: String) -> [String] {
        var seen: Set<String> = []
        let addresses = text.matches(of: #/https?://[^\s<>"']+/#.ignoresCase()).map { match in
            var address = Substring(match.output)
            while let last = address.last, engineClosing.contains(last) {
                address = address.dropLast()
            }
            return String(address)
        }

        return Array(addresses.filter { seen.insert($0).inserted }.prefix(engineLinkLimit))
    }

    /// The engine's `@max_links` and `@trailing_punctuation`.
    private static let engineLinkLimit = 2
    private static let engineClosing: Set<Character> = [")", ",", ".", ";", "!", "?", "]", "}"]
}

/// One tile of a strip.
enum ChatStripItem: Equatable, Identifiable {
    /// A file the row refers to by ref. Its bytes are in the engine's media
    /// store, which no request returns yet, so its tile is Not available.
    case media(CompanionMediaRef)
    /// A file a path in the text names, at the address the path makes.
    case file(URL)
    case link(ChatStripLink)

    /// The item's destination, which no other item of the strip shares.
    var id: String {
        switch self {
        case .media(let ref): return "ref:" + ref.ref
        case .file(let file): return file.standardizedFileURL.absoluteString
        case .link(let link): return ChatDestination(link.address).key
        }
    }
}

/// A web address as a tile: what a click opens, and the preview the engine
/// stored for it, where it stored one.
struct ChatStripLink: Equatable {
    let address: URL
    let preview: CompanionLinkPreview?
}

/// An address as the strip compares two: the same destination only when they
/// are equal once the scheme and host are lowercased, the path, query and
/// fragment compared as written. `/report` and `/report/`, two fragments and
/// two queries stay two, since a site may serve each its own page.
struct ChatDestination: Hashable {
    let key: String

    init(_ address: URL) {
        guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else {
            key = address.absoluteString
            return
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        key = parts.string ?? address.absoluteString
    }
}

/// The Fermix home as the strip reads it, from text alone: where the
/// bootstrap record says it is and where that really lands, so a path written
/// either way is inside it.
struct ChatHome: Equatable, Sendable {
    let roots: [String]

    init(roots: [String]) {
        self.roots = roots
    }

    /// The home's two spellings, read once when the chat first needs it.
    init(_ home: URL) {
        let written = home.standardizedFileURL.path
        let real = FilePlace.resolved(home.path) ?? written
        roots = written == real ? [written] : [written, real]
    }

    /// Whether a path lies under the home, by its text.
    func contains(_ file: URL) -> Bool {
        let path = file.standardizedFileURL.path
        return roots.contains { path.hasPrefix($0 + "/") }
    }
}

/// How many tiles a strip shows at a width, and how wide (M66 §3.2): 3:2
/// tiles, `stripGap` apart, between 120 and 200 points wide, as many as fit
/// up to three. With more items than it shows, **+N** follows the last tile,
/// and the room it takes is counted before the tiles are.
struct ChatStripFit: Equatable {
    let tileWidth: Double
    /// The tiles the folded strip shows, and how many a row holds once it
    /// is open.
    let shown: Int
    /// The items it does not show while folded, the N of **+N**.
    let more: Int

    var tileSize: CGSize {
        CGSize(width: tileWidth, height: tileWidth / ChatMetrics.stripTileAspect)
    }

    /// The fit of `count` items in `width`. A column too narrow for one tile
    /// and **+N** still shows one, at the narrowest width.
    static func of(count: Int, width: Double) -> ChatStripFit {
        for shown in stride(from: min(ChatMetrics.stripMostTiles, count), through: 1, by: -1) {
            let more = count - shown
            let gaps = Double(shown - 1) * ChatMetrics.stripGap
            let control = more > 0 ? ChatMetrics.stripGap + ChatMetrics.stripMoreWidth : 0
            let tile = min(ChatMetrics.stripTileWidths.upperBound, (width - gaps - control) / Double(shown))
            if tile >= ChatMetrics.stripTileWidths.lowerBound {
                return ChatStripFit(tileWidth: tile, shown: shown, more: more)
            }
        }

        return ChatStripFit(tileWidth: ChatMetrics.stripTileWidths.lowerBound, shown: min(count, 1), more: max(count - 1, 0))
    }
}
