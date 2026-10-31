import Foundation

/// When a look at a page reads it: the pane's half of the
/// engine's settle, decided from the page's fingerprints, from how many
/// navigations WebKit has started, and from the time since the look began,
/// which the caller hands in at every step. It reads no clock and touches no
/// page: `WebKitPageActions` glances, sleeps, waits for a commit or a load
/// and reads the page, and asks this what to do first (`opening`), after the
/// wait for a commit (`afterCommit`), after each other wait (`afterWait`),
/// after each glance (`next`), and when a load it waited on fails
/// (`afterFailedLoad`).
///
/// - The look after an act glances at once, and waits up to `settleBudget`
///   for the page to move off the glance taken just before the act's input.
///   A page that never moves is `unchanged` and is not read. A navigation
///   WebKit starts after that glance is a move.
/// - The look after `tab.open` or `tab.navigate` has moved by definition. It
///   first waits for its own navigation to commit, for at most
///   `navigationTimeout`, and one that never commits fails the request. Its
///   `navigationBudget` starts at that commit, and it waits for the load
///   before its first glance: a glance taken sooner sees the document being
///   left, and can fail with it as WebKit swaps processes.
/// - Once the page has moved, a navigation started since the look began and
///   still in flight is waited for, and the first one seen gets
///   `navigationBudget` from when it was seen. A load that was already in
///   flight before the look, an image that never arrives say, is not waited
///   for: it is not what the look is about.
/// - The page is read once its fingerprint has held for `restWindow` with no
///   such navigation in flight, or as it stands once the look's budget is
///   spent. A glance taken while one is in flight never counts toward the
///   rest: it shows the document being left, or one still being built.
///
/// Every wait is bounded by what is left of the look's budget, the wait for
/// a navigation's commit by its timeout, and every glance by what is left
/// plus `responseGrace`: one clock. A budget spent before a
/// glance ends the look without one, and past its budget a look answers
/// `read` or `unchanged` and nothing else, which is what ends the glances.
public struct BrowserPageSettle: Sendable {
    /// `settle_budget_ms` in the engine's `Config.act_limits/0`
    /// (`apps/fermix_core/lib/fermix_core/browser/config.ex`): how long the
    /// look after an act waits for the page to move, and how long an explicit
    /// `page.snapshot` waits for a load in flight.
    public static let settleBudget: Duration = .milliseconds(1_500)
    /// `navigation_budget_ms` there: the look after `tab.open` or
    /// `tab.navigate`, from its navigation's commit, and the load of a
    /// navigation an observed act started, from when a glance first shows it.
    /// Like the engine's, the budgets bound the decision clock, not the wall
    /// clock: a glance taken as a budget runs out may answer a response grace
    /// past it, and the read that follows takes the page script's own bound.
    /// An act's look decides within `settleBudget` plus `responseGrace` plus
    /// this, 5.75 s, since the last glance of its settle budget may be the
    /// one that first shows its navigation: well inside the engine's
    /// observed-act timeout (`action_timeout_ms` plus `settle_budget_ms`).
    public static let navigationBudget: Duration = .milliseconds(4_000)
    /// `navigation_timeout_ms` in the engine's browser config (`config.ex`
    /// there): how long `Page.navigate` waits for its navigation to commit,
    /// and how long the look after `tab.open` or `tab.navigate` waits for its
    /// own. One that never commits within it fails the request.
    public static let navigationTimeout: Duration = .seconds(30)
    /// `rest_ms` there: how long the fingerprint holds before the page is read.
    public static let restWindow: Duration = .milliseconds(150)
    /// `cdp_response_grace_ms` in the engine's browser config: how long a
    /// glance may answer past what is left of the look's budget, as the
    /// engine's own probes do, so one taken as the budget runs out is not cut
    /// off before a live page can answer.
    public static let responseGrace: Duration = .milliseconds(250)

    /// One look at the page.
    public struct Glance: Equatable, Sendable {
        public var fingerprint: BrowserPageFingerprint
        /// Whether WebKit has a navigation in flight, which the fingerprint
        /// cannot see until the new document commits.
        public var loading: Bool
        /// How many navigations WebKit has started in the page so far: one
        /// started since an earlier glance raised it, whatever the page was
        /// loading before.
        public var navigations: Int

        public init(fingerprint: BrowserPageFingerprint, loading: Bool, navigations: Int) {
            self.fingerprint = fingerprint
            self.loading = loading
            self.navigations = navigations
        }
    }

    /// What the look does next.
    public enum Step: Equatable, Sendable {
        /// Glance at the page now, for at most this long: what is left of the
        /// look's budget plus `responseGrace`.
        case glance(Duration)
        /// Wait for the look's own navigation to commit, for at most this
        /// long, then ask `afterCommit`.
        case awaitCommit(Duration)
        /// Pause for the poll interval, or for what is left of the budget if
        /// that is shorter, then ask `afterWait`.
        case poll(Duration)
        /// Wait for the navigation in flight to finish, for at most what is
        /// left of the budget, then ask `afterWait`.
        case awaitLoad(Duration)
        /// The look is over: read the page now.
        case read
        /// The look is over: the page never moved, so it is not read.
        case unchanged
        /// The look's own navigation did not commit within this timeout: the
        /// request fails, and the page is not read.
        case neverCommitted(within: Duration)
    }

    /// The glance an act's look judges a move against; nil for a
    /// navigation's look, which has moved by definition.
    private let before: Glance?
    /// How many navigations WebKit had started when the look began: one
    /// started since is the look's to wait for.
    private let baseline: Int
    private var moved: Bool
    /// Whether the look has glanced at the page yet, which a navigation's
    /// look does only once its own load is over.
    private var glanced = false
    /// When the page is read as it stands if it has not come to rest; for a
    /// navigation's look, until its commit, when its wait for it gives up.
    private var readBy: Duration
    /// Whether a navigation in flight has had its budget: once per look.
    private var loadBudgeted: Bool
    /// The fingerprint the page has held since `heldSince`, with no
    /// navigation the look waits for in flight.
    private var held: BrowserPageFingerprint?
    private var heldSince: Duration = .zero

    /// The look after an act the engine observes, judged against the glance
    /// taken just before the act's input.
    public static func afterAct(from before: Glance) -> BrowserPageSettle {
        BrowserPageSettle(before: before, baseline: before.navigations, readBy: settleBudget, loadBudgeted: false)
    }

    /// The look after `tab.open` or `tab.navigate`, begun when WebKit had
    /// started `navigations` navigations in the page, whose own navigation
    /// has `timeout` to commit: `navigationTimeout` but in a test.
    public static func afterNavigation(from navigations: Int, timeout: Duration = navigationTimeout) -> BrowserPageSettle {
        BrowserPageSettle(before: nil, baseline: navigations, readBy: timeout, loadBudgeted: true)
    }

    private init(before: Glance?, baseline: Int, readBy: Duration, loadBudgeted: Bool) {
        self.before = before
        self.baseline = baseline
        moved = before == nil
        self.readBy = readBy
        self.loadBudgeted = loadBudgeted
    }

    /// The look's first step: a navigation's look waits for its own
    /// navigation to commit, and an act's look glances at once.
    public var opening: Step {
        before == nil ? .awaitCommit(readBy) : .glance(readBy + Self.responseGrace)
    }

    /// The step after a navigation's look waited `elapsed` for its own
    /// navigation to commit: the navigation budget from the commit, spent
    /// first on its load, or, with no commit, the request's failure.
    /// `committed` is true too for a navigation that ended without failing
    /// and without a commit, which leaves the page as it stands.
    public mutating func afterCommit(_ committed: Bool, at elapsed: Duration) -> Step {
        precondition(before == nil, "only the look after a navigation waits for a commit")
        guard committed else { return .neverCommitted(within: readBy) }

        readBy = elapsed + Self.navigationBudget
        return .awaitLoad(Self.navigationBudget)
    }

    /// The step after a wait that ended `elapsed` into the look: a glance
    /// bounded by what is left of the budget plus `responseGrace`, or, with
    /// the budget spent, the end of the look without one.
    public func afterWait(at elapsed: Duration) -> Step {
        guard elapsed < readBy else { return moved ? .read : .unchanged }

        return .glance(readBy - elapsed + Self.responseGrace)
    }

    /// The step after a load the look waited on failed. A navigation's look
    /// whose own load already finished, with a glance taken since, reads the
    /// document the page still shows: a later navigation failing is not the
    /// request failing. Anything else has no step here, and the failure
    /// stands: a navigation's own load failing fails it, and an act's look
    /// cannot say what the act did.
    public func afterFailedLoad() -> Step? {
        before == nil && glanced ? .read : nil
    }

    /// The next step, for `glance` taken `elapsed` into the look. The first
    /// navigation the look waits for gets its budget however late a glance
    /// shows it, even one that answers past the budget it was taken in.
    public mutating func next(_ glance: Glance, at elapsed: Duration) -> Step {
        glanced = true
        if !moved {
            guard hasMoved(glance) else { return elapsed < readBy ? .poll(readBy - elapsed) : .unchanged }
            moved = true
        }
        if isAwaited(glance), !loadBudgeted { return awaitLoad(at: elapsed) }
        guard elapsed < readBy else { return .read }
        guard !isAwaited(glance) else { return awaitLoad(at: elapsed) }

        hold(glance.fingerprint, at: elapsed)
        return elapsed - heldSince >= Self.restWindow ? .read : .poll(readBy - elapsed)
    }

    /// A page moves when its fingerprint changes, or when WebKit starts a
    /// navigation after the glance taken before the act's input, whether or
    /// not the page was already loading something.
    private func hasMoved(_ glance: Glance) -> Bool {
        guard let before else { return true }

        return !glance.fingerprint.isSamePage(as: before.fingerprint) || glance.navigations > before.navigations
    }

    /// A load the look waits for: still in flight, and a navigation WebKit
    /// started since the look began.
    private func isAwaited(_ glance: Glance) -> Bool {
        glance.loading && glance.navigations > baseline
    }

    private mutating func hold(_ fingerprint: BrowserPageFingerprint, at elapsed: Duration) {
        if let held, fingerprint.isSamePage(as: held) { return }

        held = fingerprint
        heldSince = elapsed
    }

    /// A navigation in flight ends whatever the page held: the rest starts
    /// again at the first glance after it, even when that document reads the
    /// same as the one it replaced.
    private mutating func awaitLoad(at elapsed: Duration) -> Step {
        held = nil
        if !loadBudgeted {
            loadBudgeted = true
            readBy = max(readBy, elapsed + Self.navigationBudget)
        }

        return .awaitLoad(readBy - elapsed)
    }
}
