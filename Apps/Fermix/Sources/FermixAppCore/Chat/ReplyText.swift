import Foundation

/// A row's words as they read, before anything is drawn: every link they
/// carry, and nothing coloured (M66 §3.1). One reading serves the strip,
/// which lists the files and addresses the words link to, and the row,
/// which draws them (`ChatText.drawn`), so the two can never disagree about
/// what is a link.
///
/// Fermix's words are blocks in reading order: a fenced code block
/// (`ReplyFences`) is code, kept as it was written with the language its
/// fence names, and the words between are the paragraphs, lists, tables and
/// quotes they are written as (`ReplyStructure`), every stretch of their
/// words inline markdown, their headings read inline (`headingsInlined`),
/// with every local path (`ReplyPaths`) and every web address written out
/// (`ReplyLinks`) a link. Code carries no links. A person's words are drawn
/// as they typed them, so they are read as plain text, one block: only the
/// paths and addresses written out in them count, and no markdown is read
/// into them.
struct ReplyText: Equatable {
    /// The words in reading order.
    let blocks: [ReplyBlock]

    /// Fermix's words, `~` read as `home`.
    init(markdown text: String, home: String) {
        blocks = Self.reading(text, home: home).blocks
    }

    /// A person's words, `~` read as `home`.
    init(plain text: String, home: String) {
        blocks = [.prose(ReplyPaths.linked(ReplyLinks.linked(AttributedString(text)), home: home))]
    }

    /// Fermix's words, `~` read as `home`, as blocks, with the last place
    /// they can be cut: what a turn still being written reads (`ReplyDraft`).
    static func reading(_ text: String, home: String) -> ReplyReading {
        var blocks: [ReplyBlock] = []
        var cut: ReplyReading.Cut?
        for run in ReplyFences.runs(text) {
            switch run {
            case .prose(let lines):
                let structure = ReplyStructure(lines: lines) { parsed($0, home: home) }
                if let local = structure.cut {
                    cut = ReplyReading.Cut(index: local.index, blocks: blocks.count + local.blocks)
                }
                blocks += structure.blocks
            case .code(let code, _):
                blocks.append(.code(code))
            }
        }

        return ReplyReading(blocks: blocks, cut: cut)
    }

    /// Every link, in reading order, a link drawn over several runs (a bold
    /// word inside it) counted once.
    var links: [URL] {
        blocks.flatMap(\.words).flatMap { words in
            words.runs[\.link].compactMap { link, _ in link }
        }
    }

    /// The files the words link to: the paths made links and the markdown
    /// links to a path.
    var files: [URL] {
        links.filter(\.isFileURL)
    }

    /// The web addresses the words link to: the ones written out and the
    /// destinations of the markdown links.
    var addresses: [URL] {
        links.filter(ReplyLinks.isAddress)
    }

    /// Words as inline markdown with their links set.
    private static func parsed(_ text: String, home: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let inlined = headingsInlined(text)
        let parsed = (try? AttributedString(markdown: inlined, options: options)) ?? AttributedString(inlined)
        return ReplyPaths.linked(ReplyLinks.linked(parsed), home: home)
    }

    /// Inline markdown only, except a heading line, one to six `#` then a
    /// space then its text, which becomes that text strongly emphasised: a
    /// reply is a conversation, and a heading reads as noise on the ground
    /// rather than as structure (owner, 2026-09-28). Every other line is left
    /// as it is.
    private static func headingsInlined(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in heading(line).map { "**\($0)**" } ?? String(line) }
            .joined(separator: "\n")
    }

    /// The text of a heading line, or nil for any other line.
    private static func heading(_ line: Substring) -> String? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count), line.dropFirst(marks.count).first == " " else { return nil }
        let title = line.dropFirst(marks.count + 1).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

/// Fermix's words read as blocks, and the last place they can be cut: the
/// start of a line from which the rest reads as words of their own, so the
/// blocks before it are what the words before it read as, whatever is
/// written after them (`ReplyStructure`).
struct ReplyReading {
    struct Cut {
        /// Where the line starts, in the words read.
        let index: String.Index
        /// How many of the blocks lie before it.
        let blocks: Int
    }

    let blocks: [ReplyBlock]
    /// Nil where the words cannot be cut yet.
    let cut: Cut?
}

/// One block of a reply, in reading order.
enum ReplyBlock: Equatable {
    /// A paragraph: words, with their links set.
    case prose(AttributedString)
    /// A fenced code block, as it was written.
    case code(ReplyCode)
    /// A list, its nested items among its own.
    case list(ReplyList)
    case table(ReplyTable)
    /// A quote's words.
    case quote(AttributedString)

    var prose: AttributedString? {
        guard case .prose(let words) = self else { return nil }
        return words
    }

    var code: ReplyCode? {
        guard case .code(let code) = self else { return nil }
        return code
    }

    /// Every stretch of words the block draws, in reading order: a list's
    /// items, and a table's header and then its rows. Code has none.
    var words: [AttributedString] {
        switch self {
        case .prose(let words), .quote(let words): return [words]
        case .code: return []
        case .list(let list): return list.items.map(\.words)
        case .table(let table): return table.header + table.rows.flatMap { $0 }
        }
    }

    /// The block with each stretch of its words changed, and the rest of it
    /// as it was: how its words are drawn and marked.
    func mappingWords(_ change: (AttributedString) -> AttributedString) -> ReplyBlock {
        switch self {
        case .prose(let words):
            return .prose(change(words))
        case .quote(let words):
            return .quote(change(words))
        case .code:
            return self
        case .list(let list):
            return .list(ReplyList(items: list.items.map { ReplyListItem(depth: $0.depth, marker: $0.marker, words: change($0.words)) }))
        case .table(let table):
            return .table(ReplyTable(alignments: table.alignments, header: table.header.map(change), rows: table.rows.map { $0.map(change) }))
        }
    }
}

/// A list: its items in reading order, each as deep as it is nested.
struct ReplyList: Equatable {
    /// The deepest an item is drawn: one nested further is drawn here.
    static let deepest = 2

    let items: [ReplyListItem]
}

struct ReplyListItem: Equatable {
    /// 0 for the list's own items, one more for each list an item is
    /// nested in, never past `ReplyList.deepest`.
    let depth: Int
    let marker: ReplyListMarker
    /// The words after its mark, and the lines indented under it.
    let words: AttributedString
}

enum ReplyListMarker: Equatable {
    case bullet
    /// A number as CommonMark numbers a list: its first item's number as
    /// written, and one more for each item after it at the same depth.
    case number(Int)
    /// A task (`- [ ]`), done or not (`- [x]`).
    case task(done: Bool)
}

/// A table: how each column aligns, its header's cells, and its rows, each
/// with as many cells as the header.
struct ReplyTable: Equatable {
    let alignments: [ReplyTableAlignment]
    let header: [AttributedString]
    let rows: [[AttributedString]]

    /// The table as text with tabs, what Copy writes, to paste into a
    /// spreadsheet: a line for its header and one for each row, each cell's
    /// words as they read.
    var text: String {
        ([header] + rows)
            .map { cells in cells.map { String($0.characters) }.joined(separator: "\t") }
            .joined(separator: "\n")
    }
}

/// How a table's column aligns, as its delimiter row says: `:--` or no
/// colon is leading, `:-:` centred, and `--:` trailing.
enum ReplyTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

/// A fenced code block: the language its fence names, as written, and its
/// lines exactly as written between the fences.
struct ReplyCode: Equatable {
    /// The first word after the opening fence (`python`, `swift`), or nil
    /// where the fence names none.
    let language: String?
    /// The lines between the fences, the fence's own indent set aside, a
    /// newline apart. Empty for a block with no lines yet.
    let text: String
}

/// The fenced code blocks in a reply, read by CommonMark's rule for them: a
/// line of three or more backticks or tildes opens one, an info string after
/// it naming its language; the next line of at least as many of the same
/// mark, and nothing else, closes it; and a block never closed, as in a reply
/// still being written, runs to the end. A backtick fence's info string has
/// no backtick in it, so a line like ```` ```a``` ```` is words. A fence may
/// be indented by any amount, as it is inside a list item, and its lines lose
/// up to as much indent. A line ends at a line feed, with or without a
/// carriage return before it.
///
/// One reading of where code is serves the row, which draws it
/// (`ReplyText`), and the strip, which never touches a line of it
/// (`ChatStrip.withoutShownLines`).
enum ReplyFences {
    /// A stretch of a reply's lines: words, or one code block with its
    /// lines as written, fences included.
    enum Run: Equatable {
        case prose([Substring])
        case code(ReplyCode, lines: [Substring])
    }

    /// The reply's lines as runs, in order, every line in exactly one.
    static func runs(_ text: String) -> [Run] {
        var runs: [Run] = []
        var prose: [Substring] = []
        var open: OpenBlock?
        for line in lines(of: text) {
            if var block = open {
                block.lines.append(line)
                if block.fence.isClosed(by: line) {
                    runs.append(block.run(closed: true))
                    open = nil
                } else {
                    open = block
                }
            } else if let fence = Fence(opening: line) {
                if !prose.isEmpty { runs.append(.prose(prose)) }
                prose = []
                open = OpenBlock(fence: fence, lines: [line])
            } else {
                prose.append(line)
            }
        }
        if let open { runs.append(open.run(closed: false)) }
        if !prose.isEmpty { runs.append(.prose(prose)) }

        return runs
    }

    /// Each line of the reply with whether it is a code block's, its fences
    /// included.
    static func lines(_ text: String) -> [(line: Substring, code: Bool)] {
        runs(text).flatMap { run -> [(line: Substring, code: Bool)] in
            switch run {
            case .prose(let lines): return lines.map { ($0, false) }
            case .code(_, let lines): return lines.map { ($0, true) }
            }
        }
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    }

    /// A block whose closing fence has not come yet.
    private struct OpenBlock {
        let fence: Fence
        var lines: [Substring]

        func run(closed: Bool) -> Run {
            let body = lines.dropFirst().dropLast(closed ? 1 : 0)
            let code = ReplyCode(language: fence.language, text: body.map(fence.unindented).joined(separator: "\n"))
            return .code(code, lines: lines)
        }
    }

    /// An opening fence: its mark, how many, its indent and its language.
    private struct Fence {
        let mark: Character
        let length: Int
        let indent: Int
        let language: String?

        init?(opening line: Substring) {
            let indent = line.prefix(while: Self.isIndent)
            let marks = line.dropFirst(indent.count)
            guard let mark = marks.first, mark == "`" || mark == "~" else { return nil }
            let run = marks.prefix { $0 == mark }
            let info = marks.dropFirst(run.count)
            guard run.count >= 3, mark == "~" || !info.contains("`") else { return nil }

            self.mark = mark
            length = run.count
            self.indent = indent.count
            language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }

        func isClosed(by line: Substring) -> Bool {
            let marks = line.drop(while: Self.isIndent)
            let run = marks.prefix { $0 == mark }
            return run.count >= length && marks.dropFirst(run.count).allSatisfy(\.isWhitespace)
        }

        /// A line of the block less up to the fence's own indent.
        func unindented(_ line: Substring) -> Substring {
            line.dropFirst(line.prefix(while: Self.isIndent).prefix(indent).count)
        }

        private static func isIndent(_ character: Character) -> Bool {
            character == " " || character == "\t"
        }
    }
}

/// Marks a stretch of words that is a path or an address as written, made a
/// link here rather than by a markdown link's own words: the row draws it as
/// the text it is, apart from a markdown link (`ChatText.drawn`).
enum ReplyWrittenLink: AttributedStringKey {
    typealias Value = Bool
    static let name = "fermix.replyWrittenLink"
}

extension AttributedString {
    /// Makes a stretch a link to what it writes out, marked as written.
    mutating func linkWritten(_ range: Range<AttributedString.Index>, to destination: URL) {
        self[range].link = destination
        self[range][ReplyWrittenLink.self] = true
    }
}

/// The marks round a path or an address in a sentence that are not part of
/// it: one set, which every reader of a reply's words composes its own from.
enum ReplyMarks {
    /// What ends a clause or a sentence.
    static let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
    /// A closing quote, straight or curly, a stray backtick and a closing
    /// angle bracket.
    static let closingQuotes: Set<Character> = ["'", "\"", "\u{201D}", "\u{2019}", "`", ">"]
    /// Each closing bracket, with the one that opens it.
    static let brackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    /// What may stand before a path: an opening bracket, angle bracket or
    /// quote, straight or curly.
    static let opening: Set<Character> = ["(", "<", "\"", "'", "\u{201C}", "\u{2018}"]

    /// What may stand after a path or an address and close round it.
    static let closing: Set<Character> = punctuation.union(closingQuotes).union(brackets.keys)

    /// The engine's own rule for the end of an address it reads a preview
    /// from (`unfurl.ex`, `@trailing_punctuation`, `),.;!?]}`): the closing
    /// brackets and every mark that ends a clause but the colon.
    static let engineClosing: Set<Character> = punctuation.subtracting([":"]).union(brackets.keys)
}
