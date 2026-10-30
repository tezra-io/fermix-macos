import AppKit
import SwiftUI

extension ChatMetrics {
    /// A reply's words and a person's, in the reading face: the body's size
    /// with room between lines for reading at length (owner, 2026-10-30).
    static let readingType = TypeStyle(size: 15, leading: 23, weight: .regular, relativeTo: .body)
    /// Between two paragraphs drawn as one text: less than a blank line, so
    /// a run of paragraphs reads as one piece of writing.
    static let paragraphGap: Double = 10
    /// Inline code, a step under the words round it, as a code block is.
    static let codeSpanScale: Double = 0.9
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

/// Marks a link that may not go where it seems to, with why, on the words
/// the system's text view draws (`ChatProseText`).
extension NSAttributedString.Key {
    static let chatLinkCaution = NSAttributedString.Key("fermix.chatLinkCaution")
}

/// What a reply's words are drawn with by the system's text view: the
/// reading face at the size the reader's text size makes it, its lines a
/// fixed height apart so a line with an emoji or another script in it is
/// no taller, and its paragraphs a gap apart.
struct ChatProseStyle {
    let size: Double
    let lineHeight: Double
    let paragraphGap: Double
    private let faces: Faces

    /// The reading rung at `size`, the reader's text size applied to it.
    @MainActor
    init(size: Double) {
        let ratio = size / ChatMetrics.readingType.size
        self.size = size
        lineHeight = (ChatMetrics.readingType.leading ?? size) * ratio
        paragraphGap = ChatMetrics.paragraphGap * ratio
        faces = Self.faces(at: size)
    }

    func font(_ intent: InlinePresentationIntent?) -> NSFont {
        if intent?.contains(.code) == true { return faces.code }

        switch (intent?.contains(.stronglyEmphasized) == true, intent?.contains(.emphasized) == true) {
        case (false, false): return faces.regular
        case (true, false): return faces.strong
        case (false, true): return faces.italic
        case (true, true): return faces.strongItalic
        }
    }

    /// The fonts a reply's words are set in at one size, matched once for
    /// each size: finding a face by its family is the slow part of drawing
    /// a reply, and a turn being written draws its last paragraph again for
    /// every piece.
    private struct Faces {
        let regular: NSFont
        let strong: NSFont
        let italic: NSFont
        let strongItalic: NSFont
        let code: NSFont
    }

    @MainActor private static var matched: [Double: Faces] = [:]

    @MainActor
    private static func faces(at size: Double) -> Faces {
        if let known = matched[size] { return known }

        let faces = Faces(
            regular: ReadingFace.nsFont(size: size, weight: .regular),
            strong: ReadingFace.nsFont(size: size, weight: .semibold),
            italic: ReadingFace.nsFont(size: size, weight: .regular, italic: true),
            strongItalic: ReadingFace.nsFont(size: size, weight: .semibold, italic: true),
            code: NSFont.monospacedSystemFont(ofSize: size * ChatMetrics.codeSpanScale, weight: .regular)
        )
        matched[size] = faces
        return faces
    }

    func paragraph(first: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacingBefore = first ? 0 : paragraphGap
        return style
    }

    /// Where the first line's baseline sits under the top of the words, as
    /// TextKit lays a line of this style out: what a list item's words and
    /// its mark line up on. Laid out once for each size.
    @MainActor
    var firstBaseline: Double {
        if let known = Self.baselines[size] { return known }

        let probe = NSTextStorage(string: "X", attributes: [.font: font(nil), .paragraphStyle: paragraph(first: true)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        probe.addLayoutManager(layout)
        let baseline = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + layout.location(forGlyphAt: 0).y
        Self.baselines[size] = baseline
        return baseline
    }

    @MainActor private static var baselines: [Double: Double] = [:]
}

/// A run of a reply's paragraphs as the system's text view draws them,
/// read from the words as they were parsed (`ReplyText`):
///
/// - The words in the reply's ink; strongly emphasised words semibold,
///   emphasised ones italic, inline code monospaced a step smaller on a faint
///   fill, struck words struck through.
/// - Every link, a markdown link and an address or path written out alike,
///   in the words' own ink with a faint underline, as the person's own
///   messages draw one. Where the pointer rests on it, it names where it
///   goes, under the title of the page the engine read for it where it read
///   one.
/// - A link that may not go where it seems to (`LinkSafety`) carries why,
///   which a click is checked against (`ChatLinkGuard`), says why where the
///   pointer rests on it, and has a small caution mark after its words.
/// - A search's matches marked, as `ChatText.marking` marks them.
enum ChatProseText {
    /// The tones the words are drawn in, each made once: a dynamic colour
    /// resolves for the appearance when it is drawn.
    private static let ink = Palette.ink.nsColor
    private static let faint = Palette.faint.nsColor
    private static let codeFill = Palette.codeSpanFill.nsColor
    private static let warning = Palette.warning.nsColor
    private static let markTone = Palette.accentText.nsColor

    static func attributed(
        _ paragraphs: [AttributedString],
        marked: [String],
        titles: ChatLinkTitles,
        style: ChatProseStyle
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, words) in paragraphs.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "\n", attributes: [.font: style.font(nil)]))
            }
            let start = text.length
            text.append(paragraph(words, titles: titles, style: style))
            text.addAttribute(
                .paragraphStyle,
                value: style.paragraph(first: index == 0),
                range: NSRange(location: start, length: text.length - start)
            )
        }
        mark(marked, in: text, style: style)

        return text
    }

    /// A paragraph's words set in one piece, then each stretch drawn apart
    /// from the rest, a link's mark set in after its words last to first so
    /// every range read before stays where it was.
    private static func paragraph(_ words: AttributedString, titles: ChatLinkTitles, style: ChatProseStyle) -> NSAttributedString {
        let drawn = NSMutableAttributedString(string: String(words.characters), attributes: [.font: style.font(nil), .foregroundColor: ink])
        for run in words.runs {
            guard let intent = run.inlinePresentationIntent else { continue }

            drawn.addAttributes(attributes(of: intent, style: style), range: NSRange(run.range, in: words))
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

    private static func attributes(of intent: InlinePresentationIntent, style: ChatProseStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: style.font(intent)]
        if intent.contains(.code) {
            attributes[.backgroundColor] = codeFill
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
    static func tip(_ url: URL, title: String?, caution: LinkCaution?) -> String {
        let address = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        let heading = caution.map(ChatLinkCautionWords.sentence) ?? title
        return heading.map { $0 + "\n" + address } ?? address
    }

    /// The caution mark after a link's words, kept on their line by a narrow
    /// space that never breaks: a small triangle in the warning tone, which
    /// opens, says and is checked as the link is.
    private static func cautionMark(_ caution: LinkCaution, url: URL, style: ChatProseStyle) -> NSAttributedString {
        let sentence = ChatLinkCautionWords.sentence(caution)
        let configuration = NSImage.SymbolConfiguration(pointSize: style.size * ChatMetrics.cautionMarkScale, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [warning]))
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: sentence)?
            .withSymbolConfiguration(configuration)
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = style.font(nil)
        if let image {
            attachment.bounds = CGRect(
                x: 0,
                y: (font.capHeight - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            )
        }

        let mark = NSMutableAttributedString(string: "\u{202F}", attributes: [.font: font])
        mark.append(NSAttributedString(attachment: attachment))
        mark.addAttributes([
            .link: url,
            .chatLinkCaution: caution,
            .toolTip: tip(url, title: nil, caution: caution)
        ], range: NSRange(location: 0, length: mark.length))
        return mark
    }

    /// Every occurrence of each term, semibold in the text blue, case
    /// ignored, as the search that found them ignored it.
    private static func mark(_ terms: [String], in text: NSMutableAttributedString, style: ChatProseStyle) {
        let string = text.string as NSString
        for term in terms where !term.isEmpty {
            var searched = NSRange(location: 0, length: string.length)
            while true {
                let found = string.range(of: term, options: .caseInsensitive, range: searched)
                guard found.location != NSNotFound else { break }

                text.addAttributes([
                    .font: style.font(.stronglyEmphasized),
                    .foregroundColor: markTone
                ], range: found)
                let next = found.location + found.length
                searched = NSRange(location: next, length: string.length - next)
            }
        }
    }
}

/// Words of a reply drawn by the system's own text view rather than by
/// SwiftUI's `Text` (`ChatProseText`), for what a reader does with them: a
/// link names where it goes while the pointer rests on it and opens through
/// the chat's check (`ChatLinkGuard`); its menu offers Copy Link; and a
/// selection runs across every paragraph of the run, with the system's own
/// menu of Copy, Look Up and Translate.
///
/// Compared by what it draws, so a turn still being written draws again only
/// the run it is writing.
struct ChatProse: View, Equatable {
    /// The run's paragraphs as they were parsed, nothing coloured.
    let paragraphs: [AttributedString]
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    let titles: ChatLinkTitles
    /// Who wrote it, which VoiceOver names it by.
    let speaker: String?

    @ScaledMetric(relativeTo: .body) private var size = ChatMetrics.readingType.size
    @Environment(\.chatRows) private var rows

    static func == (lhs: ChatProse, rhs: ChatProse) -> Bool {
        lhs.paragraphs == rhs.paragraphs && lhs.marked == rhs.marked && lhs.titles == rhs.titles && lhs.speaker == rhs.speaker
    }

    var body: some View {
        let style = ChatProseStyle(size: size)
        let text = ChatProseText.attributed(paragraphs, marked: marked, titles: titles, style: style)
        let baseline = style.firstBaseline
        let check = rows?.linkGuard

        ChatProseView(text: text, label: ChatSpeaker.name(role: speaker)) { url, caution in
            check?.open(url, caution: caution)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.firstTextBaseline) { _ in CGFloat(baseline) }
    }
}

/// The system's text view in the transcript: as wide as the column gives it
/// and as tall as its lines wrap to there.
private struct ChatProseView: NSViewRepresentable {
    let text: NSAttributedString
    let label: String
    let open: (URL, LinkCaution?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(open: open)
    }

    func makeNSView(context: Context) -> ChatProseTextView {
        let view = ChatProseTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ChatProseTextView, context: Context) {
        context.coordinator.open = open
        view.show(text)
        view.setAccessibilityLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ChatProseTextView, context: Context) -> CGSize? {
        view.size(fitting: proposal.width)
    }

    /// Opens a clicked link through the chat's check, with the caution its
    /// words carry.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: (URL, LinkCaution?) -> Void

        init(open: @escaping (URL, LinkCaution?) -> Void) {
            self.open = open
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }

            let caution = textView.textStorage?.attribute(.chatLinkCaution, at: charIndex, effectiveRange: nil) as? LinkCaution
            open(url, caution)
            return true
        }
    }
}

/// A text view that only shows its words: selectable, never editable, on no
/// background of its own, with no inset, laid out by TextKit 1 so its height
/// at a width is exact. It is measured by a second layout of the same words,
/// so SwiftUI asking its size at one width never moves the lines it draws at
/// another.
final class ChatProseTextView: NSTextView {
    private let measuring = NSLayoutManager()
    private let measuringContainer = NSTextContainer()
    /// The last width it was measured at, and its size there.
    private var measured: (width: CGFloat, size: CGSize)?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        measuringContainer.lineFragmentPadding = 0
        measuring.addTextContainer(measuringContainer)
        storage.addLayoutManager(measuring)
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        displaysLinkToolTips = false
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFontPanel = false
        allowsUndo = false
        writingToolsBehavior = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("the text view is made in code")
    }

    /// The words to show, set only when they changed.
    func show(_ text: NSAttributedString) {
        guard let storage = textStorage, !storage.isEqual(to: text) else { return }

        storage.setAttributedString(text)
        measured = nil
    }

    /// Its size at a width: the width it is given, or its widest line where
    /// it is given none, and the height its lines wrap to.
    func size(fitting width: CGFloat?) -> CGSize {
        let bound = width.map { $0.isFinite ? max(0, $0) : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        if let measured, measured.width == bound { return measured.size }

        let used = laidOut(at: bound)
        let size = CGSize(width: bound == .greatestFiniteMagnitude ? ceil(used.width) : bound, height: ceil(used.height))
        measured = (bound, size)
        return size
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    private func laidOut(at width: CGFloat) -> CGRect {
        measuringContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        measuring.ensureLayout(for: measuringContainer)
        return measuring.usedRect(for: measuringContainer)
    }
}
