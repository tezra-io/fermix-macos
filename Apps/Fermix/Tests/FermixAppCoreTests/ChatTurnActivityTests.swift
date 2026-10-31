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

    /// A step is one short line: a summary shows its heading alone, never
    /// the words under it (owner, 2026-10-31).
    @Test("a summary is its heading alone, its first line read as plain words")
    func headings() {
        #expect(ChatTurnProgress.heading(of: "**Checking the calendar**\n\nToday's events first.") == "Checking the calendar")
        #expect(ChatTurnProgress.heading(of: "\n\nLooking at the **calendar** first.\nThen the rest.") == "Looking at the calendar first.")
        #expect(ChatTurnProgress.heading(of: "  \n ") == nil)
    }

    @Test("a run of the same step shows once, steps keep their order, and a summary's step is its heading")
    func steps() {
        let progress = Self.turn(steps: [
            .activity("Searching the web"), .activity("Searching the web"), .activity("Reading a web page"),
            .reasoning("**Comparing the options**\n\nTwo of them fit, and the third pauses between turns."),
            .activity("Searching the web"),
        ])

        #expect(progress.steps == ["Searching the web", "Reading a web page", "Comparing the options", "Searching the web"])
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
        #expect(ChatTurnProgress.heading(of: "**See [your bank](https://bank-login.example/verify)**\n\nMore.") == "See your bank")
    }

    @Test("how long a turn worked is said in minutes and seconds")
    func elapsed() {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        #expect(ChatTurnActivity.elapsed(since: start, until: start.addingTimeInterval(72)) == Duration.seconds(72).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
        #expect(ChatTurnActivity.elapsed(since: start, until: start.addingTimeInterval(-5)) == Duration.seconds(0).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
        #expect(ChatTurnActivity.worked(since: start, until: start.addingTimeInterval(9)).hasPrefix(String(ProductStrings[.chatWorkedFor].prefix(6))))
    }
}
