import SwiftUI

extension ChatMetrics {
    /// How far a turn's steps sit in from its line, beside a faint bar.
    static let stepsInset: Double = Spacing.s
    static let stepsBarWidth: Double = 2
    /// Between two steps, and between a step's heading and its words.
    static let stepGap: Double = Spacing.xs
    static let stepHeadingGap: Double = 2
    /// The chevron beside the line that opens the steps.
    static let stepsChevron: Double = 9
}

/// What the turn answering now shows of its work, read from its live events
/// alone (`CompanionTurn`): whether it is working or writing (`ChatTurnStatus`),
/// what it is doing now in a person's words, and every step it said it took.
///
/// What it is doing now is the step a tool is running, in the engine's
/// sentence for it, or the heading of the newest summary of its reasoning,
/// and otherwise that it is thinking. A tool is never named: a daemon that
/// sends no sentence for one shows the turn thinking, as before.
struct ChatTurnProgress: Equatable {
    /// One step, as the list of steps draws it.
    enum Step: Equatable {
        /// A tool's step, in the engine's sentence for it.
        case activity(String)
        /// A summary of the model's reasoning: its heading, where it opens
        /// with a bold line, and the words after it.
        case reasoning(heading: String?, words: String)
    }

    /// Whether the turn is working rather than writing its reply.
    let working: Bool
    /// What it is doing now, while it works.
    let current: String
    /// Every step so far, oldest first, a run of the same step once.
    let steps: [Step]

    init(_ turn: CompanionTurn) {
        working = ChatTurnStatus(turn) == .thinking
        steps = Self.read(turn.steps)
        current = Self.doing(turn, steps: steps)
    }

    /// Whether there is anything to show: a turn at work, or steps to open.
    var shows: Bool {
        working || !steps.isEmpty
    }

    private static func doing(_ turn: CompanionTurn, steps: [Step]) -> String {
        if let tool = turn.tool, tool.phase == .start, let activity = tool.activity {
            return activity
        }
        if case .reasoning(let heading, let words)? = steps.last, turn.tool?.phase != .start {
            return heading ?? words.split(separator: "\n").first.map(String.init) ?? ProductStrings[.chatThinking]
        }
        return ProductStrings[.chatThinking]
    }

    private static func read(_ steps: [CompanionTurnStep]) -> [Step] {
        var read: [Step] = []
        for step in steps {
            let next: Step
            switch step {
            case .activity(let sentence): next = .activity(sentence)
            case .reasoning(let text): next = reasoning(text)
            }
            if read.last != next { read.append(next) }
        }
        return read
    }

    /// A summary's heading is its first line where that line is wholly bold
    /// (`**Comparing hosting options**`), as the provider writes one; the
    /// words are the rest.
    static func reasoning(_ text: String) -> Step {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard first.count > 4, first.hasPrefix("**"), first.hasSuffix("**") else {
            return .reasoning(heading: nil, words: trimmed)
        }

        let heading = String(first.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        let words = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return .reasoning(heading: heading, words: words)
    }
}

/// The line over a turn being written: while it works, what it is doing now
/// with the thinking line's motion (`ThinkingLine`) and how long it has been
/// at it; once it writes, how long it worked. Where the turn said what it
/// did, the line opens the steps under it, each tool's step a line and each
/// summary of its reasoning its heading over its words.
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
                ChatTurnStepView(step: step)
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

/// One step under a turn's line: a tool's step as its sentence, and a
/// summary of the model's reasoning as its heading over its words, its
/// inline markdown read.
private struct ChatTurnStepView: View {
    let step: ChatTurnProgress.Step

    var body: some View {
        switch step {
        case .activity(let sentence):
            Text(sentence)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
        case .reasoning(let heading, let words):
            VStack(alignment: .leading, spacing: ChatMetrics.stepHeadingGap) {
                if let heading {
                    Text(heading)
                        .fermixType(Typography.style(.calloutSmall).weight(.semibold))
                        .foregroundStyle(Palette.secondary.color)
                }
                if !words.isEmpty {
                    Text(Self.inline(words))
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.faint.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func inline(_ words: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: words, options: options)) ?? AttributedString(words)
    }
}
