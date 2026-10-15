import CoreGraphics
import Foundation

/// What a finished row shows under its text (M66 §3.1): its tiles, each
/// destination once, the two things a row draws that are not tiles, its voice
/// note and the sound files Fermix made, which play where they are (§3.4),
/// and its text less the lines that only name what the row already shows.
///
/// It is worked out from the row's content alone and never looks at the disk:
/// whether a file is there, and what it looks like, is each tile's to find out
/// once it is on screen. The items are found in this order:
///
/// 1. The row's media refs, in their order.
/// 2. The stored link previews whose address is not one the text links to.
/// 3. The paths the text links to that are worth seeing: anything inside the
///    Fermix home, and a picture, video, sound, PDF or document anywhere. A
///    path that is only talked about (`/etc/hosts`) stays a link in the text.
/// 4. The web addresses the text links to, each with its stored preview where
///    it has one.
///
/// They are drawn in two kinds, each keeping that order: first the previews,
/// the paths inside the Fermix home to a picture, a video, a PDF or a
/// document, which draw what the file holds; then every other item as a
/// compact card. An item's kind is read from its path, so a tile keeps its
/// shape whatever its file turns out to be.
///
/// Its words are read once, as the row draws them (`ReplyText`): Fermix's as
/// markdown, a person's as the plain text they typed.
struct ChatStrip: Equatable {
    /// The `kind` the engine gives a phone's recorded voice.
    static let voiceKind = CompanionProtocol.audioKind

    /// The row's voice note, its first `audio` ref, drawn as its chip with
    /// the row's text as its transcript.
    let voiceNote: CompanionMediaRef?
    /// The files whose tiles draw what they hold.
    let previews: [URL]
    /// Every other item, as a compact card.
    let cards: [ChatStripItem]
    /// The sound files inside the Fermix home the text names, in reading
    /// order: each plays in the row rather than showing as a tile.
    let sounds: [URL]
    /// The row's text as it is drawn: less every line that only names a file
    /// or an address the row shows, which the tile says better
    /// (`withoutShownLines`). Empty where nothing else was written, and the
    /// row then draws its strip alone.
    let text: String
    /// That text as Fermix's row draws it, read once with its links; nil for
    /// a person's row, whose words are drawn as typed.
    let reply: ReplyText?

    /// Every item, previews first: the order they are drawn and counted in.
    var items: [ChatStripItem] {
        previews.map(ChatStripItem.file) + cards
    }

    /// The strip of a row's content. `plain` reads the words as a person's,
    /// `userHome` is what `~` reads as, and `home` the Fermix home, nil where
    /// it could not be read, which leaves nothing inside it.
    init(
        text: String,
        plain: Bool,
        mediaRefs: [CompanionMediaRef],
        linkPreviews: [CompanionLinkPreview],
        userHome: String,
        home: ChatHome?
    ) {
        let read = Self.read(text, plain: plain, userHome: userHome)
        let paths = read.files
        let addresses = read.addresses
        let previews = Self.paired(linkPreviews, in: text, with: addresses)

        voiceNote = mediaRefs.first { $0.kind == Self.voiceKind }
        sounds = Self.unique(paths.filter { Self.isSound($0, home: home) })

        let refs = mediaRefs.filter { $0.kind != Self.voiceKind }.map(ChatStripItem.media)
        let loose = previews.filter { $0.written == nil }.map { ChatStripItem.link(ChatStripLink(address: $0.opens, preview: $0.preview)) }
        let files = paths.filter { Self.isTile($0, home: home) }.map(ChatStripItem.file)
        let links = addresses.map { address in
            ChatStripItem.link(ChatStripLink(address: address, preview: previews.first { $0.written == address }?.preview))
        }
        let items = Self.unique(refs + loose + files + links)
        self.previews = items.compactMap { Self.preview($0, home: home) }
        cards = items.filter { Self.preview($0, home: home) == nil }

        let shown = Set(items.map(\.id) + sounds.map { ChatStripItem.file($0).id })
        let kept = Self.withoutShownLines(text, shown: shown, userHome: userHome)
        self.text = kept
        reply = plain ? nil : (kept == text ? read : Self.read(kept, plain: false, userHome: userHome))
    }

    private static func read(_ text: String, plain: Bool, userHome: String) -> ReplyText {
        plain ? ReplyText(plain: text, home: userHome) : ReplyText(markdown: text, home: userHome)
    }

    /// The file an item draws a preview of: a path inside the Fermix home
    /// whose type is drawn by its content. A ref has no bytes in the app's
    /// hands yet, and a link is drawn from its address.
    private static func preview(_ item: ChatStripItem, home: ChatHome?) -> URL? {
        guard case .file(let file) = item, home?.contains(file) == true,
              ChatPreviewPolicy.type(ofPath: file.path).map(ChatPreviewPolicy.showsContent) == true
        else { return nil }

        return file
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

    // MARK: - The text

    /// The text less every line that names, and only names, something the
    /// row shows under it: a line whose whole content, once its indent, a
    /// list marker (`-`, `*`, `+`, `•`, `1.`) and a code span round it are set
    /// aside, is one path or address with a tile or a player. A bare path or
    /// address, one in code, and a markdown link whose words are its own
    /// destination or that file's bare name all count; a link inside a
    /// sentence, and a markdown link with words of its own, stay. Nothing in a
    /// fenced block is touched. Where a line goes, a blank line on either side
    /// of it closes up, and the text loses any blank lines at its ends. A text
    /// that loses no line is returned as it was.
    static func withoutShownLines(_ text: String, shown: Set<String>, userHome: String) -> String {
        var kept: [Substring] = []
        var fenced = false
        var dropped = false
        var droppedSinceKept = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                fenced.toggle()
            } else if !fenced, let named = destination(ofLine: line, userHome: userHome), shown.contains(named) {
                dropped = true
                droppedSinceKept = true
                continue
            }
            if droppedSinceKept, isBlank(line), kept.last.map(isBlank) == true { continue }

            kept.append(line)
            droppedSinceKept = false
        }
        guard dropped else { return text }

        while kept.first.map(isBlank) == true { kept.removeFirst() }
        while kept.last.map(isBlank) == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// The one destination a line names, as its item's id, or nil for a line
    /// that says anything more.
    private static func destination(ofLine line: Substring, userHome: String) -> String? {
        let body = withoutListMarker(Substring(line.trimmingCharacters(in: .whitespaces)))
        var closed = body
        while let last = closed.last, ReplyMarks.punctuation.contains(last) {
            closed = closed.dropLast()
        }
        if closed.count > 2, closed.first == "`", closed.last == "`" {
            return destination(wholly: closed.dropFirst().dropLast(), userHome: userHome)
        }
        if let link = closed.wholeMatch(of: #/\[(.+)\]\((.+)\)/#) {
            return destination(ofLink: link.output.1, to: link.output.2, userHome: userHome)
        }

        return bareDestination(body, userHome: userHome)
    }

    /// A markdown link's destination, where its words are that destination
    /// or the bare name of the file it is.
    private static func destination(ofLink words: Substring, to target: Substring, userHome: String) -> String? {
        let words = words.filter { $0 != "`" }
        let target = target.hasPrefix("<") && target.hasSuffix(">") ? target.dropFirst().dropLast() : target
        guard words == target || words == (target as NSString).lastPathComponent else { return nil }

        return destination(wholly: target, userHome: userHome)
    }

    /// Text that is one path or one address from end to end.
    private static func destination(wholly text: Substring, userHome: String) -> String? {
        guard !text.contains("`") else { return nil }
        if let file = ReplyPaths.file(wholly: text, home: userHome) { return ChatStripItem.file(file).id }

        return ReplyLinks.address(wholly: text).map { ChatStripItem.link(ChatStripLink(address: $0, preview: nil)).id }
    }

    /// Plain text that is one bare path or one address, with nothing round it
    /// but the marks that open or close a sentence.
    private static func bareDestination(_ text: Substring, userHome: String) -> String? {
        let string = String(text)
        let paths = ReplyPaths.barePaths(in: string)
        if paths.count == 1, let path = paths.first, onlyMarks(string, besides: path) {
            return ChatStripItem.file(ReplyPaths.fileURL(String(ReplyPaths.withoutLineReference(string[path])), home: userHome)).id
        }
        let addresses = ReplyLinks.addresses(inText: string)
        guard addresses.count == 1, let address = addresses.first, onlyMarks(string, besides: address.range) else { return nil }

        return ChatStripItem.link(ChatStripLink(address: address.url, preview: nil)).id
    }

    private static func onlyMarks(_ text: String, besides range: Range<String.Index>) -> Bool {
        (text[..<range.lowerBound] + text[range.upperBound...]).allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    /// A list item's text, its marker gone: `-`, `*`, `+` or `•`, or a number
    /// and a full stop or bracket, then a space.
    private static func withoutListMarker(_ line: Substring) -> Substring {
        guard let marker = line.prefixMatch(of: #/(?:[-*+•]|[0-9]+[.)])\s+/#) else { return line }

        return line[marker.range.upperBound...]
    }

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy(\.isWhitespace)
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
        while let last = trimmed.last, ReplyMarks.closing.contains(last) {
            trimmed = trimmed.dropLast()
        }

        return URL(string: String(trimmed)).map(ChatDestination.init)
    }

    /// An address as the engine read it, less what closes the sentence.
    private static func asWritten(_ read: String) -> URL? {
        URL(string: String(ReplyLinks.trimmed(Substring(read))))
    }

    /// The addresses the engine reads a preview from (`unfurl.ex`): the first
    /// two different `http` or `https` addresses in the raw text, code and
    /// markdown included, each less a run of `),.;!?]}` at its end.
    static func engineAddresses(in text: String) -> [String] {
        var seen: Set<String> = []
        let addresses = text.matches(of: #/https?://[^\s<>"']+/#.ignoresCase()).map { match in
            var address = Substring(match.output)
            while let last = address.last, ReplyMarks.engineClosing.contains(last) {
                address = address.dropLast()
            }
            return String(address)
        }

        return Array(addresses.filter { seen.insert($0).inserted }.prefix(engineLinkLimit))
    }

    /// The engine's `@max_links`.
    private static let engineLinkLimit = 2
}

/// One tile of a strip. Two items are one when they name one destination
/// (M66 §3.1), so an item is equal to, and hashes as, its id.
enum ChatStripItem: Hashable, Identifiable {
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

    static func == (lhs: ChatStripItem, rhs: ChatStripItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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

/// The Fermix home as the strip reads it, by its spellings
/// (`FilePlace.spellings(of:)`): where the bootstrap record says it is and
/// where that really lands, so a path written either way is inside it.
struct ChatHome: Equatable, Sendable {
    let roots: [String]

    init(roots: [String]) {
        self.roots = roots
    }

    init(_ home: URL) {
        roots = FilePlace.spellings(of: home)
    }

    /// Whether a path lies under the home by its text: the check made before
    /// the disk is asked, which chooses a tile's kind. Whether the file is
    /// really inside, a link in the home pointing out of it among what this
    /// cannot see, is the disk's word (`ChatFileFacts.insideHome`), and only
    /// that word lets a tile draw what the file holds.
    func contains(_ file: URL) -> Bool {
        let path = file.standardizedFileURL.path
        return roots.contains { path.hasPrefix($0 + "/") }
    }
}

/// How wide a strip's tiles and cards are (M66 §3.2): 3:2 preview tiles and
/// cards of the same width, `stripGap` apart, between 120 and 200 points
/// wide, and as wide as lets up to three of a row show whole in the column.
/// A row with more than that scrolls sideways (`ChatStripView`).
enum ChatStripFit {
    /// The width for a row of `count` items in `width`. A column too narrow
    /// for one whole item still shows one, at the narrowest width.
    static func itemWidth(count: Int, width: Double) -> Double {
        for shown in stride(from: min(ChatMetrics.stripMostTiles, count), through: 1, by: -1) {
            let gaps = Double(shown - 1) * ChatMetrics.stripGap
            let item = min(ChatMetrics.stripTileWidths.upperBound, (width - gaps) / Double(shown))
            if item >= ChatMetrics.stripTileWidths.lowerBound { return item }
        }

        return ChatMetrics.stripTileWidths.lowerBound
    }

    /// A preview tile at that width, 3:2.
    static func tileSize(width: Double) -> CGSize {
        CGSize(width: width, height: width / ChatMetrics.stripTileAspect)
    }

    /// How wide a row of `count` items at `itemWidth` is, gaps included.
    static func rowWidth(count: Int, itemWidth: Double) -> Double {
        Double(count) * itemWidth + Double(max(count - 1, 0)) * ChatMetrics.stripGap
    }
}
