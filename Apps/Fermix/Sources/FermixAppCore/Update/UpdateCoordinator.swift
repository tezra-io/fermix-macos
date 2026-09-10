import Foundation

/// The one owner of what an update is allowed to do (M34 §6, R2 and R3).
///
/// It is the `UpdateChecking` seam every surface reads, and it is the updater's
/// delegate: the adapter that owns Sparkle holds no state and decides nothing,
/// so the whole state machine is provable here without a framework, a feed, a
/// signature, or a bundle to replace.
///
/// **The split, and why it is where it is.** Everything a surface reads is
/// here, on the main actor: what a check found, what the person chose, and how
/// far the transaction has got. Everything the transaction *does* — the record,
/// the drain, the unregister, the bounded waits — is `UpdateTransaction`, which
/// is deliberately not main-actor isolated. The reason is the shape of the one
/// callback that matters: `prepareForReplacement()` is called synchronously on
/// the main actor and has to hold that frame until the engine is down, and a
/// main actor held by a synchronous frame is not re-entrant. Work on this actor
/// could never run inside that barrier. Work off it can.
///
/// **Where the transaction begins, and why it is not where the plan first said.**
/// R3 originally put the drain "inside Sparkle's postponed-relaunch window".
/// That window opens *after* the installer is armed: from the moment the update
/// is extracted a separate process watches this one's pid and completes the
/// replacement on any exit, with no further call into this process and no
/// callback that can veto it. So the person's Install choice is recorded when
/// they make it, and the transaction begins at `prepareForReplacement()` — the
/// last point guaranteed to run before arming, and the first point at which the
/// download is finished and verified. The postponement is the final commit
/// only. The nine steps are the plan's; the boundary is the one that actually
/// precedes arming.
///
/// **Serialization.** Every mutation of the background service in this app — an
/// enable, a disable, a restart, the launch reconcile, and this — takes
/// `ServiceMutationGate` first. The gate is `@MainActor`, so taking it is one
/// isolated read-and-write that cannot interleave with another. This holds the
/// gate from the extraction barrier until the transaction is rolled back or the
/// process is replaced, which is what stops a restart from re-registering the
/// agent under a bundle that is about to be swapped.
@MainActor
public final class UpdateCoordinator: UpdateChecking {
    /// Everything the transaction mutates, off this actor.
    private let transaction: UpdateTransaction
    /// Read here only, to refuse an update while an earlier record is still
    /// open. `UpdateTransaction` is the one writer of both.
    private let journal: UpdateJournal
    private let lifecycle: any DaemonLifecycleControlling
    /// The one engine comparison, asked rather than repeated.
    private let engines: EngineReconciler
    private let ownership: any DaemonOwnershipReading
    private let gate: ServiceMutationGate
    private let installedApp: AppBuild
    private let now: () -> Date
    private let log = AppLog.logger(.lifecycle)

    /// The updater behind the seam. Held for the life of this object, which is
    /// the life of the process: a scheduled check belongs to a live updater.
    private var updater: (any UpdaterDriving)?
    /// Why this bundle may not run an updater, where it may not.
    private var configuration: UpdateConfigurationRefusal?

    // MARK: - What a check found (R2)

    private var offer: UpdateOffer?
    /// The release that is installed, as the feed describes it. It is the only
    /// source of the artifact Recovery would reinstall: the app cannot read the
    /// digest of an installer it does not have.
    private var installedRelease: UpdateOffer?
    private var lastSuccessfulCheck: Date?
    private var checking = false
    private var lastCheckFailed = false

    // MARK: - The transaction (R3)

    public private(set) var transactionState: UpdateTransactionState = .idle
    /// The transaction this coordinator started, where it has started one. It
    /// is also where the staged version on the update surface comes from: a
    /// later check can replace the offer, and what is being installed cannot
    /// change with it.
    private var plan: UpdateTransactionPlan?
    /// The person chose Install (R3, step 1). Recorded where they choose and
    /// acted on at the barrier, which is the first point at which the download
    /// exists to install.
    private var consented = false
    /// The engine is proven stopped. One way: the transaction holds the gate
    /// from the barrier on, so nothing puts the engine back under it.
    private var stopProven = false
    /// The installer is armed. From `didExtractUpdate` on, any exit of this
    /// process replaces the bundle and nothing left in the protocol can veto
    /// it, so the transaction is never rolled back again and its record stays
    /// for the launch reconcile.
    private var armed = false
    /// The postponed relaunch is released exactly once. A second release is not
    /// consulted, and a later session's driver over the same staged update is a
    /// different driver, so the guard is on the transaction rather than on the
    /// callback.
    private var relaunchReleased = false
    /// The one rollback in flight, so two undo callbacks in a row do not race
    /// each other back to idle.
    private var undo: Task<Void, Never>?

    public init(
        journal: UpdateJournal,
        lifecycle: any DaemonLifecycleControlling,
        services: ServiceController,
        engines: EngineReconciler,
        probe: any UpdateEngineProbing,
        ownership: any DaemonOwnershipReading,
        gate: ServiceMutationGate,
        installedApp: AppBuild,
        sleeper: any Sleeping,
        now: @escaping () -> Date = Date.init
    ) {
        self.journal = journal
        self.lifecycle = lifecycle
        self.engines = engines
        self.ownership = ownership
        self.gate = gate
        self.installedApp = installedApp
        self.now = now
        self.transaction = UpdateTransaction(
            journal: journal,
            lifecycle: lifecycle,
            services: services,
            probe: probe,
            sleeper: sleeper
        )
    }

    // MARK: - Starting

    /// Starts the updater, once.
    ///
    /// A bundle whose declared policy is wrong runs no updater at all: the
    /// alternative is the framework's own developer-facing alert, which is a
    /// user-visible string this product did not write. The refusal is what the
    /// update surface then states.
    public func start(_ updater: any UpdaterDriving) {
        precondition(self.updater == nil, "the updater is started once")

        self.updater = updater
        configuration = updater.start(self)

        guard let refusal = configuration else { return }

        log.error("this bundle runs no updater: \(String(describing: refusal), privacy: .public)")
    }

    // MARK: - UpdateChecking

    public func availability() -> UpdateAvailability {
        // A staged update outranks everything else this could say: from here
        // the bundle is replaced when Fermix quits, and no check changes that.
        if armed, let plan { return .staged(version: plan.target.app.marketingVersion) }
        if configuration != nil { return .unconfigured }
        if checking { return .checking }
        if let offer { return .available(version: offer.app.marketingVersion, releaseClass: offer.releaseClass) }
        // A check that failed is never rendered as up to date: that is the one
        // untruth this surface exists to avoid (M34 §6, R2). The date is the
        // last check that actually succeeded, kept here rather than read from
        // the updater's own stamp, which records attempts.
        if lastCheckFailed { return .checkFailed(lastCheckedAt: lastSuccessfulCheck) }
        guard let lastSuccessfulCheck else { return .unknown }

        return .upToDate(lastCheckedAt: lastSuccessfulCheck)
    }

    public var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    public func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else {
            log.log("the updater cannot take a check right now")
            return
        }

        checking = true
        updater.checkForUpdates()
    }

    // MARK: - Discovery (R2)

    /// The gate ahead of every driver, the resumption of a staged installer
    /// included.
    ///
    /// It refuses while anything else is mutating the service, so a check
    /// cannot walk into a restart or a launch reconcile that is half-way
    /// through the registration this update would take away. A staged update
    /// is the one case that proceeds while this coordinator holds the gate:
    /// refusing it would strand an installer that is already armed.
    public func mayCheck() throws {
        if let configuration { throw UpdateRefusal.notConfigured(configuration) }
        guard let holder = gate.holder else {
            checking = true
            return
        }
        guard holder == .update, armed else {
            checking = false
            throw UpdateRefusal.busy(holder)
        }

        checking = true
    }

    /// Every entry the feed carried.
    ///
    /// The entry for the build that is installed is where the prior artifact
    /// comes from. There is no other source: the journal has to name the exact
    /// installer Recovery would offer, and a running app knows neither the url
    /// it came from nor its digest.
    public func feedLoaded(_ entries: [UpdateFeedEntry]) {
        guard let mine = UpdateFeedReading.entry(for: installedApp.buildNumber, in: entries) else {
            installedRelease = nil
            log.error("the feed describes no entry for build \(self.installedApp.buildNumber, privacy: .public)")
            return
        }

        installedRelease = try? UpdateFeedReading.offer(from: mine)
    }

    public func found(_ entry: UpdateFeedEntry) {
        offer = try? UpdateFeedReading.offer(from: entry)
        lastCheckFailed = false
    }

    public func foundNothing() {
        offer = nil
    }

    /// The one veto the updater offers before anything is downloaded, shown or
    /// staged. Everything this coordinator cannot transact is refused here,
    /// because after the person chooses Install there is no refusal left.
    public func mayProceed(with entry: UpdateFeedEntry) throws {
        do {
            offer = try proceedableOffer(entry)
        } catch {
            offer = nil
            log.error("refusing an update: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func proceedableOffer(_ entry: UpdateFeedEntry) throws -> UpdateOffer {
        if let configuration { throw UpdateRefusal.notConfigured(configuration) }
        if let holder = gate.holder { throw UpdateRefusal.busy(holder) }
        if hasOpenRecord() { throw UpdateRefusal.recoveryPending }
        if case .unowned(let status) = ownership.ownership() { throw UpdateRefusal.unownedDaemon(status) }
        guard engines.bundledBuild != nil else { throw UpdateRefusal.bundledEngineUnknown }
        guard installedRelease != nil else {
            throw UpdateRefusal.priorReleaseUnknown(build: installedApp.buildNumber)
        }

        let offer = try transactable(entry)
        guard offer.app.buildNumber > installedApp.buildNumber else {
            throw UpdateRefusal.notAnUpgrade(installed: installedApp.buildNumber, offered: offer.app.buildNumber)
        }

        return offer
    }

    private func transactable(_ entry: UpdateFeedEntry) throws -> UpdateOffer {
        do {
            return try UpdateFeedReading.offer(from: entry)
        } catch let refusal as UpdateFeedRefusal {
            throw UpdateRefusal.feed(refusal)
        }
    }

    /// Whether an earlier transaction's record is still open.
    ///
    /// A record that cannot be read counts as open: it is the one file that
    /// would say what happened, and starting over it would destroy the only
    /// evidence.
    private func hasOpenRecord() -> Bool {
        do {
            if try lifecycle.interruptedTransaction() != nil { return true }

            return try journal.load() != nil
        } catch {
            log.error("a transaction record could not be read: \(String(describing: error), privacy: .public)")
            return true
        }
    }

    /// One check ended. Only a completed cycle stamps the successful-check
    /// date, so a feed that could not be read never reports the app current.
    public func cycleFinished(_ outcome: UpdateCycleOutcome) {
        checking = false

        switch outcome {
        case .completed, .dismissed:
            lastCheckFailed = false
            lastSuccessfulCheck = now()
        case .failed(let description):
            lastCheckFailed = true
            log.error("the update check did not complete: \(description, privacy: .public)")
        }
    }

    // MARK: - The person's choice (R3, step 1)

    /// What the person answered, and how far the update had got when they did.
    ///
    /// Install is recorded and nothing else: at this point the item may not
    /// even be downloaded yet, and disabling the service while the updater
    /// fetches a DMG would take the engine away for the length of a download
    /// that can still fail. The transaction begins at the barrier instead.
    ///
    /// `(dismiss, installing)` is not a cancellation: at that stage the
    /// updater's own alert re-titles Remind Me Later as `Install on Quit`, and
    /// the app stays armed whatever the answer was.
    public func userChose(_ choice: UpdateUserChoice, stage: UpdateUserStage) {
        log.log(
            "the person chose \(choice.rawValue, privacy: .public) at stage \(stage.rawValue, privacy: .public)"
        )

        switch (choice, stage) {
        case (.install, _):
            consented = true
        case (.dismiss, .installing):
            staged()
        case (.dismiss, _), (.skip, _):
            consented = false
            rollBack()
        }
    }

    public func downloadFailed(_ description: String) {
        log.error("the update download failed: \(description, privacy: .public)")
        rollBack()
    }

    public func downloadCancelled() {
        rollBack()
    }

    /// The cycle aborted, an extraction that failed included.
    ///
    /// A staged update is not rolled back: the replacement still happens when
    /// this process exits, and putting the old engine back under a bundle that
    /// is about to be swapped is the one thing that must not happen. Anything
    /// earlier is put back, which is the whole reason the barrier does not
    /// treat itself as the point of no return.
    public func aborted(_ description: String) {
        log.error("the update cycle aborted: \(description, privacy: .public)")
        checking = false
        rollBack()
    }

    // MARK: - The barrier (R3, steps 2 to 5)

    /// The last point before the installer can arm.
    ///
    /// Synchronous, and it blocks the thread it was called on. Once it returns,
    /// a separate process is watching this one's pid and completes the
    /// replacement on any exit, so everything the transaction has to do is done
    /// here or is not done at all. The drain runs off this actor precisely so
    /// that blocking this thread cannot stop it.
    ///
    /// It starts the transaction, which covers an extraction that reached this
    /// point without a recorded Install choice: the replacement is coming
    /// either way, so the engine is stopped either way and the anomaly is
    /// reported rather than acted on.
    public func prepareForReplacement() -> UpdateBarrierOutcome {
        guard let plan = startedTransaction() else { return .noTransaction }

        let outcome = BlockingBarrier.run(
            budget: UpdatePolicy.replacementBarrier.budget,
            expired: UpdateBarrierOutcome.barrierExpired
        ) { [transaction] in
            await transaction.prepare(plan)
        }
        settle(outcome, plan.transactionId)

        return outcome
    }

    /// The update is staged: any exit of this process now replaces the bundle.
    ///
    /// Recorded as a phase rather than only in memory, because the replacement
    /// can happen with no further call into this process at all.
    public func staged() {
        armed = true

        guard let plan else {
            // Armed with nothing recorded: the replacement will happen and no
            // record names what it replaced. It is the one state the launch
            // reconcile cannot resolve, so it is reported loudly here.
            log.error("an update was staged with no transaction and no record behind it")
            return
        }

        transactionState = state(plan.transactionId)
        recordBoundary { [transaction] in await transaction.markStaged() }
    }

    /// The final commit before the postponed relaunch is released.
    ///
    /// The installer is already armed, so this proves rather than prevents: it
    /// is the last bounded chance to have the engine down before the swap.
    /// Holding the postponement instead would leave the app armed and unusable
    /// rather than safe, so the caller releases it whatever this answers.
    public func commitBeforeRelaunch() async -> UpdateBarrierOutcome {
        guard let plan else { return .noTransaction }
        guard !relaunchReleased else {
            log.log("the postponed relaunch was already released")
            return stopProven ? .ready : .engineStillRunning
        }

        relaunchReleased = true
        let outcome = await transaction.commit()
        settle(outcome, plan.transactionId)

        return outcome
    }

    /// The last in-process notification before the bundle is replaced.
    public func willRelaunch() {
        recordBoundary { [transaction] in await transaction.markVerifying() }
    }

    /// Reached only if the automatic-installation policy has been defeated: the
    /// driver that calls it is constructed only when automatic downloading is
    /// on, and `SUAllowsAutomaticUpdates` in the Info.plist forbids that
    /// permanently. Returning false does not veto it, so this records the
    /// breach rather than pretending to stop it.
    public func installOnQuitReached() {
        log.error("an install on quit was offered, so the automatic installation policy is not in force")
    }

    /// The app is quitting while a replacement is inevitable.
    ///
    /// Quitting cannot be refused into safety — the installer completes the
    /// swap on any exit, a force quit included — so the honest act is to spend
    /// one more bounded budget on stopping the engine before the process ends.
    /// Nothing is stopped for an update that is not armed: there is no
    /// replacement coming, and taking the service away on the way out would be
    /// a mutation nobody asked for.
    public func prepareForQuit() async {
        guard armed, !stopProven, let plan else { return }

        log.error("quitting with an update staged and the engine still running")
        settle(await transaction.finishOnQuit(), plan.transactionId)
    }

    // MARK: - Running the transaction

    /// Records the transaction and hands the plan over, once.
    ///
    /// Idempotent: a duplicated extraction notice reaches it and only the first
    /// call builds anything.
    private func startedTransaction() -> UpdateTransactionPlan? {
        if let plan { return plan }
        guard let offer, let prior = installedRelease?.installer else {
            log.error("no transactable update is pending, so nothing was started")
            return nil
        }
        guard let source = sourceRelease() else {
            log.error("this bundle ships no readable engine manifest, so no update can be recorded")
            return nil
        }
        guard gate.acquire(.update) else {
            log.error("another transaction holds the service, so the update was not started")
            return nil
        }
        if !consented {
            log.error("an update is being extracted with no Install choice recorded")
        }

        let started = UpdateTransactionPlan(
            transactionId: UUID(),
            source: source,
            target: offer.release,
            priorInstaller: prior,
            startedAt: now()
        )
        plan = started

        return started
    }

    /// What a barrier's answer means for the transaction.
    private func settle(_ outcome: UpdateBarrierOutcome, _ id: UUID) {
        guard outcome != .noTransaction else {
            // Nothing was recorded, so there is nothing to recover and nothing
            // for the gate to protect.
            returnToIdle()
            return
        }

        if outcome == .ready { stopProven = true }
        transactionState = state(id)
    }

    /// The two facts the transaction has, as the one state every surface and
    /// the quit gate read.
    private func state(_ id: UUID) -> UpdateTransactionState {
        guard stopProven else { return .stalled(id) }

        return armed ? .armed(id) : .ready(id)
    }

    private func sourceRelease() -> UpdateRelease? {
        guard let engine = engines.bundledBuild else { return nil }

        return UpdateRelease(app: installedApp, engine: engine)
    }

    /// Writes one record boundary before the callback that asked for it
    /// returns.
    ///
    /// From extraction on, any exit of this process replaces the bundle, so a
    /// boundary left for a task to write later is a boundary that may never be
    /// written at all. It is one local file write, held under its own small
    /// bound, and a bound that runs out is reported rather than assumed.
    private func recordBoundary(_ write: @escaping @Sendable () async -> Void) {
        let written = BlockingBarrier.run(budget: UpdatePolicy.recordBudget, expired: false) {
            await write()
            return true
        }

        guard !written else { return }

        log.error("an update record boundary did not reach the disk inside its bound")
    }

    // MARK: - Undoing it

    /// Cancel, Remind Later, Skip, a failed download and an aborted cycle all
    /// come here. Anything the transaction changed is put back; anything it
    /// never reached is left alone; a staged update is never undone.
    ///
    /// The window this exists for is the one the barrier opens: the engine is
    /// stopped and the extraction has not finished. An extraction that fails
    /// there aborts the cycle, and without this the old bundle would go on
    /// running with its engine stopped and the gate held.
    private func rollBack() {
        guard plan != nil, !armed, undo == nil else { return }

        undo = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.transaction.rollBack()
            self.returnToIdle()
        }
    }

    /// Returns to idle and hands the gate back.
    ///
    /// `armed` is not reset: it is a fact about this process rather than about
    /// the transaction, and the installer does not disarm.
    private func returnToIdle() {
        plan = nil
        consented = false
        stopProven = false
        relaunchReleased = false
        undo = nil
        transactionState = .idle

        guard gate.holder == .update else { return }

        gate.release(.update)
    }
}
