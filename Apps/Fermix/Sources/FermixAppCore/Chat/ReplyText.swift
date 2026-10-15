import Foundation

/// A row's words as they read, before anything is drawn: every link they
/// carry, and nothing coloured (M66 §3.1). One reading serves the strip,
/// which lists the files and addresses the words link to, and the row,
/// which draws them (`ChatText.drawn`), so the two can never disagree about
/// what is a link.
///
/// Fermix's words are inline markdown, their headings and fenced blocks read
/// inline (`blocksInlined`), with every local path (`ReplyPaths`) and every
/// web address written out (`ReplyLinks`) a link. A person's words are drawn
/// as they typed them, so they are read as plain text: only the paths and
/// addresses written out in them count, and no markdown is read into them.
struct ReplyText: Equatable {
    /// The words with their links set.
    let attributed: AttributedString

    /// Fermix's words, `~` read as `home`.
    init(markdown text: String, home: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let inlined = Self.blocksInlined(text)
        let parsed = (try? AttributedString(markdown: inlined, options: options)) ?? AttributedString(inlined)
        attributed = ReplyPaths.linked(ReplyLinks.linked(parsed), home: home)
    }

    /// A person's words, `~` read as `home`.
    init(plain text: String, home: String) {
        attributed = ReplyPaths.linked(ReplyLinks.linked(AttributedString(text)), home: home)
    }

    /// Every link, in reading order, a link drawn over several runs (a bold
    /// word inside it) counted once.
    var links: [URL] {
        attributed.runs[\.link].compactMap { link, _ in link }
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

    /// Inline markdown only; blocks and tables are read as the text they are,
    /// except the two block marks read inline: a heading line, one to six `#`
    /// then a space then its text, becomes that text strongly emphasised, and
    /// a fenced code block loses its fence lines while each line inside
    /// becomes a code span. A reply is a conversation, and those two marks
    /// read as noise on the ground rather than as structure (owner,
    /// 2026-09-28). Every other line is left as it is.
    static func blocksInlined(_ text: String) -> String {
        var fenced = false
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                if line.hasPrefix("```") {
                    fenced.toggle()
                    return nil
                }
                if fenced { return codeSpan(line) }
                return heading(line).map { "**\($0)**" } ?? String(line)
            }
            .joined(separator: "\n")
    }

    /// The text of a heading line, or nil for any other line.
    private static func heading(_ line: Substring) -> String? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count), line.dropFirst(marks.count).first == " " else { return nil }
        let title = line.dropFirst(marks.count + 1).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// One line of a fenced block as a code span; a line with its own
    /// backtick takes the two-backtick fence, and an empty line stays empty.
    private static func codeSpan(_ line: Substring) -> String {
        if line.isEmpty { return "" }
        return line.contains("`") ? "`` \(line) ``" : "`\(line)`"
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
