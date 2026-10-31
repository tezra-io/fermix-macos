import Foundation
import Testing

@testable import FermixAppCore

/// The line over a turn being written says what it is doing in a person's
/// words, read off the turn's own events, and lists every step it said it
/// took; a tool is never named.
@Suite("Turn activity")
struct ChatTurnActivityTests {
    private static func turn(
        text: String = "",
        tool: CompanionToolEvent? = nil,
        steps: [CompanionTurnStep] = []
    ) -> ChatTurnProgress {
        var turn = CompanionTurn(turnId: "turn-1", inReplyTo: nil, text: text, tool: tool)
        turn.steps = steps
        return ChatTurnProgress(turn)
    }

    private static func tool(_ phase: CompanionToolPhase, activity: String? = "Searching the web") -> CompanionToolEvent {
        CompanionToolEvent(turnId: "turn-1", tool: "web_search", phase: phase, detail: nil, activity: phase == .start ? activity : nil)
    }

    @Test("a running tool's step is said in the engine's words, and a tool with none is thinking")
    func runningTool() {
        let running = Self.turn(tool: Self.tool(.start), steps: [.activity("Searching the web")])
        let unsaid = Self.turn(tool: Self.tool(.start, activity: nil))

        #expect(running.working)
        #expect(running.current == "Searching the web")
        #expect(unsaid.current == ProductStrings[.chatThinking])
        #expect(!unsaid.current.contains("web_search"))
    }

    @Test("after a tool stops the turn is thinking, and a newer summary of its reasoning says its heading")
    func afterTool() {
        let stopped = Self.turn(tool: Self.tool(.stop), steps: [.activity("Searching the web")])
        let reasoned = Self.turn(
            tool: Self.tool(.stop),
            steps: [.activity("Searching the web"), .reasoning("**Comparing the options**\n\nTwo of them fit.")]
        )

        #expect(stopped.current == ProductStrings[.chatThinking])
        #expect(reasoned.current == "Comparing the options")
    }

    @Test("a summary's bold first line is its heading, and one with none is its words")
    func headings() {
        #expect(ChatTurnProgress.reasoning("**Checking the calendar**\n\nToday's events first.") == .reasoning(heading: "Checking the calendar", words: "Today's events first."))
        #expect(ChatTurnProgress.reasoning("Looking at the **calendar** first.") == .reasoning(heading: nil, words: "Looking at the **calendar** first."))
        #expect(ChatTurnProgress.reasoning("**Only a heading**") == .reasoning(heading: "Only a heading", words: ""))
    }

    @Test("a run of the same step shows once, and steps keep their order")
    func steps() {
        let progress = Self.turn(steps: [.activity("Searching the web"), .activity("Searching the web"), .activity("Reading a web page"), .activity("Searching the web")])

        #expect(progress.steps == [.activity("Searching the web"), .activity("Reading a web page"), .activity("Searching the web")])
    }

    @Test("a turn writing with no steps shows nothing, and one with steps keeps its line")
    func shows() {
        #expect(!Self.turn(text: "So far").shows)
        #expect(Self.turn(text: "So far", steps: [.activity("Searching the web")]).shows)
        #expect(!Self.turn(text: "So far", steps: [.activity("Searching the web")]).working)
        #expect(Self.turn().shows)
    }

    /// A summary is the model's words, which a page it read can shape: its
    /// links are read as words, never opened past the chat's check.
    @Test("a summary's links are its words, with nothing to open")
    func noLiveLinks() {
        let words = ChatTurnStepView.inline("See [your bank](https://bank-login.example/verify) and **this**.")

        #expect(String(words.characters) == "See your bank and this.")
        #expect(words.runs.allSatisfy { $0.link == nil })
        #expect(words.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test("how long a turn worked is said in minutes and seconds")
    func elapsed() {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        #expect(ChatTurnActivity.elapsed(since: start, until: start.addingTimeInterval(72)) == Duration.seconds(72).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
        #expect(ChatTurnActivity.elapsed(since: start, until: start.addingTimeInterval(-5)) == Duration.seconds(0).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
        #expect(ChatTurnActivity.worked(since: start, until: start.addingTimeInterval(9)).hasPrefix(String(ProductStrings[.chatWorkedFor].prefix(6))))
    }
}
