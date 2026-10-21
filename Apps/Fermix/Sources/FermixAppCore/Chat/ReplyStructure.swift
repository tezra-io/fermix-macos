import Foundation

/// The blocks a stretch of Fermix's words between code blocks is written as,
/// read line by line by GitHub's markdown rules, kept to the blocks the phone
/// draws (`MarkdownDocument` in the phone app) so the two apps agree:
///
/// - A paragraph is its lines up to a blank line or a line that opens a
///   list, a table or a quote. As CommonMark has it, a list item opens a list
///   there only with words after its mark and, numbered, only from 1, so a
///   wrapped line that opens with a year stays in its paragraph. A heading
///   is a line of its paragraph.
/// - A list item is a line that opens, after any indent, with `-`, `*` or
///   `+`, or one to nine digits and `.` or `)`, and then a space. A line
///   indented past the list's own items carries on the item before it, blank
///   lines between kept, and the next item may follow blank lines; any other
///   line ends the list. An item indented past the one before it is nested
///   in it, and one indented less is back at the depth that indent opened. A
///   bullet whose words open with `[ ]`, `[x]` or `[X]` and a space is a task.
/// - A table is a line with a `|` over a delimiter row with a `|` and as
///   many cells, each dashes with a colon at either end or both, which say
///   how its column aligns. Its rows are the lines with a `|` after it, up to
///   a blank line or one without; a `\|` in a cell is a `|` in its words, and
///   a row has as many cells as the header, short ones filled with empty
///   cells and extra ones left out.
/// - A quote is its lines that open with `>`, after up to three spaces, up to
///   the first line that does not.
///
/// The words can be cut after a blank line that ends a paragraph, a table or
/// a quote, but not one after a list, which the next item may still carry
/// on, and not the last line, which is still being written: the blocks before
/// the cut are then the blocks of the words before it, whatever follows.
struct ReplyStructure {
    private(set) var blocks: [ReplyBlock] = []
    /// The last place the words can be cut, at the start of the line after
    /// the blank line, nil where there is none.
    private(set) var cut: ReplyReading.Cut?

    private let lines: [Substring]
    /// How a stretch of words reads: inline markdown with its links set.
    private let words: (String) -> AttributedString
    private var index = 0

    init(lines: [Substring], words: @escaping (String) -> AttributedString) {
        self.lines = lines
        self.words = words
        while index < lines.count {
            readBlock()
        }
    }

    private mutating func readBlock() {
        let line = lines[index]
        if Self.isBlank(line) {
            index += 1
            markCut()
        } else if let table = tableOpening(at: index) {
            readTable(table)
        } else if let item = ListLine(line) {
            readList(from: item)
        } else if Self.quoted(line) != nil {
            readQuote()
        } else {
            readParagraph()
        }
    }

    /// A blank line was read: the words can be cut after it, unless it
    /// follows a list or is the last line.
    private mutating func markCut() {
        guard index < lines.count else { return }
        if case .list = blocks.last { return }

        cut = ReplyReading.Cut(index: lines[index].startIndex, blocks: blocks.count)
    }

    // MARK: - Paragraphs and quotes

    private mutating func readParagraph() {
        var paragraph = [lines[index]]
        index += 1
        while index < lines.count, !endsParagraph(at: index) {
            paragraph.append(lines[index])
            index += 1
        }
        blocks.append(.prose(words(paragraph.joined(separator: "\n"))))
    }

    private func endsParagraph(at index: Int) -> Bool {
        let line = lines[index]
        return Self.isBlank(line) || tableOpening(at: index) != nil || ListLine(line)?.interruptsParagraph == true
            || Self.quoted(line) != nil
    }

    private mutating func readQuote() {
        var quote: [Substring] = []
        while index < lines.count, let text = Self.quoted(lines[index]) {
            quote.append(text)
            index += 1
        }
        blocks.append(.quote(words(quote.joined(separator: "\n"))))
    }

    /// A quote line's words, less its indent, its `>` and one space after
    /// it, or nil for any other line.
    private static func quoted(_ line: Substring) -> Substring? {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        guard indent.count <= 3, rest.first == ">" else { return nil }

        let text = rest.dropFirst()
        return text.first == " " ? text.dropFirst() : text
    }

    // MARK: - Lists

    private mutating func readList(from first: ListLine) {
        var nesting = ListNesting(indent: first.indent)
        var items: [(depth: Int, marker: ReplyListMarker, lines: [Substring])] = []
        var blanks = 0
        while index < lines.count {
            let line = lines[index]
            if Self.isBlank(line) {
                blanks += 1
            } else if let item = ListLine(line) {
                let placed = nesting.place(item)
                items.append((placed.depth, placed.marker, [placed.text]))
                blanks = 0
            } else if Self.indent(of: line) > nesting.base {
                items[items.count - 1].lines += Array(repeating: "", count: blanks) + [line.drop(while: Self.isIndent)]
                blanks = 0
            } else {
                break
            }
            index += 1
        }
        // The blank lines after the list are not its own: what follows them
        // reads them.
        index -= blanks

        let read = items.map { ReplyListItem(depth: $0.depth, marker: $0.marker, words: words($0.lines.joined(separator: "\n"))) }
        blocks.append(.list(ReplyList(items: read)))
    }

    // MARK: - Tables

    /// A table's header and how its columns align, where the line at
    /// `index` opens one.
    private struct TableOpening {
        let header: [String]
        let alignments: [ReplyTableAlignment]
    }

    private func tableOpening(at index: Int) -> TableOpening? {
        guard index + 1 < lines.count, lines[index].contains("|"), lines[index + 1].contains("|") else { return nil }

        let header = Self.cells(lines[index])
        let delimiters = Self.cells(lines[index + 1])
        let alignments = delimiters.compactMap(Self.alignment)
        guard delimiters.count == header.count, alignments.count == header.count else { return nil }

        return TableOpening(header: header, alignments: alignments)
    }

    private mutating func readTable(_ opening: TableOpening) {
        index += 2
        var rows: [[String]] = []
        while index < lines.count, !Self.isBlank(lines[index]), lines[index].contains("|") {
            rows.append(Self.fitted(Self.cells(lines[index]), to: opening.header.count))
            index += 1
        }
        let table = ReplyTable(
            alignments: opening.alignments,
            header: opening.header.map(words),
            rows: rows.map { $0.map(words) }
        )
        blocks.append(.table(table))
    }

    /// A row's cells: the line less a `|` at either end, split at each `|`
    /// not escaped, each cell trimmed and its `\|` read as `|`.
    private static func cells(_ line: Substring) -> [String] {
        var row = Substring(line.trimmingCharacters(in: .whitespaces))
        if row.first == "|" { row = row.dropFirst() }
        if row.last == "|", !row.dropLast().hasSuffix("\\") { row = row.dropLast() }

        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in row {
            if character == "|", !escaped {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell)

        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }

    /// How a delimiter cell aligns its column, or nil for a cell that is not
    /// one.
    private static func alignment(_ cell: String) -> ReplyTableAlignment? {
        let leading = cell.hasPrefix(":")
        let trailing = cell.hasSuffix(":")
        let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }

        switch (leading, trailing) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    private static func fitted(_ cells: [String], to count: Int) -> [String] {
        Array(cells.prefix(count)) + Array(repeating: "", count: max(0, count - cells.count))
    }

    // MARK: - Lines

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    fileprivate static func isIndent(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    /// A line's indent in columns, a tab to the next multiple of four.
    fileprivate static func indent(of line: Substring) -> Int {
        line.prefix(while: isIndent).reduce(0) { column, character in
            character == "\t" ? column + 4 - column % 4 : column + 1
        }
    }
}

/// A list item's line: its indent, its number where it is numbered, and its
/// words after its mark.
private struct ListLine {
    let indent: Int
    let number: Int?
    let text: Substring

    init?(_ line: Substring) {
        let rest = line.drop(while: ReplyStructure.isIndent)
        let digits = rest.prefix { ("0"..."9").contains($0) }
        if let mark = rest.first, "-*+".contains(mark) {
            guard let after = rest.dropFirst().first, ReplyStructure.isIndent(after) else { return nil }
            number = nil
            text = rest.dropFirst(2)
        } else {
            let after = rest.dropFirst(digits.count)
            guard (1...9).contains(digits.count), let mark = after.first, mark == "." || mark == ")",
                  let space = after.dropFirst().first, ReplyStructure.isIndent(space)
            else { return nil }
            number = Int(digits)
            text = after.dropFirst(2)
        }
        indent = ReplyStructure.indent(of: line)
    }

    /// Whether the item opens a list straight after a paragraph's line.
    var interruptsParagraph: Bool {
        !text.allSatisfy(\.isWhitespace) && (number ?? 1) == 1
    }
}

/// Where each item of a list sits: how deep, from its indent against the
/// items before it, and the number each depth has reached.
private struct ListNesting {
    /// The indent each depth opened at, the list's own first.
    private var indents: [Int]
    private var numbers: [Int?] = []

    init(indent: Int) {
        indents = [indent]
    }

    /// The indent past which a line carries on the item before it.
    var base: Int { indents[0] }

    mutating func place(_ line: ListLine) -> (depth: Int, marker: ReplyListMarker, text: Substring) {
        let depth = depth(of: line.indent)
        numbers = Array(numbers.prefix(depth + 1)) + Array(repeating: nil, count: max(0, depth + 1 - numbers.count))
        guard let written = line.number else {
            numbers[depth] = nil
            return Self.bullet(line.text, depth: depth)
        }

        let number = numbers[depth].map { $0 + 1 } ?? written
        numbers[depth] = number
        return (depth, .number(number), line.text.drop(while: ReplyStructure.isIndent))
    }

    private mutating func depth(of indent: Int) -> Int {
        while indents.count > 1, let last = indents.last, indent < last {
            indents.removeLast()
        }
        if let last = indents.last, indent > last {
            indents.append(indent)
        } else if indents.count == 1 {
            indents[0] = indent
        }
        return min(indents.count - 1, ReplyList.deepest)
    }

    /// A bullet, or a task where its words open with a box and a space.
    private static func bullet(_ text: Substring, depth: Int) -> (depth: Int, marker: ReplyListMarker, text: Substring) {
        let words = text.drop(while: ReplyStructure.isIndent)
        let box = words.prefix(3)
        guard ["[ ]", "[x]", "[X]"].contains(box), let after = words.dropFirst(3).first, ReplyStructure.isIndent(after) else {
            return (depth, .bullet, words)
        }

        return (depth, .task(done: box != "[ ]"), words.dropFirst(4).drop(while: ReplyStructure.isIndent))
    }
}
