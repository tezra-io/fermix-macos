import Foundation

/// What a stretch of code is, which its colour follows (`ChatText.code`).
enum CodeTokenKind: Equatable {
    case keyword
    case string
    case number
    case comment
}

/// One coloured stretch of a code block.
struct CodeToken: Equatable {
    let kind: CodeTokenKind
    let range: Range<String.Index>
}

/// The stretches of a code block worth a colour, read by a small scanner
/// rather than a grammar: comments, strings, numbers, and the keywords of the
/// languages Fermix writes. Everything else is plain.
///
/// It is restrained on purpose (the code should read as code, not glow), and
/// it never fails: every byte is looked at a bounded number of times, so odd
/// input (a string never closed, quotes inside quotes, one line of a hundred
/// thousand characters) costs time in proportion to its length and is drawn
/// as well as it can be. A string that does not close on its own line is not
/// a string, so an apostrophe in a log line colours nothing; a string that may
/// run over lines (three quotes, a backtick) runs to the end when it is never
/// closed, as one does while a reply is still being written.
enum CodeHighlight {
    /// The coloured stretches of `text`, in order, none overlapping.
    static func tokens(in text: String, language: String?) -> [CodeToken] {
        var scanner = CodeScanner(bytes: Array(text.utf8), syntax: CodeSyntax.named(language))
        return indexed(scanner.scan(), in: text)
    }

    /// The scanner's byte offsets as indices into the text, walked once from
    /// the start. Every offset is on a character's first byte: a stretch only
    /// starts or ends beside an ASCII mark, and a word runs over the bytes of
    /// any character outside ASCII.
    private static func indexed(_ spans: [(kind: CodeTokenKind, start: Int, end: Int)], in text: String) -> [CodeToken] {
        let utf8 = text.utf8
        var index = utf8.startIndex
        var offset = 0
        func advance(to target: Int) -> String.Index {
            index = utf8.index(index, offsetBy: target - offset)
            offset = target
            return index
        }

        return spans.map { span in
            let start = advance(to: span.start)
            return CodeToken(kind: span.kind, range: start..<advance(to: span.end))
        }
    }
}

/// How one family of languages writes the four things the scanner colours.
struct CodeSyntax {
    /// What starts a comment to the end of its line. It counts only at the
    /// start of a line or after a space, so `a#b`, `${#x}` and the `//` of an
    /// address are not comments.
    var lineComments: [String] = []
    var blockComments: [(open: String, close: String)] = []
    /// The quotes a string opens with that ends on its own line.
    var quotes: [UInt8] = [UInt8(ascii: "\""), UInt8(ascii: "'")]
    /// The quotes whose strings may run over lines: three quotes, a backtick.
    var longQuotes: [String] = []
    /// The quotes with no escapes inside: a shell's single quote.
    var rawQuotes: [UInt8] = []
    /// Rust's and Go's single quote: a character, closed within a few bytes,
    /// or else not a string at all (a Rust lifetime, `'a`).
    var characterQuote = false
    var keywords: Set<String> = []
    /// SQL's keywords are any case.
    var keywordsIgnoreCase = false

    /// The syntax a fence's language names, by its common spellings; an
    /// unknown or absent language gets strings, numbers and the commonest
    /// comments, and no keywords.
    static func named(_ language: String?) -> CodeSyntax {
        switch language?.lowercased() {
        case "sh", "bash", "zsh", "shell", "console", "shellscript", "terminal", "ksh", "fish": return shell
        case "python", "py", "python3", "ipython": return python
        case "swift": return swift
        case "javascript", "js", "jsx", "mjs", "cjs", "node", "typescript", "ts", "tsx": return javaScript
        case "json", "jsonc", "json5": return json
        case "elixir", "ex", "exs", "iex": return elixir
        case "go", "golang": return go
        case "rust", "rs": return rust
        case "sql", "postgres", "postgresql", "psql", "mysql", "sqlite": return sql
        case "yaml", "yml", "toml": return yaml
        case "html", "htm", "xml", "svg", "xhtml": return html
        case "css", "scss", "less": return css
        default: return unknown
        }
    }

    private static let cBlock = [(open: "/*", close: "*/")]

    static let unknown = CodeSyntax(lineComments: ["#", "//"], blockComments: cBlock)

    static let shell = CodeSyntax(
        lineComments: ["#"],
        rawQuotes: [UInt8(ascii: "'")],
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
            "function", "return", "export", "local", "readonly", "set", "unset", "source", "exit", "break",
            "continue",
        ]
    )

    static let python = CodeSyntax(
        lineComments: ["#"],
        longQuotes: ["\"\"\"", "'''"],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
            "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
            "or", "pass", "raise", "return", "try", "while", "with", "yield", "True", "False", "None", "self",
            "match", "case",
        ]
    )

    static let swift = CodeSyntax(
        lineComments: ["//"],
        blockComments: cBlock,
        quotes: [UInt8(ascii: "\"")],
        longQuotes: ["\"\"\""],
        keywords: [
            "actor", "any", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
            "defer", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func",
            "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "private",
            "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct",
            "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while",
        ]
    )

    static let javaScript = CodeSyntax(
        lineComments: ["//"],
        blockComments: cBlock,
        longQuotes: ["`"],
        keywords: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
            "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if",
            "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch",
            "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
            "interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "as",
            "declare", "namespace", "abstract", "keyof",
        ]
    )

    static let json = CodeSyntax(quotes: [UInt8(ascii: "\"")], keywords: ["true", "false", "null"])

    static let elixir = CodeSyntax(
        lineComments: ["#"],
        longQuotes: ["\"\"\"", "'''"],
        keywords: [
            "after", "alias", "and", "case", "catch", "cond", "def", "defp", "defmodule", "defmacro",
            "defmacrop", "defstruct", "defprotocol", "defimpl", "defdelegate", "defguard", "do", "else", "end",
            "fn", "for", "if", "import", "in", "not", "or", "quote", "raise", "receive", "require", "rescue",
            "try", "unless", "unquote", "use", "when", "with", "true", "false", "nil",
        ]
    )

    static let go = CodeSyntax(
        lineComments: ["//"],
        blockComments: cBlock,
        quotes: [UInt8(ascii: "\"")],
        longQuotes: ["`"],
        characterQuote: true,
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
            "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
            "struct", "switch", "type", "var", "true", "false", "nil", "iota",
        ]
    )

    static let rust = CodeSyntax(
        lineComments: ["//"],
        blockComments: cBlock,
        quotes: [UInt8(ascii: "\"")],
        characterQuote: true,
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
            "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
            "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
            "where", "while",
        ]
    )

    static let sql = CodeSyntax(
        lineComments: ["--"],
        blockComments: cBlock,
        keywords: [
            "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete",
            "create", "table", "drop", "alter", "add", "index", "on", "join", "left", "right", "inner", "outer",
            "full", "cross", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "union",
            "all", "null", "is", "in", "like", "between", "case", "when", "then", "else", "end", "exists",
            "primary", "key", "foreign", "references", "default", "unique", "with", "returning", "true", "false",
            "asc", "desc", "begin", "commit", "rollback", "view", "if",
        ],
        keywordsIgnoreCase: true
    )

    static let yaml = CodeSyntax(lineComments: ["#"], keywords: ["true", "false", "null"])

    static let html = CodeSyntax(blockComments: [(open: "<!--", close: "-->")])

    static let css = CodeSyntax(
        blockComments: cBlock,
        keywords: ["important", "inherit", "initial", "unset", "none", "auto"]
    )
}

/// One pass over a code block's bytes. A position is looked at once in the
/// main walk; a string that fails to close on its line is looked at once more
/// to find that out, and the next quote of its kind on the same line knows at
/// once it cannot close either, so no byte is read more than a few times.
private struct CodeScanner {
    let bytes: [UInt8]
    let syntax: CodeSyntax

    private var spans: [(kind: CodeTokenKind, start: Int, end: Int)] = []
    /// For each quote, the line end before which it is known not to close.
    private var unclosedUntil: [UInt8: Int] = [:]
    private let longestKeyword: Int
    /// The syntax's marks as bytes, read once rather than at every position.
    private let lineComments: [[UInt8]]
    private let blockComments: [(open: [UInt8], close: [UInt8])]
    private let longQuotes: [[UInt8]]

    init(bytes: [UInt8], syntax: CodeSyntax) {
        self.bytes = bytes
        self.syntax = syntax
        longestKeyword = syntax.keywords.map(\.utf8.count).max() ?? 0
        lineComments = syntax.lineComments.map { Array($0.utf8) }
        blockComments = syntax.blockComments.map { (Array($0.open.utf8), Array($0.close.utf8)) }
        longQuotes = syntax.longQuotes.map { Array($0.utf8) }
    }

    /// Characters the characterQuote rule allows between its quotes: an escape
    /// with what it names (`'\n'`, `'\u{1F600}'`), or one character.
    private static let characterReach = 12

    mutating func scan() -> [(kind: CodeTokenKind, start: Int, end: Int)] {
        var position = 0
        while position < bytes.count {
            position = step(at: position)
        }
        return spans
    }

    /// Reads what starts at `position` and answers where the next thing starts.
    private mutating func step(at position: Int) -> Int {
        if let end = blockComment(at: position) ?? lineComment(at: position) {
            return mark(.comment, from: position, to: end)
        }
        if let end = string(at: position) {
            return mark(.string, from: position, to: end)
        }
        let byte = bytes[position]
        if Self.isDigit(byte), !follows(word: position) {
            return mark(.number, from: position, to: run(from: position, while: Self.isNumberByte))
        }
        if Self.isWordByte(byte) {
            let end = run(from: position, while: Self.isWordByte)
            return isKeyword(from: position, to: end) ? mark(.keyword, from: position, to: end) : end
        }
        return position + 1
    }

    private mutating func mark(_ kind: CodeTokenKind, from start: Int, to end: Int) -> Int {
        spans.append((kind, start, end))
        return end
    }

    // MARK: - Comments

    private func blockComment(at position: Int) -> Int? {
        for (open, close) in blockComments where matches(open, at: position) {
            return find(close, from: position + open.count).map { $0 + close.count } ?? bytes.count
        }
        return nil
    }

    private func lineComment(at position: Int) -> Int? {
        guard startsWord(position), lineComments.contains(where: { matches($0, at: position) }) else { return nil }

        return lineEnd(from: position)
    }

    /// A line comment counts at the start of a line or after a space.
    private func startsWord(_ position: Int) -> Bool {
        position == 0 || Self.isSpace(bytes[position - 1])
    }

    // MARK: - Strings

    private mutating func string(at position: Int) -> Int? {
        for long in longQuotes where matches(long, at: position) {
            return closing(long, from: position + long.count) ?? bytes.count
        }
        let quote = bytes[position]
        if syntax.characterQuote, quote == UInt8(ascii: "'") {
            return character(at: position)
        }
        guard syntax.quotes.contains(quote) else { return nil }

        return lineString(quote, at: position)
    }

    /// A string that ends on its own line, or nil where it does not close
    /// there, which is then remembered for the rest of the line.
    private mutating func lineString(_ quote: UInt8, at position: Int) -> Int? {
        if let until = unclosedUntil[quote], position < until { return nil }

        let escapes = !syntax.rawQuotes.contains(quote)
        var index = position + 1
        while index < bytes.count, !Self.isNewline(bytes[index]) {
            let byte = bytes[index]
            if byte == quote { return index + 1 }
            index += escapes && byte == UInt8(ascii: "\\") && index + 1 < bytes.count && !Self.isNewline(bytes[index + 1]) ? 2 : 1
        }
        unclosedUntil[quote] = index
        return nil
    }

    /// A string that may run over lines, closed by the quote it opened with;
    /// nil where it never closes.
    private func closing(_ quote: [UInt8], from start: Int) -> Int? {
        let escapes = quote != [UInt8(ascii: "`")]
        var index = start
        while index < bytes.count {
            if escapes, bytes[index] == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if matches(quote, at: index) { return index + quote.count }
            index += 1
        }
        return nil
    }

    /// A character literal, `'a'` or `'\n'`, closed within a few bytes; any
    /// other single quote is plain.
    private func character(at position: Int) -> Int? {
        let reach = min(bytes.count, position + Self.characterReach)
        var index = position + 1
        guard index < reach, bytes[index] != UInt8(ascii: "'") else { return nil }

        if bytes[index] == UInt8(ascii: "\\") {
            index += 2
            while index < reach, bytes[index] != UInt8(ascii: "'"), !Self.isNewline(bytes[index]) { index += 1 }
        } else {
            index += Self.scalarLength(bytes[index])
        }
        return index < reach && bytes[index] == UInt8(ascii: "'") ? index + 1 : nil
    }

    // MARK: - Words

    private func isKeyword(from start: Int, to end: Int) -> Bool {
        guard end - start <= longestKeyword else { return false }

        let word = String(decoding: bytes[start..<end], as: UTF8.self)
        return syntax.keywords.contains(syntax.keywordsIgnoreCase ? word.lowercased() : word)
    }

    /// Whether a digit is inside a word (`utf8`, `x2`), and so no number.
    private func follows(word position: Int) -> Bool {
        position > 0 && Self.isWordByte(bytes[position - 1])
    }

    // MARK: - Bytes

    private func run(from start: Int, while belongs: (UInt8) -> Bool) -> Int {
        var index = start
        while index < bytes.count, belongs(bytes[index]) { index += 1 }
        return index
    }

    private func lineEnd(from start: Int) -> Int {
        run(from: start) { !Self.isNewline($0) }
    }

    private func find(_ mark: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if matches(mark, at: index) { return index }
            index += 1
        }
        return nil
    }

    private func matches(_ mark: [UInt8], at position: Int) -> Bool {
        guard position + mark.count <= bytes.count else { return false }

        for offset in mark.indices where bytes[position + offset] != mark[offset] {
            return false
        }
        return true
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || byte >= 0x80
    }

    /// A number runs over digits, letters, `_` and `.`: `0x1F`, `1_000`,
    /// `2.5e10`, `10px`, `3u8`.
    private static func isNumberByte(_ byte: UInt8) -> Bool {
        (isWordByte(byte) && byte < 0x80 && byte != UInt8(ascii: "$")) || byte == UInt8(ascii: ".")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || isNewline(byte)
    }

    private static func isNewline(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    /// How many bytes the character a lead byte starts takes.
    private static func scalarLength(_ byte: UInt8) -> Int {
        switch byte {
        case 0xF0...: return 4
        case 0xE0...: return 3
        case 0xC0...: return 2
        default: return 1
        }
    }
}
