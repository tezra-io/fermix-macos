import AppKit
import SwiftUI

extension ChatMetrics {
    /// A code block's code: the monospaced face a step under the reply's
    /// words, with room between its lines.
    static let codeType = TypeStyle(size: 13, leading: 20, weight: .regular, monospaced: true, relativeTo: .callout)
    /// A code block's corners: a card's.
    static let codeRadius: Double = Radius.card
    /// The room round a block's code inside its fill.
    static let codeInset: Double = Spacing.s + Spacing.xxs / 2
    /// The line over a block's code that names its language and holds its
    /// Copy, which sits `codeCopyInset` in from the block's top and
    /// trailing edges.
    static let codeHeaderHeight: Double = 28
    static let codeCopyInset: Double = Spacing.xxs
    /// How long Copy says Copied.
    static let codeCopiedFor: Duration = .milliseconds(1500)
    /// A table's cells: room above and under their words, and between two
    /// columns.
    static let tableCellInset: Double = 7
    static let tableColumnGap: Double = Spacing.l
    /// The narrowest a column gives way to so the table fits the reply: about
    /// eight ems of the reply's words, room for a few words a line.
    static let tableColumnFloor: Double = 8 * readingType.size
    /// How far each depth of a list sits in from the one above it, how far
    /// a list's marks sit in from the words' edge, and the room between a
    /// mark and its words.
    static let listIndent: Double = 22
    static let listMarkInset: Double = Spacing.xxs
    static let listMarkGap: Double = Spacing.xs
    /// Between two items of a list, nested or not.
    static let listItemGap: Double = Spacing.xxs
    /// A quote's bar, and the room between it and the quote's words.
    static let quoteBarWidth: Double = 3
    static let quoteGap: Double = Spacing.s
}

/// A reply as one text, which a reader selects across from its first word
/// to its last: every block of it set in the reading face (`ChatProseStyle`)
/// in reading order, each a piece of its own so a turn still being written
/// sets again only the block it is writing (`ChatReplyComposer`).
///
/// - A paragraph is its words. A heading is its words semibold, a step over
///   the words for levels 1 to 3, with more room above it than under it.
/// - A list's items each hang beside their mark, a bullet, a number as
///   CommonMark numbers it or a task's box, so an item's later lines start
///   under its words. A nested item sits a step in from the one above it.
/// - A quote sits beside a thin bar.
/// - A table spans the reply: its header semibold over a hairline, each row
///   over a fainter one, its columns sized by the browser's automatic rule and
///   each cell aligned as its delimiter row says. Copied, its cells are a tab
///   apart and its rows a line apart.
/// - A code block sits on a soft rounded fill, under a line that names its
///   language where its fence names one and holds its Copy, its code
///   coloured (`CodeHighlight`) and wrapping at the fill's edge.
struct ChatReplyDocument {
    /// Each block set, in reading order, each ending with its last
    /// paragraph's line feed.
    let pieces: [NSAttributedString]
    /// The code blocks, in reading order.
    let codes: [Code]

    /// A code block: what it is drawn in, and what its Copy writes.
    struct Code {
        let block: ChatCodeTextBlock
        let text: String
    }
}

/// Sets a reply's blocks as one text (`ChatReplyDocument`), keeping each
/// block's piece while the block, the room above it, the words a search
/// marks and the size it is set at stay the same.
@MainActor
final class ChatReplyComposer {
    private struct Key: Equatable {
        let block: ReplyBlock
        let before: Double
        let marked: [String]
        let titles: ChatLinkTitles
        let style: ChatProseStyle
    }

    private struct Piece {
        let key: Key
        let text: NSAttributedString
        let code: ChatReplyDocument.Code?
    }

    private var kept: [Piece] = []

    func document(_ blocks: [ReplyBlock], marked: [String], titles: ChatLinkTitles, style: ChatProseStyle) -> ChatReplyDocument {
        var pieces: [Piece] = []
        for (index, block) in blocks.enumerated() {
            let key = Key(
                block: block,
                before: Self.room(above: block, after: index > 0 ? blocks[index - 1] : nil, style: style),
                marked: marked,
                titles: titles,
                style: style
            )
            if index < kept.count, kept[index].key == key {
                pieces.append(kept[index])
            } else {
                pieces.append(Self.piece(key))
            }
        }
        kept = pieces

        return ChatReplyDocument(pieces: pieces.map(\.text), codes: pieces.compactMap(\.code))
    }

    /// The room above a block: none above the first, a heading's room above
    /// a heading, a heading's own room under it, and a paragraph's gap
    /// between any other two.
    static func room(above block: ReplyBlock, after previous: ReplyBlock?, style: ChatProseStyle) -> Double {
        guard let previous else { return 0 }
        if case .heading = block { return style.scaled(ChatMetrics.headingGap) }
        if case .heading = previous { return style.scaled(ChatMetrics.underHeadingGap) }

        return style.scaled(ChatMetrics.paragraphGap)
    }

    private static func piece(_ key: Key) -> Piece {
        let style = key.style
        let set: (text: NSMutableAttributedString, code: ChatReplyDocument.Code?)
        switch key.block {
        case .prose(let words):
            set = (ChatReplySetting.paragraph(words, before: key.before, titles: key.titles, style: style), nil)
        case .heading(let level, let words):
            set = (ChatReplySetting.heading(words, level: level, before: key.before, titles: key.titles, style: style), nil)
        case .list(let list):
            set = (ChatReplySetting.list(list, before: key.before, titles: key.titles, style: style), nil)
        case .quote(let words):
            set = (ChatReplySetting.quote(words, before: key.before, titles: key.titles, style: style), nil)
        case .table(let table):
            set = (ChatReplySetting.table(table, before: key.before, titles: key.titles, style: style), nil)
        case .code(let code):
            let block = ChatCodeTextBlock(language: code.language.map(CodeLanguage.name(of:)), style: style, before: key.before)
            set = (ChatReplySetting.code(code, in: block, style: style), ChatReplyDocument.Code(block: block, text: code.text))
        }
        if case .code = key.block {
            ChatProseText.mark(key.marked, in: set.text, strong: style.codeFont(strong: true))
        } else {
            ChatProseText.mark(key.marked, in: set.text, strong: style.font(.stronglyEmphasized))
        }

        return Piece(key: key, text: set.text, code: set.code)
    }
}

/// How each kind of block is set (`ChatReplyDocument`).
@MainActor
enum ChatReplySetting {
    static func paragraph(_ words: AttributedString, before: Double, titles: ChatLinkTitles, style: ChatProseStyle) -> NSMutableAttributedString {
        let text = ChatProseText.words(words, titles: titles, style: style, font: style.font)
        text.append(NSAttributedString(string: "\n", attributes: [.font: style.font(nil)]))
        styleParagraphs(of: text, first: style.paragraph(before: before), rest: style.paragraph())
        return text
    }

    static func heading(_ words: AttributedString, level: Int, before: Double, titles: ChatLinkTitles, style: ChatProseStyle) -> NSMutableAttributedString {
        let font = style.headingFont(level: level)
        let italic = style.headingFont(level: level, emphasized: true)
        let text = ChatProseText.words(words, titles: titles, style: style) { intent in
            if intent?.contains(.code) == true { return style.codeSpanFont }
            return intent?.contains(.emphasized) == true ? italic : font
        }
        text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        let lineHeight = style.headingLineHeight(level: level)
        styleParagraphs(of: text, first: style.paragraph(before: before, lineHeight: lineHeight), rest: style.paragraph(lineHeight: lineHeight))
        return text
    }

    // MARK: - Lists

    static func list(_ list: ReplyList, before: Double, titles: ChatLinkTitles, style: ChatProseStyle) -> NSMutableAttributedString {
        let marks = list.items.map { mark(of: $0, style: style) }
        let column = marks.map { $0.size().width }.max() ?? 0
        let text = NSMutableAttributedString()
        for (index, item) in list.items.enumerated() {
            let start = style.scaled(ChatMetrics.listMarkInset + Double(item.depth) * ChatMetrics.listIndent)
            let words = start + column + style.scaled(ChatMetrics.listMarkGap)
            let gap = index == 0 ? before : style.scaled(ChatMetrics.listItemGap)

            let first = style.paragraph(before: gap)
            first.firstLineHeadIndent = start
            first.headIndent = words
            first.tabStops = [NSTextTab(textAlignment: .left, location: words)]
            let rest = style.paragraph()
            rest.firstLineHeadIndent = words
            rest.headIndent = words

            let line = NSMutableAttributedString(attributedString: marks[index])
            line.append(NSAttributedString(string: "\t", attributes: [.font: style.font(nil)]))
            line.append(ChatProseText.words(item.words, titles: titles, style: style, font: style.font))
            line.append(NSAttributedString(string: "\n", attributes: [.font: style.font(nil)]))
            styleParagraphs(of: line, first: first, rest: rest)
            text.append(line)
        }
        return text
    }

    /// An item's mark in the words' ink: its number in digits all one
    /// width, the dot at its depth, or a task's box, ticked once done, which
    /// is copied as markdown writes it.
    private static func mark(of item: ReplyListItem, style: ChatProseStyle) -> NSAttributedString {
        let font = style.font(nil)
        switch item.marker {
        case .number(let number):
            let digits = NSFont.monospacedDigitSystemFont(ofSize: style.size, weight: .regular)
            return NSAttributedString(
                string: String(format: ProductStrings[.chatListNumberFormat], number),
                attributes: [.font: digits, .foregroundColor: ChatProseText.ink]
            )
        case .bullet:
            return NSAttributedString(
                string: ProductStrings[item.depth == 0 ? .chatListBullet : .chatListBulletNested],
                attributes: [.font: font, .foregroundColor: ChatProseText.ink]
            )
        case .task(let done):
            let configuration = NSImage.SymbolConfiguration(pointSize: style.size, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ChatProseText.secondary]))
            let image = NSImage(
                systemSymbolName: done ? "checkmark.square" : "square",
                accessibilityDescription: ProductStrings[done ? .chatTaskDone : .chatTaskOpen]
            )?.withSymbolConfiguration(configuration)
            let box = NSMutableAttributedString(attributedString: ChatProseText.attachment(image, centredOn: font))
            box.addAttributes([.font: font, .chatPlain: done ? "[x]" : "[ ]"], range: NSRange(location: 0, length: box.length))
            return box
        }
    }

    // MARK: - Quotes

    static func quote(_ words: AttributedString, before: Double, titles: ChatLinkTitles, style: ChatProseStyle) -> NSMutableAttributedString {
        let block = NSTextTableBlock(table: ChatReplySetting.box(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.setWidth(style.scaled(ChatMetrics.quoteBarWidth), type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(Palette.hairline(.strong).nsColor, for: .minX)
        block.setWidth(style.scaled(ChatMetrics.quoteGap), type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)

        let text = ChatProseText.words(words, titles: titles, style: style, font: style.font)
        text.addAttribute(.foregroundColor, value: ChatProseText.secondary, range: NSRange(location: 0, length: text.length))
        text.append(NSAttributedString(string: "\n", attributes: [.font: style.font(nil)]))
        let paragraph = style.paragraph()
        paragraph.textBlocks = [block]
        styleParagraphs(of: text, first: paragraph, rest: paragraph)
        return text
    }

    /// A table of one cell as wide as the reply: what holds a block of
    /// several paragraphs, a quote's or a code block's, since TextKit lays
    /// only the first paragraph of a plain text block inside it.
    static func box() -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.setContentWidth(100, type: .percentageValueType)
        return table
    }

    // MARK: - Tables

    static func table(_ table: ReplyTable, before: Double, titles: ChatLinkTitles, style: ChatProseStyle) -> NSMutableAttributedString {
        let columns = table.alignments.count
        let grid = NSTextTable()
        grid.numberOfColumns = columns
        grid.layoutAlgorithm = .automaticLayoutAlgorithm
        grid.collapsesBorders = true
        grid.hidesEmptyCells = false
        grid.setContentWidth(100, type: .percentageValueType)
        grid.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)

        let rows = [table.header] + table.rows
        let strong = style.font(.stronglyEmphasized)
        let set = rows.enumerated().map { row, cells in
            cells.map { words in
                ChatProseText.words(words, titles: titles, style: style) { intent in
                    row == 0 && intent?.contains(.code) != true ? strong : style.font(intent)
                }
            }
        }
        let shares = ChatTableColumns.shares(
            natural: (0..<columns).map { column in set.map { ceil($0[column].size().width) }.max() ?? 0 },
            available: style.scaled(ChatMetrics.columnWidth),
            gap: style.scaled(ChatMetrics.tableColumnGap),
            floor: style.scaled(ChatMetrics.tableColumnFloor)
        )
        let text = NSMutableAttributedString()
        for (row, cells) in set.enumerated() {
            for (column, words) in cells.enumerated() {
                let cell = NSTextTableBlock(table: grid, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setContentWidth(shares[column], type: .percentageValueType)
                let inset = style.scaled(ChatMetrics.tableCellInset)
                let half = style.scaled(ChatMetrics.tableColumnGap) / 2
                cell.setWidth(inset, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(inset, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(column == 0 ? 0 : half, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(column == columns - 1 ? 0 : half, type: .absoluteValueType, for: .padding, edge: .maxX)
                if row < rows.count - 1 {
                    cell.setWidth(Stroke.hairline, type: .absoluteValueType, for: .border, edge: .maxY)
                    cell.setBorderColor(Palette.hairline(row == 0 ? .standard : .faint).nsColor, for: .maxY)
                }

                let end = column == columns - 1 ? "\n" : "\t"
                words.append(NSAttributedString(string: "\n", attributes: [.font: style.font(nil), .chatPlain: end]))
                let paragraph = style.paragraph()
                paragraph.textBlocks = [cell]
                paragraph.alignment = alignment(of: table.alignments[column])
                styleParagraphs(of: words, first: paragraph, rest: paragraph)
                text.append(words)
            }
        }
        return text
    }

    private static func alignment(of column: ReplyTableAlignment) -> NSTextAlignment {
        switch column {
        case .leading: return .natural
        case .center: return .center
        case .trailing: return .right
        }
    }

    // MARK: - Code

    static func code(_ code: ReplyCode, in block: ChatCodeTextBlock, style: ChatProseStyle) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(string: code.text, attributes: [.font: style.codeFont(), .foregroundColor: ChatProseText.ink])
        for token in CodeHighlight.tokens(in: code.text, language: code.language) {
            text.addAttribute(.foregroundColor, value: colour(of: token.kind), range: NSRange(token.range, in: code.text))
        }
        text.append(NSAttributedString(string: "\n", attributes: [.font: style.codeFont()]))
        let paragraph = style.paragraph(lineHeight: style.codeLineHeight)
        paragraph.textBlocks = [block]
        paragraph.lineBreakMode = .byWordWrapping
        styleParagraphs(of: text, first: paragraph, rest: paragraph)
        return text
    }

    private static func colour(of kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .keyword: return Palette.codeKeyword.nsColor
        case .string: return Palette.codeString.nsColor
        case .number: return Palette.codeNumber.nsColor
        case .comment: return ChatProseText.faint
        }
    }

    // MARK: - Paragraphs

    /// Sets the first paragraph of a block's text in `first` and every
    /// later one, the lines a soft break starts, in `rest`.
    private static func styleParagraphs(of text: NSMutableAttributedString, first: NSParagraphStyle, rest: NSParagraphStyle) {
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            text.addAttribute(.paragraphStyle, value: location == 0 ? first : rest, range: range)
            location = NSMaxRange(range)
        }
    }
}

/// A table's columns' widths by the browser's automatic rule. A table that
/// fits the width it has at its columns' natural widths keeps them. One that
/// does not narrows its widest columns first, each brought down to the next
/// widest in turn, until it fits. No column narrows below the floor, and one
/// already narrower keeps its natural width.
enum ChatTableColumns {
    /// `natural` is each column's widest cell on one line, `available` the
    /// width the table has, and `gap` the room between two columns.
    static func widths(natural: [Double], available: Double, gap: Double, floor: Double) -> [Double] {
        let room = available - gap * Double(max(natural.count - 1, 0))
        let widest = natural.sorted(by: >)
        var rest = widest.reduce(0, +)
        var cap = 0.0
        for (rank, width) in widest.enumerated() {
            // The widest `rank + 1` columns share what the others leave.
            rest -= width
            let level = (room - rest) / Double(rank + 1)
            if level >= (rank + 1 < widest.count ? widest[rank + 1] : 0) {
                cap = level
                break
            }
        }

        return natural.map { min($0, max(cap, floor)) }
    }

    /// Each column's share of the table's width, in percent, as the rule
    /// sizes it at the reply's own width: a table spans the reply, so a
    /// narrower window narrows every column in step and wraps their words.
    /// A table with no words shares its width evenly.
    static func shares(natural: [Double], available: Double, gap: Double, floor: Double) -> [Double] {
        let sized = widths(natural: natural, available: available, gap: gap, floor: floor)
        let total = sized.reduce(0, +)
        guard total > 0 else { return natural.map { _ in 100 / Double(max(natural.count, 1)) } }

        return sized.map { 100 * $0 / total }
    }
}

/// A code block's text block, the one cell of a table as wide as the reply
/// (`ChatReplySetting.box`): its soft fill with rounded corners, and the name
/// of its language on the line over its code. The room above it is its
/// margin, which the fill leaves out.
final class ChatCodeTextBlock: NSTextTableBlock {
    private let language: String?
    private let radius: Double
    private let inset: Double
    private let labelFont: NSFont

    @MainActor
    init(language: String?, style: ChatProseStyle, before: Double) {
        self.language = language
        radius = style.scaled(ChatMetrics.codeRadius)
        inset = style.scaled(ChatMetrics.codeInset)
        labelFont = NSFont.systemFont(ofSize: style.scaled(Typography.style(.caption).size), weight: .medium)
        super.init(table: ChatReplySetting.box(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        let header = style.scaled(ChatMetrics.codeHeaderHeight)
        setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
        setWidth(header, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(inset, type: .absoluteValueType, for: .padding, edge: .maxY)
        setWidth(inset, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(inset, type: .absoluteValueType, for: .padding, edge: .maxX)
    }

    required init?(coder: NSCoder) {
        language = nil
        radius = ChatMetrics.codeRadius
        inset = ChatMetrics.codeInset
        labelFont = NSFont.systemFont(ofSize: Typography.style(.caption).size, weight: .medium)
        super.init(coder: coder)
    }

    /// The block's fill and its language's name, inside its margin.
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let box = Self.filled(frameRect, block: self)
        Palette.chipFill.nsColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()

        guard let language else { return }

        let header = width(for: .padding, edge: .minY)
        let words = NSAttributedString(string: language, attributes: [.font: labelFont, .foregroundColor: Palette.secondary.nsColor])
        let size = words.size()
        words.draw(at: NSPoint(x: box.minX + inset, y: box.minY + (header - size.height) / 2))
    }

    /// The part of a block's frame its fill covers: all of it but its
    /// margin.
    static func filled(_ frame: NSRect, block: NSTextBlock) -> NSRect {
        let top = block.width(for: .margin, edge: .minY)
        let bottom = block.width(for: .margin, edge: .maxY)
        return NSRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: frame.height - top - bottom)
    }
}
