import Foundation

/// One way a product string can break the voice rules.
public enum CopyViolation: String, CaseIterable, Sendable {
    case emDash
    case exclamationMark
    case pleaseWait
    case supersededProductName
    case placeholder
    case titleCase
}

/// The voice rules, executable.
///
/// They live in the shipping module rather than in the test so there is one
/// rule set: the gate runs them over `ProductStringKey.allCases`, and any
/// future surface that composes copy can run them over what it composed.
public enum ProductCopyRules {
    /// Substrings that are wrong wherever they appear.
    public static let forbiddenSubstrings: [(CopyViolation, String)] = [
        (.emDash, "\u{2014}"),
        (.exclamationMark, "!"),
        (.pleaseWait, "please wait"),
        (.supersededProductName, "fermixpet")
    ]

    /// Copy that was never written, only parked.
    public static let placeholderSubstrings = ["lorem", "todo", "coming soon", "tbd", "placeholder", "xxx"]

    /// The only hand-maintained part of the rules: words that are legitimately
    /// capitalised mid-sentence. The product, the vendors whose names are
    /// proper nouns, and the macOS surfaces the recovery copy has to name
    /// exactly for the instruction to be followable.
    public static let properNouns: Set<String> = [
        "Fermix", "Mac", "Terminal",
        "Setup", "Doctor", "Home", "Logs", "Pet",
        "Telegram", "Slack", "Discord",
        "ChatGPT", "Claude", "Codex", "OpenAI", "Anthropic", "OpenRouter", "Ollama", "Realtime",
        "Google",
        "Login", "Items", "System", "Settings",
        "Applications", "Library", "Launchpad", "Spotlight",
        "Homebrew", "Homebrew-managed"
    ]

    /// Multi-word product names the copy deck spells exactly.
    ///
    /// They are matched as phrases and removed before the word scan, so their
    /// generic halves stay offenders everywhere else. Exempting the bare words
    /// instead would let every future string capitalise `Code` or `Meet`
    /// mid-sentence with the gate silent, which is how an allowlist rots.
    public static let properPhrases: [String] = ["Claude Code", "Google Meet", "Setup Assistant"]

    public static func violations(in value: String) -> Set<CopyViolation> {
        let lowered = value.lowercased()
        var found: Set<CopyViolation> = []

        for (violation, substring) in forbiddenSubstrings where lowered.contains(substring.lowercased()) {
            found.insert(violation)
        }

        if placeholderSubstrings.contains(where: { lowered.contains($0) }) {
            found.insert(.placeholder)
        }

        if !titleCaseOffenders(in: value).isEmpty {
            found.insert(.titleCase)
        }

        return found
    }

    /// Words that are capitalised where sentence case says they should not be.
    ///
    /// A word is exempt when it starts a sentence, when it is entirely
    /// uppercase (the section labels are drawn that way on purpose), when it is
    /// a proper noun, or when it belongs to a proper phrase. Phrases are cut out
    /// whole first, so their trailing punctuation still ends a sentence.
    public static func titleCaseOffenders(in value: String) -> [String] {
        var offenders: [String] = []
        var startsSentence = true

        for rawWord in withoutProperPhrases(value).split(separator: " ", omittingEmptySubsequences: true) {
            let word = normalize(String(rawWord))
            defer { startsSentence = endsSentence(String(rawWord)) }

            guard !startsSentence, !word.isEmpty else { continue }
            guard let first = word.first, first.isUppercase else { continue }
            guard word != word.uppercased() else { continue }
            guard !properNouns.contains(word) else { continue }

            offenders.append(word)
        }

        return offenders
    }

    /// Replaces each proper phrase with a space, so the words around it keep
    /// their positions and the phrase's own words are never scanned.
    private static func withoutProperPhrases(_ value: String) -> String {
        properPhrases.reduce(value) { text, phrase in
            text.replacingOccurrences(of: phrase, with: " ")
        }
    }

    /// Strips the punctuation and possessive that ride on a word, so the
    /// proper-noun lookup sees `Telegram` in `Telegram,` and `Mac` in `Mac’s`.
    ///
    /// Both apostrophes, because the rule is about the possessive rather than
    /// about which mark spells it. The catalogue uses the typographic one, and
    /// a keyed word left with its suffix attached reads as a word nobody
    /// declared: `Fermix’s` was reported as title case.
    private static func normalize(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)

        for possessive in ["\u{2019}s", "'s"] where trimmed.hasSuffix(possessive) {
            return String(trimmed.dropLast(possessive.count))
        }

        return trimmed
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }

        return last == "." || last == "?" || last == ":" || word == "·"
    }

    /// Whether a sentence names a command line, a config file, or an
    /// environment variable (M34 §3.2, §5.8).
    ///
    /// The engine's own readiness and Doctor sentences say `Run mix
    /// fermix.setup …`; a native window must never render one. The boundary is
    /// a word boundary rather than a substring, because "Fermix " ends in
    /// "mix ", and a gate loosened to allow that would fire on nothing.
    public static func namesACommandLine(_ text: String) -> Bool {
        commandLineExpressions.contains { expression in
            expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) > 0
        }
    }

    /// The four patterns, compiled once from literals.
    ///
    /// A pattern that does not compile is a mistake in this file, and a gate
    /// that answered `false` for it would pass by scanning nothing. So it fails
    /// at first use instead.
    private static let commandLineExpressions: [NSRegularExpression] = [
        #"(?<![A-Za-z])mix\s"#,
        #"config\.toml"#,
        #"(?<![A-Za-z])FERMIX_[A-Z_]+"#,
        #"\$[A-Z_]{2,}"#
    ].map { pattern in
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("a copy rule pattern must compile: \(pattern)")
        }

        return expression
    }
}
