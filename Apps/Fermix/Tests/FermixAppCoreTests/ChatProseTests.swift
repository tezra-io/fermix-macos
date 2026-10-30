import AppKit
import CryptoKit
import Foundation
import Testing

@testable import FermixAppCore

/// A reply's words as the system's text view draws them (`ChatProseText`):
/// paragraphs a gap apart, every link inline with where it goes named where
/// the pointer rests on it, and a link that may not go where it seems to
/// marked and carrying why.
@MainActor
@Suite("Chat prose")
struct ChatProseTests {
    private static let style = ChatProseStyle(size: 15)

    private static func drawn(_ markdown: String, marked: [String] = [], titles: ChatLinkTitles = .none) -> NSAttributedString {
        let paragraphs = ReplyText(markdown: markdown, home: "/Users/me").blocks.compactMap(\.prose)
        return ChatProseText.attributed(paragraphs, marked: marked, titles: titles, style: style)
    }

    private static func range(of words: String, in text: NSAttributedString) throws -> NSRange {
        let found = (text.string as NSString).range(of: words)
        try #require(found.location != NSNotFound)
        return found
    }

    private static func preview(link: String?, url: String, title: String) -> CompanionLinkPreview {
        CompanionLinkPreview(link: link, url: url, site: "Site", title: title, description: nil, imageRef: nil)
    }

    // MARK: - Paragraphs

    @Test("a run of paragraphs is one text, a line apart, each later one a gap below the one before")
    func paragraphs() throws {
        let text = Self.drawn("One.\n\nTwo.\n\nThree.")
        let first = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let second = try #require(text.attribute(.paragraphStyle, at: try Self.range(of: "Two.", in: text).location, effectiveRange: nil) as? NSParagraphStyle)

        #expect(text.string == "One.\nTwo.\nThree.")
        #expect(first.paragraphSpacingBefore == 0)
        #expect(Double(second.paragraphSpacingBefore) == ChatMetrics.paragraphGap)
        #expect(Double(first.minimumLineHeight) == ChatMetrics.readingType.leading)
        #expect(Double(first.maximumLineHeight) == ChatMetrics.readingType.leading)
    }

    /// The reader's text size grows the line height and the gap with the
    /// words.
    @Test("the style grows its lines and gap with the reader's text size")
    func scaledStyle() {
        let larger = ChatProseStyle(size: 30)

        #expect(larger.lineHeight == 2 * (ChatMetrics.readingType.leading ?? 0))
        #expect(larger.paragraphGap == 2 * ChatMetrics.paragraphGap)
    }

    @Test("strong words are semibold, emphasised ones italic, and inline code monospaced on its fill")
    func inlineWords() throws {
        let text = Self.drawn("A **strong** and *soft* `code` word.")
        let strong = try #require(text.attribute(.font, at: try Self.range(of: "strong", in: text).location, effectiveRange: nil) as? NSFont)
        let soft = try #require(text.attribute(.font, at: try Self.range(of: "soft", in: text).location, effectiveRange: nil) as? NSFont)
        let codeAt = try Self.range(of: "code", in: text).location
        let code = try #require(text.attribute(.font, at: codeAt, effectiveRange: nil) as? NSFont)
        let plain = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        #expect(plain.familyName == ReadingFace.family)
        #expect(strong.familyName == ReadingFace.family)
        #expect(Self.weight(of: strong) > Self.weight(of: plain))
        #expect(soft.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(code.isFixedPitch)
        #expect(text.attribute(.backgroundColor, at: codeAt, effectiveRange: nil) != nil)
    }

    private static func weight(of font: NSFont) -> Double {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
    }

    // MARK: - Links

    /// A markdown link and an address written out are drawn alike: the
    /// words' own ink with an underline, naming where they go.
    @Test("every link is inline and underlined, and names where it goes where the pointer rests on it")
    func links() throws {
        let text = Self.drawn("Read [the guide](https://guide.example/soho) or https://a.example/x today.")
        let guide = try Self.range(of: "the guide", in: text)
        let address = try Self.range(of: "https://a.example/x", in: text)

        #expect(text.attribute(.link, at: guide.location, effectiveRange: nil) as? URL == URL(string: "https://guide.example/soho"))
        #expect(text.attribute(.link, at: address.location, effectiveRange: nil) as? URL == URL(string: "https://a.example/x"))
        #expect(text.attribute(.underlineStyle, at: guide.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(text.attribute(.underlineStyle, at: address.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(text.attribute(.toolTip, at: guide.location, effectiveRange: nil) as? String == "https://guide.example/soho")
        #expect(text.attribute(.chatLinkCaution, at: guide.location, effectiveRange: nil) == nil)
    }

    @Test("a link's page title heads where it goes, a file is named by its path")
    func tips() throws {
        let titles = ChatLinkTitles([Self.preview(link: "https://guide.example/soho", url: "https://www.guide.example/soho", title: "SoHo guide")])
        let text = Self.drawn("Read [the guide](https://guide.example/soho).", titles: titles)
        let guide = try Self.range(of: "the guide", in: text)

        #expect(text.attribute(.toolTip, at: guide.location, effectiveRange: nil) as? String == "SoHo guide\nhttps://guide.example/soho")
        #expect(ChatProseText.tip(URL(fileURLWithPath: "/Users/me/My notes.md"), title: nil, caution: nil) == "/Users/me/My notes.md")
    }

    /// The link's words name another site: why heads its tip, a mark
    /// follows its words on the same line, and a click on either carries why.
    @Test("a link that may not go where it seems to carries why, says it, and is marked after its words")
    func caution() throws {
        let text = Self.drawn("Pay at [seedswap.example/order](https://seedswap-orders.example/checkout) today.")
        let words = try Self.range(of: "seedswap.example/order", in: text)
        let caution = try #require(text.attribute(.chatLinkCaution, at: words.location, effectiveRange: nil) as? LinkCaution)
        let markAt = words.location + words.length
        let tip = try #require(text.attribute(.toolTip, at: words.location, effectiveRange: nil) as? String)

        #expect(LinkSafety.caution(words: "seedswap.example/order", url: URL(string: "https://seedswap-orders.example/checkout")!) == caution)
        #expect((text.string as NSString).substring(with: NSRange(location: markAt, length: 2)) == "\u{202F}\u{FFFC}")
        #expect(text.attribute(.attachment, at: markAt + 1, effectiveRange: nil) is NSTextAttachment)
        #expect(text.attribute(.chatLinkCaution, at: markAt + 1, effectiveRange: nil) as? LinkCaution == caution)
        #expect(text.attribute(.link, at: markAt + 1, effectiveRange: nil) as? URL == URL(string: "https://seedswap-orders.example/checkout"))
        #expect(tip == ChatLinkCautionWords.sentence(caution) + "\nhttps://seedswap-orders.example/checkout")
        #expect(text.string.hasSuffix(" today."))
    }

    @Test("a search's matches are marked semibold wherever they are, case ignored")
    func marks() throws {
        let text = Self.drawn("Seeds first, then more seeds.", marked: ["seeds"])
        let regular = try #require(text.attribute(.font, at: try Self.range(of: "first", in: text).location, effectiveRange: nil) as? NSFont)

        for at in [0, try Self.range(of: "seeds.", in: text).location] {
            let font = try #require(text.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
            #expect(Self.weight(of: font) > Self.weight(of: regular))
        }
    }

    // MARK: - Titles

    @Test("a title pairs with the link the engine read it for, or its address where it kept none")
    func titles() {
        let titles = ChatLinkTitles([
            Self.preview(link: "https://t.example/abc", url: "https://www.example.com/article", title: "Article"),
            Self.preview(link: nil, url: "https://b.example/y", title: "Bee"),
            Self.preview(link: "https://c.example/z", url: "https://c.example/z", title: ""),
        ])

        #expect(titles.title(of: URL(string: "https://t.example/abc")!) == "Article")
        #expect(titles.title(of: URL(string: "HTTPS://B.EXAMPLE/y")!) == "Bee")
        #expect(titles.title(of: URL(string: "https://c.example/z")!) == nil)
        #expect(ChatLinkTitles.none.title(of: URL(string: "https://t.example/abc")!) == nil)
    }

    // MARK: - The check

    private static func check() -> (ChatLinkGuard, RecordingWorkspaceOpener) {
        let harness = BrowserHarness()
        let workspace = RecordingWorkspaceOpener()
        let preference = InMemoryLinkPreferenceStore()
        preference.linkDestination = .system
        let opener = ContentLinkOpener(preference: preference, browser: harness.coordinator, workspace: workspace, maps: FakeMediaReader())
        return (ChatLinkGuard(links: opener), workspace)
    }

    @Test("a link with no caution opens at once, and one with a caution waits for the person")
    func guardHolds() {
        let (check, workspace) = Self.check()
        let safe = URL(string: "https://a.example/x")!
        let held = URL(string: "https://seedswap-orders.example/checkout")!
        let caution = LinkCaution.elsewhere(shown: "seedswap.example", opens: "seedswap-orders.example")

        check.open(safe, caution: nil)
        #expect(workspace.opened == [safe])
        #expect(check.held == nil)

        check.open(held, caution: caution)
        #expect(workspace.opened == [safe])
        #expect(check.held == ChatHeldLink(url: held, caution: caution))

        check.dismiss()
        #expect(check.held == nil)
        #expect(workspace.opened == [safe])

        check.open(held, caution: caution)
        check.openHeld()
        #expect(check.held == nil)
        #expect(workspace.opened == [safe, held])
    }

    /// A link known only by where it goes, in a table or a person's own
    /// message, is checked by that alone.
    @Test("a link known only by its address is checked by its address")
    func guardByAddress() throws {
        let (check, workspace) = Self.check()
        let hidden = try #require(URL(string: "https://apple.com@evil.example/"))

        check.open(hidden)
        #expect(check.held?.caution == LinkSafety.caution(url: hidden))
        #expect(check.held != nil)
        #expect(workspace.opened.isEmpty)
    }

    @Test("each caution is said in a sentence naming where the link really goes")
    func sentences() {
        let cautions: [LinkCaution] = [
            .elsewhere(shown: "apple.com", opens: "evil.example"),
            .lookalike(opens: "xn--pple-43d.com"),
            .hiddenName(opens: "evil.example"),
        ]

        for caution in cautions {
            let sentence = ChatLinkCautionWords.sentence(caution)
            #expect(ProductCopyRules.violations(in: sentence).isEmpty)
            #expect(sentence.contains(caution == cautions[1] ? "xn--pple-43d.com" : "evil.example"))
        }
        #expect(ChatLinkCautionWords.sentence(cautions[0]).contains("apple.com"))
    }

    // MARK: - Actions and time

    @Test("a reply with words carries its actions; a person's message and an empty row do not")
    func actions() {
        func row(_ text: String, role: String?) -> CompanionRow {
            CompanionRow(serverSeq: 1, text: text, role: role, timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil)
        }

        #expect(ChatMessageActions.carried(by: row("Saved.", role: CompanionProtocol.assistantRole)))
        #expect(ChatMessageActions.carried(by: row("Saved.", role: nil)))
        #expect(!ChatMessageActions.carried(by: row("Hi", role: CompanionProtocol.userRole)))
        #expect(!ChatMessageActions.carried(by: row("", role: CompanionProtocol.assistantRole)))
    }

    /// The actions under a reply stand in the seam to the next turn, so the
    /// seam gives up their room rather than adding to it.
    @Test("the seam after a reply with actions gives their room up, and no seam is ever negative")
    func turnPadding() {
        let reply = ChatItem.row(CompanionRow(serverSeq: 1, text: "Saved.", role: CompanionProtocol.assistantRole, timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil))
        let message = ChatItem.row(CompanionRow(serverSeq: 2, text: "Thanks", role: CompanionProtocol.userRole, timestamp: nil, clientMsgId: nil, inReplyTo: nil, turnId: nil))
        let error = ChatItem.error("No connection.")

        #expect(ChatTimeline.turnPadding(after: nil, before: message) == 0)
        #expect(ChatTimeline.turnPadding(after: message, before: reply) == 0)
        #expect(ChatTimeline.turnPadding(after: error, before: message) == ChatMetrics.turnGap - ChatMetrics.rowGap)
        #expect(ChatTimeline.turnPadding(after: reply, before: message) == max(0, ChatMetrics.turnGap - ChatMetrics.rowGap - ChatMetrics.actionsHeight))
    }

    @Test("a message's time is its time alone today, its day and time this year, and its whole date before")
    func said() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try Date("2026-10-30T15:00:00Z", strategy: .iso8601)
        let today = try Date("2026-10-30T09:05:00Z", strategy: .iso8601)
        let thisYear = try Date("2026-09-25T05:14:00Z", strategy: .iso8601)

        #expect(ChatTime.said("2026-10-30T09:05:00Z", now: now, calendar: calendar) == today.formatted(date: .omitted, time: .shortened))
        #expect(ChatTime.said("2026-09-25T05:14:00Z", now: now, calendar: calendar) == thisYear.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        #expect(ChatTime.said("2025-09-25T05:14:00Z", now: now, calendar: calendar) == ChatTime.written("2025-09-25T05:14:00Z"))
        #expect(ChatTime.said("yesterday", now: now, calendar: calendar) == "yesterday")
    }
}

/// The chat's reading face: shipped with its licence and its record, each
/// file byte for byte as the record says, and registered for this process.
@Suite("Reading face")
struct ReadingFaceTests {
    @Test("the face's files ship with their licence, each as its record says")
    func provenance() throws {
        let folder = try #require(AppResources.bundle.url(forResource: ReadingFace.folder, withExtension: nil))
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("PROVENANCE.json"))) as? [String: Any]
        let fonts = try #require(record?["fonts"] as? [[String: Any]])
        let files = try #require(fonts.first?["files"] as? [[String: String]])
        let named = Set(files.compactMap { $0["file"] })

        #expect(fonts.first?["family"] as? String == ReadingFace.family)
        #expect(named == Set(ReadingFace.files + ["OFL.txt"]))
        for file in files {
            let name = try #require(file["file"])
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == file["sha256"], "\(name) is not the file its record names")
        }
    }

    @Test("the face is registered for this process, upright and italic, in its weights")
    func registered() {
        let regular = ReadingFace.nsFont(size: 15, weight: .regular)
        let italic = ReadingFace.nsFont(size: 15, weight: .regular, italic: true)
        let semibold = ReadingFace.nsFont(size: 15, weight: .semibold)

        #expect(NSFontManager.shared.availableFontFamilies.contains(ReadingFace.family))
        #expect(regular.familyName == ReadingFace.family)
        #expect(italic.familyName == ReadingFace.family)
        #expect(italic.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(semibold.familyName == ReadingFace.family)
        #expect(semibold.fontName != regular.fontName)
    }

    /// The chat sets its words in the face and its code in the system's
    /// monospaced one; every other surface keeps the system's.
    @Test("a rung's face is the surface's, and a monospaced rung keeps the system's")
    func faces() {
        let body = Typography.style(.body)
        let mono = Typography.style(.mono)

        #expect(body.font(at: 15) == .system(size: 15, weight: .regular))
        #expect(body.font(at: 15, face: .reading) == ReadingFace.font(size: 15, weight: .regular))
        #expect(mono.font(at: 13, face: .reading) == .system(size: 13, weight: .regular, design: .monospaced))
    }
}
