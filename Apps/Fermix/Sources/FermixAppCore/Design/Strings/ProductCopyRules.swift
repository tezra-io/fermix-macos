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
        "ChatGPT", "Claude", "Codex", "OpenAI", "Anthropic", "OpenRouter", "Ollama",
        "Login", "Items", "System", "Settings",
        "Applications", "Homebrew", "Homebrew-managed"
    ]

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
    /// uppercase (the section labels are drawn that way on purpose), or when it
    /// is a proper noun.
    public static func titleCaseOffenders(in value: String) -> [String] {
        var offenders: [String] = []
        var startsSentence = true

        for rawWord in value.split(separator: " ", omittingEmptySubsequences: true) {
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

    /// Strips the punctuation and possessive that ride on a word, so the
    /// proper-noun lookup sees `Telegram` in `Telegram,` and `Mac` in `Mac's`.
    private static func normalize(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)

        return trimmed.hasSuffix("'s") ? String(trimmed.dropLast(2)) : trimmed
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }

        return last == "." || last == "?" || last == ":" || word == "·"
    }
}
