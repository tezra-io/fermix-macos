import Foundation
import Testing

@testable import FermixAppCore

/// When a look reads the page, decided from fingerprints, from
/// how many navigations WebKit has started, and from the time each step was
/// taken, which every case hands in: nothing here sleeps or reads a clock.
@Suite("Browser page settle")
struct BrowserPageSettleTests {
    private static func glance(
        url: String = "https://example.com/",
        elements: Int = 40,
        text: Int = 1_200,
        loading: Bool = false,
        navigations: Int = 0
    ) -> BrowserPageSettle.Glance {
        BrowserPageSettle.Glance(
            fingerprint: BrowserPageFingerprint(url: url, title: "Example", elements: elements, text: text, focus: 0, ready: "complete"),
            loading: loading,
            navigations: navigations
        )
    }

    private static func at(_ milliseconds: Int) -> Duration { .milliseconds(milliseconds) }

    /// What is left of a budget of `budget` ms at `elapsed` ms.
    private static func left(_ budget: Int, at elapsed: Int) -> Duration { .milliseconds(budget - elapsed) }

    /// A glance's bound with `budget` ms of budget at `elapsed` ms: what is
    /// left plus the response grace.
    private static func bound(_ budget: Int, at elapsed: Int) -> Duration { .milliseconds(budget - elapsed + 250) }

    /// The look after a navigation begun with `navigations` started, whose
    /// own navigation committed `milliseconds` into it.
    private static func committed(from navigations: Int, at milliseconds: Int = 0) -> BrowserPageSettle {
        var settle = BrowserPageSettle.afterNavigation(from: navigations)
        _ = settle.afterCommit(true, at: at(milliseconds))
        return settle
    }

    @Test("the budgets are the engine's act limits, and an act's longest look fits its act timeout")
    func budgetsMirrorTheEngine() {
        #expect(BrowserPageSettle.settleBudget == .milliseconds(1_500))
        #expect(BrowserPageSettle.navigationBudget == .milliseconds(4_000))
        #expect(BrowserPageSettle.restWindow == .milliseconds(150))
        #expect(BrowserPageSettle.responseGrace == .milliseconds(250))
        #expect(BrowserPageSettle.navigationTimeout == .seconds(30))
        let observedActTimeout = Duration.milliseconds(8_000) + BrowserPageSettle.settleBudget
        #expect(BrowserPageSettle.settleBudget + BrowserPageSettle.navigationBudget + BrowserPageSettle.responseGrace < observedActTimeout)
    }

    // MARK: - After an act

    @Test("an act's look glances at once, bounded by the whole settle budget plus the response grace")
    func actOpensWithAGlance() {
        let settle = BrowserPageSettle.afterAct(from: Self.glance())

        #expect(settle.opening == .glance(Self.bound(1_500, at: 0)))
    }

    @Test("a page that never moves is polled with what is left of the settle budget, then answers unchanged and is not read")
    func neverMovesIsUnchanged() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance())

        for elapsed in stride(from: 50, to: 1_500, by: 50) {
            #expect(settle.next(Self.glance(), at: Self.at(elapsed)) == .poll(Self.left(1_500, at: elapsed)))
        }
        #expect(settle.next(Self.glance(), at: Self.at(1_500)) == .unchanged)
    }

    @Test("a page that moves then rests is read once it has held still for the rest window, not at its first change")
    func movesThenRestsIsReadAfterItRests() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(elements: 40))

        #expect(settle.next(Self.glance(elements: 40), at: Self.at(50)) == .poll(Self.left(1_500, at: 50)))
        #expect(settle.next(Self.glance(elements: 52), at: Self.at(100)) == .poll(Self.left(1_500, at: 100)), "the first change, a spinner, is not read")
        #expect(settle.next(Self.glance(elements: 60), at: Self.at(150)) == .poll(Self.left(1_500, at: 150)), "the page is still rendering")
        #expect(settle.next(Self.glance(elements: 60), at: Self.at(200)) == .poll(Self.left(1_500, at: 200)))
        #expect(settle.next(Self.glance(elements: 60), at: Self.at(250)) == .poll(Self.left(1_500, at: 250)))
        #expect(settle.next(Self.glance(elements: 60), at: Self.at(300)) == .read, "held since 150 ms, for the whole rest window")
    }

    @Test("a change of text alone is a move, and the page is read once it rests rather than called unchanged")
    func textOnlyChangeIsSeen() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(elements: 40, text: 1_200))

        #expect(settle.next(Self.glance(elements: 40, text: 1_260), at: Self.at(50)) == .poll(Self.left(1_500, at: 50)))
        #expect(settle.next(Self.glance(elements: 40, text: 1_260), at: Self.at(150)) == .poll(Self.left(1_500, at: 150)))
        #expect(settle.next(Self.glance(elements: 40, text: 1_260), at: Self.at(200)) == .read)
    }

    @Test("a page that never rests is read as it stands once the settle budget is spent")
    func neverRestsIsReadAtTheBudget() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(elements: 40))

        for elapsed in stride(from: 50, to: 1_500, by: 50) {
            #expect(settle.next(Self.glance(elements: 40 + elapsed), at: Self.at(elapsed)) == .poll(Self.left(1_500, at: elapsed)))
        }
        #expect(settle.next(Self.glance(elements: 9_999), at: Self.at(1_500)) == .read)
    }

    @Test("a navigation the act starts is a move, and a load still in flight at the navigation budget is read as it stands")
    func slowLoadIsReadAtItsBudget() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance())

        #expect(settle.next(Self.glance(loading: true, navigations: 1), at: Self.at(50)) == .awaitLoad(.milliseconds(4_000)))
        #expect(settle.next(Self.glance(loading: true, navigations: 1), at: Self.at(4_050)) == .read, "never an error, never unobserved")
    }

    @Test("a load that finishes inside its budget is followed by the rest before the page is read")
    func finishedLoadThenRests() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance())
        let next = Self.glance(url: "https://example.com/next", elements: 80, navigations: 1)

        #expect(settle.next(Self.glance(loading: true, navigations: 1), at: Self.at(50)) == .awaitLoad(.milliseconds(4_000)))
        #expect(settle.next(next, at: Self.at(900)) == .poll(Self.left(4_050, at: 900)))
        #expect(settle.next(next, at: Self.at(1_000)) == .poll(Self.left(4_050, at: 1_000)))
        #expect(settle.next(next, at: Self.at(1_050)) == .read)
    }

    @Test("glances taken while the act's load is in flight never count toward the rest, though the new document reads the same as the old")
    func loadingGlancesBreakTheRest() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(elements: 40))

        #expect(settle.next(Self.glance(elements: 41), at: Self.at(50)) == .poll(Self.left(1_500, at: 50)))
        #expect(settle.next(Self.glance(elements: 41, loading: true, navigations: 1), at: Self.at(100)) == .awaitLoad(.milliseconds(4_000)))
        #expect(settle.next(Self.glance(elements: 41, loading: true, navigations: 1), at: Self.at(300)) == .awaitLoad(Self.left(4_100, at: 300)))
        #expect(settle.next(Self.glance(elements: 41, navigations: 1), at: Self.at(900)) == .poll(Self.left(4_100, at: 900)), "the rest starts after the load, not at 50 ms")
        #expect(settle.next(Self.glance(elements: 41, navigations: 1), at: Self.at(1_000)) == .poll(Self.left(4_100, at: 1_000)))
        #expect(settle.next(Self.glance(elements: 41, navigations: 1), at: Self.at(1_050)) == .read)
    }

    @Test("a load already in flight before the act, with nothing else changing, is not a move")
    func loadInFlightBeforeTheActIsNoMove() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(loading: true, navigations: 3))

        for elapsed in stride(from: 50, to: 1_500, by: 50) {
            #expect(settle.next(Self.glance(loading: true, navigations: 3), at: Self.at(elapsed)) == .poll(Self.left(1_500, at: elapsed)))
        }
        #expect(settle.next(Self.glance(loading: true, navigations: 3), at: Self.at(1_500)) == .unchanged)
    }

    @Test("an act that changes a page still loading something from before is read once the page rests, without waiting for that load")
    func loadInFlightBeforeTheActIsNotWaitedFor() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(elements: 40, loading: true, navigations: 3))

        #expect(settle.next(Self.glance(elements: 41, loading: true, navigations: 3), at: Self.at(50)) == .poll(Self.left(1_500, at: 50)))
        #expect(settle.next(Self.glance(elements: 41, loading: true, navigations: 3), at: Self.at(150)) == .poll(Self.left(1_500, at: 150)))
        #expect(settle.next(Self.glance(elements: 41, loading: true, navigations: 3), at: Self.at(200)) == .read, "the stalled load gets no navigation budget")
    }

    @Test("a navigation the act starts on a page already loading is a move before it commits, and is waited for")
    func navigationOverALoadInFlightIsAMove() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(loading: true, navigations: 3))
        let next = Self.glance(url: "https://example.com/next", elements: 80, navigations: 4)

        #expect(settle.next(Self.glance(loading: true, navigations: 4), at: Self.at(50)) == .awaitLoad(.milliseconds(4_000)), "not unchanged, though the old document still shows")
        #expect(settle.next(next, at: Self.at(2_000)) == .poll(Self.left(4_050, at: 2_000)))
        #expect(settle.next(next, at: Self.at(2_150)) == .read)
    }

    @Test("an act's look ends within the settle budget, the response grace and the navigation budget, however late its load is seen")
    func lateLoadIsBounded() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance(elements: 40))

        #expect(settle.next(Self.glance(elements: 41), at: Self.at(1_450)) == .poll(Self.left(1_500, at: 1_450)))
        #expect(settle.afterWait(at: Self.at(1_499)) == .glance(.milliseconds(251)), "the last glance may answer at 1,750 ms")
        let step = settle.next(Self.glance(elements: 41, loading: true, navigations: 1), at: Self.at(1_750))

        #expect(step == .awaitLoad(.milliseconds(4_000)))
        #expect(settle.afterWait(at: Self.at(5_750)) == .read)
        #expect(Self.at(5_750) == BrowserPageSettle.settleBudget + BrowserPageSettle.responseGrace + BrowserPageSettle.navigationBudget)
    }

    @Test("a navigation the act started gets its budget even when the glance that shows it answers past the settle budget")
    func navigationSeenPastTheSettleBudgetIsWaitedFor() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance())

        #expect(settle.next(Self.glance(), at: Self.at(1_450)) == .poll(Self.left(1_500, at: 1_450)))
        #expect(settle.next(Self.glance(loading: true, navigations: 1), at: Self.at(1_505)) == .awaitLoad(.milliseconds(4_000)), "not the document being left")
        #expect(settle.next(Self.glance(url: "https://example.com/next", navigations: 1), at: Self.at(2_000)) == .poll(Self.left(5_505, at: 2_000)))
    }

    @Test("a second load in the same look gets no budget of its own")
    func oneLoadBudgetPerLook() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance())

        #expect(settle.next(Self.glance(loading: true, navigations: 1), at: Self.at(50)) == .awaitLoad(.milliseconds(4_000)))
        #expect(settle.next(Self.glance(elements: 80, navigations: 1), at: Self.at(600)) == .poll(Self.left(4_050, at: 600)))
        #expect(settle.next(Self.glance(elements: 80, loading: true, navigations: 2), at: Self.at(650)) == .awaitLoad(.milliseconds(3_400)))
    }

    // MARK: - After a wait

    @Test("a wait that ends with budget left is followed by a glance bounded by what is left plus the response grace")
    func waitEndsInAGlance() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance())

        #expect(settle.afterWait(at: Self.at(1_400)) == .glance(Self.bound(1_500, at: 1_400)))
        #expect(settle.afterWait(at: Self.at(1_499)) == .glance(Self.bound(1_500, at: 1_499)), "never cut below the grace")
        #expect(settle.next(Self.glance(loading: true, navigations: 1), at: Self.at(1_000)) == .awaitLoad(.milliseconds(4_000)))
        #expect(settle.afterWait(at: Self.at(3_000)) == .glance(Self.bound(5_000, at: 3_000)), "the load's budget is the look's now")
    }

    @Test("a budget spent by a wait ends the look with no glance: read if the page moved, unchanged if it never did")
    func spentBudgetEndsTheLook() {
        var moved = BrowserPageSettle.afterAct(from: Self.glance(elements: 40))
        let still = BrowserPageSettle.afterAct(from: Self.glance(elements: 40))

        #expect(moved.next(Self.glance(elements: 41), at: Self.at(1_400)) == .poll(Self.left(1_500, at: 1_400)))
        #expect(moved.afterWait(at: Self.at(1_500)) == .read)
        #expect(still.afterWait(at: Self.at(1_500)) == .unchanged)
        #expect(still.afterWait(at: Self.at(1_520)) == .unchanged)
        #expect(Self.committed(from: 0).afterWait(at: Self.at(4_000)) == .read)
    }

    @Test("a failed load fails an act's look, which cannot say what the act did, and has no step of its own there")
    func failedLoadAfterAnAct() {
        var settle = BrowserPageSettle.afterAct(from: Self.glance())

        #expect(settle.afterFailedLoad() == nil)
        #expect(settle.next(Self.glance(loading: true, navigations: 1), at: Self.at(50)) == .awaitLoad(.milliseconds(4_000)))
        #expect(settle.afterFailedLoad() == nil)
    }

    @Test("a navigation's own load failing fails it, and a later one failing ends the look on the document shown")
    func failedLoadAfterANavigation() {
        var settle = Self.committed(from: 2)

        #expect(settle.afterFailedLoad() == nil, "the opening load is the request's own")
        #expect(settle.next(Self.glance(navigations: 3), at: Self.at(600)) == .poll(Self.left(4_000, at: 600)))
        #expect(settle.next(Self.glance(loading: true, navigations: 4), at: Self.at(700)) == .awaitLoad(Self.left(4_000, at: 700)))
        #expect(settle.afterFailedLoad() == .read)
    }

    // MARK: - After a navigation

    @Test("the look after a navigation first waits for its own navigation to commit, for at most the navigation timeout")
    func navigationOpensWithItsCommit() {
        #expect(BrowserPageSettle.afterNavigation(from: 2).opening == .awaitCommit(.seconds(30)))
        #expect(BrowserPageSettle.afterNavigation(from: 2, timeout: .milliseconds(50)).opening == .awaitCommit(.milliseconds(50)))
    }

    @Test("the navigation budget starts at the commit, so a response that took 25 s to arrive still gets its 4 s of load")
    func navigationBudgetStartsAtTheCommit() {
        var settle = BrowserPageSettle.afterNavigation(from: 2)
        let next = Self.glance(url: "https://example.com/next", navigations: 3)

        #expect(settle.afterCommit(true, at: Self.at(25_000)) == .awaitLoad(.milliseconds(4_000)), "its load, before its first glance")
        #expect(settle.afterWait(at: Self.at(26_000)) == .glance(Self.bound(29_000, at: 26_000)))
        #expect(settle.next(next, at: Self.at(26_100)) == .poll(Self.left(29_000, at: 26_100)))
        #expect(settle.afterWait(at: Self.at(29_000)) == .read, "read as it stands once the budget from the commit is spent")
    }

    @Test("a navigation that never commits within the timeout fails, and the page is never read")
    func navigationThatNeverCommitsFails() {
        var settle = BrowserPageSettle.afterNavigation(from: 2)
        var short = BrowserPageSettle.afterNavigation(from: 2, timeout: .milliseconds(50))

        #expect(settle.afterCommit(false, at: Self.at(30_000)) == .neverCommitted(within: .seconds(30)))
        #expect(short.afterCommit(false, at: Self.at(50)) == .neverCommitted(within: .milliseconds(50)))
    }

    @Test("the look after a navigation reads once the loaded page holds still")
    func navigationLoadsThenRests() {
        var settle = Self.committed(from: 2)

        #expect(settle.next(Self.glance(elements: 80, navigations: 3), at: Self.at(700)) == .poll(Self.left(4_000, at: 700)))
        #expect(settle.next(Self.glance(elements: 80, navigations: 3), at: Self.at(800)) == .poll(Self.left(4_000, at: 800)))
        #expect(settle.next(Self.glance(elements: 80, navigations: 3), at: Self.at(850)) == .read)
    }

    @Test("a navigation the page starts after its load is waited on, with only what is left of the budget")
    func navigationStillLoadingWaitsAgain() {
        var settle = Self.committed(from: 2)
        let next = Self.glance(url: "https://example.com/next", navigations: 4)

        #expect(settle.next(Self.glance(url: "https://example.com/next", loading: true, navigations: 4), at: Self.at(600)) == .awaitLoad(Self.left(4_000, at: 600)))
        #expect(settle.next(next, at: Self.at(1_200)) == .poll(Self.left(4_000, at: 1_200)))
        #expect(settle.next(next, at: Self.at(1_350)) == .read)
    }

    @Test("a navigation still loading when the navigation budget is spent is read as it stands")
    func navigationStillLoadingIsReadAtTheBudget() {
        var settle = Self.committed(from: 2)

        #expect(settle.next(Self.glance(url: "about:blank", elements: 3, loading: true, navigations: 3), at: Self.at(4_000)) == .read)
    }

    @Test("the look after a navigation has moved by definition, so it never answers unchanged")
    func navigationNeverUnchanged() {
        var settle = Self.committed(from: 2)

        #expect(settle.next(Self.glance(navigations: 3), at: Self.at(0)) == .poll(Self.left(4_000, at: 0)))
        #expect(settle.next(Self.glance(navigations: 3), at: Self.at(150)) == .read)
    }
}
