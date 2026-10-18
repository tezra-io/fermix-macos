import SwiftUI

/// The empty state's greeting: the time of day from the Mac's own clock, and
/// the person's first name where About you saved one.
enum ChatGreeting {
    /// The phrase for an hour of the day, 0 to 23.
    static func phrase(hour: Int) -> ProductStringKey {
        switch hour {
        case 5..<12: return .chatGreetingMorning
        case 12..<18: return .chatGreetingAfternoon
        default: return .chatGreetingEvening
        }
    }

    static func text(hour: Int, userName: String?) -> String {
        let phrase = ProductStrings[phrase(hour: hour)]
        guard let name = userName.flatMap(firstName) else { return phrase }

        return ProductStrings.commaPair(phrase, name)
    }

    /// The given name inside the name the person saved, as the system reads a
    /// person's name. A blank name has none.
    static func firstName(_ userName: String) -> String? {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return PersonNameComponentsFormatter().personNameComponents(from: trimmed)?.givenName
    }

    /// The name About you saved, as the daemon's `personalization` section
    /// publishes it: the same row the assistant writes and the Personality
    /// pane shows, read through the one settings model.
    @MainActor
    static func userName(in settings: SettingsModel) -> String? {
        let row = settings.section(AboutYouAnswers.personalizationSection).value?.rows
            .first { $0.key == AboutYouAnswers.nameKey }
        guard case .text(let name)? = row?.value else { return nil }

        return name
    }
}

/// Who wrote a row or a hit, in the words the product uses for the two sides
/// of a conversation. A role this build has no word for is shown as the
/// daemon wrote it.
enum ChatSpeaker {
    static let user = CompanionProtocol.userRole

    static func name(role: String?) -> String {
        switch role {
        case user?: return ProductStrings[.voiceCaptionSpeakerUser]
        case CompanionProtocol.assistantRole?, nil: return ProductStrings[.voiceCaptionSpeakerAssistant]
        case let other?: return other
        }
    }

    static func isUser(_ role: String?) -> Bool {
        role == user
    }
}

/// The turn answering now, as one of two quiet states: thinking, from
/// `turn_started` until reply text starts arriving and again whenever a tool
/// it called is running; and quiet, while it writes. A tool is never named:
/// the reader sees Fermix thinking, not the call it made.
///
/// Every case is read straight off `CompanionTurn`'s own fields: nothing here
/// is a fact of its own, so a provider's own lifecycle (carried, today, as a
/// `tool_event` naming no real tool) is never matched by name to reach it.
enum ChatTurnStatus: Equatable {
    case thinking
    case quiet

    init(_ turn: CompanionTurn) {
        self = turn.text.isEmpty || turn.tool?.phase == .start ? .thinking : .quiet
    }
}

/// Reply text as it is drawn: a row's words as they read (`ReplyText`),
/// coloured, and a search's matches marked where the reader was sent to them.
/// A link opens through the surface's content link opener, in the pane or the
/// person's own browser, or, for a local path, as the file it names.
enum ChatText {
    /// The blank line between two paragraphs drawn as one text.
    private static let paragraphBreak = "\n\n"

    /// Each block of the words drawn (`drawn(_:marking:)`).
    static func drawn(_ reply: ReplyText) -> [ReplyBlock] {
        reply.blocks.map { drawn($0) }
    }

    /// A block drawn: every stretch of its words in their links' colours with
    /// their inline code on a faint fill, and a search's matches marked; code
    /// as it was written, which its own block colours and marks (`code`).
    static func drawn(_ block: ReplyBlock, marking terms: [String] = []) -> ReplyBlock {
        block.mappingWords { marking(terms, in: drawn($0)) }
    }

    /// A run of paragraphs drawn as one text, as a block's words are, with
    /// a blank line between each two.
    static func paragraphs(_ run: [AttributedString], marking terms: [String]) -> AttributedString {
        marking(terms, in: joined(run.map(drawn), by: paragraphBreak))
    }

    /// Words drawn in their links' colours. A markdown link's own words are
    /// the text blue, `accentText`, which holds §9's floor on the dark
    /// ground: left to the window's tint they would be the accent, which
    /// does not. A path or an address written out is the text it is, so it
    /// keeps the reply's own `ink`, because blue on every path read as noise,
    /// and is underlined in `faint`, because ink alone passed for plain text
    /// (owner, 2026-10-04; M66 §3.1). A code span sits on a faint fill
    /// (`codeSpanFill`), which marks it as code without changing the line's
    /// height.
    private static func drawn(_ words: AttributedString) -> AttributedString {
        var drawn = words
        for run in words.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                drawn[run.range].backgroundColor = Palette.codeSpanFill.color
            }
            guard run.link != nil else { continue }

            if run[ReplyWrittenLink.self] == true {
                drawn[run.range].foregroundColor = Palette.ink.color
                drawn[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: Palette.faint.color)
            } else {
                drawn[run.range].foregroundColor = Palette.accentText.color
            }
        }

        return drawn
    }

    /// A code block's text as it is drawn: the reply's ink, its comments
    /// faint, and its keywords, strings and numbers each in its muted tone
    /// (`CodeHighlight`), with a search's matches marked.
    static func code(_ code: ReplyCode, marking terms: [String]) -> AttributedString {
        var drawn = AttributedString()
        var plain = code.text.startIndex
        for token in CodeHighlight.tokens(in: code.text, language: code.language) {
            drawn += AttributedString(String(code.text[plain..<token.range.lowerBound]))
            var coloured = AttributedString(String(code.text[token.range]))
            coloured.foregroundColor = colour(of: token.kind).color
            drawn += coloured
            plain = token.range.upperBound
        }
        drawn += AttributedString(String(code.text[plain...]))

        return marking(terms, in: drawn)
    }

    private static func colour(of kind: CodeTokenKind) -> ThemedColor {
        switch kind {
        case .keyword: return Palette.codeKeyword
        case .string: return Palette.codeString
        case .number: return Palette.codeNumber
        case .comment: return Palette.faint
        }
    }

    /// The blocks as one text, for a place that draws a row's words as one, a
    /// voice note's transcript: each part a row draws (`ChatReplyPart`) on
    /// lines of its own, a run of paragraphs as a row draws it, code as code,
    /// a list's items each after its mark (`ChatListBlock.label`) and a
    /// table's rows as Copy writes them.
    static func oneText(_ blocks: [ReplyBlock]) -> AttributedString {
        joined(ChatReplyPart.parts(of: blocks).map(oneText), by: "\n")
    }

    private static func oneText(_ part: ChatReplyPart) -> AttributedString {
        switch part {
        case .paragraphs(let run): return joined(run, by: paragraphBreak)
        case .block(let block): return oneText(block)
        }
    }

    private static func oneText(_ block: ReplyBlock) -> AttributedString {
        switch block {
        case .prose(let words), .quote(let words):
            return words
        case .code(let code):
            return codeLines(code)
        case .list(let list):
            return joined(list.items.map { AttributedString(ChatListBlock.label($0) + " ") + $0.words }, by: "\n")
        case .table(let table):
            return joined(([table.header] + table.rows).map { joined($0, by: "\t") }, by: "\n")
        }
    }

    /// The parts one after another, the separator between each two.
    private static func joined(_ parts: [AttributedString], by separator: String) -> AttributedString {
        parts.enumerated().reduce(into: AttributedString()) { text, part in
            if part.offset > 0 { text += AttributedString(separator) }
            text += part.element
        }
    }

    private static func codeLines(_ code: ReplyCode) -> AttributedString {
        var lines = AttributedString(code.text)
        lines.inlinePresentationIntent = .code
        return lines
    }

    static func plain(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    /// Every occurrence of each term, marked. Case is ignored, as the search
    /// that found them ignored it.
    static func marking(_ terms: [String], in text: AttributedString) -> AttributedString {
        var marked = text
        for term in terms where !term.isEmpty {
            var searchStart = marked.startIndex
            while let found = marked[searchStart...].range(of: term, options: .caseInsensitive) {
                marked[found].inlinePresentationIntent = .stronglyEmphasized
                marked[found].foregroundColor = Palette.accentText.color
                searchStart = found.upperBound
            }
        }

        return marked
    }
}

/// A reply's blocks as a row draws them: each run of paragraphs one text, a
/// blank line between each two as they were written, so a reader selects
/// across them and the line between them follows the type; and every other
/// block on its own.
enum ChatReplyPart: Equatable {
    /// A run of paragraphs, in reading order.
    case paragraphs([AttributedString])
    case block(ReplyBlock)

    static func parts(of blocks: [ReplyBlock]) -> [ChatReplyPart] {
        var parts: [ChatReplyPart] = []
        for block in blocks {
            guard let words = block.prose else {
                parts.append(.block(block))
                continue
            }
            if case .paragraphs(let run)? = parts.last {
                parts[parts.count - 1] = .paragraphs(run + [words])
            } else {
                parts.append(.paragraphs([words]))
            }
        }

        return parts
    }
}

/// A search hit's excerpt, with the ranges the daemon matched.
///
/// The ranges count Unicode scalar values, not characters, so they are walked
/// over the scalars. A range that runs past the excerpt names text the excerpt
/// does not have and marks nothing.
enum ChatExcerpt {
    static func ranges(of hit: CompanionSearchHit) -> [Range<String.Index>] {
        let scalars = hit.excerpt.unicodeScalars

        return hit.ranges.compactMap { match in
            guard match.start >= 0, match.length > 0,
                  let start = scalars.index(scalars.startIndex, offsetBy: match.start, limitedBy: scalars.endIndex),
                  let end = scalars.index(start, offsetBy: match.length, limitedBy: scalars.endIndex)
            else { return nil }

            return start..<end
        }
    }

    static func terms(of hit: CompanionSearchHit) -> [String] {
        ranges(of: hit).map { String(hit.excerpt[$0]) }
    }

    static func attributed(_ hit: CompanionSearchHit) -> AttributedString {
        var attributed = AttributedString(hit.excerpt)
        for range in ranges(of: hit) {
            guard let marked = Range(range, in: attributed) else { continue }

            attributed[marked].inlinePresentationIntent = .stronglyEmphasized
            attributed[marked].foregroundColor = Palette.accentText.color
        }

        return attributed
    }
}

/// When a hit was written, in this Mac's own zone and format. A time the
/// parser refuses is shown as the daemon wrote it, the only thing known about
/// it, as a log line's is.
enum ChatTime {
    static func written(_ wire: String) -> String {
        guard let moment = try? Date(wire, strategy: .iso8601) else { return wire }

        return moment.formatted(date: .abbreviated, time: .shortened)
    }
}
