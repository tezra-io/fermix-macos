import Foundation
import Testing

@testable import FermixAppCore

/// A code block's colours come from a small scanner: comments, strings,
/// numbers and each language's keywords, nothing else, and never a failure.
/// Odd input costs time in proportion to its length.
@Suite("Code highlight")
struct CodeHighlightTests {
    /// Each coloured stretch as its kind and its text.
    private static func tokens(_ text: String, _ language: String?) -> [String] {
        CodeHighlight.tokens(in: text, language: language).map { token in
            "\(token.kind) \(text[token.range])"
        }
    }

    private static func kinds(_ text: String, _ language: String?, _ kind: CodeTokenKind) -> [String] {
        CodeHighlight.tokens(in: text, language: language).filter { $0.kind == kind }.map { String(text[$0.range]) }
    }

    // MARK: - Languages

    @Test("shell: comments only at a word's start, both quotes, numbers and its keywords")
    func shell() {
        let text = "#!/bin/bash\n# list\nif [ -f a#b ]; then ls \"$HOME/x\" 'it''s' ${#arr} 42; fi # done"

        #expect(Self.tokens(text, "bash") == [
            "comment #!/bin/bash", "comment # list", "keyword if", "keyword then", "string \"$HOME/x\"",
            "string 'it'", "string 's'", "number 42", "keyword fi", "comment # done",
        ])
        #expect(Self.tokens("echo 'a \\' b", "sh") == ["string 'a \\'"])
    }

    @Test("Python: triple-quoted strings over lines, comments, numbers and keywords")
    func python() {
        let text = "def f(x=1.5e3):\n    \"\"\"Doc\n    more\"\"\"\n    return f\"{x}\" if x else None  # why"

        #expect(Self.tokens(text, "python") == [
            "keyword def", "number 1.5e3", "string \"\"\"Doc\n    more\"\"\"", "keyword return", "string \"{x}\"",
            "keyword if", "keyword else", "keyword None", "comment # why",
        ])
    }

    @Test("Swift: line and block comments, multi-line strings and keywords")
    func swift() {
        let text = "/* top */\nlet s = \"\"\"\n  a \"q\"\n  \"\"\" // end\nfunc go() -> Int { return 0x1F }"

        #expect(Self.tokens(text, "swift") == [
            "comment /* top */", "keyword let", "string \"\"\"\n  a \"q\"\n  \"\"\"", "comment // end",
            "keyword func", "keyword return", "number 0x1F",
        ])
    }

    @Test("JavaScript and TypeScript: template strings over lines and both languages' keywords")
    func javaScript() {
        let text = "const t = `a\n${b}` // c\ninterface A { x: number }"

        #expect(Self.tokens(text, "ts") == ["keyword const", "string `a\n${b}`", "comment // c", "keyword interface"])
        #expect(Self.kinds("let a = 'x'", "javascript", .string) == ["'x'"])
    }

    @Test("JSON: keys and values as strings, numbers, and its three words")
    func json() {
        #expect(Self.tokens("{\"a\": -1.5, \"b\": [true, null]}", "json") == [
            "string \"a\"", "number 1.5", "string \"b\"", "keyword true", "keyword null",
        ])
    }

    @Test("Elixir: a string with an interpolation is one string, and its block words are keywords")
    func elixir() {
        let text = "defmodule A do\n  def b, do: \"x #{y}\" # c\nend"

        #expect(Self.tokens(text, "elixir") == [
            "keyword defmodule", "keyword do", "keyword def", "keyword do", "string \"x #{y}\"", "comment # c", "keyword end",
        ])
    }

    @Test("Go: a rune, a raw string over lines and its keywords")
    func go() {
        let text = "func main() {\n\tr := 'a'\n\ts := `raw\nline`\n}"

        #expect(Self.tokens(text, "go") == ["keyword func", "string 'a'", "string `raw\nline`"])
    }

    /// A Rust lifetime is a single quote with no partner close by, and is
    /// no string.
    @Test("Rust: a character is a string, a lifetime is not")
    func rust() {
        let text = "fn f<'a>(x: &'a str) -> char { let mut c = '\\n'; c }"

        #expect(Self.tokens(text, "rust") == ["keyword fn", "keyword let", "keyword mut", "string '\\n'"])
    }

    @Test("SQL: keywords in any case, its own comment mark and doubled quotes")
    func sql() {
        let text = "SELECT name FROM t WHERE n > 10 -- big\nand s = 'it''s'"

        #expect(Self.tokens(text, "sql") == [
            "keyword SELECT", "keyword FROM", "keyword WHERE", "number 10", "comment -- big", "keyword and",
            "string 'it'", "string 's'",
        ])
    }

    @Test("YAML: comments, strings, numbers and its three words")
    func yaml() {
        #expect(Self.tokens("on: push # when\nport: 8080\nname: \"x\"\ndebug: true", "yml") == [
            "comment # when", "number 8080", "string \"x\"", "keyword true",
        ])
    }

    @Test("HTML and CSS: their comments and strings, a size a number, and a colour no comment")
    func htmlAndCSS() {
        #expect(Self.tokens("<!-- c --><a href=\"x\">Don't</a>", "html") == ["comment <!-- c -->", "string \"x\""])
        #expect(Self.tokens("a { color: #fff; margin: 10px } /* c */", "css") == ["number 10px", "comment /* c */"])
    }

    /// A language this scanner does not know, or none, gets strings,
    /// numbers and the commonest comments, and no keywords. An address's
    /// `//` is no comment, nor is an apostrophe a string.
    @Test("an unknown or absent language: strings, numbers and comments only")
    func unknown() {
        let text = "if x then 'y' # c\ncurl https://a.com/x // c\nDon't panic, 3 left"

        for language in [nil, "brainfuck"] {
            #expect(Self.tokens(text, language) == ["string 'y'", "comment # c", "comment // c", "number 3"])
        }
    }

    // MARK: - Names

    /// A block's header and VoiceOver name the language a fence's tag is,
    /// by its common spellings in any case.
    @Test("a fence's common tags name their language", arguments: [
        ("sh", "Shell"), ("bash", "Shell"), ("zsh", "Shell"), ("shell", "Shell"), ("console", "Shell"),
        ("py", "Python"), ("python", "Python"), ("Python3", "Python"),
        ("js", "JavaScript"), ("jsx", "JavaScript"), ("mjs", "JavaScript"),
        ("ts", "TypeScript"), ("tsx", "TypeScript"),
        ("swift", "Swift"), ("json", "JSON"), ("yaml", "YAML"), ("yml", "YAML"), ("html", "HTML"), ("css", "CSS"),
        ("sql", "SQL"), ("rb", "Ruby"), ("go", "Go"), ("rs", "Rust"), ("ex", "Elixir"), ("exs", "Elixir"),
        ("kt", "Kotlin"), ("java", "Java"), ("c", "C"), ("cpp", "C++"), ("c++", "C++"), ("cc", "C++"), ("hpp", "C++"),
        ("cs", "C#"), ("csharp", "C#"), ("md", "Markdown"), ("diff", "Diff"), ("toml", "TOML"), ("xml", "XML"),
        ("dockerfile", "Dockerfile"), ("Makefile", "Makefile"), ("ps1", "PowerShell"), ("powershell", "PowerShell"),
        ("BASH", "Shell"), ("JSON", "JSON"),
    ])
    func languageNames(_ tag: String, _ name: String) {
        #expect(CodeLanguage.name(of: tag) == name)
    }

    @Test("a tag it does not know names itself as written")
    func unknownTagsAsWritten() {
        for tag in ["brainfuck", "Nim", "c--"] {
            #expect(CodeLanguage(tag: tag) == nil)
            #expect(CodeLanguage.name(of: tag) == tag)
        }
    }

    /// One owner of which language a tag is: no spelling is two languages'.
    @Test("no tag is given to two languages")
    func tagsAreOneLanguagesEach() {
        let tags = CodeLanguage.allCases.flatMap(\.tags)

        #expect(tags.count == Set(tags).count)
        #expect(tags.allSatisfy { $0 == $0.lowercased() })
    }

    @Test("VoiceOver names a block by its language's name, and a block with no language as code")
    func spokenLanguage() {
        #expect(ChatCodeBlock.label(of: ReplyCode(language: "py", text: "x = 1")) == ProductStrings.commaPair(ProductStrings[.chatCode], "Python"))
        #expect(ChatCodeBlock.label(of: ReplyCode(language: "nim", text: "x")) == ProductStrings.commaPair(ProductStrings[.chatCode], "nim"))
        #expect(ChatCodeBlock.label(of: ReplyCode(language: nil, text: "x")) == ProductStrings[.chatCode])
    }

    // MARK: - Hostile input

    @Test("a string never closed is no string, and a quote inside another is part of it")
    func oddQuotes() {
        #expect(Self.tokens("print(\"abc", "python").isEmpty)
        #expect(Self.tokens("say \"it's 'fine' \\\"ok\\\"\" now", nil) == ["string \"it's 'fine' \\\"ok\\\"\""])
        #expect(Self.tokens("a = \"x\\\nb\"", "python") == [])
        #expect(Self.tokens("/* open", "go") == ["comment /* open"])
        #expect(Self.tokens("x = \"\"\"never", "python") == ["string \"\"\"never"])
    }

    @Test("characters outside ASCII are words and parts of strings, never cut")
    func unicode() {
        let text = "naïve = \"café ☕️\" # 日本 é\nlet 変数 = 1"

        #expect(Self.tokens(text, "python") == ["string \"café ☕️\"", "comment # 日本 é", "number 1"])
        #expect(Self.tokens(text, "swift") == ["string \"café ☕️\"", "keyword let", "number 1"])
    }

    /// Each line is a hundred thousand characters or more of what makes a
    /// naive scanner quadratic or lose its place; together they take well
    /// under the bound, and every token lies inside its text.
    @Test("a hundred-thousand-character line of odd input is read in time proportional to it")
    func longLines() {
        let lines = [
            String(repeating: "a'", count: 50_000),
            String(repeating: "\"\\", count: 50_000),
            String(repeating: "x = \"", count: 25_000),
            String(repeating: "'", count: 100_000),
            String(repeating: "\"", count: 100_001),
            String(repeating: "/*", count: 50_000),
            String(repeating: "1", count: 100_000),
            String(repeating: "if ", count: 40_000),
            String(repeating: "'\\", count: 50_000),
            String(repeating: "é\"", count: 50_000),
        ]
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for line in lines {
                for language in [nil, "python", "rust", "sh", "sql"] {
                    let tokens = CodeHighlight.tokens(in: line, language: language)
                    #expect(tokens.allSatisfy { $0.range.upperBound <= line.endIndex })
                }
            }
        }

        #expect(elapsed < .seconds(10))
    }
}
