import AppKit
import SwiftUI

extension ChatMetrics {
    /// A reply's words and a person's: the system's face at the body's size,
    /// with room between lines for reading at length.
    static let readingType = TypeStyle(size: 16, leading: 26, weight: .regular, relativeTo: .body)
    /// Above a paragraph, a list, a quote, a table or a code block that
    /// follows another block: less than a blank line, so a reply reads as one
    /// piece of writing.
    static let paragraphGap: Double = 12
    /// Above a heading that follows another block, and under a heading
    /// before the block it heads, so a heading sits with what it heads.
    static let headingGap: Double = 22
    static let underHeadingGap: Double = 6
    /// Inline code, a step under the words round it, as a code block is.
    static let codeSpanScale: Double = 0.88
    /// The mark after a link that may not go where it seems to, as a share
    /// of the words' size.
    static let cautionMarkScale: Double = 0.8
}

/// The titles the engine read for a row's links (M72): each link the row's
/// text writes, by where it goes (`ChatDestination`), to the title of the
/// page its stored preview was made from. A link with no preview has none.
struct ChatLinkTitles: Equatable {
    static let none = ChatLinkTitles([])

    private let titles: [String: String]

    init(_ previews: [CompanionLinkPreview]) {
        var titles: [String: String] = [:]
        for preview in previews where !preview.title.isEmpty {
            guard let link = URL(string: preview.link ?? preview.url) else { continue }

            titles[ChatDestination(link).key] = preview.title
        }
        self.titles = titles
    }

    func title(of url: URL) -> String? {
        titles[ChatDestination(url).key]
    }
}

extension NSAttributedString.Key {
    /// Marks a link that may not go where it seems to, with why, on the
    /// words a reply's text view draws (`ChatProseText`).
    static let chatLinkCaution = NSAttributedString.Key("fermix.chatLinkCaution")
    /// Marks inline code, whose fill the reply's text view draws round
    /// (`ChatReplyLayoutManager`).
    static let chatCodeSpan = NSAttributedString.Key("fermix.chatCodeSpan")
    /// What a stretch of a reply's text is copied as where it is not its own
    /// characters: a table cell's end is a tab, a task's box its markdown,
    /// and a caution mark nothing (`ChatReplyTextView`).
    static let chatPlain = NSAttributedString.Key("fermix.chatPlain")
}

/// What a reply's words are set in: the system's face at the size the
/// reader's text size makes the reading rung, its lines a fixed height
/// apart so a line with an emoji or another script in it is no taller, and
/// every other measure grown with it.
struct ChatProseStyle: Equatable {
    let size: Double
    /// How much the reader's text size grew the reading rung.
    let ratio: Double
    let lineHeight: Double

    /// The reading rung at `size`, the reader's text size applied to it.
    init(size: Double) {
        ratio = size / ChatMetrics.readingType.size
        self.size = size
        lineHeight = (ChatMetrics.readingType.leading ?? size) * ratio
    }

    /// A measure of the redlines grown with the words.
    func scaled(_ value: Double) -> Double {
        value * ratio
    }

    /// The words' face for what inline markdown made of them.
    @MainActor
    func font(_ intent: InlinePresentationIntent?) -> NSFont {
        if intent?.contains(.code) == true { return codeSpanFont }

        let strong = intent?.contains(.stronglyEmphasized) == true
        return Self.face(size: size, weight: strong ? .semibold : .regular, italic: intent?.contains(.emphasized) == true)
    }

    /// A heading's size: a level 1 or 2 heading a step over the words, a
    /// level 3 heading half a step, and any deeper one the words' own size,
    /// all semibold.
    func headingSize(level: Int) -> Double {
        switch level {
        case 1, 2: return size * 1.25
        case 3: return size * 1.125
        default: return size
        }
    }

    @MainActor
    func headingFont(level: Int, emphasized: Bool = false) -> NSFont {
        Self.face(size: headingSize(level: level), weight: .semibold, italic: emphasized)
    }

    func headingLineHeight(level: Int) -> Double {
        (headingSize(level: level) * 1.35).rounded()
    }

    @MainActor
    var codeSpanFont: NSFont {
        Self.mono(size: size * ChatMetrics.codeSpanScale, weight: .regular)
    }

    /// A code block's code: the code rung, grown with the words.
    @MainActor
    func codeFont(strong: Bool = false) -> NSFont {
        Self.mono(size: scaled(ChatMetrics.codeType.size), weight: strong ? .semibold : .regular)
    }

    var codeLineHeight: Double {
        scaled(ChatMetrics.codeType.leading ?? ChatMetrics.codeType.size)
    }

    /// A paragraph of the words, `before` points under what comes before it.
    func paragraph(before: Double = 0, lineHeight: Double? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight ?? self.lineHeight
        style.maximumLineHeight = lineHeight ?? self.lineHeight
        style.paragraphSpacingBefore = before
        return style
    }

    /// The faces a reply is set in, each made once for its size: finding a
    /// face is the slow part of setting a reply, and a turn being written
    /// sets its last block again for every piece.
    @MainActor private static var faces: [String: NSFont] = [:]

    @MainActor
    private static func face(size: Double, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let key = "\(size)-\(weight.rawValue)-\(italic)"
        if let known = faces[key] { return known }

        let upright = NSFont.systemFont(ofSize: size, weight: weight)
        let font = italic ? NSFontManager.shared.convert(upright, toHaveTrait: .italicFontMask) : upright
        faces[key] = font
        return font
    }

    @MainActor
    private static func mono(size: Double, weight: NSFont.Weight) -> NSFont {
        let key = "mono-\(size)-\(weight.rawValue)"
        if let known = faces[key] { return known }

        let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        faces[key] = font
        return font
    }
}

/// One stretch of a reply's words as the reply's text view draws them,
/// read from the words as they were parsed (`ReplyText`):
///
/// - The words in the reply's ink; strongly emphasised words semibold,
///   emphasised ones italic, inline code monospaced a step smaller on a
///   rounded faint fill, struck words struck through.
/// - Every link, a markdown link and an address or path written out alike,
///   in the words' own ink with a faint underline, as the person's own
///   messages draw one. Where the pointer rests on it, it names where it
///   goes, under the title of the page the engine read for it where it read
///   one.
/// - A link that may not go where it seems to (`LinkSafety`) carries why,
///   which a click is checked against (`ChatLinkGuard`), says why where the
///   pointer rests on it, and has a small caution mark after its words.
/// - A search's matches marked, as `ChatText.marking` marks them.
@MainActor
enum ChatProseText {
    /// The tones the words are drawn in, each made once: a dynamic colour
    /// resolves for the appearance when it is drawn.
    static let ink = Palette.ink.nsColor
    static let secondary = Palette.secondary.nsColor
    static let faint = Palette.faint.nsColor
    private static let codeFill = Palette.codeSpanFill.nsColor
    private static let warning = Palette.warning.nsColor
    private static let markTone = Palette.accentText.nsColor

    /// The words set in one piece in `base`, then each stretch drawn apart
    /// from the rest, a link's mark set in after its words last to first so
    /// every range read before stays where it was. `font` sets a stretch's
    /// face for what inline markdown made of it.
    static func words(
        _ words: AttributedString,
        titles: ChatLinkTitles,
        style: ChatProseStyle,
        font: (InlinePresentationIntent?) -> NSFont
    ) -> NSMutableAttributedString {
        let drawn = NSMutableAttributedString(string: String(words.characters), attributes: [.font: font(nil), .foregroundColor: ink])
        for run in words.runs {
            guard let intent = run.inlinePresentationIntent else { continue }

            drawn.addAttributes(attributes(of: intent, font: font(intent)), range: NSRange(run.range, in: words))
        }
        for link in links(in: words).reversed() {
            let range = NSRange(link.range, in: words)
            drawn.addAttributes(linkAttributes(link, titles: titles), range: range)
            if let caution = link.caution {
                drawn.insert(cautionMark(caution, url: link.url, style: style), at: range.upperBound)
            }
        }

        return drawn
    }

    private static func attributes(of intent: InlinePresentationIntent, font: NSFont) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if intent.contains(.code) {
            attributes[.backgroundColor] = codeFill
            attributes[.chatCodeSpan] = true
        }
        if intent.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        return attributes
    }

    /// A link in the words: where it goes, the words it takes, and its
    /// caution, read once from its words.
    private struct Link {
        let url: URL
        let range: Range<AttributedString.Index>
        let caution: LinkCaution?
    }

    private static func links(in words: AttributedString) -> [Link] {
        words.runs[\.link].compactMap { url, range in
            guard let url else { return nil }

            return Link(url: url, range: range, caution: LinkSafety.caution(words: String(words[range].characters), url: url))
        }
    }

    private static func linkAttributes(_ link: Link, titles: ChatLinkTitles) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .link: link.url,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: faint,
            .toolTip: tip(link.url, title: titles.title(of: link.url), caution: link.caution)
        ]
        if let caution = link.caution {
            attributes[.chatLinkCaution] = caution
        }

        return attributes
    }

    /// What a link says where the pointer rests on it: why it may not go
    /// where it seems to, or the title of its page, and under either the
    /// whole of where it goes.
    nonisolated static func tip(_ url: URL, title: String?, caution: LinkCaution?) -> String {
        let address = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        let heading = caution.map(ChatLinkCautionWords.sentence) ?? title
        return heading.map { $0 + "\n" + address } ?? address
    }

    /// The caution mark after a link's words, kept on their line by a narrow
    /// space that never breaks: a small triangle in the warning tone, which
    /// opens, says and is checked as the link is, and is copied as nothing.
    private static func cautionMark(_ caution: LinkCaution, url: URL, style: ChatProseStyle) -> NSAttributedString {
        let sentence = ChatLinkCautionWords.sentence(caution)
        let configuration = NSImage.SymbolConfiguration(pointSize: style.size * ChatMetrics.cautionMarkScale, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [warning]))
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: sentence)?
            .withSymbolConfiguration(configuration)
        let font = style.font(nil)
        let mark = NSMutableAttributedString(string: "\u{202F}", attributes: [.font: font])
        mark.append(attachment(image, centredOn: font))
        mark.addAttributes([
            .link: url,
            .chatLinkCaution: caution,
            .chatPlain: "",
            .toolTip: tip(url, title: nil, caution: caution)
        ], range: NSRange(location: 0, length: mark.length))
        return mark
    }

    /// An image in the words, centred on the height of a capital of `font`.
    static func attachment(_ image: NSImage?, centredOn font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        if let image {
            attachment.bounds = CGRect(
                x: 0,
                y: (font.capHeight - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            )
        }
        return NSAttributedString(attachment: attachment)
    }

    /// Every occurrence of each term, in the text blue and in `strong`'s
    /// weight, case ignored, as the search that found them ignored it.
    static func mark(_ terms: [String], in text: NSMutableAttributedString, strong: NSFont) {
        let string = text.string as NSString
        for term in terms where !term.isEmpty {
            var searched = NSRange(location: 0, length: string.length)
            while true {
                let found = string.range(of: term, options: .caseInsensitive, range: searched)
                guard found.location != NSNotFound else { break }

                text.addAttributes([.font: strong, .foregroundColor: markTone], range: found)
                let next = found.location + found.length
                searched = NSRange(location: next, length: string.length - next)
            }
        }
    }
}
