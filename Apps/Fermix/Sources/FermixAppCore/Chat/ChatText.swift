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
    static let user = "user"

    static func name(role: String?) -> String {
        switch role {
        case user?: return ProductStrings[.voiceCaptionSpeakerUser]
        case "assistant"?, nil: return ProductStrings[.voiceCaptionSpeakerAssistant]
        case let other?: return other
        }
    }

    static func isUser(_ role: String?) -> Bool {
        role == user
    }
}

/// A turn's latest tool call as one quiet line.
enum ChatToolLine {
    static func sentence(_ tool: CompanionToolEvent) -> String {
        switch tool.phase {
        case .start: return String(format: ProductStrings[.chatToolRunningFormat], tool.tool)
        case .stop: return String(format: ProductStrings[.chatToolFinishedFormat], tool.tool)
        case .unrecognized: return tool.tool
        }
    }
}

/// Reply text as it is drawn: SwiftUI's inline markdown, with its links
/// live, and a search's matches marked where the reader was sent to them. A
/// link opens through the surface's content link opener, in the pane or the
/// person's own browser.
enum ChatText {
    /// Inline markdown only; blocks and tables are drawn as the text they are.
    static func reply(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
