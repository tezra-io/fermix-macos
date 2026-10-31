import SwiftUI

extension ChatMetrics {
    /// How far a turn's steps sit in from its line, beside a faint bar.
    static let stepsInset: Double = Spacing.s
    static let stepsBarWidth: Double = 2
    /// Between two steps.
    static let stepGap: Double = Spacing.xxs
    /// The chevron beside the line that opens the steps.
    static let stepsChevron: Double = 9
}

/// What the turn answering now shows of its work, read from its live events
/// alone (`CompanionTurn`): whether it is working or writing (`ChatTurnStatus`),
/// what it is doing now in a person's words, and every step it said it took,
/// each one short line.
///
/// A tool's step is the engine's sentence for it, and a summary of the
/// model's reasoning is its heading alone (owner, 2026-10-31: the heading
/// says enough, the rest is clutter). What it is doing now is the step a tool
/// is running, or the newest summary's heading, and otherwise that it is
/// thinking. A tool is never named: a daemon that sends no sentence for one
/// shows the turn thinking, as before.
struct ChatTurnProgress: Equatable {
    /// Whether the turn is working rather than writing its reply.
    let working: Bool
    /// What it is doing now, while it works.
    let current: String
    /// Every step so far, oldest first, a run of the same step once.
    let steps: [String]

    init(_ turn: CompanionTurn) {
        working = ChatTurnStatus(turn) == .thinking
        steps = Self.read(turn.steps)
        current = Self.doing(turn)
    }

    /// Whether there is anything to show: a turn at work, or steps to open.
    var shows: Bool {
        working || !steps.isEmpty
    }

    private static func doing(_ turn: CompanionTurn) -> String {
        if let tool = turn.tool, tool.phase == .start, let activity = tool.activity {
            return activity
        }
        if case .reasoning(let text)? = turn.steps.last, turn.tool?.phase != .start {
            return heading(of: text) ?? ProductStrings[.chatThinking]
        }
        return ProductStrings[.chatThinking]
    }

    private static func read(_ steps: [CompanionTurnStep]) -> [String] {
        var read: [String] = []
        for step in steps {
            let line: String?
            switch step {
            case .activity(let sentence): line = sentence
            case .reasoning(let text): line = heading(of: text)
            }
            if let line, read.last != line { read.append(line) }
        }
        return read
    }

    /// A summary's heading: its first line, as the provider writes one in
    /// bold (`**Comparing hosting options**`), read as plain words, so a link
    /// in it is words with nothing to open past the chat's check
    /// (`ChatLinkGuard`). A summary with no words has none.
    static func heading(of text: String) -> String? {
        let first = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
        guard let first else { return nil }

        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let line = String(first)
        let read = (try? AttributedString(markdown: line, options: options)).map { String($0.characters) } ?? line
        let words = read.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }
}

/// The line over a turn being written: while it works, what it is doing now
/// with the thinking line's motion (`ThinkingLine`) and how long it has been
/// at it; once it writes, how long it worked. Where the turn said what it
/// did, the line opens the steps under it, one short line each.
struct ChatTurnActivity: View {
    let progress: ChatTurnProgress
    /// When this Mac saw the turn start, and when it started writing.
    let started: Date
    let wrote: Date?

    @State private var open = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if progress.steps.isEmpty {
                line
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
            } else {
                Button {
                    open.toggle()
                } label: {
                    line
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint(ProductStrings[open ? .chatStepsHide : .chatStepsShow])

                if open {
                    steps
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        progress.working ? progress.current : Self.worked(since: started, until: wrote ?? .now)
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            if progress.working {
                ThinkingLine(word: progress.current)
                    .lineLimit(1)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Self.elapsed(since: started, until: context.date))
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.faint.color)
                        .monospacedDigit()
                }
                .accessibilityHidden(true)
            } else {
                Text(Self.worked(since: started, until: wrote ?? .now))
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }

            if !progress.steps.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: ChatMetrics.stepsChevron, weight: .semibold))
                    .foregroundStyle(Palette.faint.color)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.stepGap) {
            ForEach(Array(progress.steps.enumerated()), id: \.offset) { _, step in
                Text(step)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
            }
        }
        .padding(.leading, ChatMetrics.stepsInset)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Palette.hairline(.standard, increaseContrast: contrast == .increased).color)
                .frame(width: ChatMetrics.stepsBarWidth)
        }
        .textSelection(.enabled)
    }

    /// How long the turn has been at it, in minutes and seconds.
    static func elapsed(since start: Date, until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }

    static func worked(since start: Date, until end: Date) -> String {
        String(format: ProductStrings[.chatWorkedFor], elapsed(since: start, until: end))
    }
}
